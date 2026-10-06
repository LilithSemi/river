import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/src/core/iterative_fp_int.dart';
import 'package:test/test.dart';

/// [IterativeFpIntConvert] against an exact reference built on BigInt.
///
/// The execution unit reads this core for every fcvt between an integer and a
/// float, at both destination formats. Integer to float rounds once, and float
/// to integer reports the truncated magnitude with a round and a sticky bit
/// that the caller turns into the RISC-V rounding mode and saturation.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  int f64Bits(double v) => (ByteData(8)..setFloat64(0, v)).getUint64(0);
  double bitsF64(int v) => (ByteData(8)..setUint64(0, v)).getFloat64(0);

  /// Correctly rounded pack of a non-negative magnitude into a float with
  /// [mW] mantissa bits. Round to nearest, ties to even.
  int packFromBig(BigInt mag, bool neg, int eW, int mW) {
    final signBit = neg ? 1 << (eW + mW) : 0;
    if (mag == BigInt.zero) {
      return signBit;
    }
    final msb = mag.bitLength - 1;
    var exp = msb;
    BigInt sig;
    var up = false;
    final drop = msb - mW;
    if (drop <= 0) {
      sig = mag << (-drop);
    } else {
      sig = mag >> drop;
      final guard = (mag >> (drop - 1)) & BigInt.one;
      final rest = mag & ((BigInt.one << (drop - 1)) - BigInt.one);
      up =
          guard == BigInt.one &&
          (rest != BigInt.zero || (sig & BigInt.one) == BigInt.one);
    }
    if (up) {
      sig += BigInt.one;
      if (sig.bitLength > mW + 1) {
        sig = sig >> 1;
        exp += 1;
      }
    }
    final bias = (1 << (eW - 1)) - 1;
    final man = (sig & ((BigInt.one << mW) - BigInt.one)).toInt();
    return signBit | ((exp + bias) << mW) | man;
  }

  /// The magnitude, round bit and sticky bit of a binary64 value, and whether
  /// it is at least 2^64.
  ({BigInt mag, int round, int sticky, bool ovf}) magnitudeOf(int bits) {
    final expField = (bits >> 52) & 0x7ff;
    final man = BigInt.from(bits & 0xFFFFFFFFFFFFF);
    final sig = expField == 0 ? man : man | (BigInt.one << 52);
    final e = (expField == 0 ? 1 : expField) - 1023;
    final ovf = e >= 64;
    final shift = e - 52;
    if (shift >= 0) {
      return (mag: sig << shift, round: 0, sticky: 0, ovf: ovf);
    }
    final k = -shift;
    final mag = sig >> k;
    final round = ((sig >> (k - 1)) & BigInt.one).toInt();
    final rest = sig & ((BigInt.one << (k - 1)) - BigInt.one);
    return (
      mag: mag,
      round: round,
      sticky: rest == BigInt.zero ? 0 : 1,
      ovf: ovf,
    );
  }

  /// One job: [fp, int, signed, toInt, narrow].
  Future<List<({int fp, BigInt mag, int round, int sticky, int ovf})>> run(
    List<List<Object>> jobs,
  ) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final fpIn = Logic(name: 'fpIn', width: 64);
    final intIn = Logic(name: 'intIn', width: 64);
    final intSigned = Logic(name: 'intSigned');
    final toInt = Logic(name: 'toInt');
    final narrow = Logic(name: 'narrow');
    final dut = IterativeFpIntConvert(
      clk,
      reset,
      start,
      fpIn,
      intIn,
      intSigned,
      toInt,
      narrow,
    );
    await dut.build();
    reset.inject(1);
    start.inject(0);
    fpIn.inject(0);
    intIn.inject(0);
    intSigned.inject(0);
    toInt.inject(0);
    narrow.inject(0);
    unawaited(Simulator.run());
    for (var i = 0; i < 3; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 2; i++) {
      await clk.nextPosedge;
    }

    final out = <({int fp, BigInt mag, int round, int sticky, int ovf})>[];
    for (final job in jobs) {
      fpIn.inject(job[0] as int);
      intIn.inject(job[1] as BigInt);
      intSigned.inject(job[2] as int);
      toInt.inject(job[3] as int);
      narrow.inject(job[4] as int);
      start.inject(1);
      var guard = 0;
      while (dut.done.value.toInt() == 0) {
        await clk.nextPosedge;
        guard++;
        if (guard > 400) {
          fail('convert never finished');
        }
      }
      out.add((
        fp: dut.fpOut.value.toInt(),
        mag: dut.intMag.value.toBigInt(),
        round: dut.roundBit.value.toInt(),
        sticky: dut.sticky.value.toInt(),
        ovf: dut.overflow.value.toInt(),
      ));
      start.inject(0);
      for (var i = 0; i < 2; i++) {
        await clk.nextPosedge;
      }
    }
    await Simulator.endSimulation();
    return out;
  }

  List<Object> i2f(BigInt v, {required bool signed, required bool narrow}) => [
    0,
    v,
    signed ? 1 : 0,
    0,
    narrow ? 1 : 0,
  ];
  List<Object> f2i(int bits) => [bits, BigInt.zero, 0, 1, 0];
  // The same direction with a binary32 source, read from its own fields.
  List<Object> f2iN(int bits) => [bits, BigInt.zero, 0, 1, 1];

  int f32Bits(double v) => (ByteData(4)..setFloat32(0, v)).getUint32(0);
  double bitsF32(int v) => (ByteData(4)..setUint32(0, v)).getFloat32(0);

  final u64 = (BigInt.one << 64) - BigInt.one;

  test(
    'integer to binary64 is correctly rounded',
    () async {
      final rnd = math.Random(5150);
      final mags = <BigInt>[
        BigInt.zero,
        BigInt.one,
        BigInt.from(123),
        BigInt.from(1) << 52,
        (BigInt.one << 53) - BigInt.one,
        BigInt.one << 53,
        (BigInt.one << 53) + BigInt.one, // ties to even
        (BigInt.one << 53) + BigInt.from(3),
        (BigInt.one << 63) - BigInt.one,
        BigInt.one << 63,
        u64,
        u64 - BigInt.one,
      ];
      for (var i = 0; i < 60; i++) {
        mags.add(
          BigInt.from(rnd.nextInt(1 << 32)) << 32 |
              BigInt.from(rnd.nextInt(1 << 32)),
        );
      }
      final jobs = <List<Object>>[];
      final want = <int>[];
      for (final v in mags) {
        // Unsigned source: the whole 64-bit pattern is the magnitude.
        jobs.add(i2f(v, signed: false, narrow: false));
        want.add(packFromBig(v, false, 11, 52));
        // Signed source: the same pattern read as two's complement.
        final neg = (v >> 63) == BigInt.one;
        final mag = neg ? (BigInt.one << 64) - v : v;
        jobs.add(i2f(v, signed: true, narrow: false));
        want.add(packFromBig(mag, neg, 11, 52));
      }
      final got = await run(jobs);
      for (var i = 0; i < jobs.length; i++) {
        expect(
          got[i].fp.toRadixString(16),
          want[i].toRadixString(16),
          reason: 'job $i: ${jobs[i][1]} signed=${jobs[i][2]}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    'integer to binary32 is correctly rounded',
    () async {
      final rnd = math.Random(606);
      final mags = <BigInt>[
        BigInt.zero,
        BigInt.one,
        BigInt.from(16777215), // 2^24 - 1, exact
        BigInt.from(16777217), // needs rounding
        BigInt.from(16777219),
        (BigInt.one << 63) - BigInt.one,
        BigInt.one << 63,
        u64,
      ];
      for (var i = 0; i < 60; i++) {
        mags.add(
          BigInt.from(rnd.nextInt(1 << 32)) << 32 |
              BigInt.from(rnd.nextInt(1 << 32)),
        );
      }
      final jobs = <List<Object>>[];
      final want = <int>[];
      for (final v in mags) {
        jobs.add(i2f(v, signed: false, narrow: true));
        want.add(packFromBig(v, false, 8, 23));
        final neg = (v >> 63) == BigInt.one;
        final mag = neg ? (BigInt.one << 64) - v : v;
        jobs.add(i2f(v, signed: true, narrow: true));
        want.add(packFromBig(mag, neg, 8, 23));
      }
      final got = await run(jobs);
      for (var i = 0; i < jobs.length; i++) {
        expect(
          got[i].fp.toRadixString(16),
          want[i].toRadixString(16),
          reason: 'job $i: ${jobs[i][1]} signed=${jobs[i][2]}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    'binary64 to integer magnitude is exact',
    () async {
      final rnd = math.Random(1717);
      final vals = <double>[
        0.0,
        -0.0,
        1.0,
        -1.0,
        0.5,
        1.5,
        2.5,
        -2.5,
        123.456,
        1e18,
        -1e18,
        9.223372036854775e18,
        1.8446744073709552e19, // exactly 2^64, overflows
        1e-300,
        4.9e-324,
        2.2250738585072011e-308,
        1e300,
        double.infinity,
        -double.infinity,
      ];
      for (var i = 0; i < 60; i++) {
        final v = rnd.nextDouble() * math.pow(2.0, rnd.nextInt(140) - 70);
        vals.add(rnd.nextBool() ? v : -v);
      }
      final jobs = vals.map((v) => f2i(f64Bits(v))).toList();
      final got = await run(jobs);
      for (var i = 0; i < jobs.length; i++) {
        final ref = magnitudeOf(jobs[i][0] as int);
        expect(got[i].ovf, ref.ovf ? 1 : 0, reason: 'ovf job $i: ${vals[i]}');
        if (ref.ovf) {
          continue;
        }
        expect(got[i].mag, ref.mag, reason: 'mag job $i: ${vals[i]}');
        expect(got[i].round, ref.round, reason: 'round job $i: ${vals[i]}');
        expect(got[i].sticky, ref.sticky, reason: 'sticky job $i: ${vals[i]}');
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    'binary64 to integer over random bit patterns is exact',
    () async {
      final rnd = math.Random(31415);
      final jobs = <List<Object>>[];
      for (var i = 0; i < 120; i++) {
        final bits = (rnd.nextInt(1 << 32) << 32) | rnd.nextInt(1 << 32);
        if (bitsF64(bits).isNaN) {
          continue;
        }
        jobs.add(f2i(bits));
      }
      final got = await run(jobs);
      for (var i = 0; i < jobs.length; i++) {
        final ref = magnitudeOf(jobs[i][0] as int);
        expect(got[i].ovf, ref.ovf ? 1 : 0, reason: 'ovf job $i');
        if (ref.ovf) {
          continue;
        }
        expect(got[i].mag, ref.mag, reason: 'mag job $i');
        expect(got[i].round, ref.round, reason: 'round job $i');
        expect(got[i].sticky, ref.sticky, reason: 'sticky job $i');
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    'binary32 to integer magnitude is exact',
    () async {
      // A single-precision fcvt.w.s reads the binary32 fields directly. The
      // widening is exact, so the reference is the same magnitude routine run on
      // the binary64 image of the same value.
      final rnd = math.Random(8080);
      final vals = <double>[
        0.0,
        -0.0,
        1.0,
        -1.0,
        0.5,
        2.5,
        -2.5,
        123.456,
        1e18,
        -1e18,
        1.8446744073709552e19, // 2^64, overflows
        3.4028234663852886e38, // largest finite binary32, overflows
        1.401298464324817e-45, // smallest subnormal
        1.1754942106924411e-38, // largest subnormal
        1.1754943508222875e-38, // smallest normal
        double.infinity,
        -double.infinity,
      ].map((v) => bitsF32(f32Bits(v))).toList();
      for (var i = 0; i < 60; i++) {
        final v = bitsF32(
          f32Bits(rnd.nextDouble() * math.pow(2.0, rnd.nextInt(90) - 45)),
        );
        vals.add(rnd.nextBool() ? v : -v);
      }
      final jobs = vals.map((v) => f2iN(f32Bits(v))).toList();
      final got = await run(jobs);
      for (var i = 0; i < jobs.length; i++) {
        final ref = magnitudeOf(f64Bits(vals[i]));
        expect(got[i].ovf, ref.ovf ? 1 : 0, reason: 'ovf job $i: ${vals[i]}');
        if (ref.ovf) {
          continue;
        }
        expect(got[i].mag, ref.mag, reason: 'mag job $i: ${vals[i]}');
        expect(got[i].round, ref.round, reason: 'round job $i: ${vals[i]}');
        expect(got[i].sticky, ref.sticky, reason: 'sticky job $i: ${vals[i]}');
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    'binary32 to integer over random bit patterns is exact',
    () async {
      final rnd = math.Random(60606);
      final jobs = <List<Object>>[];
      final srcs = <double>[];
      for (var i = 0; i < 120; i++) {
        final bits = rnd.nextInt(1 << 32);
        final v = bitsF32(bits);
        if (v.isNaN) {
          continue;
        }
        jobs.add(f2iN(bits));
        srcs.add(v);
      }
      final got = await run(jobs);
      for (var i = 0; i < jobs.length; i++) {
        final ref = magnitudeOf(f64Bits(srcs[i]));
        expect(got[i].ovf, ref.ovf ? 1 : 0, reason: 'ovf job $i: ${srcs[i]}');
        if (ref.ovf) {
          continue;
        }
        expect(got[i].mag, ref.mag, reason: 'mag job $i: ${srcs[i]}');
        expect(got[i].round, ref.round, reason: 'round job $i: ${srcs[i]}');
        expect(got[i].sticky, ref.sticky, reason: 'sticky job $i: ${srcs[i]}');
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
