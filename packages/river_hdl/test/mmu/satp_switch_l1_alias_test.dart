import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../adversarial_memory.dart';
import '../core_harness.dart';

/// Does a `satp` write really separate two address spaces in the L1 caches?
///
/// Both L1s sit in FRONT of the MMU, so they are virtually indexed AND
/// virtually tagged. Linux switches `satp` on every context switch and, once
/// its ASID allocator is on, it does NOT follow the write with an `sfence.vma`.
/// The core answers the write by pulsing the same `fence` net that carries
/// `fence.i` and `sfence.vma`, which drives `icFlush`, `dFlush` and
/// `mmuTlbFlush` (core.dart:1584-1586, exec.dart:3727 and 6170).
///
/// Every simulation ever run on this core used ONE address space. These tests
/// use two: the SAME virtual address maps to DIFFERENT physical pages under
/// two `satp` values, so a stale L1 line or a stale MMU TLB entry returns the
/// other address space's data and the test says so by name.
///
/// WHY THE CACHES ARE LIVE HERE. `cacheableBase` is 0x80000000
/// (harbor l1_cache.dart), and the D-cache is 256 B, direct mapped, 8-byte
/// lines, so with xlen 64: byteBits 3, offBits 0, idxBits 5, index = VA[7:3],
/// tag = VA[38:8] plus the 2-bit privilege context.
///
///   shared VA 0xC0002000 -> index (0xC0002000 >> 3) & 0x1F = 0
///   alias  VA 0x40002000 -> index (0x40002000 >> 3) & 0x1F = 0
///
/// The shared VA is at or above `cacheableBase`, so it takes the CACHED path.
/// The alias VA is below it, so its store is a write-through that does not
/// allocate and, because `storeInv` is gated on `cacheableOf(reqAddr)`, does
/// not invalidate the shared VA's line either. That is what makes the
/// cache-live control below work: the alias store changes the physical word
/// under the shared VA without touching the cache.
///
/// The first test carries its own proof that the D-cache was serving hits, so
/// it cannot pass vacuously through the bypass path.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const base = 0x80000000;
  const mainPc = base;
  const handlerPc = base + 0x800;
  const rootA = base + 0x1000; // page table of address space A
  const rootB = base + 0x2000; // page table of address space B
  const rootC = base + 0x3000; // a third space, used by the trap handler
  const witness = base + 0x4000; // machine-mode (untranslated) witness word

  const satpA = 0x8000000000000000 | (rootA >> 12);
  const satpB = 0x8000000000000000 | (rootB >> 12);
  const satpC = 0x8000000000000000 | (rootC >> 12);

  // The shared virtual address. Region 3 (VA[38:30] == 3) is mapped to a
  // DIFFERENT 1 GB physical megapage by each root table.
  const sharedVa = 0xC0002000; // D-cache index 0, cacheable
  const aliasVa = 0x40002000; // region 1, identity, same physical word as A
  const paA = 0x40002000; // what sharedVa names in space A
  const paB = 0xC0002000; // what sharedVa names in space B

  // Bit 63 stays clear in every data value: the harness compares
  // `LogicValue.toInt()` against a Dart int.
  const valueA = 0x0A0A0A0A11111111;
  const valueB = 0x0B0B0B0B22222222;
  const poison = 0x0C0C0C0C33333333;
  const witnessValue = 0x0D0D0D0D44444444;

  // Sv39 1 GB leaf: V|R|W|X|A|D with U clear, a supervisor page. A and D are
  // pre-set so no hardware writeback adds bus traffic.
  int megapage(int pa) => ((pa >> 12) << 10) | 0xCF;

  // Root table shared by every space for regions 0, 1 and 2 (identity), with
  // region 3 pointing wherever the space wants.
  List<int> rootTable(int region3Pa) => [
    for (final pa in [0x00000000, 0x40000000, 0x80000000, region3Pa]) ...[
      megapage(pa),
      0,
    ],
  ];

  RiverCoreConfig cfg() => RiverCoreConfigV1.full(
    resetVector: base,
    interrupts: [],
    // The Xilinx RAMB36E1 shape the delta bitstream carries.
    regfileReadLatency: 1,
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

  // A memory that acknowledges a write three cycles before it commits, the
  // shape the DDR write path presents.
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
  const mret = 0x30200073;

  const csrMstatus = 0x300;
  const csrMie = 0x304;
  const csrMtvec = 0x305;
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

  /// A 64-bit value as the two 32-bit words the image format wants.
  List<int> word64(int v) => [v & 0xFFFFFFFF, (v >> 32) & 0xFFFFFFFF];

  // =========================================================================
  // 1. The straight question: same VA, two address spaces, no sfence.vma.
  // =========================================================================
  //
  //   csrw satp,x29     space A: sharedVa -> paA (valueA)
  //   ld   x5,0(x20)    fills D-cache line 0 with tag(sharedVa, S-mode)
  //   sd   x21,0(x22)   poison paA through the UNCACHEABLE alias VA. The line
  //                     for sharedVa is untouched (different tag, and the
  //                     store does not invalidate an uncacheable address).
  //   ld   x6,0(x20)    CACHE-LIVE CONTROL: still valueA means the D-cache
  //                     answered from its line and did not go to memory.
  //   csrw satp,x30     space B: sharedVa -> paB (valueB)
  //   ld   x7,0(x20)    must be valueB. valueA here is a STALE LINE.
  //   csrw satp,x29     back to space A
  //   ld   x28,0(x20)   must be the poison now in paA, never valueB.
  final aliasBody = <int>[
    csrrw(0, csrSatp, 29),
    ld(5, 20, 0),
    sd(21, 22, 0),
    ld(6, 20, 0),
    csrrw(0, csrSatp, 30),
    ld(7, 20, 0),
    csrrw(0, csrSatp, 29),
    ld(28, 20, 0),
    jal(0, 0),
  ];
  final aliasPark = mainPc + (aliasBody.length - 1) * 4;

  final aliasImage = memImage({
    mainPc: aliasBody,
    rootA: rootTable(0x40000000),
    rootB: rootTable(0xC0000000),
    paA: word64(valueA),
    paB: word64(valueB),
  });

  test(
    'satp switch: the same VA must not hit the old address space D-cache line',
    timeout: const Timeout(Duration(minutes: 30)),
    () => coreTest(
      aliasImage,
      {
        // The cache-live control comes FIRST: if x6 is not valueA the D-cache
        // never held the line and nothing below this line means anything.
        Register.x6: valueA,
        Register.x5: valueA,
        Register.x7: valueB,
        Register.x28: poison,
      },
      cfg(),
      initRegisters: {
        Register.x20: sharedVa,
        Register.x21: poison,
        Register.x22: aliasVa,
        Register.x29: satpA,
        Register.x30: satpB,
      },
      startPriv: PrivilegeMode.supervisor,
      nextPc: aliasPark,
      maxCycles: 200000,
      memory: posted,
    ),
  );

  // =========================================================================
  // 2. The same switch in a loop, with a machine-mode trap handler that
  //    ITSELF writes satp, and a timer interrupt that walks across every
  //    phase of the loop.
  // =========================================================================
  //
  // This is the Linux shape: supervisor code switching address spaces, with
  // traps taken into a different privilege that also touches satp. The
  // D-cache context tag is the privilege (core.dart:440-450), so the handler's
  // machine-mode lines and the loop's supervisor lines carry different tags
  // and only the flush separates the two SUPERVISOR spaces.
  const iterations = 6;

  final setup = <int>[
    csrrw(0, csrMtvec, 24),
    // stvec too: if the machine timer is delegated the trap targets stvec, and
    // an unset stvec sends it to address 0 instead of the handler.
    csrrw(0, csrStvec, 24),
    csrrw(0, csrMepc, 25),
    addi(3, 0, 1 << 7), // MTIE
    csrrw(0, csrMie, 3),
    // Read mie back. Without the enable no interrupt can fire and the run
    // proves nothing, so make that a named failure.
    csrrs(28, csrMie, 0),
    addi(3, 0, 0x445),
    slli(3, 3, 1), // 0x88A = MPP(supervisor) | MPIE | MIE | SIE
    csrrs(0, csrMstatus, 3),
    mret, // -> supervisor at loopPc, paging off until the first satp write
  ];
  final loopPc = mainPc + setup.length * 4;

  final loop = <int>[];
  void emitLoop(List<int> instrs) => loop.addAll(instrs);
  final loopPatches = <int>[];

  emitLoop([
    csrrw(0, csrSatp, 29), // space A
    ld(5, 20, 0),
  ]);
  loopPatches.add(loop.length);
  emitLoop([0]); // bne x5, x9, ERR
  emitLoop([
    csrrw(0, csrSatp, 30), // space B, same VA, different page
    ld(6, 20, 0),
  ]);
  loopPatches.add(loop.length);
  emitLoop([0]); // bne x6, x10, ERR
  emitLoop([addi(4, 4, -1)]);
  final backEdge = loop.length;
  emitLoop([0]); // bne x4, x0, LOOP
  final jumpOverErr = loop.length;
  emitLoop([0]); // jal PARK
  final errPc = loopPc + loop.length * 4;
  emitLoop([addi(22, 22, 1)]); // ERR falls through into PARK
  final parkPc = loopPc + loop.length * 4;
  emitLoop([jal(0, 0)]);

  loop[loopPatches[0]] = bne(5, 9, errPc - (loopPc + loopPatches[0] * 4));
  loop[loopPatches[1]] = bne(6, 10, errPc - (loopPc + loopPatches[1] * 4));
  loop[backEdge] = bne(4, 0, loopPc - (loopPc + backEdge * 4));
  loop[jumpOverErr] = jal(0, parkPc - (loopPc + jumpOverErr * 4));

  // Machine-mode handler. It saves satp, installs a THIRD address space,
  // does a cached machine-mode load, restores satp and returns. Both satp
  // writes flush the L1s and the MMU TLBs under the interrupted supervisor
  // code, which must not notice.
  //
  // The handler's load is machine mode, so it is NOT translated: it reads the
  // witness word physically. Its D-cache line carries context 3 (machine)
  // while the loop's lines carry context 1 (supervisor).
  final handler = <int>[
    csrrs(8, csrSatp, 0), // save the interrupted satp
    csrrw(0, csrSatp, 31), // space C
    ld(26, 23, 0), // cached machine-mode load
    csrrw(0, csrSatp, 8), // restore
    addi(27, 0, 0xAB), // marker, the positive control for the interrupt
    mret,
  ];

  final loopImage = memImage({
    mainPc: setup,
    loopPc: loop,
    handlerPc: handler,
    rootA: rootTable(0x40000000),
    rootB: rootTable(0xC0000000),
    rootC: rootTable(0x00000000),
    paA: word64(valueA),
    paB: word64(valueB),
    witness: word64(witnessValue),
  });

  final loopInit = {
    Register.x4: iterations,
    Register.x9: valueA,
    Register.x10: valueB,
    Register.x20: sharedVa,
    Register.x23: witness,
    Register.x24: handlerPc,
    Register.x25: loopPc,
    Register.x29: satpA,
    Register.x30: satpB,
    Register.x31: satpC,
  };

  final loopExpected = <Register, int>{
    // Setup witness first, so a broken interrupt setup names itself.
    Register.x28: 1 << 7, // mie.MTIE stuck
    Register.x22: 0, // no address-space mismatch
    Register.x4: 0, // the loop ran to completion
    Register.x5: valueA,
    Register.x6: valueB,
    Register.x27: 0, // no interrupt in the baseline
  };

  test(
    'baseline: a satp switch loop reads the right address space every time',
    timeout: const Timeout(Duration(minutes: 30)),
    () => coreTest(
      loopImage,
      loopExpected,
      cfg(),
      initRegisters: loopInit,
      nextPc: parkPc,
      maxCycles: 400000,
      memory: posted,
    ),
  );

  // The periods are mutually coprime with the loop length, so the take drifts
  // across every instruction of the body instead of locking to one phase. The
  // line is held high for 40 cycles: an interrupt is taken only at
  // mopStep == 0, which is ONE cycle of an instruction, and an instruction
  // here costs an Sv39 walk plus an L1 miss plus a posted write.
  for (final period in const [401, 509, 601, 701]) {
    test(
      'timer IRQ every $period cycles cannot expose the other address space',
      timeout: const Timeout(Duration(minutes: 30)),
      () => coreTest(
        loopImage,
        {
          ...loopExpected,
          // x27 is the handler's only marker, so it is the positive control:
          // 0 means no interrupt was taken and the run proved nothing.
          Register.x27: 0xAB,
          Register.x26: witnessValue,
        },
        cfg(),
        initRegisters: loopInit,
        nextPc: parkPc,
        maxCycles: 400000,
        memory: posted,
        timerIrqPeriod: period,
        timerIrqHigh: 40,
      ),
    );
  }

  // =========================================================================
  // 3. The fetch side: the same VA must EXECUTE the new address space's
  //    instructions after a satp write.
  // =========================================================================
  //
  // This covers the I-cache flush AND the MMU fetch TLB together. A stale
  // I-cache line and a stale fetch TLB entry both show up the same way: the
  // routine at the shared VA runs the OLD address space's code.
  //
  // I-cache line arithmetic (64 B, direct mapped, 8-byte lines, xlen 64):
  // byteBits 3, offBits 0, idxBits 3, index = VA[5:3].
  //
  //   routine VA 0xC0001000 -> index (0xC0001000 >> 3) & 7 = 0
  //   caller  VA 0x80000000 and 0x80000004 -> index 0
  //   caller  VA 0x80000008 .. 0x8000000C  -> index 1
  //   caller  VA 0x80000010 .. 0x80000014  -> index 2
  //
  // So the routine occupies line 0, and the caller instructions that run
  // BETWEEN the two calls sit on lines 1 and 2 and cannot evict it. The
  // routine's line therefore reaches the satp write intact, which is what
  // gives the flush something to drop.
  const routineVa = 0xC0001000;
  const routinePaA = 0x40001000;
  const routinePaB = 0xC0001000;

  int jalr(int rd, int rs1, int imm) =>
      ((imm & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x67;

  final fetchBody = <int>[
    csrrw(0, csrSatp, 29), // space A
    jalr(1, 19, 0), // call the routine at the shared VA
    addi(6, 5, 0), // keep the space A answer
    csrrw(0, csrSatp, 30), // space B, same VA, different physical page
    jalr(1, 19, 0), // call it again
    addi(7, 5, 0), // keep the space B answer
    jal(0, 0),
  ];
  final fetchPark = mainPc + (fetchBody.length - 1) * 4;

  final fetchImage = memImage({
    mainPc: fetchBody,
    rootA: rootTable(0x40000000),
    rootB: rootTable(0xC0000000),
    routinePaA: [addi(5, 0, 0x11), jalr(0, 1, 0)],
    routinePaB: [addi(5, 0, 0x22), jalr(0, 1, 0)],
  });

  test(
    'satp switch: the same VA must not fetch the old address space code',
    timeout: const Timeout(Duration(minutes: 30)),
    () => coreTest(
      fetchImage,
      {
        // x6 is the positive control: without it the routine never ran in
        // space A and there was no line for the flush to drop.
        Register.x6: 0x11,
        Register.x7: 0x22,
      },
      cfg(),
      initRegisters: {
        Register.x19: routineVa,
        Register.x29: satpA,
        Register.x30: satpB,
      },
      startPriv: PrivilegeMode.supervisor,
      nextPc: fetchPark,
      maxCycles: 200000,
      memory: posted,
    ),
  );
}
