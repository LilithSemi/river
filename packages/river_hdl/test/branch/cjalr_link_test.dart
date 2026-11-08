import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Regression for the rc1-s (creek microcode) core computing the JAL/JALR LINK
/// address from a fixed +4 instead of the actual instruction length. On RV64
/// the only compressed call is `c.jalr` (there is no `c.jal`), so a +4 link is
/// invisible to direct-call-heavy code and only bites function-pointer/vtable
/// dispatch: the callee returns two bytes too far, into the middle of the next
/// instruction. This is exactly the trap storm Ferrite hits on its first
/// `std.Io.Writer` `drain` call (sepc = call+4, not call+2).
///
/// `c.jalr rs1` must set ra (x1) = PC + 2 (the address of the instruction right
/// after the 2-byte `c.jalr`), and jump to rs1. A full-width `jalr`/`jal` must
/// set ra = PC + 4. The two lengths share the microcode link path; this pins
/// the compressed case with an ABSOLUTE expectation (not an emulator-golden
/// compare, which would pass if the emulator shares the bug).
HarborMmuConfig _mmu() => HarborMmuConfig(
  mxlen: RiscVMxlen.rv64,
  pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
  tlbLevels: const [],
  pmp: HarborPmpConfig.none,
  hasSupervisorUserMemory: true,
  hasMakeExecutableReadable: true,
);

const _clk = HarborClockConfig(
  name: 'test',
  rate: HarborFixedClockRate(12000000),
);

RiverCoreConfig _rc1s() => RiverCoreConfigV1.small(
  mmu: _mmu(),
  interrupts: [],
  clock: _clk,
  resetVector: 0,
);

// rc1-ma: the OoO/dual-issue macro tier. fu_branch.dart hardcodes the link as
// PC+4 too, so this is expected to share the c.jalr link bug (follow-up).
RiverCoreConfig _rc1ma() =>
    RiverCoreConfigV1.macro(mmu: _mmu(), interrupts: [], clock: _clk);

String _memString(List<int> words) {
  final sb = StringBuffer('@0\n');
  for (final w in words) {
    for (var b = 0; b < 4; b++) {
      sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
  }
  return '${sb.toString().trimRight()}\n';
}

// Program (RV64, reset vector 0). c.jalr sits at 0x8 (2 bytes), so a correct
// link is ra = 0xa; a +4-length bug yields ra = 0xc. The jump TARGET (0x10) is
// correct either way, so the program terminates at nextPc = 0x14 regardless and
// we read ra back to judge the link.
//   0:  auipc x5, 0x0        x5 = 0                 0x00000297
//   4:  addi  x5, x5, 0x10   x5 = 0x10 (target)     0x01028293
//   8:  c.jalr x5            ra = 0xa; pc = 0x10     0x9282  (low half @8)
//   a:  c.nop                                        0x0001  (high half @a)
//   c:  nop                  (jumped over)           0x00000013
//   10: addi  x6, x0, 0x99   x6 = 0x99 (target ran)  0x09900313
//   14: nop  (halt here)                             0x00000013
const _program = <int>[
  0x00000297,
  0x01028293,
  0x00019282, // low: c.jalr x5 @0x8 ; high: c.nop @0xa
  0x00000013,
  0x09900313,
  0x00000013,
];

Future<void> _runLinkTest(RiverCoreConfig config) async {
  await Simulator.reset();
  await coreTest(
    _memString(_program),
    {
      // x6 proves the jump target (0x10) was reached at all.
      Register.x6: 0x99,
      // The claim under test: ra = address after the 2-byte c.jalr = 0xa.
      // With the +4 link bug this is 0xc and the test fails.
      Register.x1: 0xa,
    },
    config,
    nextPc: 0x14,
  );
}

void main() {
  test('c.jalr link address is PC+2, not PC+4 (rc1-s microcode)', () async {
    await _runLinkTest(_rc1s());
  }, timeout: Timeout(Duration(minutes: 5)));

  test('c.jalr link address is PC+2, not PC+4 (rc1-ma OoO)', () async {
    await _runLinkTest(_rc1ma());
  }, timeout: Timeout(Duration(minutes: 5)));
}
