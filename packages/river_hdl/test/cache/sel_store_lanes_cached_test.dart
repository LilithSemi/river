import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_harness.dart';
import '../sel_store_cells.dart';

/// Store byte-lane coverage through the REAL L1 hierarchy.
///
/// The D-cache is write-through, so the store still reaches the bus with its own
/// address, size and data, and the MMU makes the SEL mask from that size. Two
/// paths are covered by the two regions: a low store whose read-back bypasses
/// the cache, and a high store that invalidates a resident line and then refills
/// it. A size that the cache carries wrongly reaches the bus as a wrong SEL mask
/// and corrupts the bytes next to the store.
///
/// The config is rc1-f: rv64, in-order, full microcode, the real split L1.
void main() {
  const mxlen = RiscVMxlen.rv64;
  runMatrix(
    'matrix: store byte lanes ${mxlenLabel(mxlen)} microcode + L1',
    matrixConfig(
      mxlen,
      Uarch.inOrder,
      'loadstore',
      microcodeMode: MicrocodeMode.full,
      cached: true,
    ),
    selStoreAllCells(),
    highMemBase: 0x80000000,
    timeout: const Duration(minutes: 30),
  );
}
