import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// mcycle / minstret must actually count.
///
/// CounterCsr was declared readOnly. rohd_hcl runs every backdoor write value
/// through Csr.getWriteData, which for a readOnly register returns the current
/// value and drops the new data. So the per-cycle hardware increment (the
/// backdoor write in RiscVCsrFile._wireCounters) was discarded and mcycle and
/// minstret stayed at their reset value 0. Linux read rdcycle (emulated from
/// mcycle by Weir) for its ChaCha CSPRNG and spun forever on a stuck counter.
///
/// This reads each counter twice, a few cycles apart, and proves the second
/// read is strictly greater. On the stuck core both reads are 0 and each sltu
/// yields 0, so the test fails before the fix and passes after it.
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
  test('mcycle and minstret advance (not stuck at 0)', () async {
    await Simulator.reset();
    // All reads happen in M-mode (reset privilege), where both 0xB00 and
    // 0xB02 are legal.
    final program = <int, int>{
      0x00: 0xB00022f3, // csrr x5, mcycle
      0x04: 0xB0202473, // csrr x8, minstret
      0x08: 0x00000013, // nop
      0x0c: 0x00000013, // nop
      0x10: 0xB0002373, // csrr x6, mcycle
      0x14: 0xB02024f3, // csrr x9, minstret
      0x18: 0x0062b3b3, // sltu x7, x5, x6    (mcycle later > earlier)
      0x1c: 0x00943533, // sltu x10, x8, x9   (minstret later > earlier)
      0x20: 0x09900593, // addi x11, x0, 0x99 (sentinel: program ran)
      0x24: 0x00000013, // nop
    };
    await coreTest(
      _memString(program),
      {Register.x7: 1, Register.x10: 1, Register.x11: 0x99},
      _rc1s(),
      nextPc: 0x28,
    );
  }, timeout: Timeout(Duration(minutes: 5)));
}
