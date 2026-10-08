import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Privileged operations must trap when the current mode is too low.
///
/// Harbor gives each operation a `privilegeLevel` (3 for mret, 1 for the
/// supervisor ops). River read it only to pick the mode to return TO, so
/// U-mode ran mret, sret and sfence.vma instead of raising illegal.
RiverCoreConfig config(MicrocodeMode mode) => RiverCoreConfig(
  mxlen: RiscVMxlen.rv64,
  extensions: [rvC, rvZicsr, rvZifencei, rvM, rvA, rvPriv, rv64i, rv32i],
  type: RiverCoreType.general,
  executionMode: ExecutionMode.inOrder,
  microcodeMode: mode,
  mmu: HarborMmuConfig(
    mxlen: RiscVMxlen.rv64,
    pagingModes: const [RiscVPagingMode.bare],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
  ),
  interrupts: [],
  clock: const HarborClockConfig(
    name: 'test',
    rate: HarborFixedClockRate(10000),
  ),
);

int csrw(int csr, int rs1) => (csr << 20) | (rs1 << 15) | (0x1 << 12) | 0x73;
int csrr(int csr, int rd) => (csr << 20) | (0x2 << 12) | (rd << 7) | 0x73;
int addi(int rd, int rs1, int imm) =>
    ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13;

const mret = 0x30200073;
const sret = 0x10200073;
const sfenceVma = 0x12000073;
const jalLoop = 0x0000006F;
const nop = 0x00000013;

String words(List<int> ws) => ws
    .expand(
      (w) => [
        for (var b = 0; b < 4; b++)
          ((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'),
      ],
    )
    .join(' ');

/// Drops to U-mode at 0x20, runs [victim] there, and parks the trap handler at
/// 0x40 so it can report mcause and mepc.
String program(int victim) => words([
  addi(14, 0, 0x20),
  csrw(0x341, 14), // mepc = 0x20
  csrw(0x300, 0), // mstatus = 0, so MPP selects U
  addi(13, 0, 0x40),
  csrw(0x305, 13), // mtvec = 0x40
  mret, // 0x14, enters U-mode at 0x20
  nop,
  nop,
  victim, // 0x20
  nop,
  nop,
  nop,
  nop,
  nop,
  nop,
  nop,
  csrr(0x342, 5), // 0x40, x5 = mcause
  csrr(0x341, 6), // 0x44, x6 = mepc
  jalLoop, // 0x48
]);

void main() {
  tearDown(() async => Simulator.reset());

  const victims = {'mret': mret, 'sret': sret, 'sfence.vma': sfenceVma};

  for (final mode in [MicrocodeMode.none, MicrocodeMode.full]) {
    for (final victim in victims.entries) {
      test(
        'U-mode ${victim.key} traps illegal (${mode.name})',
        timeout: const Timeout(Duration(minutes: 10)),
        () => coreTest(
          '@0\n${program(victim.value)}\n',
          // cause 2 is illegal instruction, and mepc is the faulting PC.
          {Register.x5: 2, Register.x6: 0x20},
          config(mode),
          nextPc: 0x48,
          maxCycles: 4000,
        ),
      );
    }
  }
}
