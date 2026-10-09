import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// An FP op River has no datapath for must raise an illegal instruction.
///
/// Harbor gives the Zfa ops real functs, so a config carrying rvZfa decodes
/// them. Before this, executing one wedged the sequencer: the program simply
/// never finished, which reads as a hang rather than a fault. Trapping turns
/// the gap into a diagnosable exception and keeps the gap visible.
RiverCoreConfig config(MicrocodeMode mode) => RiverCoreConfig(
  mxlen: RiscVMxlen.rv64,
  extensions: [rvZicsr, rvZifencei, rvM, rvF, rvD, rvZfa, rvPriv, rv64i, rv32i],
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

int fp(int funct7, int funct3) =>
    (funct7 << 25) | (2 << 20) | (1 << 15) | (funct3 << 12) | (3 << 7) | 0x53;

const luiX7Two = 0x000023B7; // lui x7, 2 -> mstatus.FS = Initial
const csrwMstatusX7 = 0x30039073; // csrw mstatus, x7
const addiX13Vec = 0x06000693; // addi x13, x0, 0x60
const csrwMtvecX13 = 0x30569073; // csrw mtvec, x13
const addiX1Data = 0x20000093; // addi x1, x0, 0x200
const fldF1 = 0x0000B087; // fld f1, 0(x1)
const fldF2 = 0x0080B107; // fld f2, 8(x1)
const addiX8Sentinel = 0x07B00413; // addi x8, x0, 0x7B
const jalPastHandler = 0x0440006F; // jal x0, +0x44, from 0x24 to 0x68
const csrrX5Mcause = 0x342022F3;
const csrrX6Mepc = 0x34102373;
const jalLoop = 0x0000006F;
const nop = 0x00000013;
const ranSentinel = 0x7B;

const twoPoint0 = 0x4000000000000000;
const onePoint0 = 0x3FF0000000000000;

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

/// Runs [victim] at 0x1C with f1 = 2.0 and f2 = 1.0. A trap vectors to the
/// handler at 0x60; if the op instead executes, x8 is marked and the jump skips
/// the handler, so the two outcomes cannot alias.
String program(int victim) =>
    '@0\n${words([
      luiX7Two, // 0x00
      csrwMstatusX7, // 0x04
      addiX13Vec, // 0x08
      csrwMtvecX13, // 0x0C, mtvec = 0x60
      addiX1Data, // 0x10
      fldF1, // 0x14
      fldF2, // 0x18
      victim, // 0x1C
      addiX8Sentinel, // 0x20, only if the victim ran
      jalPastHandler, // 0x24
      nop, nop, nop, nop, nop, nop, nop, nop, nop, nop, nop, nop, nop,
      nop, // 0x28..0x5C
      csrrX5Mcause, // 0x60
      csrrX6Mepc, // 0x64
      jalLoop, // 0x68
    ])}\n@200\n${bytes8(twoPoint0)} ${bytes8(onePoint0)}\n';

void main() {
  tearDown(() async => Simulator.reset());

  // funct7/funct3 for Zfa ops River does not implement.
  const unimplemented = {
    'fminm.d': (0x15, 0x2),
    'fmaxm.d': (0x15, 0x3),
    'fround.d': (0x21, 0x4),
  };

  for (final mode in [MicrocodeMode.none, MicrocodeMode.full]) {
    for (final op in unimplemented.entries) {
      test(
        '${op.key} raises illegal rather than wedging (${mode.name})',
        timeout: const Timeout(Duration(minutes: 10)),
        () => coreTest(
          program(fp(op.value.$1, op.value.$2)),
          // cause 2, mepc at the victim, and x8 proving it never executed.
          {Register.x5: 2, Register.x6: 0x1C, Register.x8: 0},
          config(mode),
          nextPc: 0x68,
          maxCycles: 4000,
        ),
      );
    }
  }

  // Control: an implemented op in the same config must still execute.
  // fmin.d(2.0, 1.0) = 1.0, which is operand B, so a fall-through to the
  // default arm returning operand A could not pass this.
  for (final mode in [MicrocodeMode.none, MicrocodeMode.full]) {
    test(
      'fmin.d still executes with rvZfa present (${mode.name})',
      timeout: const Timeout(Duration(minutes: 10)),
      () => coreTest(
        program(fp(0x15, 0x0)),
        {Register.x8: ranSentinel, Register.x5: 0},
        config(mode),
        nextPc: 0x68,
        maxCycles: 4000,
      ),
    );
  }
}
