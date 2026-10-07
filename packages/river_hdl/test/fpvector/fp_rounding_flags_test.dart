import 'dart:async';

import 'package:river_hdl/src/core/iterative_sqrt.dart';
import 'package:river_hdl/src/core/iterative_fp_arith.dart';
import 'package:river_hdl/src/core/iterative_fp_int.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void _arithmeticTests(int e, int m, bool narrow) {
  final single = narrow || e == 8;
  final eb = single ? 8 : 11, mb = single ? 23 : 52;
  final bias = (1 << (eb - 1)) - 1;
  final sign = 1 << (eb + mb), one = bias << mb;
  final two = (bias + 1) << mb, half = (bias - 1) << mb;
  final inf = ((1 << eb) - 1) << mb;
  final qnan = inf | (1 << (mb - 1));
  final minNormal = 1 << mb;
  final halfUlp = (bias - mb - 1) << mb;
  group('arithmetic e=$e m=$m narrow=$narrow', () {
    for (var mode = 0; mode < 5; mode++) {
      final rm = mode;
      test('rm=$rm results and flags', () async {
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(), start = Logic();
        final a = Logic(width: 1 + e + m),
            b = Logic(width: 1 + e + m),
            c = Logic(width: 1 + e + m);
        final rounding = Logic(width: 3);
        final fma = Logic(), mul = Logic(), div = Logic();
        final dut = IterativeFpArith(
          clk,
          reset,
          start,
          a,
          b,
          c,
          fma,
          Const(0),
          Const(0),
          div,
          mul,
          Const(0),
          Const(narrow ? 1 : 0),
          exponentWidth: e,
          mantissaWidth: m,
          rm: rounding,
        );
        await dut.build();
        reset.inject(1);
        start.inject(0);
        a.inject(0);
        b.inject(0);
        c.inject(0);
        rounding.inject(rm);
        fma.inject(0);
        mul.inject(0);
        div.inject(0);
        final upPositive = rm == 0 || rm == 3 || rm == 4;
        final upNegative = rm == 0 || rm == 2 || rm == 4;
        final cases = <(String, int, int, int, int, int)>[
          ('add', one, one, 0, two, 0),
          ('add', one, halfUlp, 0, one + (rm == 3 || rm == 4 ? 1 : 0), 1),
          (
            'add',
            sign | one,
            sign | halfUlp,
            0,
            sign | (one + (rm == 2 || rm == 4 ? 1 : 0)),
            1,
          ),
          ('add', one, sign | one, 0, rm == 2 ? sign : 0, 0),
          ('add', 0, sign, 0, rm == 2 ? sign : 0, 0),
          ('add', sign, sign, 0, sign, 0),
          ('mul', inf - 1, two, 0, upPositive ? inf : inf - 1, 5),
          (
            'mul',
            sign | (inf - 1),
            two,
            0,
            sign | (upNegative ? inf : inf - 1),
            5,
          ),
          ('div', one, 0, 0, inf, 8),
          ('div', 0, 0, 0, qnan, 16),
          ('div', inf, 0, 0, inf, 0),
          ('div', one, inf, 0, 0, 0),
          ('div', inf, inf, 0, qnan, 16),
          ('mul', 0, inf, 0, qnan, 16),
          ('add', qnan, one, 0, qnan, 0),
          ('add', inf | 1, one, 0, qnan, 16),
          ('fma', 0, inf, qnan, qnan, 16),
          ('fma', qnan, inf, sign | inf, qnan, 0),
          ('fma', inf, one, sign | inf, qnan, 16),
          ('fma', one, one, inf | 1, qnan, 16),
          ('fma', one, one, sign | one, rm == 2 ? sign : 0, 0),
          (
            'fma',
            one + 1,
            one - 2,
            sign | one,
            sign | ((bias - 2 * mb) << mb),
            0,
          ),
          ('fma', inf - 1, two, sign | (inf - 1), inf - 1, 0),
          ('fma', 1, half, 1, upPositive ? 2 : 1, 3),
          ('mul', 1, half, 0, rm == 3 || rm == 4 ? 1 : 0, 3),
          ('mul', sign | 1, half, 0, sign | (rm == 2 || rm == 4 ? 1 : 0), 3),
          ('mul', minNormal, half, 0, minNormal >> 1, 0),
          // Tininess is tested after unbounded-exponent rounding. A subnormal
          // rounding to minNormal can still raise UF; a value whose earlier
          // precision rounding reaches minNormal does not.
          (
            'mul',
            minNormal,
            one - 1,
            0,
            upPositive ? minNormal : minNormal - 1,
            3,
          ),
          (
            'mul',
            minNormal - 1,
            one + 1,
            0,
            upPositive ? minNormal : minNormal - 1,
            upPositive ? 1 : 3,
          ),
          (
            'mul',
            sign | (minNormal - 1),
            one + 1,
            0,
            sign | (upNegative ? minNormal : minNormal - 1),
            upNegative ? 1 : 3,
          ),
        ];
        Simulator.setMaxSimTime(1000000);
        unawaited(Simulator.run());
        try {
          await clk.nextNegedge;
          await clk.nextNegedge;
          reset.inject(0);
          await clk.nextNegedge;
          for (final (op, av, bv, cv, answer, flags) in cases) {
            a.inject(av);
            b.inject(bv);
            c.inject(cv);
            rounding.inject(rm);
            fma.inject(op == 'fma' ? 1 : 0);
            mul.inject(op == 'mul' ? 1 : 0);
            div.inject(op == 'div' ? 1 : 0);
            start.inject(1);
            await clk.nextNegedge;
            rounding.inject((rm + 1) % 5);
            for (
              var cycle = 0;
              !dut.done.value.toBool() && cycle < 512;
              cycle++
            ) {
              await clk.nextNegedge;
            }
            expect(dut.done.value.toBool(), isTrue, reason: '$op completion');
            for (var held = 0; held < 3; held++) {
              expect(
                dut.result.value.toInt(),
                answer,
                reason:
                    '$op ${av.toRadixString(16)} ${bv.toRadixString(16)} ${cv.toRadixString(16)} rm=$rm',
              );
              expect(
                dut.flags.value.toInt(),
                flags,
                reason: '$op flags input=${av.toRadixString(16)} rm=$rm',
              );
              await clk.nextNegedge;
            }
            start.inject(0);
            await clk.nextNegedge;
            expect(dut.done.value.toBool(), isFalse);
          }
        } finally {
          await Simulator.endSimulation();
          await Simulator.simulationEnded;
        }
      });
    }
  });
}

void _integerTests(int e, int m, bool narrow) {
  final single = narrow || e == 8;
  final eb = single ? 8 : 11, mb = single ? 23 : 52;
  final bias = (1 << (eb - 1)) - 1;
  final sign = 1 << (eb + mb), one = bias << mb;
  final precision = mb + 1;
  final power = 1 << precision, powerBits = (bias + precision) << mb;
  group('integer to float e=$e m=$m narrow=$narrow', () {
    for (var mode = 0; mode < 5; mode++) {
      final rm = mode;
      test('rm=$rm results and flags', () async {
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(), start = Logic(), signed = Logic();
        final input = Logic(width: 64), rounding = Logic(width: 3);
        final dut = IterativeFpIntConvert(
          clk,
          reset,
          start,
          Const(0, width: 1 + e + m),
          input,
          signed,
          Const(0),
          Const(narrow ? 1 : 0),
          exponentWidth: e,
          mantissaWidth: m,
          rm: rounding,
        );
        await dut.build();
        reset.inject(1);
        start.inject(0);
        input.inject(0);
        signed.inject(1);
        rounding.inject(rm);
        final cases = <(int, bool, int, int)>[
          (0, true, 0, 0),
          (1, true, one, 0),
          (-1, true, sign | one, 0),
          (power - 1, true, powerBits - 1, 0),
          (power + 1, true, powerBits + (rm == 3 || rm == 4 ? 1 : 0), 1),
          (
            -(power + 1),
            true,
            sign | (powerBits + (rm == 2 || rm == 4 ? 1 : 0)),
            1,
          ),
          (power + 2, true, powerBits + 1, 0),
          (power + 3, true, powerBits + (rm == 1 || rm == 2 ? 1 : 2), 1),
          (
            0x7fffffffffffffff,
            true,
            ((bias + 63) << mb) - (rm == 1 || rm == 2 ? 1 : 0),
            1,
          ),
          (0x8000000000000000, true, sign | ((bias + 63) << mb), 0),
          (-1, false, ((bias + 64) << mb) - (rm == 1 || rm == 2 ? 1 : 0), 1),
        ];
        Simulator.setMaxSimTime(1000000);
        unawaited(Simulator.run());
        try {
          await clk.nextNegedge;
          await clk.nextNegedge;
          reset.inject(0);
          await clk.nextNegedge;
          for (final (value, isSigned, expected, flags) in cases) {
            input.inject(value);
            signed.inject(isSigned ? 1 : 0);
            rounding.inject(rm);
            start.inject(1);
            await clk.nextNegedge;
            rounding.inject((rm + 1) % 5);
            for (
              var cycles = 0;
              !dut.done.value.toBool() && cycles < 128;
              cycles++
            ) {
              await clk.nextNegedge;
            }
            expect(dut.done.value.toBool(), isTrue);
            for (var held = 0; held < 3; held++) {
              expect(
                dut.fpOut.value.toInt(),
                expected,
                reason: 'integer $value signed=$isSigned rm=$rm',
              );
              expect(dut.fpFlags.value.toInt(), flags);
              await clk.nextNegedge;
            }
            start.inject(0);
            await clk.nextNegedge;
          }
        } finally {
          await Simulator.endSimulation();
          await Simulator.simulationEnded;
        }
      });
    }
  });
}

void main() {
  tearDown(Simulator.reset);
  for (final shape in [(8, 23, false), (11, 52, false), (11, 52, true)]) {
    final (e, m, narrow) = shape;
    final single = narrow || e == 8;
    _arithmeticTests(e, m, narrow);
    _integerTests(e, m, narrow);
    group('sqrt e=$e m=$m narrow=$narrow', () {
      for (var mode = 0; mode < 5; mode++) {
        final rm = mode;
        test('rm=$rm results and flags', () async {
          final clk = SimpleClockGenerator(10).clk;
          final reset = Logic(), start = Logic();
          final operand = Logic(width: 1 + e + m);
          final rounding = Logic(width: 3);
          final dut = IterativeFpSqrt(
            clk,
            reset,
            start,
            operand,
            Const(narrow ? 1 : 0),
            exponentWidth: e,
            mantissaWidth: m,
            rm: rounding,
          );
          await dut.build();
          reset.inject(1);
          start.inject(0);
          operand.inject(0);
          rounding.inject(rm);
          Simulator.setMaxSimTime(1000000);
          unawaited(Simulator.run());
          try {
            await clk.nextNegedge;
            await clk.nextNegedge;
            reset.inject(0);
            await clk.nextNegedge;
            final cases = single
                ? <(int, int, int)>[
                    (0x40800000, 0x40000000, 0), // exact sqrt(4)
                    (0x40000000, rm == 3 ? 0x3fb504f4 : 0x3fb504f3, 1),
                    (0x80000000, 0x80000000, 0), // -0, not invalid
                    (0, 0, 0),
                    (0x7f800000, 0x7f800000, 0),
                    (0xbf800000, 0x7fc00000, 16),
                    (0xff800000, 0x7fc00000, 16),
                    (0x7f800001, 0x7fc00000, 16), // signaling NaN
                    (0x7fc00001, 0x7fc00000, 0),
                    (0xffc00001, 0x7fc00000, 0), // negative quiet NaN
                    (1, rm == 3 ? 0x1a3504f4 : 0x1a3504f3, 1),
                    (
                      0x007fffff,
                      rm == 1 || rm == 2 ? 0x1ffffffe : 0x1fffffff,
                      1,
                    ),
                  ]
                : <(int, int, int)>[
                    (0x4010000000000000, 0x4000000000000000, 0),
                    (
                      0x4000000000000000,
                      rm == 1 || rm == 2
                          ? 0x3ff6a09e667f3bcc
                          : 0x3ff6a09e667f3bcd,
                      1,
                    ),
                    (0x8000000000000000, 0x8000000000000000, 0),
                    (0, 0, 0),
                    (0x7ff0000000000000, 0x7ff0000000000000, 0),
                    (0xbff0000000000000, 0x7ff8000000000000, 16),
                    (0xfff0000000000000, 0x7ff8000000000000, 16),
                    (0x7ff0000000000001, 0x7ff8000000000000, 16),
                    (0x7ff8000000000001, 0x7ff8000000000000, 0),
                    (0xfff8000000000001, 0x7ff8000000000000, 0),
                    (1, 0x1e60000000000000, 0),
                  ];
            for (final (input, answer, flags) in cases) {
              operand.inject(input);
              rounding.inject(rm);
              start.inject(1);
              await clk.nextNegedge;
              // The accepted operation retains its rounding mode.
              rounding.inject((rm + 1) % 5);
              for (
                var cycles = 0;
                !dut.done.value.toBool() && cycles < 256;
                cycles++
              ) {
                await clk.nextNegedge;
              }
              expect(
                dut.done.value.toBool(),
                isTrue,
                reason: 'sqrt completion',
              );
              for (var held = 0; held < 3; held++) {
                expect(
                  dut.result.value.toInt(),
                  answer,
                  reason: 'sqrt input=0x${input.toRadixString(16)}, rm=$rm',
                );
                expect(dut.flags.value.toInt(), flags);
                await clk.nextNegedge;
              }
              start.inject(0);
              await clk.nextNegedge;
              expect(dut.done.value.toBool(), isFalse);
            }
          } finally {
            await Simulator.endSimulation();
            await Simulator.simulationEnded;
          }
        });
      }
    });
  }
}
