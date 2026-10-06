import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_harness.dart';
import '../sel_store_cells.dart';

/// Atomic byte-lane coverage through the REAL L1 hierarchy.
///
/// An AMO is a read-modify-write, so its store half drives the SEL mask and the
/// write-data lane the same way a plain store does. The matrix memory model now
/// honors SEL, so a `.w` atomic that names the wrong lanes changes the bytes
/// beside it and the cell fails.
///
/// This is the path Linux uses most: every spinlock, refcount and bitop is an
/// atomic, and a `.w` atomic at offset 4 of a 64-bit word is common. A wrong
/// lane there corrupts whatever shares the word with the lock.
///
/// The config is rc1-f with the A extension: rv64, in-order, full microcode, the
/// real split L1.
void main() {
  const mxlen = RiscVMxlen.rv64;
  runMatrix(
    'matrix: atomic byte lanes ${mxlenLabel(mxlen)} microcode + L1',
    matrixConfig(
      mxlen,
      Uarch.inOrder,
      'a',
      microcodeMode: MicrocodeMode.full,
      cached: true,
    ),
    selAmoAllCells(),
    highMemBase: 0x80000000,
    timeout: const Duration(minutes: 30),
  );
}
