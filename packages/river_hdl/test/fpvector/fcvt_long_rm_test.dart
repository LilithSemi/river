import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// A reserved rounding mode must make the 64-bit integer converts illegal.
///
/// `roundedFunctions` gates that check, and the four `fcvt` forms that move
/// between a float and a 64-bit integer were missing from it, so they accepted
/// a static rm of 5 or 6 and an invalid frm under DYN. They do round: float to
/// int64 takes its direction from rm, and int64 exceeds both significands.
RiverCoreConfig config(MicrocodeMode mode) => RiverCoreConfig(
  mxlen: RiscVMxlen.rv64,
  extensions: [rvZicsr, rvZifencei, rvM, rvF, rvD, rvPriv, rv64i, rv32i],
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
int fcvt(int funct7, int rm) =>
    (funct7 << 25) | (2 << 20) | (1 << 15) | (rm << 12) | (3 << 7) | 0x53;

const luiX7Two = 0x000023B7; // lui x7, 2 -> mstatus.FS = Initial
const fldF1 = 0x0000B087; // fld f1, 0(x1)
const jalPastHandler = 0x0200006F; // jal x0, +0x20, from 0x48 to 0x68
const jalLoop = 0x0000006F;
const nop = 0x00000013;
const ranSentinel = 0x7B;

/// 1.0 as binary64 at 0x200, the operand fld reads into f1.
const operand = '@200\n00 00 00 00 00 00 f0 3f\n';

const mstatusCsr = 0x300;
const frmCsr = 0x002;
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

/// Enables FP, optionally programs [frm], then runs [victim] at 0x40.
///
/// A trap vectors to 0x60 and reports mcause. If the convert instead runs, the
/// next instructions mark x8 and jump past the handler, so a legal execution
/// and a trap cannot look alike.
String program(int victim, {int? frm}) => words([
  luiX7Two, // 0x00
  csrw(mstatusCsr, 7), // 0x04, FS = Initial
  addi(13, 0, 0x60), // 0x08
  csrw(mtvecCsr, 13), // 0x0C, mtvec = 0x60
  addi(1, 0, 0x200), // 0x10
  fldF1, // 0x14, f1 = memory[0x200]
  if (frm != null) ...[
    addi(14, 0, frm), // 0x18
    csrw(frmCsr, 14), // 0x1C
  ] else ...[
    nop,
    nop,
  ],
  nop, nop, nop, nop, nop, nop, nop, nop, // 0x20..0x3C
  victim, // 0x40
  addi(8, 0, ranSentinel), // 0x44, only reached if the victim ran
  jalPastHandler, // 0x48
  nop, nop, nop, nop, nop, // 0x4C..0x5C
  csrr(mcauseCsr, 5), // 0x60, x5 = mcause
  jalLoop, // 0x64
  nop, // 0x68
]);

void main() {
  tearDown(() async => Simulator.reset());

  // funct7 for the four float <-> int64 converts (rs2 = 2 selects the L form).
  const longConverts = {
    'fcvt.l.s': 0x60,
    'fcvt.s.l': 0x68,
    'fcvt.l.d': 0x61,
    'fcvt.d.l': 0x69,
  };

  void cases(MicrocodeMode mode, Map<String, int> ops) {
    for (final op in ops.entries) {
      test(
        '${op.key} with a reserved static rm traps illegal (${mode.name})',
        timeout: const Timeout(Duration(minutes: 10)),
        () => coreTest(
          '@0\n${program(fcvt(op.value, 5))}\n$operand',
          {Register.x5: 2, Register.x8: 0},
          config(mode),
          nextPc: 0x64,
          maxCycles: 4000,
        ),
      );

      test(
        '${op.key} with DYN and an invalid frm traps illegal (${mode.name})',
        timeout: const Timeout(Duration(minutes: 10)),
        () => coreTest(
          '@0\n${program(fcvt(op.value, 7), frm: 5)}\n$operand',
          {Register.x5: 2, Register.x8: 0},
          config(mode),
          nextPc: 0x64,
          maxCycles: 4000,
        ),
      );

      // Control: RNE is legal, so the convert must run and reach the sentinel.
      test(
        '${op.key} with rm=RNE runs (${mode.name})',
        timeout: const Timeout(Duration(minutes: 10)),
        () => coreTest(
          '@0\n${program(fcvt(op.value, 0))}\n$operand',
          {Register.x8: ranSentinel, Register.x5: 0},
          config(mode),
          nextPc: 0x68,
          maxCycles: 4000,
        ),
      );
    }
  }

  cases(MicrocodeMode.none, longConverts);
  // The check lives in the shared execution-unit base, so one op is enough to
  // confirm the microcoded unit inherits it.
  cases(MicrocodeMode.full, {'fcvt.l.d': 0x61});
}
