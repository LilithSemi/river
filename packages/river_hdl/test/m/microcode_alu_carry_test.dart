import 'dart:math';

import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  for (final mxlen in [RiscVMxlen.rv32, RiscVMxlen.rv64]) {
    test('RV${mxlen.size} shared add/sub carry boundaries', () async {
      final width = mxlen.size;
      final mask = (BigInt.one << width) - BigInt.one;
      final a = Logic(width: width);
      final b = Logic(width: width);
      final funct = Logic(width: MicroOpAluFunct.width);
      final dut = MicrocodeAlu(a, b, funct, mxlen: mxlen);
      await dut.build();
      final edges = {
        BigInt.zero,
        BigInt.one,
        mask,
        mask - BigInt.one,
        for (final bit in [15, 16, 30, 31, 32, width - 1])
          for (final delta in [-1, 0, 1])
            ((BigInt.one << bit) + BigInt.from(delta)) & mask,
      };
      final random = Random(0x51a7);
      BigInt operand() =>
          ((BigInt.from(random.nextInt(1 << 32)) << 32) |
              BigInt.from(random.nextInt(1 << 32))) &
          mask;
      final pairs = [
        for (final x in edges)
          for (final y in edges) (x, y),
        for (var i = 0; i < 512; i++) (operand(), operand()),
      ];
      for (final operation in [
        MicroOpAluFunct.add,
        MicroOpAluFunct.sub,
        if (width == 64) ...[MicroOpAluFunct.addw, MicroOpAluFunct.subw],
      ]) {
        final subtract =
            operation == MicroOpAluFunct.sub ||
            operation == MicroOpAluFunct.subw;
        final word =
            operation == MicroOpAluFunct.addw ||
            operation == MicroOpAluFunct.subw;
        funct.put(operation);
        for (final pair in pairs) {
          a.put(pair.$1);
          b.put(pair.$2);
          var expected = subtract ? pair.$1 - pair.$2 : pair.$1 + pair.$2;
          if (word) expected = expected.toSigned(32);
          expect(
            dut.result.value.toBigInt(),
            expected & mask,
            reason: 'funct=$operation a=${pair.$1} b=${pair.$2}',
          );
        }
      }
    });
  }
}
