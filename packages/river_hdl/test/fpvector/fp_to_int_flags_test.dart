import 'package:river/river.dart';
import 'package:river_hdl/src/core/exec.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final width in [32, 64]) {
    test(
      'binary$width comparison and min/max NaN and zero semantics',
      () async {
        final m = width == 32 ? 23 : 52, e = width == 32 ? 8 : 11;
        final sign = 1 << (width - 1);
        final inf = ((1 << e) - 1) << m;
        final one = ((1 << (e - 1)) - 1) << m;
        final qnan = inf | (1 << (m - 1));
        final operands = <(int, int, bool, bool)>[
          (sign | inf, -2, false, false),
          (sign | one, -1, false, false),
          (sign, 0, false, false),
          (0, 0, false, false),
          (one, 1, false, false),
          (inf, 2, false, false),
          (qnan, 0, true, false),
          (inf | 1, 0, true, true),
          (sign | qnan, 0, true, false),
          (sign | inf | 1, 0, true, true),
        ];
        final checks = <void Function()>[];
        for (final (a, av, an, asn) in operands) {
          for (final (b, bv, bn, bsn) in operands) {
            final result = fpBitOps(
              Const(a, width: width),
              Const(b, width: width),
              width,
            );
            final unordered = an || bn;
            final nv = asn || bsn ? 16 : 0;
            final min = an
                ? (bn ? qnan : b)
                : bn
                ? a
                : av < bv
                ? a
                : av > bv
                ? b
                : av == 0
                ? (a | b)
                : a;
            final max = an
                ? (bn ? qnan : b)
                : bn
                ? a
                : av > bv
                ? a
                : av < bv
                ? b
                : av == 0
                ? (a & b)
                : a;
            checks.add(() {
              expect(result.eq.value.toBool(), !unordered && av == bv);
              expect(result.lt.value.toBool(), !unordered && av < bv);
              expect(result.le.value.toBool(), !unordered && av <= bv);
              expect(result.eqFlags.value.toInt(), nv);
              expect(
                result.orderedCompareFlags.value.toInt(),
                unordered ? 16 : 0,
              );
              expect(result.minMaxFlags.value.toInt(), nv);
              expect(result.fmin.value.toInt(), min);
              expect(result.fmax.value.toInt(), max);
            });
          }
        }
        await Simulator.run();
        for (final check in checks) {
          check();
        }
      },
    );
  }
  for (final xlen in [RiscVMxlen.rv32, RiscVMxlen.rv64]) {
    for (final bits in [32, if (xlen == RiscVMxlen.rv64) 64]) {
      for (final unsigned in [false, true]) {
        group('${xlen.name} ${unsigned ? "unsigned" : "signed"} $bits', () {
          for (var mode = 0; mode < 5; mode++) {
            final rm = mode;
            test('rm=$rm saturation and flags', () async {
              final max =
                  (BigInt.one << (unsigned ? bits : bits - 1)) - BigInt.one;
              final min = unsigned ? BigInt.zero : -(BigInt.one << (bits - 1));
              final mask64 = (BigInt.one << 64) - BigInt.one;
              final probes = <(Logic, Logic, BigInt, int)>[];
              for (final magnitude in {
                BigInt.zero,
                BigInt.one,
                max,
                max + BigInt.one,
                BigInt.one << (bits - 1),
                mask64,
              }) {
                for (final negative in [false, true]) {
                  for (var fraction = 0; fraction < 4; fraction++) {
                    // Quarter-unit fractions exercise exact, below-half, tie,
                    // and above-half cases without host floating arithmetic.
                    final increment = switch (rm) {
                      0 => fraction > 2 || (fraction == 2 && magnitude.isOdd),
                      1 => false,
                      2 => negative && fraction != 0,
                      3 => !negative && fraction != 0,
                      _ => fraction >= 2,
                    };
                    final rounded =
                        magnitude + (increment ? BigInt.one : BigInt.zero);
                    final value = negative ? -rounded : rounded;
                    final invalid = value < min || value > max;
                    final clipped = value < min
                        ? min
                        : value > max
                        ? max
                        : value;
                    final expected =
                        (bits == 32 ? clipped.toSigned(32) : clipped)
                            .toUnsigned(xlen.size);
                    final flags = Logic(width: 5);
                    final result = roundSatFpToInt(
                      intMag: Const(magnitude, width: 64),
                      roundBit: Const(fraction >> 1),
                      sticky: Const(fraction & 1),
                      ovf: Const(magnitude > mask64 ? 1 : 0),
                      signBit: Const(negative ? 1 : 0),
                      isNaN: Const(0),
                      isInf: Const(0),
                      rm: Const(rm, width: 3),
                      isL: Const(bits == 64 ? 1 : 0),
                      uns: Const(unsigned ? 1 : 0),
                      mxlen: xlen,
                      flagsOut: flags,
                    );
                    probes.add((
                      result,
                      flags,
                      expected,
                      invalid
                          ? 16
                          : fraction != 0
                          ? 1
                          : 0,
                    ));
                  }
                }
              }
              for (final nan in [false, true]) {
                for (final negative in [false, true]) {
                  final clipped = nan || !negative ? max : min;
                  final expected = (bits == 32 ? clipped.toSigned(32) : clipped)
                      .toUnsigned(xlen.size);
                  final flags = Logic(width: 5);
                  final result = roundSatFpToInt(
                    intMag: Const(0, width: 64),
                    roundBit: Const(1),
                    sticky: Const(1),
                    ovf: Const(1),
                    signBit: Const(negative ? 1 : 0),
                    isNaN: Const(nan ? 1 : 0),
                    isInf: Const(nan ? 0 : 1),
                    rm: Const(rm, width: 3),
                    isL: Const(bits == 64 ? 1 : 0),
                    uns: Const(unsigned ? 1 : 0),
                    mxlen: xlen,
                    flagsOut: flags,
                  );
                  probes.add((result, flags, expected, 16));
                }
              }
              await Simulator.run();
              for (var i = 0; i < probes.length; i++) {
                final (result, flags, expected, expectedFlags) = probes[i];
                expect(
                  result.value.toBigInt(),
                  expected,
                  reason: 'probe $i result',
                );
                expect(
                  flags.value.toInt(),
                  expectedFlags,
                  reason: 'probe $i flags',
                );
              }
            });
          }
        });
      }
    }
  }
}
