import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';
import 'fp_boot.dart';

/// Floating-point ARITHMETIC on the microcoded execution path.
///
/// rc1-f runs MicrocodeMode.full, so every F/D instruction comes out of the
/// micro-op ROM and executes in the DynamicExecutionUnit. That unit had no
/// FpuOp arm at all: an `fadd.s` fell through to the default case and trapped
/// illegal, although all the arithmetic hardware was already instantiated and
/// wired to the operand latches. [core_fp_test] does not cover this, because it
/// builds a core with the default MicrocodeMode.none and therefore exercises
/// only the STATIC execution unit.
///
/// Results come back through fmv.x.w / fmv.x.d, which move the raw bits of an
/// FP register into a GPR, so every check is on an exact bit pattern.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig config() => RiverCoreConfigV1.full(
    resetVector: fpResetVector,
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    clock: const HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
  );

  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  // OP-FP (opcode 0x53). funct7 picks the operation, funct3 the rounding mode
  // or the sub-selector, rs2 the convert width and signedness.
  int fop(int funct7, int rs2, int rs1, int funct3, int rd) =>
      (funct7 << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (funct3 << 12) |
      (rd << 7) |
      0x53;
  // R4-type fused multiply-add. fmt bits[26:25] select the precision.
  int fma(int opcode, int fmt, int rs3, int rs2, int rs1, int rm, int rd) =>
      (rs3 << 27) |
      (fmt << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (rm << 12) |
      (rd << 7) |
      opcode;
  int flw(int rd, int rs1, int imm) =>
      ((imm & 0xfff) << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x07;
  int fld(int rd, int rs1, int imm) =>
      ((imm & 0xfff) << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x07;
  int fsd(int rs2, int rs1, int imm) =>
      (((imm >> 5) & 0x7f) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (3 << 12) |
      ((imm & 0x1f) << 7) |
      0x27;
  const park = 0x0000006f;

  String memImage(Map<int, List<int>> words) {
    final sb = StringBuffer();
    final addrs = words.keys.toList()..sort();
    for (final a in addrs) {
      sb.writeln('@${a.toRadixString(16)}');
      for (final w in words[a]!) {
        for (var i = 0; i < 4; i++) {
          sb.write(((w >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }
      sb.writeln();
    }
    return withFpBoot(sb.toString());
  }

  // Single-precision operands in memory: 2.0f, 4.0f, -1.0f, 1.0f.
  final singleBody = <int>[
    addi(10, 0, 0x200), // x10 = 0x200 (operand base)
    flw(1, 10, 0), // f1 = 2.0f
    flw(2, 10, 4), // f2 = 4.0f
    flw(5, 10, 8), // f5 = -1.0f
    flw(8, 10, 12), // f8 = 1.0f
    fop(0x00, 2, 1, 0, 3), // fadd.s f3, f1, f2   -> 6.0f
    fop(0x08, 2, 1, 0, 4), // fmul.s f4, f1, f2   -> 8.0f
    fop(0x0C, 1, 2, 0, 10), // fdiv.s f10, f2, f1 -> 2.0f
    fop(0x70, 0, 3, 0, 20), // fmv.x.w x20, f3
    fop(0x70, 0, 4, 0, 21), // fmv.x.w x21, f4
    fop(0x70, 0, 10, 0, 22), // fmv.x.w x22, f10
    addi(11, 0, 5), // x11 = 5
    fop(0x68, 0, 11, 0, 6), // fcvt.s.w f6, x11   -> 5.0f
    fop(0x70, 0, 6, 0, 23), // fmv.x.w x23, f6
    fop(0x60, 0, 1, 0, 24), // fcvt.w.s x24, f1   -> 2
    fop(0x50, 2, 1, 2, 25), // feq.s x25, f1, f2  -> 0
    fop(0x50, 2, 1, 1, 26), // flt.s x26, f1, f2  -> 1
    fop(0x50, 2, 1, 0, 27), // fle.s x27, f1, f2  -> 1
    fop(0x10, 5, 1, 0, 7), // fsgnj.s f7, f1, f5  -> -2.0f
    fop(0x70, 0, 7, 0, 28), // fmv.x.w x28, f7
    fma(0x43, 0, 8, 2, 1, 0, 9), // fmadd.s f9, f1, f2, f8 -> 9.0f
    fop(0x70, 0, 9, 0, 29), // fmv.x.w x29, f9
    // fsqrt is multi-cycle: the micro-op parks until the shared root reports
    // done. sqrt(2.0f) is irrational, so it also pins the rounding.
    fop(0x2C, 0, 1, 0, 11), // fsqrt.s f11, f1    -> 1.41421356f
    fop(0x70, 0, 11, 0, 30), // fmv.x.w x30, f11
    fsd(1, 10, 16), // mem[0x210] = f1 (proves the flw NaN box)
    park,
  ];

  // Double-precision operands in memory: 2.0d then 4.0d, low word first.
  final doubleBody = <int>[
    addi(10, 0, 0x200),
    fld(1, 10, 0), // f1 = 2.0d
    fld(2, 10, 8), // f2 = 4.0d
    fop(0x01, 2, 1, 0, 3), // fadd.d f3, f1, f2 -> 6.0d
    fop(0x09, 2, 1, 0, 4), // fmul.d f4, f1, f2 -> 8.0d
    fop(0x05, 1, 2, 0, 5), // fsub.d f5, f2, f1 -> 2.0d
    fop(0x0D, 1, 2, 0, 8), // fdiv.d f8, f2, f1 -> 2.0d
    fop(0x71, 0, 3, 0, 20), // fmv.x.d x20, f3
    fop(0x71, 0, 4, 0, 21), // fmv.x.d x21, f4
    fop(0x71, 0, 5, 0, 22), // fmv.x.d x22, f5
    fop(0x11, 2, 1, 0, 6), // fsgnj.d f6, f1, f2 -> 2.0d
    fop(0x71, 0, 6, 0, 23), // fmv.x.d x23, f6
    fma(0x43, 1, 1, 2, 1, 0, 7), // fmadd.d f7, f1, f2, f1 -> 10.0d
    fop(0x71, 0, 7, 0, 24), // fmv.x.d x24, f7
    fop(0x71, 0, 8, 0, 25), // fmv.x.d x25, f8
    // sqrt(2.0d) is irrational, so it pins the rounding of the shared root;
    // sqrt(4.0d) pins the exact case.
    fop(0x2D, 0, 1, 0, 9), // fsqrt.d f9, f1     -> 1.41421356237d
    fop(0x71, 0, 9, 0, 26), // fmv.x.d x26, f9
    fop(0x2D, 0, 2, 0, 10), // fsqrt.d f10, f2   -> 2.0d
    fop(0x71, 0, 10, 0, 27), // fmv.x.d x27, f10
    park,
  ];

  test(
    'microcoded single-precision FP arithmetic (rc1-f)',
    timeout: Timeout(Duration(minutes: 20)),
    () => coreTest(
      memImage({
        0x0: singleBody,
        0x200: [0x40000000, 0x40800000, 0xBF800000, 0x3F800000, 0, 0],
      }),
      {
        Register.x20: 0x40C00000, // fadd.s  6.0f
        Register.x21: 0x41000000, // fmul.s  8.0f
        Register.x22: 0x40000000, // fdiv.s  2.0f
        Register.x23: 0x40A00000, // fcvt.s.w 5.0f
        Register.x24: 2, // fcvt.w.s
        Register.x25: 0, // feq.s
        Register.x26: 1, // flt.s
        Register.x27: 1, // fle.s
        Register.x28: 0xFFFFFFFFC0000000, // fmv.x.w sign-extends -2.0f bits
        Register.x29: 0x41100000, // fmadd.s 9.0f
        Register.x30: 0x3FB504F3, // fsqrt.s sqrt(2)
      },
      config(),
      nextPc: (singleBody.length - 1) * 4,
      maxCycles: 100000,
      // flw is a 32-bit load into a 64-bit register, so the upper half must be
      // all ones (NaN boxing).
      memStates: {0x210: 0xFFFFFFFF40000000},
    ),
  );

  test(
    'microcoded double-precision FP arithmetic (rc1-f)',
    timeout: Timeout(Duration(minutes: 20)),
    () => coreTest(
      memImage({
        0x0: doubleBody,
        0x200: [0x00000000, 0x40000000, 0x00000000, 0x40100000],
      }),
      {
        Register.x20: 0x4018000000000000, // fadd.d  6.0d
        Register.x21: 0x4020000000000000, // fmul.d  8.0d
        Register.x22: 0x4000000000000000, // fsub.d  2.0d
        Register.x23: 0x4000000000000000, // fsgnj.d 2.0d
        Register.x24: 0x4024000000000000, // fmadd.d 10.0d
        Register.x25: 0x4000000000000000, // fdiv.d  2.0d
        Register.x26: 0x3FF6A09E667F3BCD, // fsqrt.d sqrt(2)
        Register.x27: 0x4000000000000000, // fsqrt.d 2.0d
      },
      config(),
      nextPc: (doubleBody.length - 1) * 4,
      maxCycles: 100000,
    ),
  );
}
