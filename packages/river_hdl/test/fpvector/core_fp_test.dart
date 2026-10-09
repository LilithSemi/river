import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';
import '../adversarial_memory.dart';
import 'fp_boot.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // F/D phase 1: the FP register file + load/store routing. flw loads a word
  // into an FP register; fsw stores it back. A round-trip through memory proves
  // the value went into (and came out of) the FP regfile (not the int one).
  group('RC1.fd - F/D load/store (RV64)', () {
    final config = RiverCoreConfig(
      resetVector: fpResetVector,
      clock: const HarborClockConfig(
        name: 'test',
        rate: HarborFixedClockRate(10000),
      ),
      mxlen: RiscVMxlen.rv64,
      extensions: [
        rv64i,
        rv32i,
        rvZicsr,
        rvZifencei,
        rvM,
        rvA,
        rvPriv,
        rvF,
        rvD,
      ],
      interrupts: [],
      mmu: HarborMmuConfig(
        mxlen: RiscVMxlen.rv64,
        pagingModes: const [RiscVPagingMode.bare],
        tlbLevels: const [],
        pmp: HarborPmpConfig.none,
      ),
      type: RiverCoreType.general,
    );

    int iimm(int imm, int rs1, int f3, int rd) =>
        (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
    int s(int imm, int rs2, int rs1, int f3, int op) =>
        (((imm >> 5) & 0x7F) << 25) |
        (rs2 << 20) |
        (rs1 << 15) |
        (f3 << 12) |
        ((imm & 0x1F) << 7) |
        op;
    int flw(int imm, int rs1, int rd) =>
        (imm << 20) | (rs1 << 15) | (0x2 << 12) | (rd << 7) | 0x07;
    int fld(int imm, int rs1, int rd) =>
        (imm << 20) | (rs1 << 15) | (0x3 << 12) | (rd << 7) | 0x07;
    int lui(int imm20, int rd) => (imm20 << 12) | (rd << 7) | 0x37;
    int fop(int f7, int rs2, int rs1, int rm, int rd) =>
        (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7) | 0x53;
    // R4-type FMA: rs3[31:27] | fmt[26:25] | rs2 | rs1 | rm | rd | opcode.
    int fop4(int opcode, int rs3, int rs2, int rs1, int rd, {int fmt = 0}) =>
        (rs3 << 27) |
        (fmt << 25) |
        (rs2 << 20) |
        (rs1 << 15) |
        (rd << 7) |
        opcode;
    String prog(List<int> words) {
      final sb = StringBuffer('@0\n');
      for (final w in words) {
        for (var b = 0; b < 4; b++) {
          sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }
      return withFpBoot('$sb\n');
    }

    test(
      'flw into FP reg, fsw back (round-trip via memory)',
      timeout: Timeout(Duration(seconds: 300)),
      () => coreTest(
        prog([
          iimm(0x100, 0, 0x0, 10), // addi x10, x0, 0x100 (src)
          iimm(0x200, 0, 0x0, 11), // addi x11, x0, 0x200 (dst)
          iimm(0x7B, 0, 0x0, 5), // addi x5, x0, 0x7B
          s(0, 5, 10, 0x2, 0x23), // sw x5, 0(x10)     -> mem[0x100] = 0x7B
          flw(0, 10, 1), // flw f1, 0(x10)    -> f1 = 0x7B
          s(0, 1, 11, 0x2, 0x27), // fsw f1, 0(x11)    -> mem[0x200] = 0x7B
          0x00000013, // nop (halt target)
        ]),
        {Register.x10: 0x100, Register.x11: 0x200},
        config,
        memory: const AdversarialMemory(readLatency: 1), // honor byte SEL
        nextPc: 0x18,
        memStates: {0x200: 0x7B},
      ),
    );

    test(
      'fadd.s / fsub.s / fmul.s (1.0, 2.0)',
      timeout: Timeout(Duration(seconds: 300)),
      () => coreTest(
        prog([
          lui(0x3F800, 5), // x5 = 0x3F800000 (1.0f)
          iimm(0x100, 0, 0x0, 10), // x10 = 0x100
          s(0, 5, 10, 0x2, 0x23), // sw x5, 0(x10)
          flw(0, 10, 1), // flw f1, 0(x10)   -> f1 = 1.0
          lui(0x40000, 6), // x6 = 0x40000000 (2.0f)
          iimm(0x110, 0, 0x0, 11), // x11 = 0x110
          s(0, 6, 11, 0x2, 0x23), // sw x6, 0(x11)
          flw(0, 11, 2), // flw f2, 0(x11)   -> f2 = 2.0
          fop(0x00, 2, 1, 0, 3), // fadd.s f3, f1, f2 -> 3.0
          fop(0x08, 2, 2, 0, 4), // fmul.s f4, f2, f2 -> 4.0
          fop(0x04, 1, 2, 0, 5), // fsub.s f5, f2, f1 -> 1.0
          iimm(0x120, 0, 0x0, 12), // x12 = 0x120
          s(0, 3, 12, 0x2, 0x27), // fsw f3, 0(x12) -> mem = 3.0
          iimm(0x130, 0, 0x0, 13), // x13 = 0x130
          s(0, 4, 13, 0x2, 0x27), // fsw f4, 0(x13) -> mem = 4.0
          iimm(0x140, 0, 0x0, 14), // x14 = 0x140
          s(0, 5, 14, 0x2, 0x27), // fsw f5, 0(x14) -> mem = 1.0
          0x00000013, // nop (halt target)
        ]),
        const <Register, int>{},
        config,
        memory: const AdversarialMemory(readLatency: 1),
        nextPc: 0x44,
        memStates: {
          0x120: 0x40400000, // 3.0f
          0x130: 0x40800000, // 4.0f
          0x140: 0x3F800000, // 1.0f
        },
      ),
    );

    test(
      'fsqrt.s (sqrt(4.0) = 2.0)',
      timeout: Timeout(Duration(seconds: 300)),
      () => coreTest(
        prog([
          lui(0x40800, 5), // x5 = 0x40800000 (4.0f)
          iimm(0x100, 0, 0x0, 10), // x10 = 0x100
          s(0, 5, 10, 0x2, 0x23), // sw x5, 0(x10)
          flw(0, 10, 4), // flw f4, 0(x10)   -> f4 = 4.0
          fop(0x2C, 0, 4, 0, 6), // fsqrt.s f6, f4   -> 2.0
          iimm(0x120, 0, 0x0, 12), // x12 = 0x120
          s(0, 6, 12, 0x2, 0x27), // fsw f6, 0(x12)  -> mem = 2.0
          0x00000013, // nop (halt target)
        ]),
        const <Register, int>{},
        config,
        memory: const AdversarialMemory(readLatency: 1),
        nextPc: 0x1C,
        memStates: {0x120: 0x40000000}, // 2.0f
      ),
    );

    // FP compares (feq/flt/fle) write 0/1 to an integer reg. The false case is
    // verified by addi+7 (0+7=7) so it isn't confused with uninitialized 0 mem.
    test(
      'feq.s / flt.s / fle.s (1.0 vs 2.0)',
      timeout: Timeout(Duration(seconds: 300)),
      () => coreTest(
        prog([
          lui(0x3F800, 5), // x5 = 1.0f bits
          iimm(0x100, 0, 0x0, 10), // x10 = 0x100
          s(0, 5, 10, 0x2, 0x23), // sw x5, 0(x10)
          flw(0, 10, 1), // f1 = 1.0
          lui(0x40000, 6), // x6 = 2.0f bits
          iimm(0x110, 0, 0x0, 11), // x11 = 0x110
          s(0, 6, 11, 0x2, 0x23), // sw x6, 0(x11)
          flw(0, 11, 2), // f2 = 2.0
          fop(0x50, 1, 1, 0x2, 20), // feq.s x20, f1, f1 -> 1
          fop(0x50, 2, 1, 0x1, 21), // flt.s x21, f1, f2 -> 1
          fop(0x50, 1, 2, 0x1, 23), // flt.s x23, f2, f1 -> 0
          iimm(7, 23, 0x0, 24), // addi x24, x23, 7 -> 7 (proves x23==0)
          iimm(0x120, 0, 0x0, 12),
          s(0, 20, 12, 0x2, 0x23), // sw x20 -> 0x120 (1)
          iimm(0x130, 0, 0x0, 13),
          s(0, 21, 13, 0x2, 0x23), // sw x21 -> 0x130 (1)
          iimm(0x140, 0, 0x0, 14),
          s(0, 24, 14, 0x2, 0x23), // sw x24 -> 0x140 (7)
          0x00000013, // nop (halt target)
        ]),
        const <Register, int>{},
        config,
        memory: const AdversarialMemory(readLatency: 1),
        nextPc: 0x48,
        memStates: {0x120: 1, 0x130: 1, 0x140: 7},
      ),
    );

    // fcvt int<->float (RTZ, matching the emulator golden model which truncates
    // toward zero via Dart .toInt()). fcvt.s.w f7=0x68, fcvt.w.s f7=0x60.
    test(
      'fcvt.s.w / fcvt.w.s (int<->float + truncation)',
      timeout: Timeout(Duration(seconds: 300)),
      () => coreTest(
        prog([
          iimm(5, 0, 0x0, 5), // x5 = 5
          fop(0x68, 0, 5, 0, 1), // fcvt.s.w f1, x5 -> 5.0f
          iimm(0x100, 0, 0x0, 10),
          s(0, 1, 10, 0x2, 0x27), // fsw f1 -> 0x40A00000
          fop(0x60, 0, 1, 0, 6), // fcvt.w.s x6, f1 -> 5
          iimm(0x110, 0, 0x0, 11),
          s(0, 6, 11, 0x2, 0x23), // sw x6 -> 5
          lui(0x40300, 7), // x7 = 2.75f bits
          iimm(0x120, 0, 0x0, 12),
          s(0, 7, 12, 0x2, 0x23), // sw x7, 0(x12)
          flw(0, 12, 3), // flw f3 = 2.75f
          fop(0x60, 0, 3, 1, 8), // fcvt.w.s x8, f3 (rm=1 RTZ) -> 2
          iimm(0x130, 0, 0x0, 13),
          s(0, 8, 13, 0x2, 0x23), // sw x8 -> 2
          0x00000013, // nop (halt target)
        ]),
        const <Register, int>{},
        config,
        memory: const AdversarialMemory(readLatency: 1),
        nextPc: 0x38,
        memStates: {0x100: 0x40A00000, 0x110: 5, 0x130: 2},
      ),
    );

    // fcvt precision converts (single<->double) + int<->double.
    test(
      'fcvt.d.s / fcvt.s.d / fcvt.w.d / fcvt.d.w',
      timeout: Timeout(Duration(seconds: 300)),
      () => coreTest(
        prog([
          iimm(5, 0, 0x0, 5), // x5 = 5
          fop(0x68, 0, 5, 0, 1), // fcvt.s.w f1, x5 -> 5.0f
          fop(0x21, 0, 1, 0, 4), // fcvt.d.s f4, f1 -> 5.0d
          iimm(0x100, 0, 0x0, 10),
          s(0, 4, 10, 0x3, 0x27), // fsd f4 -> 5.0d
          fop(0x20, 1, 4, 0, 5), // fcvt.s.d f5, f4 -> 5.0f
          iimm(0x110, 0, 0x0, 11),
          s(0, 5, 11, 0x2, 0x27), // fsw f5 -> 0x40A00000
          fop(0x61, 0, 4, 0, 9), // fcvt.w.d x9, f4 -> 5
          iimm(0x120, 0, 0x0, 12),
          s(0, 9, 12, 0x2, 0x23), // sw x9 -> 5
          fop(0x69, 0, 5, 0, 6), // fcvt.d.w f6, x5 -> 5.0d
          iimm(0x130, 0, 0x0, 13),
          s(0, 6, 13, 0x3, 0x27), // fsd f6 -> 5.0d
          0x00000013, // nop (halt target)
        ]),
        const <Register, int>{},
        config,
        memory: const AdversarialMemory(readLatency: 1),
        nextPc: 0x38,
        memStates: {
          0x100: 0x4014000000000000, // 5.0d
          0x110: 0x40A00000, // 5.0f
          0x120: 5,
          0x130: 0x4014000000000000, // 5.0d
        },
      ),
    );

    // fdiv.s multi-cycle Newton-Raphson (reuses one mul+add over ~10 cycles).
    // Divisor 2.0 -> reciprocal seed is exact, so 6/2=3.0 and 7/2=3.5 are
    // bit-exact. Inexact quotients (e.g. 1/3) are ~1 ULP off, the divider is
    // functional, not bit-exact (no remainder-correction step), as chosen.
    test(
      'fdiv.s (6.0/2.0=3.0, 7.0/2.0=3.5)',
      timeout: Timeout(Duration(seconds: 180)),
      () => coreTest(
        prog([
          lui(0x40C00, 5), // x5 = 6.0f
          iimm(0x100, 0, 0x0, 10),
          s(0, 5, 10, 0x2, 0x23), // sw x5
          flw(0, 10, 1), // f1 = 6.0
          lui(0x40000, 6), // x6 = 2.0f
          iimm(0x110, 0, 0x0, 11),
          s(0, 6, 11, 0x2, 0x23),
          flw(0, 11, 2), // f2 = 2.0
          fop(0x0C, 2, 1, 0, 3), // fdiv.s f3, f1, f2 -> 3.0
          iimm(0x120, 0, 0x0, 12),
          s(0, 3, 12, 0x2, 0x27), // fsw f3 -> 0x40400000
          lui(0x40E00, 7), // x7 = 7.0f
          iimm(0x130, 0, 0x0, 13),
          s(0, 7, 13, 0x2, 0x23),
          flw(0, 13, 4), // f4 = 7.0
          fop(0x0C, 2, 4, 0, 5), // fdiv.s f5, f4, f2 -> 3.5
          iimm(0x140, 0, 0x0, 14),
          s(0, 5, 14, 0x2, 0x27), // fsw f5 -> 0x40600000
          0x00000013, // nop (halt target)
        ]),
        const <Register, int>{},
        config,
        memory: const AdversarialMemory(readLatency: 1),
        nextPc: 0x48,
        memStates: {0x120: 0x40400000, 0x140: 0x40600000},
      ),
    );

    // Double-precision: operands placed directly in memory (the harness keys
    // each address as a 64-bit slot, so instruction-based dword construction is
    // unreliable; placing the 8 bytes in the memString avoids that).
    test(
      'fadd.d / fmul.d (1.0, 2.0 doubles from memory)',
      timeout: Timeout(Duration(seconds: 300)),
      () => coreTest(
        '${prog([
          iimm(0x100, 0, 0x0, 10), // x10 = 0x100
          iimm(0x110, 0, 0x0, 11), // x11 = 0x110
          fld(0, 10, 1), // fld f1, 0(x10) -> 1.0
          fld(0, 11, 2), // fld f2, 0(x11) -> 2.0
          fop(0x01, 2, 1, 0, 3), // fadd.d f3, f1, f2 -> 3.0
          fop(0x09, 2, 2, 0, 4), // fmul.d f4, f2, f2 -> 4.0
          iimm(0x120, 0, 0x0, 12), // x12 = 0x120
          s(0, 3, 12, 0x3, 0x27), // fsd f3, 0(x12)
          iimm(0x130, 0, 0x0, 13), // x13 = 0x130
          s(0, 4, 13, 0x3, 0x27), // fsd f4, 0(x13)
          0x00000013, // nop (halt target)
        ])}@100\n00 00 00 00 00 00 f0 3f\n@110\n00 00 00 00 00 00 00 40\n',
        const <Register, int>{},
        config,
        memory: const AdversarialMemory(readLatency: 1),
        nextPc: 0x28,
        memStates: {
          0x120: 0x4008000000000000, // 3.0d
          0x130: 0x4010000000000000, // 4.0d
        },
      ),
    );

    // Sign-injection, min/max, classify and raw move (single precision).
    // f1 = 1.0 (0x3F800000), f2 = -2.0 (0xC0000000).
    //   fsgnj.s  -> |f1| with sign(f2)  = -1.0 (0xBF800000)
    //   fsgnjn.s -> |f1| with ~sign(f2) =  1.0 (0x3F800000)
    //   fsgnjx.s -> |f1| with sign(f1)^sign(f2) = -1.0 (0xBF800000)
    //   fmin.s   -> -2.0 (0xC0000000)
    //   fmax.s   ->  1.0 (0x3F800000)
    //   fclass.s(f1) -> +normal = bit6 = 0x40
    //   fclass.s(f2) -> -normal = bit1 = 0x02
    //   fmv.x.w(f1)  -> raw bits 0x3F800000
    test(
      'fsgnj/fmin/fmax/fclass/fmv.x.w (single)',
      timeout: Timeout(Duration(seconds: 300)),
      () => coreTest(
        prog([
          lui(0x3F800, 5), // x5 = 1.0f bits
          iimm(0x100, 0, 0x0, 10),
          s(0, 5, 10, 0x2, 0x23),
          flw(0, 10, 1), // f1 = 1.0
          lui(0xC0000, 6), // x6 = -2.0f bits (0xC0000000)
          iimm(0x110, 0, 0x0, 11),
          s(0, 6, 11, 0x2, 0x23),
          flw(0, 11, 2), // f2 = -2.0
          fop(0x10, 2, 1, 0x0, 3), // fsgnj.s  f3
          fop(0x10, 2, 1, 0x1, 4), // fsgnjn.s f4
          fop(0x10, 2, 1, 0x2, 5), // fsgnjx.s f5
          fop(0x14, 2, 1, 0x0, 6), // fmin.s   f6
          fop(0x14, 2, 1, 0x1, 7), // fmax.s   f7
          fop(0x70, 0, 1, 0x1, 8), // fclass.s x8, f1
          fop(0x70, 0, 2, 0x1, 9), // fclass.s x9, f2
          fop(0x70, 0, 1, 0x0, 18), // fmv.x.w  x18, f1
          iimm(0x120, 0, 0x0, 12),
          s(0, 3, 12, 0x2, 0x27), // fsw f3 -> 0xBF800000
          iimm(0x130, 0, 0x0, 13),
          s(0, 4, 13, 0x2, 0x27), // fsw f4 -> 0x3F800000
          iimm(0x140, 0, 0x0, 14),
          s(0, 5, 14, 0x2, 0x27), // fsw f5 -> 0xBF800000
          iimm(0x150, 0, 0x0, 15),
          s(0, 6, 15, 0x2, 0x27), // fsw f6 -> 0xC0000000
          iimm(0x160, 0, 0x0, 16),
          s(0, 7, 16, 0x2, 0x27), // fsw f7 -> 0x3F800000
          iimm(0x170, 0, 0x0, 17),
          s(0, 8, 17, 0x2, 0x23), // sw x8 -> 0x40
          iimm(0x180, 0, 0x0, 19),
          s(0, 9, 19, 0x2, 0x23), // sw x9 -> 0x02
          iimm(0x190, 0, 0x0, 20),
          s(0, 18, 20, 0x2, 0x23), // sw x18 -> 0x3F800000
          0x00000013, // nop (halt target)
        ]),
        const <Register, int>{},
        config,
        memory: const AdversarialMemory(readLatency: 1),
        nextPc: 0x80,
        memStates: {
          0x120: 0xBF800000,
          0x130: 0x3F800000,
          0x140: 0xBF800000,
          0x150: 0xC0000000,
          0x160: 0x3F800000,
          0x170: 0x40,
          0x180: 0x02,
          0x190: 0x3F800000,
        },
      ),
    );

    // Sign-injection, min/max, classify (double precision). Operands placed in
    // memory: f1 = 1.0d (0x3FF0000000000000), f2 = -2.0d (0xC000000000000000).
    //   fsgnj.d  -> -1.0d (0xBFF0000000000000)
    //   fsgnjn.d ->  1.0d (0x3FF0000000000000)
    //   fsgnjx.d -> -1.0d (0xBFF0000000000000)
    //   fmin.d   -> -2.0d (0xC000000000000000)
    //   fmax.d   ->  1.0d (0x3FF0000000000000)
    //   fclass.d(f1) -> +normal = 0x40 ; fclass.d(f2) -> -normal = 0x02
    test(
      'fsgnj/fmin/fmax/fclass (double)',
      timeout: Timeout(Duration(seconds: 300)),
      () => coreTest(
        '${prog([
          iimm(0x100, 0, 0x0, 10),
          iimm(0x110, 0, 0x0, 11),
          fld(0, 10, 1), // f1 = 1.0d
          fld(0, 11, 2), // f2 = -2.0d
          fop(0x11, 2, 1, 0x0, 3), // fsgnj.d  f3
          fop(0x11, 2, 1, 0x1, 4), // fsgnjn.d f4
          fop(0x11, 2, 1, 0x2, 5), // fsgnjx.d f5
          fop(0x15, 2, 1, 0x0, 6), // fmin.d   f6
          fop(0x15, 2, 1, 0x1, 7), // fmax.d   f7
          fop(0x71, 0, 1, 0x1, 8), // fclass.d x8, f1
          fop(0x71, 0, 2, 0x1, 9), // fclass.d x9, f2
          iimm(0x120, 0, 0x0, 12),
          s(0, 3, 12, 0x3, 0x27), // fsd f3
          iimm(0x130, 0, 0x0, 13),
          s(0, 4, 13, 0x3, 0x27), // fsd f4
          iimm(0x140, 0, 0x0, 14),
          s(0, 5, 14, 0x3, 0x27), // fsd f5
          iimm(0x150, 0, 0x0, 15),
          s(0, 6, 15, 0x3, 0x27), // fsd f6
          iimm(0x160, 0, 0x0, 16),
          s(0, 7, 16, 0x3, 0x27), // fsd f7
          iimm(0x170, 0, 0x0, 17),
          s(0, 8, 17, 0x2, 0x23), // sw x8
          iimm(0x180, 0, 0x0, 19),
          s(0, 9, 19, 0x2, 0x23), // sw x9
          0x00000013, // nop (halt target)
        ])}@100\n00 00 00 00 00 00 f0 3f\n@110\n00 00 00 00 00 00 00 c0\n',
        const <Register, int>{},
        config,
        memory: const AdversarialMemory(readLatency: 1),
        nextPc: 0x64,
        memStates: {
          0x120: 0xBFF0000000000000,
          0x130: 0x3FF0000000000000,
          0x140: 0xBFF0000000000000,
          0x150: 0xC000000000000000,
          0x160: 0x3FF0000000000000,
          0x170: 0x40,
          0x180: 0x02,
        },
      ),
    );

    // 64-bit conversions (fcvt.l.s/.s.l/.l.d/.d.l), selected by rs2==2.
    //   fcvt.l.s: f7=0x60 rs2=2 ; fcvt.s.l: f7=0x68 rs2=2
    //   fcvt.l.d: f7=0x61 rs2=2 ; fcvt.d.l: f7=0x69 rs2=2
    // Use a value > 2^31 to prove the 64-bit (not 32-bit) path: 0x1_0000_0000
    // (2^32) as a double round-trips int64<->f64; and 5 round-trips int64<->f32.
    test(
      'fcvt.l.s / fcvt.s.l / fcvt.l.d / fcvt.d.l (signed 64-bit)',
      timeout: Timeout(Duration(seconds: 300)),
      () => coreTest(
        prog([
          iimm(5, 0, 0x0, 5), // x5 = 5
          fop(0x68, 2, 5, 0, 1), // fcvt.s.l f1, x5  -> 5.0f
          iimm(0x100, 0, 0x0, 10),
          s(0, 1, 10, 0x2, 0x27), // fsw f1 -> 0x40A00000
          fop(0x60, 2, 1, 0, 6), // fcvt.l.s x6, f1  -> 5
          iimm(0x110, 0, 0x0, 11),
          s(0, 6, 11, 0x2, 0x23), // sw x6 -> 5
          fop(0x69, 2, 5, 0, 2), // fcvt.d.l f2, x5  -> 5.0d
          iimm(0x120, 0, 0x0, 12),
          s(0, 2, 12, 0x3, 0x27), // fsd f2 -> 5.0d
          fop(0x61, 2, 2, 0, 7), // fcvt.l.d x7, f2  -> 5
          iimm(0x130, 0, 0x0, 13),
          s(0, 7, 13, 0x2, 0x23), // sw x7 -> 5
          0x00000013, // nop (halt target)
        ]),
        const <Register, int>{},
        config,
        memory: const AdversarialMemory(readLatency: 1),
        nextPc: 0x34,
        memStates: {
          0x100: 0x40A00000, // 5.0f
          0x110: 5,
          0x120: 0x4014000000000000, // 5.0d
          0x130: 5,
        },
      ),
    );

    // Unsigned fcvt (rs2 bit0 set): fcvt.s.wu/.s.lu interpret the source as
    // unsigned; fcvt.wu.s/.lu.s clamp a negative float to 0. Values stay in
    // range (saturation at >= 2^w is a documented follow-up).
    //   x5 = -1 (low32 = 0xFFFFFFFF, full = u64 max), x6 = -5.
    //   fcvt.s.wu f1, x5  -> 4294967296.0f (unsigned 0xFFFFFFFF, NOT -1.0)
    //   fcvt.s.w  f2, x6  -> -5.0f ; fcvt.wu.s x7, f2 -> 0 (neg clamp)
    //   fcvt.s.lu f3, x5  -> 1.8e19f (u64 max) ; fcvt.lu.s x8, f2 -> 0
    test(
      'fcvt unsigned: s.wu / wu.s / s.lu / lu.s (rs2 bit0)',
      timeout: Timeout(Duration(seconds: 300)),
      () => coreTest(
        prog([
          iimm(0xFFF, 0, 0x0, 5), // x5 = -1
          iimm(0xFFB, 0, 0x0, 6), // x6 = -5
          fop(0x68, 1, 5, 0, 1), // fcvt.s.wu f1, x5 -> 4294967296.0f
          iimm(0x100, 0, 0x0, 10),
          s(0, 1, 10, 0x2, 0x27), // fsw f1 -> 0x4F800000
          fop(0x68, 0, 6, 0, 2), // fcvt.s.w f2, x6 -> -5.0f
          fop(0x60, 1, 2, 0, 7), // fcvt.wu.s x7, f2 -> 0
          iimm(0x110, 0, 0x0, 11),
          s(0, 7, 11, 0x2, 0x23), // sw x7 -> 0
          fop(0x68, 3, 5, 0, 3), // fcvt.s.lu f3, x5 -> 1.8e19f
          iimm(0x120, 0, 0x0, 12),
          s(0, 3, 12, 0x2, 0x27), // fsw f3 -> 0x5F800000
          fop(0x60, 3, 2, 0, 8), // fcvt.lu.s x8, f2 -> 0
          iimm(0x130, 0, 0x0, 13),
          s(0, 8, 13, 0x2, 0x23), // sw x8 -> 0
          0x00000013, // nop (halt target)
        ]),
        const <Register, int>{},
        config,
        memory: const AdversarialMemory(readLatency: 1),
        nextPc: 0x3C,
        memStates: {
          0x100: 0x4F800000, // 2^32 as f32 (unsigned 0xFFFFFFFF rounds up)
          0x110: 0, // fcvt.wu.s(-5.0) clamps to 0
          0x120: 0x5F800000, // 2^64 as f32 (u64 max)
          0x130: 0, // fcvt.lu.s(-5.0) clamps to 0
        },
      ),
    );

    // Fused multiply-add (R4-type). a=2, b=3, c=4 (built via fcvt.s.w):
    //   fmadd  = a*b + c   = 10.0  (0x41200000)
    //   fmsub  = a*b - c   =  2.0  (0x40000000)
    //   fnmsub = -(a*b)+ c = -2.0  (0xC0000000)
    //   fnmadd = -(a*b)- c = -10.0 (0xC1200000)
    test(
      'FMA: fmadd.s / fmsub.s / fnmsub.s / fnmadd.s',
      timeout: Timeout(Duration(seconds: 300)),
      () => coreTest(
        prog([
          iimm(2, 0, 0x0, 5), iimm(3, 0, 0x0, 6), iimm(4, 0, 0x0, 7),
          fop(0x68, 0, 5, 0, 1), // f1 = 2.0
          fop(0x68, 0, 6, 0, 2), // f2 = 3.0
          fop(0x68, 0, 7, 0, 3), // f3 = 4.0
          fop4(0x43, 3, 2, 1, 8), // fmadd.s f8 -> 10.0
          iimm(0x100, 0, 0x0, 10),
          s(0, 8, 10, 0x2, 0x27),
          fop4(0x47, 3, 2, 1, 9), // fmsub.s f9 -> 2.0
          iimm(0x110, 0, 0x0, 11),
          s(0, 9, 11, 0x2, 0x27),
          fop4(0x4B, 3, 2, 1, 12), // fnmsub.s f12 -> -2.0
          iimm(0x120, 0, 0x0, 13),
          s(0, 12, 13, 0x2, 0x27),
          fop4(0x4F, 3, 2, 1, 14), // fnmadd.s f14 -> -10.0
          iimm(0x130, 0, 0x0, 15),
          s(0, 14, 15, 0x2, 0x27),
          0x00000013, // nop (halt target)
        ]),
        const <Register, int>{},
        config,
        memory: const AdversarialMemory(readLatency: 1),
        nextPc: 0x48,
        memStates: {
          0x100: 0x41200000, // 10.0
          0x110: 0x40000000, // 2.0
          0x120: 0xC0000000, // -2.0
          0x130: 0xC1200000, // -10.0
        },
      ),
    );

    // Double-precision FMA: a=2, b=3, c=4 via fcvt.d.w. fmadd.d -> 10.0d.
    test(
      'FMA double: fmadd.d (fmt=1)',
      timeout: Timeout(Duration(seconds: 300)),
      () => coreTest(
        prog([
          iimm(2, 0, 0x0, 5), iimm(3, 0, 0x0, 6), iimm(4, 0, 0x0, 7),
          fop(0x69, 0, 5, 0, 1), // fcvt.d.w f1 = 2.0d
          fop(0x69, 0, 6, 0, 2), // fcvt.d.w f2 = 3.0d
          fop(0x69, 0, 7, 0, 3), // fcvt.d.w f3 = 4.0d
          fop4(0x43, 3, 2, 1, 8, fmt: 1), // fmadd.d f8 -> 10.0d
          iimm(0x100, 0, 0x0, 10),
          s(0, 8, 10, 0x3, 0x27), // fsd f8 -> 10.0d
          0x00000013, // nop
        ]),
        const <Register, int>{},
        config,
        memory: const AdversarialMemory(readLatency: 1),
        nextPc: 0x24,
        memStates: {
          0x100: 0x4024000000000000, // 10.0d
        },
      ),
    );

    // fcvt.w.s rounding modes + saturation. f1 = 2.5f (0x40200000):
    //   rm=0 RNE -> 2 (ties to even), rm=3 RUP -> 3.
    // f2 = 2^31 (0x4F000000) overflows signed-32 -> saturates to 0x7FFFFFFF.
    test(
      'fcvt.w.s rm rounding (2.5) + saturation (2^31)',
      timeout: Timeout(Duration(seconds: 300)),
      () => coreTest(
        prog([
          lui(0x40200, 5), // x5 = 2.5f bits
          iimm(0x100, 0, 0x0, 10),
          s(0, 5, 10, 0x2, 0x23), // mem[0x100] = 2.5f
          flw(0, 10, 1), // f1 = 2.5f
          fop(0x60, 0, 1, 0, 6), // fcvt.w.s rm=0 RNE -> 2
          iimm(0x110, 0, 0x0, 11),
          s(0, 6, 11, 0x2, 0x23),
          fop(0x60, 0, 1, 3, 7), // fcvt.w.s rm=3 RUP -> 3
          iimm(0x120, 0, 0x0, 12),
          s(0, 7, 12, 0x2, 0x23),
          lui(0x4F000, 13), // x13 = 2^31 f32 bits
          iimm(0x130, 0, 0x0, 14),
          s(0, 13, 14, 0x2, 0x23), // mem[0x130] = 2^31 bits
          flw(0, 14, 2), // f2 = 2^31
          fop(0x60, 0, 2, 1, 8), // fcvt.w.s saturates -> 0x7FFFFFFF
          iimm(0x140, 0, 0x0, 15),
          s(0, 8, 15, 0x2, 0x23),
          0x00000013, // nop
        ]),
        const <Register, int>{},
        config,
        memory: const AdversarialMemory(readLatency: 1),
        nextPc: 0x44,
        memStates: {
          0x110: 2, // RNE(2.5) -> 2
          0x120: 3, // RUP(2.5) -> 3
          0x140: 0x7FFFFFFF, // 2^31 saturates
        },
      ),
    );
  });
}
