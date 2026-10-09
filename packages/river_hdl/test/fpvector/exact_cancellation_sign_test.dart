import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// IEEE 754 2019 section 6.3: when adding two operands of opposite sign, or
/// subtracting two of like sign, and the exact result is zero, the result is
/// +0 under every rounding direction except roundTowardNegative.
///
/// River picks the result sign from the larger operand, and on an exact
/// cancellation the magnitudes are equal, so it can return -0 instead.
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
int addi(int rd, int rs1, int imm) =>
    ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13;

const luiX7Two = 0x000023B7; // lui x7, 2 -> mstatus.FS = Initial
const fldF1 = 0x0000B087; // fld f1, 0(x1)
const fldF2 = 0x0080B107; // fld f2, 8(x1)
const faddD = 0x022081D3; // fadd.d f3, f1, f2 (rm = RNE)
const fsubD = 0x0A2081D3; // fsub.d f3, f1, f2 (rm = RNE)
const fmvXD = 0xE2018553; // fmv.x.d x10, f3
const jalLoop = 0x0000006F;

const mstatusCsr = 0x300;

const posOne = 0x3FF0000000000000;
const negOne = 0xBFF0000000000000;

String bytes8(int v) => [
  for (var b = 0; b < 8; b++)
    ((v >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'),
].join(' ');

String words(List<int> ws) => ws
    .expand(
      (w) => [
        for (var b = 0; b < 4; b++)
          ((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'),
      ],
    )
    .join(' ');

/// Computes [op] on the two operands at 0x200 and moves the result to x10, so
/// the sign bit of an exact zero is directly observable.
String program(int op, int a, int b) =>
    '@0\n${words([luiX7Two, csrw(mstatusCsr, 7), addi(1, 0, 0x200), fldF1, fldF2, op, fmvXD, jalLoop])}\n@200\n${bytes8(a)} ${bytes8(b)}\n';

void main() {
  tearDown(() async => Simulator.reset());

  // name, instruction, operand a, operand b. Every exact result here is zero.
  const scenarios = [
    ('fadd.d -1.0 + 1.0', faddD, negOne, posOne),
    ('fadd.d 1.0 + -1.0', faddD, posOne, negOne),
    ('fsub.d 1.0 - 1.0', fsubD, posOne, posOne),
    ('fsub.d -1.0 - -1.0', fsubD, negOne, negOne),
  ];

  for (final mode in [MicrocodeMode.none, MicrocodeMode.full]) {
    for (final s in scenarios) {
      test(
        '${s.$1} gives +0 (${mode.name})',
        timeout: const Timeout(Duration(minutes: 10)),
        () => coreTest(
          program(s.$2, s.$3, s.$4),
          // +0 is all zero bits. -0 would read back as the sign bit alone.
          {Register.x10: 0},
          config(mode),
          nextPc: 0x1C,
          maxCycles: 4000,
        ),
      );
    }
  }
}
