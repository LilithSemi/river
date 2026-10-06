import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/src/core/iterative_fp_arith.dart';
import 'package:test/test.dart';

import 'fma_reference.dart';

/// Non-fused operations use Dart's IEEE arithmetic as their reference. FMA
/// uses exact integer arithmetic so the oracle does not round the product.
///
/// The execution unit reads this core for fadd, fsub, fmul, fdiv and the four
/// fused multiply-add forms, at both precisions, because a single-precision
/// operation widens into the double unit first. So the binary64 direction is
/// the one that must be exact to the last bit.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  int f64Bits(double v) => (ByteData(8)..setFloat64(0, v)).getUint64(0);
  double bitsF64(int v) => (ByteData(8)..setUint64(0, v)).getFloat64(0);
  int f32Bits(double v) => (ByteData(4)..setFloat32(0, v)).getUint32(0);
  double bitsF32(int v) => (ByteData(4)..setUint32(0, v)).getFloat32(0);

  Future<List<int>> run(
    List<List<Object>> jobs, {
    required int exponentWidth,
    required int mantissaWidth,
  }) async {
    final width = 1 + exponentWidth + mantissaWidth;
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final opA = Logic(name: 'opA', width: width);
    final opB = Logic(name: 'opB', width: width);
    final opC = Logic(name: 'opC', width: width);
    final selFma = Logic(name: 'selFma');
    final selNegA = Logic(name: 'selNegA');
    final selNegB = Logic(name: 'selNegB');
    final selDiv = Logic(name: 'selDiv');
    final selMul = Logic(name: 'selMul');
    final selCvt = Logic(name: 'selCvt');
    final selSingle = Logic(name: 'selSingle');
    final dut = IterativeFpArith(
      clk,
      reset,
      start,
      opA,
      opB,
      opC,
      selFma,
      selNegA,
      selNegB,
      selDiv,
      selMul,
      selCvt,
      selSingle,
      exponentWidth: exponentWidth,
      mantissaWidth: mantissaWidth,
    );
    await dut.build();
    reset.inject(1);
    start.inject(0);
    opA.inject(0);
    opB.inject(0);
    opC.inject(0);
    selFma.inject(0);
    selNegA.inject(0);
    selNegB.inject(0);
    selDiv.inject(0);
    selMul.inject(0);
    selCvt.inject(0);
    selSingle.inject(0);
    unawaited(Simulator.run());
    for (var i = 0; i < 3; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 2; i++) {
      await clk.nextPosedge;
    }

    final out = <int>[];
    for (final job in jobs) {
      opA.inject(job[0] as int);
      opB.inject(job[1] as int);
      opC.inject(job[2] as int);
      selFma.inject(job[3] as int);
      selNegA.inject(job[4] as int);
      selNegB.inject(job[5] as int);
      selDiv.inject(job[6] as int);
      selMul.inject(job[7] as int);
      selCvt.inject(job.length > 8 ? job[8] as int : 0);
      selSingle.inject(job.length > 9 ? job[9] as int : 0);
      start.inject(1);
      var guard = 0;
      while (dut.done.value.toInt() == 0) {
        await clk.nextPosedge;
        guard++;
        if (guard > 5000) {
          fail('operation never finished');
        }
      }
      out.add(dut.result.value.toInt());
      start.inject(0);
      for (var i = 0; i < 2; i++) {
        await clk.nextPosedge;
      }
    }
    await Simulator.endSimulation();
    return out;
  }

  // Operand/select tuples for the eight arithmetic forms.
  List<Object> add(int a, int b) => [a, b, 0, 0, 0, 0, 0, 0];
  List<Object> sub(int a, int b) => [a, b, 0, 0, 0, 1, 0, 0];
  List<Object> mul(int a, int b) => [a, b, 0, 0, 0, 0, 0, 1];
  List<Object> div(int a, int b) => [a, b, 0, 0, 0, 0, 1, 0];
  List<Object> fmadd(int a, int b, int c) => [a, b, c, 1, 0, 0, 0, 0];
  List<Object> fmsub(int a, int b, int c) => [a, b, c, 1, 0, 1, 0, 0];
  List<Object> fnmsub(int a, int b, int c) => [a, b, c, 1, 1, 0, 0, 0];
  List<Object> fnmadd(int a, int b, int c) => [a, b, c, 1, 1, 1, 0, 0];

  for (final shape in [(8, 23, false), (11, 52, false), (11, 52, true)]) {
    final (e, m, narrow) = shape;
    final single = narrow || e == 8;
    final eb = single ? 8 : 11;
    final mb = single ? 23 : 52;
    final directed = single
        ? <List<int>>[
            [0x3f800001, 0x3f7ffffe, 0xbf800000, 0xa8800000],
            [0x7f7fffff, 0x40000000, 0xff7fffff, 0x7f7fffff],
            [1, 0x3f000000, 1, 2],
            [0x80000000, 0x40000000, 0x80000000, 0x80000000],
            [0x7f800000, 0, 0x3f800000, 0x7fc00000],
          ]
        : <List<int>>[
            [
              0x3ff0000000000001,
              0x3feffffffffffffe,
              0xbff0000000000000,
              0xb970000000000000,
            ],
            [
              0x7fefffffffffffff,
              0x4000000000000000,
              0xffefffffffffffff,
              0x7fefffffffffffff,
            ],
            [1, 0x3fe0000000000000, 1, 2],
            [
              0x8000000000000000,
              0x4000000000000000,
              0x8000000000000000,
              0x8000000000000000,
            ],
            [0x7ff0000000000000, 0, 0x3ff0000000000000, 0x7ff8000000000000],
          ];
    test('single-rounding FMA e=$e m=$m narrow=$narrow', () async {
      for (final row in directed) {
        expect(
          fusedBits(row[0], row[1], row[2], exponentBits: eb, fractionBits: mb),
          row[3],
          reason: 'independent exact cancellation/range/special witness',
        );
      }
      final rnd = math.Random(0xf00d);
      int randomBits() => single
          ? rnd.nextInt(1 << 32)
          : (rnd.nextInt(1 << 32) << 32) | rnd.nextInt(1 << 32);
      final triples = <List<int>>[
        for (final row in directed) row.sublist(0, 3),
        for (var i = 0; i < 128; i++)
          [randomBits(), randomBits(), randomBits()],
      ];
      // Cancellation exposes low product bits that broad random exponents
      // rarely exercise. The rounded host product is only the input addend,
      // never the expected fused answer.
      for (var i = 0; i < 64; i++) {
        final a = single
            ? 0x3f800000 | rnd.nextInt(1 << 23)
            : 0x3ff0000000000000 | (randomBits() & 0x000fffffffffffff);
        final b = single
            ? 0x3f800000 | rnd.nextInt(1 << 23)
            : 0x3ff0000000000000 | (randomBits() & 0x000fffffffffffff);
        final c = single
            ? f32Bits(-bitsF32(a) * bitsF32(b))
            : f64Bits(-bitsF64(a) * bitsF64(b));
        triples.add([a, b, c]);
      }
      final jobs = <List<Object>>[];
      final expected = <int>[];
      for (final row in triples) {
        for (final negateProduct in [false, true]) {
          for (final negateAddend in [false, true]) {
            jobs.add([
              row[0],
              row[1],
              row[2],
              1,
              negateProduct ? 1 : 0,
              negateAddend ? 1 : 0,
              0,
              0,
              0,
              narrow ? 1 : 0,
            ]);
            expected.add(
              fusedBits(
                row[0],
                row[1],
                row[2],
                exponentBits: eb,
                fractionBits: mb,
                negateProduct: negateProduct,
                negateAddend: negateAddend,
              ),
            );
          }
        }
      }
      final got = await run(jobs, exponentWidth: e, mantissaWidth: m);
      for (var i = 0; i < got.length; i++) {
        expect(got[i], expected[i], reason: 'FMA job $i: ${jobs[i]}');
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  }

  List<double> spread(math.Random rnd, int count) {
    final vals = <double>[
      1.0,
      2.0,
      -1.0,
      0.5,
      3.0,
      -3.0,
      1e300,
      1e-300,
      math.pi,
      -math.e,
      1.0000000000000002,
      4.9e-324, // smallest subnormal
      2.2250738585072011e-308, // largest subnormal
      2.2250738585072014e-308, // smallest normal
      1.7976931348623157e308, // largest finite
      -4.9e-324,
      123456789.0,
      1.0 / 3.0,
    ];
    for (var i = 0; i < count; i++) {
      final v = rnd.nextDouble() * math.pow(2.0, rnd.nextInt(200) - 100);
      vals.add(rnd.nextBool() ? v : -v);
    }
    return vals;
  }

  test(
    'binary64 add and subtract are bit exact',
    () async {
      final rnd = math.Random(7);
      final vals = spread(rnd, 24);
      final jobs = <List<Object>>[];
      final want = <int>[];
      for (var i = 0; i < vals.length; i++) {
        for (var k = 0; k < 4; k++) {
          final b = vals[(i * 5 + k * 3 + 1) % vals.length];
          jobs.add(add(f64Bits(vals[i]), f64Bits(b)));
          want.add(f64Bits(vals[i] + b));
          jobs.add(sub(f64Bits(vals[i]), f64Bits(b)));
          want.add(f64Bits(vals[i] - b));
        }
      }
      final got = await run(jobs, exponentWidth: 11, mantissaWidth: 52);
      for (var i = 0; i < jobs.length; i++) {
        expect(
          got[i].toRadixString(16),
          want[i].toRadixString(16),
          reason:
              'job $i: ${bitsF64(jobs[i][0] as int)} op '
              '${bitsF64(jobs[i][1] as int)}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'binary64 multiply and divide are bit exact',
    () async {
      final rnd = math.Random(11);
      final vals = spread(rnd, 24);
      final jobs = <List<Object>>[];
      final want = <int>[];
      for (var i = 0; i < vals.length; i++) {
        for (var k = 0; k < 4; k++) {
          final b = vals[(i * 7 + k * 3 + 2) % vals.length];
          jobs.add(mul(f64Bits(vals[i]), f64Bits(b)));
          want.add(f64Bits(vals[i] * b));
          jobs.add(div(f64Bits(vals[i]), f64Bits(b)));
          want.add(f64Bits(vals[i] / b));
        }
      }
      final got = await run(jobs, exponentWidth: 11, mantissaWidth: 52);
      for (var i = 0; i < jobs.length; i++) {
        expect(
          got[i].toRadixString(16),
          want[i].toRadixString(16),
          reason:
              'job $i: ${bitsF64(jobs[i][0] as int)} op '
              '${bitsF64(jobs[i][1] as int)}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'binary64 fused multiply-add forms are bit exact',
    () async {
      final rnd = math.Random(13);
      final vals = spread(rnd, 12);
      final jobs = <List<Object>>[];
      final want = <int>[];
      for (var i = 0; i < vals.length; i++) {
        final a = vals[i];
        final b = vals[(i * 3 + 1) % vals.length];
        final c = vals[(i * 5 + 2) % vals.length];
        final ab = f64Bits(a);
        final bb = f64Bits(b);
        final cb = f64Bits(c);
        jobs.add(fmadd(ab, bb, cb));
        want.add(fusedBits(ab, bb, cb, exponentBits: 11, fractionBits: 52));
        jobs.add(fmsub(ab, bb, cb));
        want.add(
          fusedBits(
            ab,
            bb,
            cb,
            exponentBits: 11,
            fractionBits: 52,
            negateAddend: true,
          ),
        );
        jobs.add(fnmsub(ab, bb, cb));
        want.add(
          fusedBits(
            ab,
            bb,
            cb,
            exponentBits: 11,
            fractionBits: 52,
            negateProduct: true,
          ),
        );
        jobs.add(fnmadd(ab, bb, cb));
        want.add(
          fusedBits(
            ab,
            bb,
            cb,
            exponentBits: 11,
            fractionBits: 52,
            negateProduct: true,
            negateAddend: true,
          ),
        );
      }
      final got = await run(jobs, exponentWidth: 11, mantissaWidth: 52);
      for (var i = 0; i < jobs.length; i++) {
        expect(
          got[i].toRadixString(16),
          want[i].toRadixString(16),
          reason: 'job $i',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'binary64 special values follow IEEE',
    () async {
      const pInf = 0x7ff0000000000000;
      const nInf = 0xfff0000000000000;
      const qNaN = 0x7ff8000000000000;
      const pZero = 0x0000000000000000;
      const nZero = 0x8000000000000000;
      const one = 0x3ff0000000000000;
      const negOne = 0xbff0000000000000;
      final jobs = <List<Object>>[
        add(pInf, nInf), // NaN
        add(pInf, one), // +inf
        add(pZero, nZero), // +0
        add(nZero, nZero), // -0
        sub(one, one), // +0
        add(qNaN, one), // NaN
        mul(pInf, pZero), // NaN
        mul(nInf, one), // -inf
        mul(pZero, negOne), // -0
        div(one, pZero), // +inf
        div(negOne, pZero), // -inf
        div(pZero, pZero), // NaN
        div(pInf, pInf), // NaN
        div(one, pInf), // +0
        div(one, nInf), // -0
        mul(0x7fefffffffffffff, 0x7fefffffffffffff), // overflow to +inf
        mul(1, 1), // underflow to +0
        fmadd(pInf, pZero, one), // NaN
      ];
      final want = <int>[
        qNaN,
        pInf,
        pZero,
        nZero,
        pZero,
        qNaN,
        qNaN,
        nInf,
        nZero,
        pInf,
        nInf,
        qNaN,
        qNaN,
        pZero,
        nZero,
        pInf,
        pZero,
        qNaN,
      ];
      final got = await run(jobs, exponentWidth: 11, mantissaWidth: 52);
      for (var i = 0; i < jobs.length; i++) {
        expect(
          got[i].toRadixString(16),
          want[i].toRadixString(16),
          reason: 'special job $i',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'binary64 subnormal results round correctly',
    () async {
      // Products and quotients that land inside the subnormal range, where the
      // answer needs a right shift and a second rounding.
      final pairs = <List<double>>[
        [4.9e-324, 0.5],
        [4.9e-324, 1.5],
        [2.2250738585072014e-308, 0.5],
        [2.2250738585072014e-308, 1.0 / 3.0],
        [1e-300, 1e-30],
        [5e-324, 3.0],
        [2.2250738585072011e-308, 2.0],
      ];
      final jobs = <List<Object>>[];
      final want = <int>[];
      for (final p in pairs) {
        jobs.add(mul(f64Bits(p[0]), f64Bits(p[1])));
        want.add(f64Bits(p[0] * p[1]));
        jobs.add(div(f64Bits(p[0]), f64Bits(p[1])));
        want.add(f64Bits(p[0] / p[1]));
        jobs.add(add(f64Bits(p[0]), f64Bits(p[1])));
        want.add(f64Bits(p[0] + p[1]));
      }
      final got = await run(jobs, exponentWidth: 11, mantissaWidth: 52);
      for (var i = 0; i < jobs.length; i++) {
        expect(
          got[i].toRadixString(16),
          want[i].toRadixString(16),
          reason: 'subnormal job $i',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'binary32 arithmetic is bit exact',
    () async {
      // An F-without-D core builds the unit at binary32. Every operand and
      // answer here is exact in binary32, so Dart's binary64 arithmetic gives
      // the same bits after the narrowing.
      final vals = <double>[1.0, 2.0, 3.0, -4.0, 0.5, 0.25, 6.0, -1.5, 1024.0];
      final jobs = <List<Object>>[];
      final want = <int>[];
      for (var i = 0; i < vals.length; i++) {
        final a = vals[i];
        final b = vals[(i * 3 + 1) % vals.length];
        jobs.add(add(f32Bits(a), f32Bits(b)));
        want.add(f32Bits(a + b));
        jobs.add(sub(f32Bits(a), f32Bits(b)));
        want.add(f32Bits(a - b));
        jobs.add(mul(f32Bits(a), f32Bits(b)));
        want.add(f32Bits(a * b));
        jobs.add(div(f32Bits(a), f32Bits(b)));
        want.add(f32Bits(a / b));
      }
      final got = await run(jobs, exponentWidth: 8, mantissaWidth: 23);
      for (var i = 0; i < jobs.length; i++) {
        expect(
          got[i].toRadixString(16),
          want[i].toRadixString(16),
          reason: 'f32 job $i: ${bitsF32(jobs[i][0] as int)}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'binary64 random bit patterns are bit exact',
    () async {
      // Uniform random bit patterns, not random reals: these land all over the
      // exponent range and hit subnormals, huge/tiny exponent gaps and exact
      // cancellation far more often than sampling doubles does. NaN operands are
      // covered by the special-value test instead, because Dart keeps a payload.
      final rnd = math.Random(20260907);
      final jobs = <List<Object>>[];
      final want = <int>[];
      double pick() {
        while (true) {
          final hi = rnd.nextInt(1 << 32);
          final lo = rnd.nextInt(1 << 32);
          final v = bitsF64((hi << 32) | lo);
          if (!v.isNaN) {
            return v;
          }
        }
      }

      for (var i = 0; i < 90; i++) {
        final a = pick();
        final b = pick();
        final ab = f64Bits(a);
        final bb = f64Bits(b);
        jobs.add(add(ab, bb));
        want.add(f64Bits(a + b));
        jobs.add(sub(ab, bb));
        want.add(f64Bits(a - b));
        jobs.add(mul(ab, bb));
        want.add(f64Bits(a * b));
        jobs.add(div(ab, bb));
        want.add(f64Bits(a / b));
      }
      // Values that share an exponent, so the alignment is zero and the subtract
      // cancels most of the significand.
      for (var i = 0; i < 30; i++) {
        final base = rnd.nextInt(1 << 32);
        final a = bitsF64((0x3ff00000 << 32) | base);
        final b = bitsF64((0x3ff00000 << 32) | rnd.nextInt(1 << 32));
        jobs.add(sub(f64Bits(a), f64Bits(b)));
        want.add(f64Bits(a - b));
        jobs.add(add(f64Bits(a), f64Bits(b)));
        want.add(f64Bits(a + b));
      }
      final got = await run(jobs, exponentWidth: 11, mantissaWidth: 52);
      for (var i = 0; i < jobs.length; i++) {
        expect(
          got[i].toRadixString(16),
          want[i].toRadixString(16),
          reason:
              'job $i: ${bitsF64(jobs[i][0] as int)} sel'
              '${jobs[i].sublist(3)} ${bitsF64(jobs[i][1] as int)}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  // Single-precision jobs on the binary64 unit: the operands are binary32 in
  // the low bits and the answer comes back binary32.
  List<Object> addS(int a, int b) => [a, b, 0, 0, 0, 0, 0, 0, 0, 1];
  List<Object> subS(int a, int b) => [a, b, 0, 0, 0, 1, 0, 0, 0, 1];
  List<Object> mulS(int a, int b) => [a, b, 0, 0, 0, 0, 0, 1, 0, 1];
  List<Object> divS(int a, int b) => [a, b, 0, 0, 0, 0, 1, 0, 0, 1];
  List<Object> fmaddS(int a, int b, int c) => [a, b, c, 1, 0, 0, 0, 0, 0, 1];
  List<Object> fnmaddS(int a, int b, int c) => [a, b, c, 1, 1, 1, 0, 0, 0, 1];
  // fcvt.s.d rounds a binary64 operand to binary32; the precision select names
  // the SOURCE format, so it is low here and high for fcvt.d.s.
  List<Object> cvtSD(int a) => [a, 0, 0, 0, 0, 0, 0, 0, 1, 0];
  List<Object> cvtDS(int a) => [a, 0, 0, 0, 0, 0, 0, 0, 1, 1];

  test(
    'single-precision arithmetic on the double unit is bit exact',
    () async {
      final rnd = math.Random(31337);
      final vals = <double>[
        1.0,
        2.0,
        -1.0,
        0.5,
        3.0,
        -7.0,
        1.0 / 3.0,
        1e30,
        1e-30,
        math.pi,
        1.401298464324817e-45, // smallest binary32 subnormal
        1.1754942106924411e-38, // largest binary32 subnormal
        1.1754943508222875e-38, // smallest binary32 normal
        3.4028234663852886e38, // largest finite binary32
        -1.401298464324817e-45,
      ].map((v) => bitsF32(f32Bits(v))).toList();
      for (var i = 0; i < 40; i++) {
        final v = bitsF32(
          f32Bits(rnd.nextDouble() * math.pow(2.0, rnd.nextInt(60) - 30)),
        );
        vals.add(rnd.nextBool() ? v : -v);
      }
      final jobs = <List<Object>>[];
      final want = <int>[];
      for (var i = 0; i < vals.length; i++) {
        final a = vals[i];
        final b = vals[(i * 5 + 3) % vals.length];
        final c = vals[(i * 7 + 1) % vals.length];
        final ab = f32Bits(a);
        final bb = f32Bits(b);
        final cb = f32Bits(c);
        jobs.add(addS(ab, bb));
        want.add(f32Bits(a + b));
        jobs.add(subS(ab, bb));
        want.add(f32Bits(a - b));
        jobs.add(mulS(ab, bb));
        want.add(f32Bits(a * b));
        jobs.add(divS(ab, bb));
        want.add(f32Bits(a / b));
        jobs.add(fmaddS(ab, bb, cb));
        want.add(fusedBits(ab, bb, cb, exponentBits: 8, fractionBits: 23));
        jobs.add(fnmaddS(ab, bb, cb));
        want.add(
          fusedBits(
            ab,
            bb,
            cb,
            exponentBits: 8,
            fractionBits: 23,
            negateProduct: true,
            negateAddend: true,
          ),
        );
      }
      final got = await run(jobs, exponentWidth: 11, mantissaWidth: 52);
      for (var i = 0; i < jobs.length; i++) {
        expect(
          got[i].toRadixString(16),
          want[i].toRadixString(16),
          reason:
              'job $i: ${bitsF32(jobs[i][0] as int)} sel${jobs[i].sublist(3)} '
              '${bitsF32(jobs[i][1] as int)}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    'single-precision specials and overflow follow IEEE',
    () async {
      const pInfS = 0x7f800000;
      const nInfS = 0xff800000;
      const qNaNS = 0x7fc00000;
      const oneS = 0x3f800000;
      const negOneS = 0xbf800000;
      const maxS = 0x7f7fffff;
      final jobs = <List<Object>>[
        addS(pInfS, nInfS),
        addS(pInfS, oneS),
        addS(0, 0x80000000),
        addS(0x80000000, 0x80000000),
        subS(oneS, oneS),
        mulS(pInfS, 0),
        mulS(0, negOneS),
        divS(oneS, 0),
        divS(negOneS, 0),
        divS(0, 0),
        mulS(maxS, maxS), // overflow to +inf
        mulS(1, 1), // underflow to +0
        addS(maxS, maxS), // overflow to +inf
        addS(1, 0), // smallest subnormal plus zero stays exact
      ];
      final want = <int>[
        qNaNS,
        pInfS,
        0,
        0x80000000,
        0,
        qNaNS,
        0x80000000,
        pInfS,
        nInfS,
        qNaNS,
        pInfS,
        0,
        pInfS,
        1,
      ];
      final got = await run(jobs, exponentWidth: 11, mantissaWidth: 52);
      for (var i = 0; i < jobs.length; i++) {
        expect(
          got[i].toRadixString(16),
          want[i].toRadixString(16),
          reason: 'single special job $i',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'fcvt.s.d and fcvt.d.s are bit exact',
    () async {
      final rnd = math.Random(4242);
      final wide = <double>[
        1.0,
        -1.0,
        0.5,
        1.0 / 3.0,
        math.pi,
        1e300, // overflows binary32
        -1e300,
        1e-300, // underflows binary32 to zero
        1e-40, // lands in the binary32 subnormal range
        1.4e-45,
        3.4028235677973366e38, // rounds up to binary32 infinity
        3.4028234663852886e38,
        2.2250738585072014e-308,
      ];
      for (var i = 0; i < 40; i++) {
        final v = rnd.nextDouble() * math.pow(2.0, rnd.nextInt(90) - 45);
        wide.add(rnd.nextBool() ? v : -v);
      }
      final jobs = <List<Object>>[];
      final want = <int>[];
      for (final v in wide) {
        jobs.add(cvtSD(f64Bits(v)));
        want.add(f32Bits(v));
      }
      // The other direction is exact for every binary32, subnormals included.
      final narrow = <double>[
        1.0,
        -2.5,
        1.401298464324817e-45,
        1.1754942106924411e-38,
        3.4028234663852886e38,
        0.0,
        -0.0,
      ];
      for (var i = 0; i < 25; i++) {
        narrow.add(
          bitsF32(
            f32Bits(rnd.nextDouble() * math.pow(2.0, rnd.nextInt(60) - 30)),
          ),
        );
      }
      for (final v in narrow) {
        jobs.add(cvtDS(f32Bits(v)));
        want.add(f64Bits(bitsF32(f32Bits(v))));
      }
      // Specials both ways.
      jobs.add(cvtSD(0x7ff0000000000000));
      want.add(0x7f800000);
      jobs.add(cvtSD(0xfff0000000000000));
      want.add(0xff800000);
      jobs.add(cvtSD(0x7ff8000000000000));
      want.add(0x7fc00000);
      jobs.add(cvtSD(0x8000000000000000));
      want.add(0x80000000);
      jobs.add(cvtDS(0x7f800000));
      want.add(0x7ff0000000000000);
      jobs.add(cvtDS(0x7fc00000));
      want.add(0x7ff8000000000000);
      jobs.add(cvtDS(0x80000000));
      want.add(0x8000000000000000);

      final got = await run(jobs, exponentWidth: 11, mantissaWidth: 52);
      for (var i = 0; i < jobs.length; i++) {
        expect(
          got[i].toRadixString(16),
          want[i].toRadixString(16),
          reason: 'convert job $i',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    'single-precision random bit patterns are bit exact',
    () async {
      // Uniform random binary32 patterns, which land all over the exponent range
      // and hit subnormals and exact cancellation far more often than sampling
      // reals does.
      final rnd = math.Random(90909);
      double pick() {
        while (true) {
          final v = bitsF32(rnd.nextInt(1 << 32));
          if (!v.isNaN) {
            return v;
          }
        }
      }

      final jobs = <List<Object>>[];
      final want = <int>[];
      for (var i = 0; i < 70; i++) {
        final a = pick();
        final b = pick();
        final ab = f32Bits(a);
        final bb = f32Bits(b);
        jobs.add(addS(ab, bb));
        want.add(f32Bits(a + b));
        jobs.add(subS(ab, bb));
        want.add(f32Bits(a - b));
        jobs.add(mulS(ab, bb));
        want.add(f32Bits(a * b));
        jobs.add(divS(ab, bb));
        want.add(f32Bits(a / b));
        jobs.add(cvtSD(f64Bits(a)));
        want.add(f32Bits(a));
      }
      final got = await run(jobs, exponentWidth: 11, mantissaWidth: 52);
      for (var i = 0; i < jobs.length; i++) {
        expect(
          got[i].toRadixString(16),
          want[i].toRadixString(16),
          reason:
              'job $i: ${bitsF32(jobs[i][0] as int)} sel${jobs[i].sublist(3)} '
              '${bitsF32(jobs[i][1] as int)}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
