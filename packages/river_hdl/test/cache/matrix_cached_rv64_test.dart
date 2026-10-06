import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_instructions.dart';
import '../matrix_harness.dart';

/// The differential matrix, run through the REAL L1 hierarchy.
///
/// Every other matrix file builds its config with no `l1cache`, so the cells
/// reach memory directly and the I-cache and D-cache are not in the design at
/// all. That blind spot has shipped two bugs: the D-cache had no faulting
/// response path (a NULL dereference froze the core instead of trapping), and
/// both L1s were never flushed on an address-space switch. This file re-runs the
/// same cells with the caches present, so a cache that mishandles a fill, a
/// store, a bypass or a handshake shows up as a parity failure.
///
/// Bare mode keeps VA == PA, so no cell needs changing. Note that the D-cache
/// only caches at or above its `cacheableBase` (0x80000000) and the cells use
/// low addresses, so this covers the I-cache fill/hit path and the D-cache
/// bypass and store paths. Covering the D-cache fill/hit path needs cells whose
/// data lives above that base.
void main() {
  const category = 'base';
  const mxlen = RiscVMxlen.rv64;
  const uarch = Uarch.inOrder;
  runMatrix(
    'matrix: $category ${mxlenLabel(mxlen)} ${uarchLabel(uarch)} + L1',
    matrixConfig(mxlen, uarch, category, cached: true),
    instructionsFor(category, mxlen),
  );
}
