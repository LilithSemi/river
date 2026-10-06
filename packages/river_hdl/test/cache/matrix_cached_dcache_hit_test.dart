import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_encoders.dart';
import '../matrix_harness.dart';

/// Differential matrix cells that exercise the L1 D-cache FILL and HIT paths.
///
/// [HarborL1DCache] allocates a line only for an address at or above its
/// `cacheableBase` (0x80000000). Every other matrix cell keeps its data in the
/// low SRAM, so those cells take the bypass path and the cache never fills, hits
/// or evicts a data line. The cells here put their data at 0x80000000 and up, so
/// the load miss allocates a line and the following loads answer out of the
/// cache block RAM.
///
/// What each group pins down:
///  - fill then hit: a miss allocates, the same load again must answer from the
///    cache with identical data.
///  - sub-word hits: the hit path applies its own byte-lane shift (`rdShift`,
///    from addrQ[2:0]) because the cache holds the RAW aligned line word while
///    the data path expects the addressed sub-word in lane 0. A wrong shift is a
///    SILENT wrong-data bug, so lb/lbu at all 8 offsets, lh/lhu at all 4 and
///    lw/lwu at both halves are all compared against the emulator.
///  - store to a resident line: the store is write-through and invalidates the
///    line, so the next load must refill and read the NEW value, not the stale
///    cached one.
///  - aliasing eviction: 0x80000100 and 0x80000200 share the D-cache index
///    (addr[7:3] over 32 lines) but differ in tag. Filling one must evict the
///    other, and re-reading the evicted address must return its own data.
///
/// The config is rc1-f: rv64, in-order, full microcode, the real split L1.
void main() {
  const mxlen = RiscVMxlen.rv64;

  // Data window. Only this region is cacheable, which is the whole point.
  const dramBase = 0x80000000;

  // addrA and addrB collide on the D-cache index (addr[7:3] of a 32-line cache)
  // and differ in tag, so each fill evicts the other. addrC is the next line, so
  // it stays resident next to addrA.
  const addrA = 0x80000100;
  const addrB = 0x80000200;
  const addrC = 0x80000108;

  // 0xB8409D6B4217A53E. All eight bytes differ, and the byte, halfword and word
  // views mix both signs, so a wrong lane shift or a wrong sign extension on a
  // cache hit cannot read back as correct.
  const lineA = [0x4217A53E, 0xB8409D6B];
  const lineB = [0xCAFEBABE, 0x0BADF00D];
  // Upper half zero: the harness memory model has no byte lanes, so a sub-word
  // store writes the whole 64-bit word. Keeping the upper half zero makes the
  // HDL and the emulator agree after a `sw`.
  const lineC = [0xAABBCCDD, 0x00000000];

  const newValue = 0x0F0E0D0C0B0A0908;

  // funct3: lb=0 lh=1 lw=2 ld=3 lbu=4 lhu=5 lwu=6. Stores: sb=0 sh=1 sw=2 sd=3.
  final cells = <MatrixCell>[
    MatrixCell(
      'fill then hit (ld)',
      [
        load(0, 10, 3, 12), // ld x12, 0(x10): miss, allocates the line
        load(0, 10, 3, 13), // ld x13, 0(x10): must hit
        nop,
      ],
      seed: {Register.x10: addrA},
      dataMem: {addrA: lineA},
      checkRegs: [Register.x12, Register.x13],
      nextPc: 0x0C,
    ),
    MatrixCell(
      'hit both word halves (lw/lwu)',
      [
        load(0, 10, 2, 12), // lw  x12, 0(x10): miss, then reads the low word
        load(4, 10, 2, 13), // lw  x13, 4(x10): hit, rdShift = 32
        load(0, 10, 6, 14), // lwu x14, 0(x10)
        load(4, 10, 6, 15), // lwu x15, 4(x10)
        nop,
      ],
      seed: {Register.x10: addrA},
      dataMem: {addrA: lineA},
      checkRegs: [Register.x12, Register.x13, Register.x14, Register.x15],
      nextPc: 0x14,
    ),
    MatrixCell(
      'hit lbu at all 8 byte offsets',
      [
        load(0, 10, 3, 5), // ld: allocate the line first
        load(0, 10, 4, 12),
        load(1, 10, 4, 13),
        load(2, 10, 4, 14),
        load(3, 10, 4, 15),
        load(4, 10, 4, 16),
        load(5, 10, 4, 17),
        load(6, 10, 4, 18),
        load(7, 10, 4, 19),
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
      nextPc: 0x24,
    ),
    MatrixCell(
      'hit lb at all 8 byte offsets',
      [
        load(0, 10, 3, 5),
        load(0, 10, 0, 12),
        load(1, 10, 0, 13),
        load(2, 10, 0, 14),
        load(3, 10, 0, 15),
        load(4, 10, 0, 16),
        load(5, 10, 0, 17),
        load(6, 10, 0, 18),
        load(7, 10, 0, 19),
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
      nextPc: 0x24,
    ),
    MatrixCell(
      'hit lh/lhu at all 4 halfword offsets',
      [
        load(0, 10, 3, 5),
        load(0, 10, 1, 12),
        load(2, 10, 1, 13),
        load(4, 10, 1, 14),
        load(6, 10, 1, 15),
        load(0, 10, 5, 16),
        load(2, 10, 5, 17),
        load(4, 10, 5, 18),
        load(6, 10, 5, 19),
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
      nextPc: 0x24,
    ),
    MatrixCell(
      'sd to a resident line, then load the new value',
      [
        load(0, 10, 3, 12), // ld: allocate the line
        store(0, 11, 10, 3), // sd: write-through, invalidates the line
        load(0, 10, 3, 13), // ld: must refill and read the NEW value
        nop,
      ],
      seed: {Register.x10: addrA, Register.x11: newValue},
      dataMem: {addrA: lineA},
      checkRegs: [Register.x12, Register.x13],
      checkMem: [addrA],
      nextPc: 0x10,
    ),
    MatrixCell(
      'sd to a resident line, then sub-word loads of the new value',
      [
        load(0, 10, 3, 12),
        store(0, 11, 10, 3),
        load(4, 10, 6, 13), // lwu: high half of the stored value
        load(0, 10, 6, 14), // lwu: low half, a hit on the refilled line
        nop,
      ],
      seed: {Register.x10: addrA, Register.x11: newValue},
      dataMem: {addrA: lineA},
      checkRegs: [Register.x12, Register.x13, Register.x14],
      checkMem: [addrA],
      nextPc: 0x14,
    ),
    MatrixCell(
      'sw to a resident line, then load the new value',
      [
        load(0, 13, 2, 12), // lw: allocate the line at the next index
        store(0, 11, 13, 2), // sw
        load(0, 13, 3, 14), // ld: must read the NEW value
        nop,
      ],
      seed: {Register.x13: addrC, Register.x11: 0x1234},
      dataMem: {addrC: lineC},
      checkRegs: [Register.x12, Register.x14],
      checkMem: [addrC],
      nextPc: 0x10,
    ),
    MatrixCell(
      'store to a line that is not resident, then fill',
      [
        store(0, 11, 10, 3), // sd first: no write-allocate, nothing is cached
        load(0, 10, 3, 12), // ld: miss, fills with the stored value
        load(0, 10, 3, 13), // ld: hit
        nop,
      ],
      seed: {Register.x10: addrA, Register.x11: newValue},
      dataMem: {addrA: lineA},
      checkRegs: [Register.x12, Register.x13],
      checkMem: [addrA],
      nextPc: 0x10,
    ),
    MatrixCell(
      'aliasing eviction and refetch',
      [
        load(0, 10, 3, 12), // fill addrA
        load(0, 11, 3, 13), // fill addrB: same index, evicts addrA
        load(0, 10, 3, 14), // addrA must refetch its OWN data
        load(0, 11, 3, 15), // addrB must refetch its OWN data
        nop,
      ],
      seed: {Register.x10: addrA, Register.x11: addrB},
      dataMem: {addrA: lineA, addrB: lineB},
      checkRegs: [Register.x12, Register.x13, Register.x14, Register.x15],
      nextPc: 0x14,
    ),
    MatrixCell(
      'two lines stay resident together',
      [
        load(0, 10, 3, 12), // fill index n
        load(0, 11, 3, 13), // fill index n+1
        load(0, 10, 3, 14), // hit index n
        load(0, 11, 3, 15), // hit index n+1
        nop,
      ],
      seed: {Register.x10: addrA, Register.x11: addrC},
      dataMem: {addrA: lineA, addrC: lineC},
      checkRegs: [Register.x12, Register.x13, Register.x14, Register.x15],
      nextPc: 0x14,
    ),
    MatrixCell(
      'store to an aliasing line leaves the resident line alone',
      [
        load(0, 10, 3, 14), // fill addrA
        store(0, 12, 11, 3), // sd to addrB: same index, different tag
        load(0, 10, 3, 15), // addrA must be unchanged
        load(0, 11, 3, 16), // addrB holds the stored value
        nop,
      ],
      seed: {Register.x10: addrA, Register.x11: addrB, Register.x12: 0x99},
      dataMem: {addrA: lineA, addrB: lineB},
      checkRegs: [Register.x14, Register.x15, Register.x16],
      checkMem: [addrA, addrB],
      nextPc: 0x14,
    ),
    MatrixCell(
      'cached and uncached loads interleaved',
      [
        load(0, 10, 3, 12), // cacheable: fill
        load(0, 11, 3, 13), // below cacheableBase: bypass, no allocation
        load(0, 10, 3, 14), // must still hit with addrA data
        load(4, 10, 2, 15), // lw hit on the upper half
        nop,
      ],
      seed: {Register.x10: addrA, Register.x11: 0x200},
      dataMem: {
        addrA: lineA,
        0x200: [0x12345678, 0x00000000],
      },
      checkRegs: [Register.x12, Register.x13, Register.x14, Register.x15],
      nextPc: 0x14,
    ),
  ];

  runMatrix(
    'matrix: dcache fill/hit ${mxlenLabel(mxlen)} microcode + L1',
    matrixConfig(
      mxlen,
      Uarch.inOrder,
      'loadstore',
      microcodeMode: MicrocodeMode.full,
      cached: true,
    ),
    cells,
    highMemBase: dramBase,
    timeout: const Duration(minutes: 30),
  );
}
