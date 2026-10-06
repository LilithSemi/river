import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_instructions.dart';
import '../matrix_harness.dart';

/// Differential matrix for the 'base' category, run through Sv39 TRANSLATION on
/// the microcode path (rc1-f's real datapath).
///
/// Every other matrix file pins `pagingModes: [bare]`, so the whole matrix has
/// never made one translated memory access: no TLB lookup, no page-table walk,
/// no permission check. The core ships in Sv39 under Linux, so the shipping
/// configuration is the one the matrix does not cover. Two shipped bugs lived in
/// that blind spot, one of them the virtually tagged L1 caches that kept their
/// lines across an address-space switch.
///
/// The map is an identity map of Sv39 1GB megapages, so VA == PA. The cells keep
/// their addresses and the emulator goldens stay valid: every existing cell is
/// re-run through the translation datapath for free.
void main() {
  const category = 'base';
  const mxlen = RiscVMxlen.rv64;
  const uarch = Uarch.inOrder;
  runMatrix(
    'matrix: $category ${mxlenLabel(mxlen)} microcode + Sv39',
    matrixConfig(
      mxlen,
      uarch,
      category,
      microcodeMode: MicrocodeMode.full,
      paged: true,
    ),
    instructionsFor(category, mxlen),
    timeout: const Duration(minutes: 25),
  );
}
