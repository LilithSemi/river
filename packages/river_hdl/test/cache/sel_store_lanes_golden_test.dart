import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_encoders.dart';
import '../matrix_harness.dart';
import '../sel_store_cells.dart';

/// HAND-VERIFIED store byte-lane vectors.
///
/// The matrix cells compare the HDL against the emulator, so a fault in BOTH
/// engines would still pass. These vectors carry the expected 64-bit words that
/// I computed by hand from the pattern and the store value, and [runGolden]
/// checks the emulator AND the HDL against them. That pins the byte lanes to
/// external truth.
///
/// The pattern block holds bytes A1 B2 C3 D4 E5 F6 17 28 39 4A 5B 6C 7D 8E 9F 10
/// at offsets 0 to 15, so the first word reads 0x2817F6E5D4C3B2A1 and the second
/// reads 0x109F8E7D6C5B4A39. The stored value is 0x9988776655443322, whose bytes
/// are 22 33 44 55 66 77 88 99 from the low end.
void main() {
  const mxlen = RiscVMxlen.rv64;

  const w0 = 0x2817F6E5D4C3B2A1; // the untouched first word
  const w1 = 0x109F8E7D6C5B4A39; // the untouched second word

  // One store, then read both words back. x12 = word 0, x13 = word 1.
  GoldenCell vector(
    String name,
    int base,
    int f3,
    int off, {
    required int want0,
    required int want1,
  }) => GoldenCell(
    name,
    [store(off, 11, 10, f3), load(0, 10, 3, 12), load(8, 10, 3, 13), nop],
    seed: {Register.x10: base, Register.x11: selStoreValue},
    dataMem: {base: selPatternWords},
    expectedRegs: {Register.x12: want0, Register.x13: want1},
    expectedMem: {base: want0, base + 8: want1},
    nextPc: 0x10,
  );

  List<GoldenCell> vectors(int base, String tag) => [
    // sb: only the named byte changes.
    vector('$tag sb +3', base, 0, 3, want0: 0x2817F6E522C3B2A1, want1: w1),
    vector('$tag sb +5', base, 0, 5, want0: 0x281722E5D4C3B2A1, want1: w1),
    vector('$tag sb +7', base, 0, 7, want0: 0x2217F6E5D4C3B2A1, want1: w1),
    // A store in the second word must leave the first word alone.
    vector('$tag sb +11', base, 0, 11, want0: w0, want1: 0x109F8E7D225B4A39),
    // sh: two bytes, and the halfword at offset 6 must not reach offset 8.
    vector('$tag sh +2', base, 1, 2, want0: 0x2817F6E53322B2A1, want1: w1),
    vector('$tag sh +6', base, 1, 6, want0: 0x3322F6E5D4C3B2A1, want1: w1),
    // sw: four bytes, at both halves of a word.
    vector('$tag sw +4', base, 2, 4, want0: 0x55443322D4C3B2A1, want1: w1),
    vector('$tag sw +8', base, 2, 8, want0: w0, want1: 0x109F8E7D55443322),
    // sd: the whole word, and only that word.
    vector('$tag sd +0', base, 3, 0, want0: selStoreValue, want1: w1),
    vector('$tag sd +8', base, 3, 8, want0: w0, want1: selStoreValue),
  ];

  runGolden(
    'golden: store byte lanes ${mxlenLabel(mxlen)} microcode + L1',
    matrixConfig(
      mxlen,
      Uarch.inOrder,
      'loadstore',
      microcodeMode: MicrocodeMode.full,
      cached: true,
    ),
    [...vectors(selLowBase, 'low'), ...vectors(selHighBase, 'high')],
    highMemBase: 0x80000000,
    timeout: const Duration(minutes: 30),
  );
}
