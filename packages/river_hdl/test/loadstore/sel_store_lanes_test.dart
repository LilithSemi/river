import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_harness.dart';
import '../sel_store_cells.dart';

/// Store byte-lane coverage with NO cache: the store goes straight from the MMU
/// to the bus.
///
/// The core sends a word-aligned address, the write data shifted into its byte
/// lane, and a SEL mask that names the lanes. The matrix memory model now honors
/// SEL, so a store that names the wrong lanes, or that puts the data in the
/// wrong lane, corrupts the pattern around the target and the cell fails.
///
/// The config is rc1-f without the L1: rv64, in-order, full microcode.
void main() {
  const mxlen = RiscVMxlen.rv64;
  runMatrix(
    'matrix: store byte lanes ${mxlenLabel(mxlen)} microcode',
    matrixConfig(
      mxlen,
      Uarch.inOrder,
      'loadstore',
      microcodeMode: MicrocodeMode.full,
    ),
    selStoreAllCells(),
    highMemBase: 0x80000000,
    timeout: const Duration(minutes: 30),
  );
}
