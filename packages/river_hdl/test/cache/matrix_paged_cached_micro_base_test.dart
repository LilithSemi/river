import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_instructions.dart';
import '../matrix_harness.dart';

/// Differential matrix for the 'base' category, run through Sv39 TRANSLATION
/// AND the real split L1 hierarchy, on the microcode path.
///
/// This is the closest the matrix comes to the configuration the core ships:
/// rc1-f under Linux runs in Sv39 with both L1 caches present. The caches sit in
/// FRONT of the MMU, so they are indexed and tagged by VIRTUAL address, and the
/// interaction between the two blocks is the part no other matrix cell covers.
/// The paged-only and cached-only variants each cover one half.
///
/// The map is an identity map of Sv39 1GB megapages, so VA == PA. The cells keep
/// their addresses and the emulator goldens stay valid.
void main() {
  const category = 'base';
  const mxlen = RiscVMxlen.rv64;
  const uarch = Uarch.inOrder;
  runMatrix(
    'matrix: $category ${mxlenLabel(mxlen)} microcode + Sv39 + L1',
    matrixConfig(
      mxlen,
      uarch,
      category,
      microcodeMode: MicrocodeMode.full,
      paged: true,
      cached: true,
    ),
    instructionsFor(category, mxlen),
    timeout: const Duration(minutes: 30),
  );
}
