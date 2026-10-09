import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Minimal repro of the HW illegal-trap on Linux's `_start_kernel` return
/// targets. On the delta board the rc1-f microcode core traps ILLEGAL
/// (scause 2) on the `auipc` at a jalr RETURN TARGET after a call, even though
/// auipc is a base instruction that decodes fine in straight-line code. The
/// theory: the microcode ROM scan starts from a stale counter at the redirect
/// and misses the pattern.
///
/// Program (all 32-bit, base ISA only):
///   0x00 addi x6, x0, 0x11        marker
///   0x04 auipc ra, 0              ra = 0x04
///   0x08 jalr  ra, 16(ra)         call 0x14, return addr ra = 0x0c
///   0x0c auipc a0, 0              RETURN TARGET (the suspect) -> a0 = 0x0c
///   0x10 jal   x0, 0              park
///   0x14 jalr  x0, 0(ra)          ret -> 0x0c
///
/// If the decoder is correct: a0 == 0x0c, x6 == 0x11, parks at 0x10.
/// If the redirect hazard bites: the auipc @0x0c traps and we never reach 0x10.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig full() => RiverCoreConfigV1.full(
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
  );

  RiverCoreConfig lanes1() => RiverCoreConfig(
    clock: const HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv64,
    extensions: [
      rvC,
      rvZicsr,
      rvZifencei,
      rvM,
      rvA,
      rvF,
      rvD,
      rvPriv,
      rv64i,
      rv32i,
    ],
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
    executionMode: ExecutionMode.inOrder,
    issueWidth: IssueWidth.single,
    microcodeMode: MicrocodeMode.full,
    microcodeDecodeLanes: 1,
  );

  String prog() {
    final words = <int>[
      0x01100313, // addi x6, x0, 0x11
      0x00000097, // auipc ra, 0
      0x010080e7, // jalr ra, 16(ra)
      0x00000517, // auipc a0, 0   (return target)
      0x0000006f, // jal x0, 0     (park @ 0x10)
      0x00008067, // jalr x0, 0(ra) (ret -> 0x0c)
    ];
    final sb = StringBuffer('@0\n');
    for (final w in words) {
      for (var i = 0; i < 4; i++) {
        sb.write(((w >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return '$sb\n';
  }

  test(
    'auipc at a jalr return target decodes (lanes=2)',
    timeout: Timeout(Duration(minutes: 6)),
    () => coreTest(
      prog(),
      {Register.x6: 0x11, Register.x10: 0x0c},
      full(),
      nextPc: 0x10,
    ),
  );

  test(
    'auipc at a jalr return target decodes (lanes=1)',
    timeout: Timeout(Duration(minutes: 6)),
    () => coreTest(
      prog(),
      {Register.x6: 0x11, Register.x10: 0x0c},
      lanes1(),
      nextPc: 0x10,
    ),
  );
}
