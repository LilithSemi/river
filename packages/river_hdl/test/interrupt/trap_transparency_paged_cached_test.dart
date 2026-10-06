import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../adversarial_memory.dart';
import '../core_harness.dart';

/// Trap transparency on the FULL silicon shape of the delta core.
///
/// The two interrupt tests that came closest to this shape each drop something:
///
///  * `irq_regfile_latency_sweep_test` and `trap_frame_burst_test` run at
///    `regfileReadLatency: 1` with posted writes, but in BARE mode, and their
///    programs sit at addresses below 0x80000000. `cacheableBase` is
///    0x80000000, so every one of their data accesses BYPASSES the D-cache:
///    the "256-byte direct-mapped cache thrash" those files describe never
///    reaches the cache at all.
///  * Their handlers touch ONE register. A Linux trap prologue swaps the stack
///    pointer through a scratch CSR, saves a register set, runs, restores it and
///    returns. That is the sequence the hardware fails inside.
///
/// This file puts all of it together:
///
///  * Sv39 translation, with the interrupted code in SUPERVISOR mode and the
///    handler in MACHINE mode, which is the Linux-under-Weir split.
///  * Program and data above `cacheableBase`, so both L1 caches are live. The
///    frame slots are 256 bytes apart, so they collide on ONE line of the
///    256-byte direct-mapped D-cache and every access is a conflict miss with a
///    dirty write-back behind it. The handler frame collides with the main
///    frame on the same line.
///  * `regfileReadLatency: 1`, the Xilinx RAMB36E1 shape.
///  * A memory that acknowledges a write three cycles before it commits.
///  * A handler that swaps sp through mscratch (`csrrw sp, mscratch, sp`),
///    saves four registers, CLOBBERS them, restores them and returns. The
///    interrupted stream reads back every value it stores, so a lost store, a
///    stale refill, a clobbered pointer or a desynced sp shadow is caught in the
///    iteration where it happens.
///
/// The interrupt must be transparent: only x27 (the handler's marker) may
/// differ from the interrupt-free run.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const base = 0x80000000;
  const mainPc = base + 0x100;
  const handlerPc = base + 0x800;
  const rootTable = base + 0x1000;
  const patternSrc = base + 0x2000;
  const amoAddr = base + 0x3000;
  const stackTop = base + 0x4000;
  const frameBase = base + 0x5000;
  const handlerFrame = base + 0x6000;

  const satpValue = 0x8000000000000000 | (rootTable >> 12);

  // Sv39 leaf PTE for the 1GB megapage at [pa]: V|R|W|X|A|D, A and D pre-set so
  // no hardware A/D writeback adds bus traffic.
  int megapage(int pa) => ((pa >> 12) << 10) | 0xCF;

  RiverCoreConfig cfg({int? readLatency}) => RiverCoreConfigV1.small(
    resetVector: base,
    interrupts: [],
    regfileReadLatency: readLatency,
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
      hasSupervisorUserMemory: true,
      hasMakeExecutableReadable: true,
    ),
    clock: const HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
  );

  const posted = AdversarialMemory(
    postedWriteCycles: 3,
    readsPassPendingWrites: true,
    seed: 13,
  );

  // ===== encoders ==========================================================
  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  int slli(int rd, int rs1, int sh) =>
      ((sh & 0x3f) << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x13;
  int ld(int rd, int rs1, int imm) =>
      ((imm & 0xfff) << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x03;
  int sd(int rs2, int rs1, int imm) =>
      (((imm >> 5) & 0x7f) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (3 << 12) |
      ((imm & 0x1f) << 7) |
      0x23;
  int bne(int rs1, int rs2, int imm) =>
      (((imm >> 12) & 1) << 31) |
      (((imm >> 5) & 0x3f) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (1 << 12) |
      (((imm >> 1) & 0xf) << 8) |
      (((imm >> 11) & 1) << 7) |
      0x63;
  int jal(int rd, int imm) =>
      (((imm >> 20) & 1) << 31) |
      (((imm >> 1) & 0x3ff) << 21) |
      (((imm >> 11) & 1) << 20) |
      (((imm >> 12) & 0xff) << 12) |
      (rd << 7) |
      0x6f;
  int csrrw(int rd, int csr, int rs1) =>
      (csr << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x73;
  int csrrs(int rd, int csr, int rs1) =>
      (csr << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x73;
  int srli(int rd, int rs1, int sh) =>
      ((sh & 0x3f) << 20) | (rs1 << 15) | (5 << 12) | (rd << 7) | 0x13;
  int andi(int rd, int rs1, int imm) =>
      ((imm & 0xfff) << 20) | (rs1 << 15) | (7 << 12) | (rd << 7) | 0x13;
  int amoaddD(int rd, int rs2, int rs1) =>
      (rs2 << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x2F;
  const mret = 0x30200073;
  const sfenceVma = 0x12000073;

  const csrMstatus = 0x300;
  const csrMie = 0x304;
  const csrMtvec = 0x305;
  const csrMscratch = 0x340;
  const csrMepc = 0x341;
  const csrStvec = 0x105;
  const csrSatp = 0x180;

  String memImage(Map<int, List<int>> words) {
    final sb = StringBuffer();
    final addrs = words.keys.toList()..sort();
    for (final a in addrs) {
      sb.writeln('@${a.toRadixString(16)}');
      for (final w in words[a]!) {
        for (var i = 0; i < 4; i++) {
          sb.write(((w >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }
      sb.writeln();
    }
    return sb.toString();
  }

  // ===== the register plan =================================================
  // Seeded (backdoor) before the run. x2 (sp) is NOT seeded: the sp SHADOW in
  // exec.dart is not reachable through the register write port, so sp must be
  // set by a real instruction or the shadow starts at 0 and every stack access
  // goes to the wrong address for a reason that is not a core bug.
  //   x24 sp value   x3 frame base   x9 pattern source   x14 AMO address
  //   x31 handler stack   x29 satp   x30 mtvec   x28 mepc (the S-mode entry)
  //
  // The save set the loop carries. x1, x5, x6 and x7 are also the four the
  // HANDLER clobbers and restores, so they only survive if the trap prologue
  // and epilogue are both correct.
  const saveSet = [1, 5, 6, 7, 10, 11, 12, 13];

  // Distinct in every byte lane, non-zero in the upper word so a 32-bit-only
  // write shows up, and far from any small constant.
  int pattern(int k) => ((0x1234 + k) << 32) | (0x5A5A0000 + k * 0x1111);

  // Frame slot for the k-th register. 256 bytes apart, so all eight collide on
  // one line of the 256-byte direct-mapped D-cache.
  int slot(int k) => k * 256;

  const iterations = 3;

  // ===== machine-mode setup at `base` ======================================
  final setup = <int>[
    csrrw(0, csrSatp, 29), // satp = Sv39 identity map
    sfenceVma,
    csrrw(0, csrMtvec, 30), // mtvec = handler
    // stvec too. If the machine timer is delegated the trap targets stvec, and
    // an unset stvec sends it to address 0 instead of the handler.
    csrrw(0, csrStvec, 30),
    csrrw(0, csrMscratch, 31), // mscratch = handler stack
    addi(2, 24, 0), // sp, through WriteRegister so the shadow follows
    addi(8, 0, 1 << 7), // MTIE
    csrrw(0, csrMie, 8),
    // Read mie back. If the machine timer-enable bit did not stick, no
    // interrupt can ever fire and the run proves nothing, so make that a named
    // failure instead of a silent one.
    csrrs(26, csrMie, 0),
    csrrw(0, csrMepc, 28), // mepc = the supervisor entry
    addi(8, 0, 0x445),
    slli(8, 8, 1), // 0x88A = MPP(S) | MPIE | MIE | SIE
    csrrs(0, csrMstatus, 8),
    // Read mstatus.MPP back before the mret consumes it, for the same reason.
    csrrs(25, csrMstatus, 0),
    srli(25, 25, 11),
    andi(25, 25, 3),
    mret, // -> supervisor, paging on
  ];

  // ===== supervisor-mode body at `mainPc` ==================================
  final body = <int>[];
  void emit(List<int> instrs) => body.addAll(instrs);

  for (var k = 0; k < saveSet.length; k++) {
    emit([ld(saveSet[k], 9, k * 8)]);
  }
  emit([
    addi(15, 0, 1), // AMO addend
    addi(22, 0, 0), // error counter
    addi(4, 0, iterations),
  ]);

  final loopPc = mainPc + body.length * 4;
  final errPatches = <int>[];

  for (var k = 0; k < saveSet.length; k++) {
    emit([sd(saveSet[k], 3, slot(k))]);
  }
  for (var k = 0; k < saveSet.length; k++) {
    emit([ld(8, 3, slot(k))]);
    errPatches.add(body.length);
    emit([0]); // bne x8, reg, ERR
  }
  // A stack push and pop through sp itself, so the sp shadow is on the hook.
  emit([addi(2, 2, -16), sd(10, 2, 0), sd(11, 2, 8), ld(8, 2, 0)]);
  final errSp0 = body.length;
  emit([0]);
  emit([ld(8, 2, 8)]);
  final errSp1 = body.length;
  emit([0]);
  emit([
    addi(2, 2, 16),
    amoaddD(16, 15, 14), // mem[amoAddr] += 1, x16 = old
    addi(4, 4, -1),
  ]);
  final bneLoop = body.length;
  emit([0]);
  // sp as the DATAPATH sees it. core.regs holds the register-file copy, so a
  // desynced shadow is invisible in a plain x2 check; this moves it.
  emit([addi(17, 2, 0)]);
  final jumpOverErr = body.length;
  emit([0]);
  final errPc = mainPc + body.length * 4;
  emit([addi(22, 22, 1)]); // ERR falls through into PARK
  final parkPc = mainPc + body.length * 4;
  emit([jal(0, 0)]);

  for (var k = 0; k < errPatches.length; k++) {
    final at = errPatches[k];
    body[at] = bne(8, saveSet[k], errPc - (mainPc + at * 4));
  }
  body[errSp0] = bne(8, 10, errPc - (mainPc + errSp0 * 4));
  body[errSp1] = bne(8, 11, errPc - (mainPc + errSp1 * 4));
  body[bneLoop] = bne(4, 0, loopPc - (mainPc + bneLoop * 4));
  body[jumpOverErr] = jal(0, parkPc - (mainPc + jumpOverErr * 4));

  // ===== machine-mode handler at `handlerPc` ===============================
  // The Linux shape: swap sp through a scratch CSR, save, clobber, restore,
  // swap back, return. The handler frame collides with the main frame on the
  // same D-cache line.
  final handler = <int>[
    csrrw(2, csrMscratch, 2), // sp <-> handler stack
    sd(1, 2, 0),
    sd(5, 2, 256),
    sd(6, 2, 512),
    sd(7, 2, 768),
    addi(1, 0, 0x111),
    addi(5, 0, 0x222),
    addi(6, 0, 0x333),
    addi(7, 0, 0x444),
    ld(1, 2, 0),
    ld(5, 2, 256),
    ld(6, 2, 512),
    ld(7, 2, 768),
    csrrw(2, csrMscratch, 2), // sp <-> back
    addi(27, 0, 0xAB), // the marker, and the positive control
    mret,
  ];

  final source = <int>[];
  for (var k = 0; k < saveSet.length; k++) {
    final p = pattern(k);
    source.add(p & 0xFFFFFFFF);
    source.add((p >> 32) & 0xFFFFFFFF);
  }

  String prog() => memImage({
    base: setup,
    mainPc: body,
    handlerPc: handler,
    rootTable: [
      for (var i = 0; i < 4; i++) ...[megapage(i << 30), 0],
    ],
    patternSrc: source,
    amoAddr: [0, 0],
  });

  final init = {
    Register.x3: frameBase,
    Register.x9: patternSrc,
    Register.x14: amoAddr,
    Register.x24: stackTop,
    Register.x28: mainPc,
    Register.x29: satpValue,
    Register.x30: handlerPc,
    Register.x31: handlerFrame,
  };

  final expected = <Register, int>{
    // Setup witnesses, checked FIRST so a broken interrupt setup names itself
    // instead of showing up as "no interrupt was taken".
    Register.x26: 1 << 7, // mie.MTIE stuck
    Register.x25: 1, // mstatus.MPP == supervisor before the mret
    Register.x22: 0, // no read-back mismatch
    Register.x4: 0, // the loop ran to completion
    Register.x2: stackTop, // sp came home (register-file copy)
    Register.x17: stackTop, // sp came home (shadow, read by an instruction)
    Register.x16: iterations - 1, // last AMO old value
    Register.x3: frameBase, // the pointers survived
    Register.x9: patternSrc,
    Register.x14: amoAddr,
    // x27 is the handler's only marker, so it is the positive control: 0 means
    // no interrupt was taken and the run proved nothing.
    Register.x27: 0,
    for (var k = 0; k < saveSet.length; k++)
      Register.values.firstWhere((r) => r.value == saveSet[k]): pattern(k),
  };

  final memStates = <int, int>{
    for (var k = 0; k < saveSet.length; k++) frameBase + slot(k): pattern(k),
    amoAddr: iterations,
    stackTop - 16: pattern(4), // x10
    stackTop - 8: pattern(5), // x11
  };

  test(
    'baseline: no interrupt (Sv39 + L1 + readLatency 1 + posted writes)',
    timeout: Timeout(Duration(minutes: 30)),
    () => coreTest(
      prog(),
      expected,
      cfg(readLatency: 1),
      initRegisters: init,
      memStates: memStates,
      nextPc: parkPc,
      maxCycles: 400000,
      memory: posted,
    ),
  );

  final expectedIrq = {...expected, Register.x27: 0xAB};

  // The periods are mutually coprime, so the take drifts across the whole loop
  // body instead of locking to one phase.
  //
  // The line is held high for 40 cycles, not the 3 the bare-mode interrupt tests
  // use. An interrupt is taken only at mopStep == 0, which is ONE cycle of an
  // instruction, and an instruction here costs far more than in bare mode: every
  // access is an Sv39 translation plus an L1 conflict miss plus a posted write.
  // A 3-cycle line therefore almost never coincides with an instruction boundary
  // and the run takes no interrupt at all, which the x27 control then reports.
  // 40 cycles out of 401 is 10 percent, still far shorter than the handler round
  // trip, so the line is always low again by the mret and the handler cannot
  // re-enter without the interrupted instruction retiring.
  for (final period in const [401, 509, 601, 701]) {
    test(
      'timer IRQ every $period cycles is transparent through the prologue',
      timeout: Timeout(Duration(minutes: 30)),
      () => coreTest(
        prog(),
        expectedIrq,
        cfg(readLatency: 1),
        initRegisters: init,
        memStates: memStates,
        nextPc: parkPc,
        maxCycles: 200000,
        memory: posted,
        timerIrqPeriod: period,
        timerIrqHigh: 40,
      ),
    );
  }

  // The same stream at readLatency 0, so a failure above can be attributed to
  // the register-file read pipeline rather than to the trap path.
  for (final period in const [401, 601]) {
    test(
      'readLatency 0: timer IRQ every $period cycles is transparent',
      timeout: Timeout(Duration(minutes: 30)),
      () => coreTest(
        prog(),
        expectedIrq,
        cfg(),
        initRegisters: init,
        memStates: memStates,
        nextPc: parkPc,
        maxCycles: 200000,
        memory: posted,
        timerIrqPeriod: period,
        timerIrqHigh: 40,
      ),
    );
  }
}
