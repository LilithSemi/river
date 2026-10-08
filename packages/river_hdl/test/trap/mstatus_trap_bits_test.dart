import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// mstatus TSR, TVM and TW let M-mode trap supervisor operations that the
/// privilege level alone permits. Every case here runs the victim in S-mode,
/// where privilege already allows it, so only the trap bit can reject it.
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
int csrs(int csr, int rs1) => (csr << 20) | (rs1 << 15) | (0x2 << 12) | 0x73;
int addi(int rd, int rs1, int imm) =>
    ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
int slli(int rd, int rs1, int shamt) =>
    (shamt << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x13;

const sret = 0x10200073;
const sfenceVma = 0x12000073;
const wfi = 0x10500073;
const mret = 0x30200073;
const jalPastHandler = 0x0200006F; // jal x0, +0x20, from 0x48 to 0x68
const jalLoop = 0x0000006F;
const nop = 0x00000013;
const ranSentinel = 0x7B;
const csrrSatp = 0x180024F3; // csrr x9, satp

const mstatusCsr = 0x300;
const mepcCsr = 0x341;
const mcauseCsr = 0x342;
const mtvecCsr = 0x305;

String words(List<int> ws) => ws
    .expand(
      (w) => [
        for (var b = 0; b < 4; b++)
          ((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'),
      ],
    )
    .join(' ');

/// Enters S-mode at 0x40 with [trapBit] of mstatus set and runs [victim] there.
///
/// A trap vectors to the handler at 0x60, which runs in M-mode and may read
/// mcause. If the victim instead runs, the next instructions mark x8 and jump
/// PAST the handler, because an S-mode read of mcause would itself be illegal
/// and would otherwise look exactly like the victim trapping.
String program(int victim, int? trapBit) => words([
  csrw(mstatusCsr, 0), // 0x00, clear, MPP starts at U
  addi(14, 0, 1), // 0x04
  slli(14, 14, 11), // 0x08, bit 11 selects MPP = S
  csrs(mstatusCsr, 14), // 0x0C
  if (trapBit != null) ...[
    addi(15, 0, 1), // 0x10
    slli(15, 15, trapBit), // 0x14
    csrs(mstatusCsr, 15), // 0x18
  ] else ...[
    nop,
    nop,
    nop,
  ],
  addi(14, 0, 0x40), // 0x1C
  csrw(mepcCsr, 14), // 0x20, mepc = 0x40
  addi(13, 0, 0x60), // 0x24
  csrw(mtvecCsr, 13), // 0x28, mtvec = 0x60
  mret, // 0x2C, enters S-mode at 0x40
  nop, nop, nop, nop, // 0x30..0x3C
  victim, // 0x40
  addi(8, 0, ranSentinel), // 0x44, only reached if the victim ran
  jalPastHandler, // 0x48, skip the M-mode handler
  nop, nop, nop, nop, nop, // 0x4C..0x5C
  csrr(mcauseCsr, 5), // 0x60, handler, x5 = mcause
  csrr(mepcCsr, 6), // 0x64, x6 = mepc
  jalLoop, // 0x68
]);

void main() {
  tearDown(() async => Simulator.reset());

  // Victim, and the mstatus bit that must reject it in S-mode.
  const traps = {
    'sret under TSR': (victim: sret, bit: 22),
    'sfence.vma under TVM': (victim: sfenceVma, bit: 20),
    'wfi under TW': (victim: wfi, bit: 21),
    'satp read under TVM': (victim: csrrSatp, bit: 20),
  };

  // The same victims with the trap bit clear. Each is legal in S-mode and must
  // run, which is what separates a real reject from a blanket one. River treats
  // wfi as a nop hint, so it retires rather than waiting.
  const controls = {'sfence.vma': sfenceVma, 'wfi': wfi, 'satp read': csrrSatp};

  for (final mode in [MicrocodeMode.none, MicrocodeMode.full]) {
    for (final entry in traps.entries) {
      test(
        'S-mode ${entry.key} traps illegal (${mode.name})',
        timeout: const Timeout(Duration(minutes: 10)),
        () => coreTest(
          '@0\n${program(entry.value.victim, entry.value.bit)}\n',
          // mepc pins the trap to the victim, and x8 proves it never ran.
          {Register.x5: 2, Register.x6: 0x40, Register.x8: 0},
          config(mode),
          nextPc: 0x68,
          maxCycles: 4000,
        ),
      );
    }

    for (final entry in controls.entries) {
      test(
        'S-mode ${entry.key} runs with its trap bit clear (${mode.name})',
        timeout: const Timeout(Duration(minutes: 10)),
        () => coreTest(
          '@0\n${program(entry.value, null)}\n',
          {Register.x8: ranSentinel, Register.x5: 0},
          config(mode),
          nextPc: 0x68,
          maxCycles: 4000,
        ),
      );
    }
  }
}
