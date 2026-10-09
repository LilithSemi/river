import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Repro: on real hardware the rc1-f microcode core trapped ILLEGAL (mcause 2)
/// on `c.addi16sp` (0x7179) at a NixOS EFI entry point. c.addi16sp is a valid
/// RVC instruction, so a trap/mis-decode is a core bug. This runs it in sim to
/// see whether it reproduces deterministically (decode bug) or not (the HW trap
/// was the intermittent timing effect, which sim cannot show).
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // rc1-f, RV64GC microcode, lanes=2 (the shipping config).
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

  // Same, but force the classic 1-lane decode scan, to isolate whether the
  // 2-lane packed decode is the culprit.
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

  int iimm(int imm, int rs1, int f3, int rd) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;

  // Program (mixed 16/32-bit):
  //   @0x00  addi sp, x0, 0x400     (set sp the real way, mirrors to nextSp)
  //   @0x04  c.addi16sp sp, -48     (0x7179, the faulting instruction)
  //   @0x06  addi x5, sp, 0         (capture the result of the c.addi16sp)
  //   @0x0a  jal x0, 0              (park)
  // Expect: sp = 0x400 - 48 = 0x3D0, and x5 == 0x3D0.
  String prog() {
    final bytes = <int>[];
    void emit32(int w) {
      for (var i = 0; i < 4; i++) {
        bytes.add((w >> (i * 8)) & 0xFF);
      }
    }

    void emit16(int h) {
      bytes.add(h & 0xFF);
      bytes.add((h >> 8) & 0xFF);
    }

    emit32(iimm(0x400, 0, 0x0, 2)); // addi sp, x0, 0x400
    emit16(0x7179); // c.addi16sp sp, -48
    emit32(iimm(0, 2, 0x0, 5)); // addi x5, sp, 0
    emit32(0x0000006f); // jal x0, 0 (park @ 0x0a)

    final sb = StringBuffer('@0\n');
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
    return '$sb\n';
  }

  test(
    'c.addi16sp executes on rc1-f (lanes=2) - x5 == sp-48',
    timeout: Timeout(Duration(minutes: 6)),
    () => coreTest(
      prog(),
      {Register.x5: 0x3D0, Register.x2: 0x3D0},
      full(),
      nextPc: 0x0a,
    ),
  );

  test(
    'c.addi16sp executes on rc1-f (lanes=1) - x5 == sp-48',
    timeout: Timeout(Duration(minutes: 6)),
    () => coreTest(
      prog(),
      {Register.x5: 0x3D0, Register.x2: 0x3D0},
      lanes1(),
      nextPc: 0x0a,
    ),
  );
}
