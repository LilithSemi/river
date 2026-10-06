import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_encoders.dart';
import '../matrix_harness.dart';

/// Differential matrix cells for a MULTI-WORD D-cache line.
///
/// The default matrix cache uses an 8-byte line, which on rv64 is exactly one
/// machine word, so the fill FSM writes one word and stops. Its loop is never
/// taken: the fillWord counter never increments and the per-word refill address
/// never walks. This file gives the D-cache a 32-byte line (four rv64 words) so
/// one miss must fetch four paced words in order, and the following loads must
/// find each of them at its own place inside the line.
///
/// The data is a byte ramp: the byte at offset k inside the line holds k. A word
/// select (`dataEntryOf`) or a fill-order defect therefore shows up as a plainly
/// wrong value, not as a plausible one.
///
/// Geometry: a 256-byte D-cache with a 32-byte line is 8 lines, so the index is
/// addr[7:5]. 0x80000100 and 0x80000200 share the index and differ in tag, and
/// 0x80000120 is the next line.
///
/// The config is rc1-f: rv64, in-order, full microcode, the real split L1.
void main() {
  const mxlen = RiscVMxlen.rv64;

  const dramBase = 0x80000000;
  const addrA = 0x80000100;
  const addrB = 0x80000200; // same index as addrA, different tag
  const addrC = 0x80000120; // the next line

  // Byte at offset k of the line holds base + k.
  const lineA = [
    0x03020100,
    0x07060504,
    0x0B0A0908,
    0x0F0E0D0C,
    0x13121110,
    0x17161514,
    0x1B1A1918,
    0x1F1E1D1C,
  ];
  const lineB = [
    0x83828180,
    0x87868584,
    0x8B8A8988,
    0x8F8E8D8C,
    0x93929190,
    0x97969594,
    0x9B9A9998,
    0x9F9E9D9C,
  ];
  const lineC = [
    0x43424140,
    0x47464544,
    0x4B4A4948,
    0x4F4E4D4C,
    0x53525150,
    0x57565554,
    0x5B5A5958,
    0x5F5E5D5C,
  ];

  const newValue = 0x0F1E2D3C4B5A6978;

  final cells = <MatrixCell>[
    MatrixCell(
      'fill a 4-word line, then hit every word',
      [
        load(0, 10, 3, 12), // ld: miss, fetches all four line words
        load(8, 10, 3, 13), // hit, word 1
        load(16, 10, 3, 14), // hit, word 2
        load(24, 10, 3, 15), // hit, word 3
        nop,
      ],
      seed: {Register.x10: addrA},
      dataMem: {addrA: lineA},
      checkRegs: [Register.x12, Register.x13, Register.x14, Register.x15],
      nextPc: 0x14,
    ),
    MatrixCell(
      'miss on the last word of a line, then hit the first',
      [
        load(24, 10, 3, 12), // the fill still starts at the line base
        load(0, 10, 3, 13), // hit, word 0
        load(16, 10, 3, 14), // hit, word 2
        nop,
      ],
      seed: {Register.x10: addrA},
      dataMem: {addrA: lineA},
      checkRegs: [Register.x12, Register.x13, Register.x14],
      nextPc: 0x10,
    ),
    MatrixCell(
      'sub-word hits at both ends of every line word',
      [
        load(0, 10, 3, 5), // allocate the line
        load(0, 10, 4, 12), // lbu, word 0 byte 0
        load(7, 10, 4, 13), // lbu, word 0 byte 7
        load(8, 10, 4, 14), // lbu, word 1 byte 0
        load(15, 10, 4, 15), // lbu, word 1 byte 7
        load(16, 10, 4, 16),
        load(23, 10, 4, 17),
        load(24, 10, 4, 18),
        load(31, 10, 4, 19),
        nop,
      ],
      seed: {Register.x10: addrA},
      dataMem: {addrA: lineA},
      checkRegs: [
        Register.x12,
        Register.x13,
        Register.x14,
        Register.x15,
        Register.x16,
        Register.x17,
        Register.x18,
        Register.x19,
      ],
      nextPc: 0x28,
    ),
    MatrixCell(
      'sub-word hits at the halfword and word views of a line',
      [
        load(0, 10, 3, 5),
        load(2, 10, 5, 12), // lhu inside word 0
        load(10, 10, 5, 13), // lhu inside word 1
        load(20, 10, 5, 14), // lhu inside word 2
        load(30, 10, 5, 15), // lhu inside word 3
        load(4, 10, 6, 16), // lwu, upper half of word 0
        load(12, 10, 6, 17), // lwu, upper half of word 1
        load(20, 10, 6, 18), // lwu, upper half of word 2
        load(28, 10, 6, 19), // lwu, upper half of word 3
        nop,
      ],
      seed: {Register.x10: addrA},
      dataMem: {addrA: lineA},
      checkRegs: [
        Register.x12,
        Register.x13,
        Register.x14,
        Register.x15,
        Register.x16,
        Register.x17,
        Register.x18,
        Register.x19,
      ],
      nextPc: 0x28,
    ),
    MatrixCell(
      'store into the middle of a resident line',
      [
        load(8, 10, 3, 12), // fill the line
        store(8, 11, 10, 3), // sd into word 1: write-through, drops the line
        load(8, 10, 3, 13), // the new value
        load(0, 10, 3, 14), // word 0 refills unchanged
        load(24, 10, 3, 15), // word 3 refills unchanged
        nop,
      ],
      seed: {Register.x10: addrA, Register.x11: newValue},
      dataMem: {addrA: lineA},
      checkRegs: [Register.x12, Register.x13, Register.x14, Register.x15],
      checkMem: [addrA, addrA + 8, addrA + 24],
      nextPc: 0x18,
    ),
    MatrixCell(
      'aliasing eviction of a 4-word line',
      [
        load(8, 10, 3, 12), // fill line A
        load(8, 11, 3, 13), // fill line B: same index, evicts A
        load(8, 10, 3, 14), // A refetches its OWN word 1
        load(24, 11, 3, 15), // B refetches its OWN word 3
        nop,
      ],
      seed: {Register.x10: addrA, Register.x11: addrB},
      dataMem: {addrA: lineA, addrB: lineB},
      checkRegs: [Register.x12, Register.x13, Register.x14, Register.x15],
      nextPc: 0x14,
    ),
    MatrixCell(
      'neighbouring lines stay resident together',
      [
        load(0, 10, 3, 12), // fill line A
        load(0, 11, 3, 13), // fill the next line
        load(24, 10, 3, 14), // hit inside line A
        load(24, 11, 3, 15), // hit inside the next line
        nop,
      ],
      seed: {Register.x10: addrA, Register.x11: addrC},
      dataMem: {addrA: lineA, addrC: lineC},
      checkRegs: [Register.x12, Register.x13, Register.x14, Register.x15],
      nextPc: 0x14,
    ),
  ];

  runMatrix(
    'matrix: dcache 32B line ${mxlenLabel(mxlen)} microcode + L1',
    matrixConfig(
      mxlen,
      Uarch.inOrder,
      'loadstore',
      microcodeMode: MicrocodeMode.full,
      cached: true,
      l1: matrixL1(iSize: 256, dSize: 256, lineSize: 32),
    ),
    cells,
    highMemBase: dramBase,
    timeout: const Duration(minutes: 30),
  );
}
