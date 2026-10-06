import 'package:river/river.dart';

import '../adversarial_memory.dart';
import '../matrix_configs.dart';
import '../matrix_instructions.dart';
import '../matrix_harness.dart';

/// The differential matrix on the SILICON SHAPE of rc1-f.
///
/// Every existing matrix file relaxes at least one property of the shipping
/// core, and the relaxations do not overlap in one file:
///
///  * `inorder_read_latency_test` forces `regfileReadLatency: 1`, but it runs
///    the STATIC execution unit (`MicrocodeMode.none`), with no cache, no
///    paging and the instantaneous memory. rc1-f runs the DynamicExecutionUnit.
///  * `matrix_paged_cached_micro_*` run the DEU with the L1s and Sv39, but at
///    `regfileReadLatency: 0`. On openXC7 the integer register file is a
///    RAMB36E1 and reads at latency 1, so the operand read is a PIPELINE.
///  * No matrix file uses the posted-write memory, so no cell has ever seen a
///    write that is acknowledged before it commits.
///
/// This file sets all four at once: the DEU, both L1 caches, Sv39 translation,
/// the register file at read latency 1, and a memory that posts its writes. It
/// covers the categories that touch the register-read pipeline hardest, which
/// are the ones that reuse a read PORT inside a single instruction.
void main() {
  const mxlen = RiscVMxlen.rv64;
  const uarch = Uarch.inOrder;

  // Acknowledge a write three cycles before it commits, and let an unrelated
  // read pass the pending writes. This is the DDR3 path the delta board has.
  const posted = AdversarialMemory(
    postedWriteCycles: 3,
    readsPassPendingWrites: true,
    seed: 5,
  );

  // 'a' matters most: the AMO, LR and SC destination commits drive the register
  // write port directly instead of going through a WriteRegister micro-op.
  //
  // 'zacas' is NOT in the list. The DynamicExecutionUnit does not implement
  // `amocas`: its amoNewVal combine falls through to the plain source value for
  // the cas selector ("cas fallthrough (static path only)" in exec.dart), so on
  // a no-match cas stores the source instead of leaving memory alone. rc1-f and
  // rc1-s do not enable Zacas, so nothing ships with it, and running the cells
  // here would only re-report that known gap.
  //
  // 'csr' is NOT in the list either, for a harness reason rather than a core
  // one. `paged: true` starts the cells in SUPERVISOR mode (bare mode makes
  // M-mode data untranslated, so the cells would never reach the translation
  // datapath), and the csr cells read and write `mscratch`, a MACHINE CSR. The
  // core correctly raises an illegal instruction, so all six cells fail on a
  // trap that is the right answer.
  for (final category in const ['base', 'loadstore', 'm', 'a', 'branch']) {
    runMatrix(
      'matrix: $category rv64 DEU + L1 + Sv39 + readLatency=1 + posted writes',
      matrixConfig(
        mxlen,
        uarch,
        category,
        microcodeMode: MicrocodeMode.full,
        regfileReadLatency: 1,
        cached: true,
        paged: true,
      ),
      instructionsFor(category, mxlen),
      memory: posted,
      timeout: const Duration(minutes: 40),
    );
  }
}
