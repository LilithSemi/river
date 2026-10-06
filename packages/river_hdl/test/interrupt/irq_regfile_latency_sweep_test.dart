import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../adversarial_memory.dart';
import '../core_harness.dart';

/// Async-interrupt transparency on the SILICON shape of rc1-f.
///
/// Every interrupt test in this repo runs the core with a latency-0 register
/// file behind an instantaneous, perfectly ordered memory. The delta board runs
/// rc1-f on openXC7, where HarborRegisterFile picks the Xilinx RAMB36E1
/// backend: read latency 1, so the operand read is a PIPELINE, not a wire. The
/// memory behind it is fabric plus a clock-domain FIFO plus a DDR3 controller,
/// which posts writes. Both differences sit on the interrupt-take path, so a
/// hole there is invisible to the existing tests.
///
/// Building this core costs far more than running it, so the sweep is done
/// INSIDE one simulation: the program loops, and the machine timer line pulses
/// on a period that does not divide the loop, which walks the take across every
/// phase of the stream. The interrupt must be transparent: the handler touches
/// one scratch register, so every other register and every stored word must
/// match the interrupt-free result.
///
/// KNOWN GAP. The program sits at low addresses (code at 0, data at 0x2000,
/// stack at 0x1000) and `HarborL1DCache.cacheableBase` is 0x80000000, so every
/// data access takes the D-cache BYPASS path. This sweep covers the register
/// read pipeline, the interrupt take and the posted-write memory, but it does
/// not put a single line in the D-cache.
/// `trap_transparency_paged_cached_test.dart` covers the cached and translated
/// shape.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // rc1-f is the delta core. rc1-s is the same scalar personality and the same
  // microcode datapath without F/D, and it simulates several times faster, so
  // the fine sweep runs on it and rc1-f confirms the result.
  RiverCoreConfig cfgSmall({int? readLatency}) => RiverCoreConfigV1.small(
    interrupts: [],
    regfileReadLatency: readLatency,
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    clock: const HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
  );

  RiverCoreConfig cfgFull({int? readLatency}) => RiverCoreConfigV1.full(
    interrupts: [],
    regfileReadLatency: readLatency,
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    clock: const HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
  );

  // A memory that acknowledges a write before it commits, the way the DDR3
  // path does, and that answers reads late and unevenly.
  const posted = AdversarialMemory(
    postedWriteCycles: 3,
    readsPassPendingWrites: true,
    seed: 7,
  );

  const mret = 0x30200073;

  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  int add(int rd, int rs1, int rs2) =>
      (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33;
  int ld(int rd, int rs1, int imm) =>
      ((imm & 0xfff) << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x03;
  int sd(int rs2, int rs1, int imm) =>
      (((imm >> 5) & 0x7f) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (3 << 12) |
      ((imm & 0x1f) << 7) |
      0x23;
  int lui(int rd, int imm20) => ((imm20 & 0xfffff) << 12) | (rd << 7) | 0x37;
  int amoaddD(int rd, int rs2, int rs1) =>
      (rs2 << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x2F;
  int branch(int f3, int rs1, int rs2, int imm) =>
      (((imm >> 12) & 1) << 31) |
      (((imm >> 5) & 0x3f) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (f3 << 12) |
      (((imm >> 1) & 0xf) << 8) |
      (((imm >> 11) & 1) << 7) |
      0x63;
  int bne(int rs1, int rs2, int imm) => branch(1, rs1, rs2, imm);
  int jal(int rd, int imm) =>
      (((imm >> 20) & 1) << 31) |
      (((imm >> 1) & 0x3ff) << 21) |
      (((imm >> 11) & 1) << 20) |
      (((imm >> 12) & 0xff) << 12) |
      (rd << 7) |
      0x6f;

  String mem(Map<int, List<int>> words) {
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

  // csrw mtvec,x5 ; csrw mie,x6 ; csrs mstatus,x7
  const setup = [0x30529073, 0x30431073, 0x3003a073];
  // A handler that touches ONE register (x7, free once the setup has used it)
  // and returns. x7 doubles as the positive control: if it still holds its
  // setup value at the end, no interrupt was ever taken and the run proved
  // nothing. A long-ish body plus a short assertion window keeps the mret from
  // landing at a fixed phase of the timer line, so the take drifts instead of
  // re-firing before the interrupted instruction can retire.
  const handlerMark = 0xAB;
  final handler = <int>[addi(7, 0, handlerMark), mret];

  // Loop trip counts. Long enough for the drifting timer phase to land the take
  // on every cycle of the body several times over.
  const nA = 6;
  const nB = 6;

  // ===== the program ========================================================
  // x5 mtvec, x6 mie, x7 mstatus bit, x10 data pointer, x31 = 1, x2 = sp.
  //
  // Loop A is a read-modify-write chain through a POINTER register plus an AMO:
  // it reads back everything it stores and branches to ERR on any mismatch, so
  // a lost or duplicated store, or a clobbered pointer, is caught in the
  // iteration it happens rather than only at the end.
  //
  // Loop B is a trap-prologue burst through sp. exec.dart keeps a SHADOW copy
  // of x2 (`currentSp`/`nextSp`): a ReadRegister micro-op that resolves to x2
  // takes the shadow instead of the register file, and core.dart commits
  // `sp < pipeline.nextSp` on EVERY retire, a trap included. If an interrupt
  // splits an x2 update the shadow and the register file disagree, and the
  // shadow is what the next instruction reads. sp not returning home is the
  // symptom.
  final body = <int>[];
  void emit(List<int> instrs) => body.addAll(instrs);

  emit(setup);
  emit([lui(2, 1), addi(28, 0, nA), addi(29, 0, 0)]);
  final loopA = body.length * 4;
  emit([
    ld(18, 10, 0), // x18 = counter
    addi(19, 18, 1),
    sd(19, 10, 0),
    ld(20, 10, 0), // read back
  ]);
  final bneA0 = body.length; // patched below
  emit([0]);
  emit([
    addi(21, 19, 0x10),
    addi(22, 21, 0x20),
    add(23, 21, 22),
    sd(23, 10, 8),
    ld(24, 10, 8),
  ]);
  final bneA1 = body.length;
  emit([0]);
  emit([
    addi(26, 10, 16),
    amoaddD(25, 31, 26), // mem[ptr+16] += 1, x25 = old
    addi(28, 28, -1),
  ]);
  final bneA2 = body.length;
  emit([0]);

  emit([addi(28, 0, nB)]);
  final loopB = body.length * 4;
  emit([
    addi(2, 2, -32),
    sd(18, 2, 0),
    sd(19, 2, 8),
    sd(20, 2, 16),
    ld(18, 2, 0),
    ld(19, 2, 8),
    ld(20, 2, 16),
    addi(2, 2, 32),
    addi(28, 28, -1),
  ]);
  final bneB = body.length;
  emit([0]);
  final jumpOverErr = body.length;
  emit([0]);
  final errPc = body.length * 4;
  emit([addi(29, 29, 1)]); // ERR falls through into PARK
  final parkPc = body.length * 4;
  emit([jal(0, 0)]);

  body[bneA0] = bne(20, 19, errPc - bneA0 * 4);
  body[bneA1] = bne(24, 23, errPc - bneA1 * 4);
  body[bneA2] = bne(28, 0, loopA - bneA2 * 4);
  body[bneB] = bne(28, 0, loopB - bneB * 4);
  body[jumpOverErr] = jal(0, parkPc - jumpOverErr * 4);

  String prog() => mem({0x0: body, 0x300: handler});

  final init = {
    Register.x5: 0x300,
    Register.x6: 1 << 7, // MTIE
    Register.x7: 1 << 3, // MIE
    Register.x10: 0x2000,
    Register.x31: 1,
  };

  // Interrupt-free result of the program above.
  final expected = {
    Register.x7: 1 << 3, // untouched: no interrupt was taken
    Register.x29: 0, // no read-back mismatch
    Register.x28: 0, // both loops ran to completion
    Register.x2: 0x1000, // sp came home
    Register.x10: 0x2000, // the pointer survived
    Register.x31: 1,
    Register.x18: nA - 1,
    Register.x19: nA,
    Register.x20: nA,
    Register.x21: nA + 0x10,
    Register.x22: nA + 0x30,
    Register.x23: 2 * nA + 0x40,
    Register.x24: 2 * nA + 0x40,
    Register.x25: nA - 1, // last AMO old value
    Register.x26: 0x2010,
  };
  // With interrupts, everything above must still hold, and x7 must carry the
  // handler's mark, which proves at least one interrupt was actually taken.
  final expectedIrq = {...expected, Register.x7: handlerMark};
  final memStates = {
    0x2000: nA,
    0x2008: 2 * nA + 0x40,
    0x2010: nA,
    // The stack frame the last loop-B iteration wrote.
    0x0fe0: nA - 1,
    0x0fe8: nA,
    0x0ff0: nA,
  };

  // Baseline: the same program with no interrupt at all. If this fails the
  // program, not the interrupt, is wrong.
  for (final entry in <String, RiverCoreConfig Function()>{
    'rc1-s latency 1': () => cfgSmall(readLatency: 1),
    'rc1-s latency 0': () => cfgSmall(),
  }.entries) {
    test(
      'baseline: no interrupt (${entry.key})',
      timeout: Timeout(Duration(minutes: 20)),
      () => coreTest(
        prog(),
        expected,
        entry.value(),
        initRegisters: init,
        memStates: memStates,
        nextPc: parkPc,
        maxCycles: 40000,
        memory: posted,
      ),
    );
  }

  // The sweep. Each period walks the take across a different set of phases of
  // the loop body, so one simulation covers many take offsets.
  //
  // The period must EXCEED the handler round trip. mip.MTIP is a level, and the
  // handler here cannot clear it the way a real timer handler clears mtimecmp,
  // so a period shorter than the round trip finds the line still high at the
  // mret and re-enters without ever retiring the interrupted instruction. The
  // periods below are all longer than the round trip and mutually coprime, so
  // the take drifts across the whole loop body instead of locking to one phase.
  for (final period in const [97, 101, 103, 107, 109, 113]) {
    test(
      'rc1-s latency 1: timer IRQ every $period cycles is transparent',
      timeout: Timeout(Duration(minutes: 20)),
      () => coreTest(
        prog(),
        expectedIrq,
        cfgSmall(readLatency: 1),
        initRegisters: init,
        memStates: memStates,
        nextPc: parkPc,
        maxCycles: 80000,
        memory: posted,
        timerIrqPeriod: period,
        timerIrqHigh: 3,
      ),
    );
  }

  // The same stream with the latency-0 register file every other interrupt test
  // uses, so a failure can be attributed to the read pipeline.
  for (final period in const [97, 109]) {
    test(
      'rc1-s latency 0: timer IRQ every $period cycles is transparent',
      timeout: Timeout(Duration(minutes: 20)),
      () => coreTest(
        prog(),
        expectedIrq,
        cfgSmall(),
        initRegisters: init,
        memStates: memStates,
        nextPc: parkPc,
        maxCycles: 80000,
        memory: posted,
        timerIrqPeriod: period,
        timerIrqHigh: 3,
      ),
    );
  }

  // The delta core itself, on the two periods that stress the take hardest.
  for (final period in const [101]) {
    test(
      'rc1-f latency 1: timer IRQ every $period cycles is transparent',
      timeout: Timeout(Duration(minutes: 40)),
      () => coreTest(
        prog(),
        expectedIrq,
        cfgFull(readLatency: 1),
        initRegisters: init,
        memStates: memStates,
        nextPc: parkPc,
        maxCycles: 80000,
        memory: posted,
        timerIrqPeriod: period,
        timerIrqHigh: 3,
      ),
    );
  }
}
