import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_instructions.dart';
import '../matrix_harness.dart';

/// Differential matrix for the 'csr' category (CSR access, including the satp write that switches address space), run through the REAL
/// L1 hierarchy on the MICROCODE path. This is rc1-f's configuration: the core
/// delta ships.
///
/// Every other matrix file builds its config with no `l1cache`, so the caches
/// are not in the design and the cells reach memory directly. Two shipped bugs
/// lived in that blind spot: the D-cache had no faulting response path (a NULL
/// dereference froze the core instead of trapping), and both L1s were never
/// flushed on an address-space switch. Re-running the cells with the caches
/// present turns a cache handshake defect into a parity failure.
///
/// Bare mode keeps VA == PA so no cell changes. The D-cache only caches at or
/// above `cacheableBase` (0x80000000) and the cells use low addresses, so this
/// covers the I-cache fill/hit path plus the D-cache bypass and store paths.
void main() {
  const category = 'csr';
  const mxlen = RiscVMxlen.rv64;
  const uarch = Uarch.inOrder;
  runMatrix(
    'matrix: $category ${mxlenLabel(mxlen)} microcode + L1',
    matrixConfig(
      mxlen,
      uarch,
      category,
      microcodeMode: MicrocodeMode.full,
      cached: true,
    ),
    instructionsFor(category, mxlen),
  );
}
