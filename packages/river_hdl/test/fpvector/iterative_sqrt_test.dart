import 'dart:math' as math;
import 'dart:async';
import 'dart:typed_data';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/src/core/iterative_sqrt.dart';
import 'package:test/test.dart';

/// [IterativeFpSqrt] against the golden model the emulator uses (math.sqrt).
///
/// The exec unit reads this core for every fsqrt, single and double, because a
/// single-precision square root widens into the double units first. So the
/// binary64 direction is the one that must be exact to the last bit.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  int f64Bits(double v) {
    final b = ByteData(8);
    b.setFloat64(0, v);
    return b.getUint64(0);
  }

  double bitsF64(int v) {
    final b = ByteData(8);
    b.setUint64(0, v);
    return b.getFloat64(0);
  }

  int f32Bits(double v) {
    final b = ByteData(4);
    b.setFloat32(0, v);
    return b.getUint32(0);
  }

  double bitsF32(int v) {
    final b = ByteData(4);
    b.setUint32(0, v);
    return b.getFloat32(0);
  }

  Future<List<int>> run(
    List<int> operands, {
    required int exponentWidth,
    required int mantissaWidth,
    bool narrowOut = false,
  }) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final operand = Logic(
      name: 'operand',
      width: 1 + exponentWidth + mantissaWidth,
    );
    final narrow = Logic(name: 'narrow');
    final dut = IterativeFpSqrt(
      clk,
      reset,
      start,
      operand,
      narrow,
      exponentWidth: exponentWidth,
      mantissaWidth: mantissaWidth,
    );
    await dut.build();
    reset.inject(1);
    start.inject(0);
    operand.inject(0);
    narrow.inject(narrowOut ? 1 : 0);
    unawaited(Simulator.run());
    for (var i = 0; i < 3; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 2; i++) {
      await clk.nextPosedge;
    }

    final out = <int>[];
    for (final op in operands) {
      operand.inject(op);
      start.inject(1);
      var guard = 0;
      while (dut.done.value.toInt() == 0) {
        await clk.nextPosedge;
        guard++;
        if (guard > 400) {
          fail('sqrt never finished for ${op.toRadixString(16)}');
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

  test('binary64 square root is bit exact against math.sqrt', () async {
    final rnd = math.Random(1234);
    final vals = <double>[
      4.0,
      1.0,
      2.0,
      9.0,
      0.5,
      1.5,
      2.5,
      1234.5678,
      1e300,
      1e-300,
      3.0,
    ];
    for (var i = 0; i < 40; i++) {
      vals.add(rnd.nextDouble() * math.pow(2.0, rnd.nextInt(120) - 60));
    }
    final ops = vals.map(f64Bits).toList()
      // The smallest subnormal and the largest one exercise the normalise
      // phase, which the unrolled unit never handled.
      ..add(1)
      ..add(0x000fffffffffffff);
    final got = await run(ops, exponentWidth: 11, mantissaWidth: 52);
    for (var i = 0; i < ops.length; i++) {
      expect(
        got[i],
        f64Bits(math.sqrt(bitsF64(ops[i]))),
        reason: 'sqrt(${bitsF64(ops[i])})',
      );
    }
  });

  test('binary64 special values follow IEEE', () async {
    final ops = <int>[
      0x0000000000000000, // +0
      0x8000000000000000, // -0
      0x7ff0000000000000, // +inf
      0xfff0000000000000, // -inf
      0x7ff8000000000000, // qNaN
      0xbff0000000000000, // -1.0
    ];
    final got = await run(ops, exponentWidth: 11, mantissaWidth: 52);
    expect(got[0], 0x0000000000000000);
    expect(got[1], 0x8000000000000000);
    expect(got[2], 0x7ff0000000000000);
    expect(got[3], 0x7ff8000000000000);
    expect(got[4], 0x7ff8000000000000);
    expect(got[5], 0x7ff8000000000000);
  });

  test('binary32 square root is bit exact against math.sqrt', () async {
    final rnd = math.Random(99);
    final vals = <double>[4.0, 1.0, 2.0, 9.0, 0.5, 1.5, 2.5, 100.0];
    for (var i = 0; i < 30; i++) {
      vals.add(
        bitsF32(
          f32Bits(rnd.nextDouble() * math.pow(2.0, rnd.nextInt(40) - 20)),
        ),
      );
    }
    final ops = vals.map(f32Bits).toList()..add(1);
    final got = await run(ops, exponentWidth: 8, mantissaWidth: 23);
    for (var i = 0; i < ops.length; i++) {
      expect(
        got[i],
        f32Bits(math.sqrt(bitsF32(ops[i]))),
        reason: 'sqrtf(${bitsF32(ops[i])})',
      );
    }
  });

  test('binary32 root taken on the binary64 core is bit exact', () async {
    // A single-precision root runs on the double core, reading the binary32
    // operand fields DIRECTLY and rounding ONCE at the binary32 position. That
    // is what the execution unit does, so this is the shape that ships: there
    // is no widening converter in front of the core.
    final rnd = math.Random(2718);
    final vals = <double>[4.0, 2.0, 1.0, 9.0, 0.5, 1.5, 100.0, 1e30, 1e-30];
    for (var i = 0; i < 40; i++) {
      vals.add(
        bitsF32(
          f32Bits(rnd.nextDouble() * math.pow(2.0, rnd.nextInt(60) - 30)),
        ),
      );
    }
    // The smallest binary32 subnormal and the largest one exercise the
    // normalise phase through the widened operand.
    final f32Ops = vals.map(f32Bits).toList()
      ..add(1)
      ..add(0x007fffff);
    // The core reads the binary32 fields itself, so feed the raw pattern.
    final ops = f32Ops;
    final got = await run(
      ops,
      exponentWidth: 11,
      mantissaWidth: 52,
      narrowOut: true,
    );
    for (var i = 0; i < ops.length; i++) {
      expect(
        got[i],
        f32Bits(math.sqrt(bitsF32(f32Ops[i]))),
        reason: 'sqrtf(${bitsF32(f32Ops[i])})',
      );
    }
  });

  test('binary32 specials on the binary64 core follow IEEE', () async {
    final ops = <int>[
      0x00000000, // +0
      0x80000000, // -0
      0x7f800000, // +inf
      0xff800000, // -inf
      0x7fc00000, // qNaN
      0xbf800000, // -1.0
    ];
    final got = await run(
      ops,
      exponentWidth: 11,
      mantissaWidth: 52,
      narrowOut: true,
    );
    expect(got[0], 0x00000000);
    expect(got[1], 0x80000000);
    expect(got[2], 0x7f800000);
    expect(got[3], 0x7fc00000);
    expect(got[4], 0x7fc00000);
    expect(got[5], 0x7fc00000);
  });
}
