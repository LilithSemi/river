import 'dart:async';

import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Drive packed rows directly: the selected row and its match decision must
/// have identical priority, including zero/nonzero-field guards and padding.
void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    await Simulator.reset();
  });

  for (final mxlen in [RiscVMxlen.rv32, RiscVMxlen.rv64]) {
    for (final lanes in [1, 2, 4, 8]) {
      test('RV${mxlen.size} $lanes lanes preserve match priority', () async {
        final rom = MicrocodeRom(
          RiscVIsaConfig(mxlen: mxlen, extensions: [rv32i]),
        );
        final patterns = rom.decodeLookup.values.toList();
        final first = patterns.first;
        final second = patterns.firstWhere((p) => p.opIndex != first.opIndex);
        final typeWidth = rom.typeStructs.length.bitLength;
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic()..put(1);
        final enable = Logic()..put(0);
        final instruction = Logic(width: 32)..put(0);
        final port = DataPortInterface(
          rom.patternWidth * lanes,
          rom.decodeLookup.length.bitLength,
        );
        port.data.put(0);
        port.done.put(0);
        port.valid.put(0);
        final dut = DynamicInstructionDecoder(
          clk,
          reset,
          enable,
          instruction,
          port,
          microcode: rom,
          mxlen: mxlen,
        );
        await dut.build();

        Simulator.setMaxSimTime(100000);
        unawaited(Simulator.run());
        Future<void> tick() async {
          await clk.nextPosedge;
          await clk.nextNegedge;
        }

        OperationDecodePattern row(int index, {int nz = 0, int z = 0}) =>
            OperationDecodePattern(0x7f, 0x13, index, first.type, nz, z);
        final miss = OperationDecodePattern(
          0x7f,
          0x33,
          second.opIndex,
          second.type,
          0,
          0,
        );
        const padding = OperationDecodePattern(0, 0, 0, 0, 0, 0);

        Future<void> check(
          List<OperationDecodePattern> rows,
          int? expected,
        ) async {
          reset.put(1);
          enable.put(0);
          await tick();
          reset.put(0);
          enable.put(1);
          instruction.put(0x00108093); // addi x1, x1, 1
          var packed = BigInt.zero;
          for (var lane = 0; lane < lanes; lane++) {
            packed |=
                rows[lane].encode(rom.opIndexWidth, typeWidth) <<
                (lane * rom.patternWidth);
          }
          port.data.put(packed);
          port.valid.put(1);
          port.done.put(0);
          for (var i = 0; i < 3; i++) {
            await tick();
            expect(dut.done.value.toBool(), isFalse);
          }
          port.done.put(1);
          var completed = false;
          for (var i = 0; i < 8; i++) {
            // A one-lane nonmatch advances to a zero-filled ROM tail.
            if (expected == null && i == 2) port.data.put(0);
            await tick();
            if (dut.done.value.toBool()) {
              completed = true;
              break;
            }
          }
          expect(completed, isTrue, reason: 'decoder must terminate');
          expect(dut.valid.value.toBool(), expected != null);
          if (expected != null) {
            expect(dut.index.value.toInt(), expected);
            // Once committed, changes at the ROM input must not replace it.
            port.data.put(0);
            for (var i = 0; i < 3; i++) {
              await tick();
              expect(dut.done.value.toBool(), isTrue);
              expect(dut.valid.value.toBool(), isTrue);
              expect(dut.index.value.toInt(), expected);
            }
          }
        }

        // Every lane can win; no earlier nonmatching lane may steal its row.
        for (var winner = 0; winner < lanes; winner++) {
          final rows = List.filled(lanes, miss);
          rows[winner] = row(first.opIndex);
          await check(rows, first.opIndex);
        }
        // Multiple matches: lowest lane wins, not last matching lane.
        await check([
          row(first.opIndex),
          for (var lane = 1; lane < lanes; lane++) row(second.opIndex),
        ], first.opIndex);
        // Nonzero and zero-field predicates must travel with the row.
        for (final guarded in [
          row(first.opIndex, nz: 1 << 20),
          row(first.opIndex, z: 1 << 21),
        ]) {
          await check([
            guarded,
            ...List.filled(lanes - 1, padding),
          ], first.opIndex);
        }
        for (final rejected in [
          row(first.opIndex, nz: 1 << 21),
          row(first.opIndex, z: 1 << 20),
        ]) {
          await check([rejected, ...List.filled(lanes - 1, padding)], null);
          if (lanes > 1) {
            await check([
              rejected,
              row(second.opIndex),
              ...List.filled(lanes - 2, padding),
            ], second.opIndex);
          }
        }
        await check(List.filled(lanes, padding), null);
      });
    }
  }
}
