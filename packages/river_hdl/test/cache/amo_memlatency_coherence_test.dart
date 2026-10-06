import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// The amoadd loop through the real D-cache, but with MEMORY LATENCY.
///
/// [amoadd_loop_coherence_test] and [amoadd_paged_coherence_test] drive the same
/// loop at `memLatency: 0`. On delta every D-cache miss goes to DDR and takes
/// many cycles. HarborL1DCache is write-through / no-write-allocate: a store
/// writes to memory and invalidates the resident line, gated on
/// `storeInv = committedHitOf(reqAddr)` (l1_cache.dart). The race that the
/// invalidate can lose is a store whose hit-check runs while a fill for the same
/// line is still in flight. That window only opens when the fill takes more than
/// one cycle, so a zero-latency test cannot reach it.
///
/// Each case runs N amoadd.w on ONE cached address and requires the final value
/// to be exactly N. A lost read-after-write gives less than N.
///
///   x5 = 0x80001000 (target), x7 = 1 (increment), x8 = N (count)
///   loop: amoadd.w.aqrl x6, x7, (x5)   ; mem[x5] += 1, x6 = old
///         addi x8, x8, -1
///         bnez x8, loop
///         jal  x0, 0                    ; park
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const n = 12;

  // amoadd.w.aqrl x6,x7,(x5): opcode 0x2f, f3=2, funct7=0x03 (aq=rl=1),
  // rs2=7, rs1=5, rd=6.
  const amoaddAqrl =
      (0x03 << 25) | (7 << 20) | (5 << 15) | (2 << 12) | (6 << 7) | 0x2f;

  String program() {
    final words = <int, int>{
      0x00: 0x00100393, // addi x7, x0, 1
      0x04: (n << 20) | (0 << 15) | (0 << 12) | (8 << 7) | 0x13, // addi x8,x0,N
      0x08: amoaddAqrl, // loop
      0x0c: 0xfff40413, // addi x8, x8, -1
      0x10: 0xfe041ce3, // bnez x8, -8
      0x14: 0x0000006f, // jal x0, 0 (park)
    };
    final sb = StringBuffer('@0\n');
    final maxA = words.keys.reduce((a, b) => a > b ? a : b);
    for (var addr = 0; addr <= maxA + 4; addr += 4) {
      final w = words[addr] ?? 0x00000013;
      for (var b = 0; b < 4; b++) {
        sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return sb.toString();
  }

  for (final memLatency in [1, 2, 4, 8]) {
    test(
      'amoadd.w.aqrl loop keeps every increment at memLatency=$memLatency',
      timeout: Timeout(Duration(minutes: 15)),
      () async {
        await coreTest(
          program(),
          {
            Register.x6: n - 1, // the last amoadd returns the previous value
            Register.x8: 0,
          },
          RiverCoreConfigV1.full(
            interrupts: [],
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
          ),
          initRegisters: {Register.x5: 0x80001000},
          memStates: {0x80001000: n},
          memLatency: memLatency,
          nextPc: 0x14,
        );
      },
    );
  }
}
