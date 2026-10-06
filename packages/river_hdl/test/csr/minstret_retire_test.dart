import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// minstret must count RETIRED INSTRUCTIONS, on a real core.
///
/// It used the same unconditional per-cycle expression as mcycle, so it was a
/// second cycle counter. There was no retire signal in the CSR file at all.
/// Measured on silicon: IPC exactly 1.000000, which no microcoded core with
/// DRAM and cache misses can produce.
///
/// The program below reads both counters at two points a known number of
/// instructions apart, then computes both deltas into registers. It pins the
/// instruction delta EXACTLY, and it proves the cycle delta is larger, so a
/// counter that tracks cycles cannot pass.
RiverCoreConfig _rc1s() => RiverCoreConfigV1.small(
  mmu: HarborMmuConfig(
    mxlen: RiscVMxlen.rv64,
    pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
    hasSupervisorUserMemory: true,
    hasMakeExecutableReadable: true,
  ),
  interrupts: [],
  clock: const HarborClockConfig(
    name: 'test',
    rate: HarborFixedClockRate(12000000),
  ),
  resetVector: 0,
);

// Emit ONE contiguous block from @0, gaps filled with nop.
String _memString(Map<int, int> words) {
  const nop = 0x00000013;
  final maxAddr = words.keys.reduce((a, b) => a > b ? a : b);
  final sb = StringBuffer('@0\n');
  for (var addr = 0; addr <= maxAddr + 4; addr += 4) {
    final w = words[addr] ?? nop;
    for (var b = 0; b < 4; b++) {
      sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
  }
  return sb.toString();
}

void main() {
  test(
    'minstret counts instructions and mcycle counts more of them',
    () async {
      await Simulator.reset();
      // Six instructions retire between the two minstret reads: the two csrr
      // that take the first pair of samples, and the four nops after them.
      final program = <int, int>{
        0x00: 0xB02022f3, // csrr x5, minstret
        0x04: 0xB0002473, // csrr x8, mcycle
        0x08: 0x00000013, // nop
        0x0c: 0x00000013, // nop
        0x10: 0x00000013, // nop
        0x14: 0x00000013, // nop
        0x18: 0xB0202373, // csrr x6, minstret
        0x1c: 0xB00024f3, // csrr x9, mcycle
        0x20: 0x405303b3, // sub  x7, x6, x5   (instructions retired)
        0x24: 0x40848533, // sub  x10, x9, x8  (cycles elapsed)
        0x28: 0x00a3b633, // sltu x12, x7, x10 (instructions < cycles)
        0x2c: 0x09900593, // addi x11, x0, 0x99 (sentinel: program ran)
        0x30: 0x00000013, // nop
      };
      await coreTest(
        _memString(program),
        {Register.x7: 6, Register.x12: 1, Register.x11: 0x99},
        _rc1s(),
        nextPc: 0x34,
      );
    },
    timeout: Timeout(Duration(minutes: 5)),
  );
}
