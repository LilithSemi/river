import 'package:river/river.dart';

import 'matrix_encoders.dart';
import 'matrix_harness.dart';

/// Store byte-lane cells, shared by the SEL matrix files.
///
/// A store must change ONLY the bytes it names. The core says which bytes those
/// are with the Wishbone SEL mask, and it shifts the write data into the same
/// byte lane. Until now the matrix memory model ignored SEL and wrote the whole
/// bus word, so a store that named the wrong lanes still passed: every cell put
/// zeros around the target, and a full-word write of zeros looks the same as a
/// correct partial write.
///
/// These cells close that hole. Sixteen bytes get a distinct NON-ZERO pattern,
/// one aligned store lands in the middle of it, and both 64-bit words are read
/// back and compared. A store that writes a byte it must not touch, or that
/// misses a byte it must write, now changes the result.
///
/// Every legal alignment of every store width is covered: sb at all 16 offsets,
/// sh at all 8, sw at all 4, sd at both.

/// The 16 pre-loaded bytes, as 32-bit words. Byte k of the block holds a value
/// that appears nowhere else in the block and nowhere in [selStoreValue], so a
/// byte written by mistake is always visible.
const selPatternWords = [
  0xD4C3B2A1, // bytes 0..3   = A1 B2 C3 D4
  0x2817F6E5, // bytes 4..7   = E5 F6 17 28
  0x6C5B4A39, // bytes 8..11  = 39 4A 5B 6C
  0x109F8E7D, // bytes 12..15 = 7D 8E 9F 10
];

/// The value the cells store. Its bytes (0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
/// 0x88, 0x99) are all different from the pattern bytes.
const selStoreValue = 0x9988776655443322;

/// Cells for one 8-byte-aligned [base]. [tag] names the region in the cell name
/// so cells from two bases can share one matrix run.
List<MatrixCell> selStoreCells(int base, String tag) {
  MatrixCell cell(String width, int f3, int off) => MatrixCell(
    '$tag $width +$off',
    [
      store(off, 11, 10, f3), // the store under test
      load(0, 10, 3, 12), // read the first word back
      load(8, 10, 3, 13), // read the second word back
      nop,
    ],
    seed: {Register.x10: base, Register.x11: selStoreValue},
    dataMem: {base: selPatternWords},
    checkRegs: [Register.x12, Register.x13],
    checkMem: [base, base + 8],
    nextPc: 0x10,
  );

  return [
    for (var off = 0; off < 16; off++) cell('sb', 0, off),
    for (var off = 0; off < 16; off += 2) cell('sh', 1, off),
    for (var off = 0; off < 16; off += 4) cell('sw', 2, off),
    for (var off = 0; off < 16; off += 8) cell('sd', 3, off),
  ];
}

/// Atomic byte-lane cells. An AMO is a read-modify-WRITE, so its store half
/// drives SEL and the write-data lane exactly like a plain store does. A `.w`
/// atomic at offset 4 must touch only bytes 4 to 7. Linux runs atomics
/// constantly (spinlocks, refcounts), so a wrong lane here corrupts whatever
/// shares the 64-bit word with the lock.
///
/// The same 16-byte pattern is pre-loaded, one atomic runs, and both 64-bit
/// words are read back. [tag] names the region in the cell name.
List<MatrixCell> selAmoCells(int base, String tag) {
  // x10 holds the atomic address, x13 holds the block base for the read-back,
  // x11 is the operand. x12 takes the old value the atomic returns.
  MatrixCell cell(String op, int funct5, int f3, int off) => MatrixCell(
    '$tag $op +$off',
    [
      amo(funct5, 11, 10, f3, 12),
      load(0, 13, 3, 14), // read the first word back
      load(8, 13, 3, 15), // read the second word back
      nop,
    ],
    seed: {
      Register.x10: base + off,
      Register.x11: selStoreValue,
      Register.x13: base,
    },
    dataMem: {base: selPatternWords},
    checkRegs: [Register.x12, Register.x14, Register.x15],
    checkMem: [base, base + 8],
    nextPc: 0x10,
  );

  // amoand clears bits, so a write that lands in the wrong lane wipes pattern
  // bytes and cannot look correct by accident.
  const ops = <String, int>{
    'amoadd': 0x00,
    'amoswap': 0x01,
    'amoand': 0x0C,
    'amoor': 0x08,
  };

  return [
    for (final e in ops.entries) ...[
      for (var off = 0; off < 16; off += 4) cell('${e.key}.w', e.value, 2, off),
      for (var off = 0; off < 16; off += 8) cell('${e.key}.d', e.value, 3, off),
    ],
    // lr/sc at a non-zero lane: the sc write must land in the reserved lane.
    for (var off = 0; off < 16; off += 4)
      MatrixCell(
        '$tag lr/sc.w +$off',
        [
          amo(0x02, 0, 10, 0x2, 12), // lr.w x12 = mem, reserve
          amo(0x03, 11, 10, 0x2, 16), // sc.w x16 = 0 on success
          load(0, 13, 3, 14),
          load(8, 13, 3, 15),
          nop,
        ],
        seed: {
          Register.x10: base + off,
          Register.x11: selStoreValue,
          Register.x13: base,
        },
        dataMem: {base: selPatternWords},
        checkRegs: [Register.x12, Register.x14, Register.x15, Register.x16],
        checkMem: [base, base + 8],
        nextPc: 0x14,
      ),
  ];
}

/// Low base. Below the D-cache cacheableBase, so a load takes the bypass path.
const selLowBase = 0x300;

/// High base. At or above the D-cache cacheableBase (0x80000000), so a load
/// fills and hits a cache line.
const selHighBase = 0x80000100;

/// The cells for both regions. The store path is shared, but the read-back path
/// is not: one bypasses the D-cache and the other goes through a line fill.
List<MatrixCell> selStoreAllCells() => [
  ...selStoreCells(selLowBase, 'low'),
  ...selStoreCells(selHighBase, 'high'),
];

/// The atomic cells for both regions.
List<MatrixCell> selAmoAllCells() => [
  ...selAmoCells(selLowBase, 'low'),
  ...selAmoCells(selHighBase, 'high'),
];
