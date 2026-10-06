import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../adversarial_memory.dart';
import '../core_harness.dart';

/// A Linux trap prologue is a burst of ~36 `sd` into pt_regs followed, on the
/// way out, by ~36 `ld` back. The rc1 L1 D-cache is 256 bytes, DIRECT MAPPED,
/// with an 8-byte line, so a frame that spans more than 256 bytes evicts itself
/// while it is being written: every access is a conflict miss with a dirty
/// write-back behind it. That burst runs once per interrupt, which is why the
/// hardware time-to-failure tracks the interrupt rate.
///
/// This test reproduces that access pattern deliberately. Consecutive frame
/// slots are 256 bytes apart, so they land on the SAME cache line and each store
/// forces a write-back of the previous one. The values are only ever moved
/// between registers and the frame, never recomputed, so ONE lost store, stale
/// refill or dropped write-back leaves a register (and the frame) wrong at the
/// end.
///
/// It runs with the posted-write memory from [AdversarialMemory], because the
/// instantaneous MemoryModel the other harnesses use cannot expose a write that
/// is acknowledged before it commits.
///
/// KNOWN GAP. The frame described above never reaches the D-cache.
/// `HarborL1DCache.cacheableBase` is 0x80000000 and this program puts its frame
/// at 0x4000, so every access here takes the D-cache BYPASS path: no line is
/// ever allocated, nothing is ever evicted, and the conflict-miss pattern the
/// comment describes does not happen. What the test does cover is the store and
/// load handshake through the bypass path under posted writes and a read-latency
/// 1 register file, which is still worth having.
/// `trap_transparency_paged_cached_test.dart` puts the same access pattern above
/// the cacheable base, where the collisions are real.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig cfg({int? readLatency}) => RiverCoreConfigV1.small(
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

  const posted = AdversarialMemory(
    postedWriteCycles: 3,
    readsPassPendingWrites: true,
    seed: 11,
  );

  const mret = 0x30200073;

  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  int lui(int rd, int imm20) => ((imm20 & 0xfffff) << 12) | (rd << 7) | 0x37;
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

  // csrw mtvec,x5 is not usable here (x5 is in the save set), so the setup uses
  // x10 for every CSR write and then loads the save set.
  const iterations = 3;

  // x0 hardwired, x2 = sp, x4 = loop counter, x10 = scratch/source pointer,
  // x28 = the only register the handler touches.
  const saveSet = [
    1,
    3,
    5,
    6,
    7,
    8,
    9,
    11,
    12,
    13,
    14,
    15,
    16,
    17,
    18,
    19,
    20,
    21,
    22,
    23,
    24,
    25,
    26,
    27,
    29,
    30,
    31,
  ];

  // Frame slot for the k-th register. Consecutive slots are 256 bytes apart, so
  // they collide on the same direct-mapped line and force a write-back.
  int slot(int k) => (k ~/ 2) * 8 + (k % 2) * 256;

  // The pattern each register carries. Distinct in every byte lane so a partial
  // or mis-selected write shows up, and far from any small constant.
  int pattern(int k) => 0x5A00 + (k * 0x11) + ((k + 3) << 8);

  final body = <int>[];
  void emit(List<int> instrs) => body.addAll(instrs);

  // mtvec = 0x800, mie = MTIE, mstatus.MIE = 1, via x10.
  emit([
    addi(10, 0, 0x800),
    0x30551073, // csrw mtvec, x10
    addi(10, 0, 1 << 7),
    0x30451073, // csrw mie, x10
    addi(10, 0, 1 << 3),
    0x30052073, // csrs mstatus, x10
    lui(2, 4), // sp = 0x4000 (frame base)
    lui(10, 2), // x10 = 0x2000 (pattern source)
    addi(4, 0, iterations),
  ]);
  // Load the save set with its patterns.
  for (var k = 0; k < saveSet.length; k++) {
    emit([ld(saveSet[k], 10, k * 8)]);
  }

  final loopPc = body.length * 4;
  for (var k = 0; k < saveSet.length; k++) {
    emit([sd(saveSet[k], 2, slot(k))]);
  }
  for (var k = 0; k < saveSet.length; k++) {
    emit([ld(saveSet[k], 2, slot(k))]);
  }
  emit([addi(4, 4, -1)]);
  final bnePos = body.length;
  emit([0]);
  final parkPc = body.length * 4;
  emit([0x0000006f]); // jal x0, 0
  body[bnePos] = bne(4, 0, loopPc - bnePos * 4);

  // A long-ish handler so the mret does not land at a fixed phase of the timer
  // line, and a short assertion window so the line is low at most instruction
  // boundaries. Together they keep the take drifting without livelocking the
  // core on a level-asserted MTIP that re-fires before the interrupted
  // instruction can retire.
  final handler = <int>[addi(28, 0, 0xAB), mret];

  // The pattern source at 0x2000, one 64-bit word per save-set register.
  final source = <int>[];
  for (var k = 0; k < saveSet.length; k++) {
    source.add(pattern(k) & 0xFFFFFFFF);
    source.add(0);
  }

  String prog() => memImage({0x0: body, 0x800: handler, 0x2000: source});

  final expected = <Register, int>{
    // x28 is the handler's only scratch register, so it doubles as the positive
    // control: 0 means no interrupt was taken and the run proved nothing.
    Register.x28: 0,
    Register.x4: 0,
    Register.x2: 0x4000,
    for (var k = 0; k < saveSet.length; k++)
      Register.values.firstWhere((r) => r.value == saveSet[k]): pattern(k),
  };
  final memStates = <int, int>{
    for (var k = 0; k < saveSet.length; k++) 0x4000 + slot(k): pattern(k),
  };

  test(
    'baseline: frame burst with no interrupt',
    timeout: Timeout(Duration(minutes: 25)),
    () => coreTest(
      prog(),
      expected,
      cfg(readLatency: 1),
      memStates: memStates,
      nextPc: parkPc,
      maxCycles: 200000,
      memory: posted,
    ),
  );

  final expectedIrq = {...expected, Register.x28: 0xAB};

  for (final period in const [97, 103, 109]) {
    test(
      'frame burst with a timer IRQ every $period cycles',
      timeout: Timeout(Duration(minutes: 25)),
      () => coreTest(
        prog(),
        expectedIrq,
        cfg(readLatency: 1),
        memStates: memStates,
        nextPc: parkPc,
        maxCycles: 300000,
        memory: posted,
        timerIrqPeriod: period,
        timerIrqHigh: 3,
      ),
    );
  }
}
