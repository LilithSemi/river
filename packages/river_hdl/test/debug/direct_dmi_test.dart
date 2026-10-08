import 'dart:async';
import 'package:river_hdl/src/core/debug.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final width in [32, 64]) {
    for (final scenario in [
      'register transfers',
      'idle address has no side effect',
      'abstract command ownership',
      'resume completion persists',
      'halt dominance',
      'reset and ndmreset',
      'SBA busy includes an accepted start',
    ]) {
      test('rv$width direct DMI $scenario', () async {
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic()..inject(1);
        final request = Logic()..inject(0), write = Logic()..inject(0);
        final address = Logic(width: 7)..inject(0),
            wdata = Logic(width: 32)..inject(0);
        final halted = Logic()..inject(1), ready = Logic()..inject(0);
        final rdata = Logic(width: width)..inject(0x1234);
        final dm = RiverDebugModule(
          clk,
          reset,
          Const(0),
          Const(0),
          Const(0),
          Const(1),
          directDmi: true,
          dmiRequest: request,
          dmiWrite: write,
          dmiAddress: address,
          dmiWriteData: wdata,
          xlen: width,
          hartHalted: halted,
          regReady: ready,
          regRdata: rdata,
        );
        final sampledResponse = Logic(width: 32);
        Sequential(clk, [sampledResponse < dm.dmiRdata]);
        await dm.build();
        expect(dm.inputs.containsKey('tck'), isFalse);
        expect(dm.inputs.containsKey('tms'), isFalse);
        Future<void> tick([int count = 1]) async {
          for (var i = 0; i < count; i++) {
            await clk.nextNegedge;
          }
        }

        Future<int> access(int addr, [int? value]) async {
          request.inject(0);
          address.inject(addr);
          write.inject(value == null ? 0 : 1);
          wdata.inject(value ?? 0);
          await tick();
          final result = dm.dmiRdata.value.toInt();
          request.inject(1);
          await tick();
          request.inject(0);
          return result;
        }

        final command = ((width == 64 ? 3 : 2) << 20) | (1 << 17) | 0x100b;
        Simulator.setMaxSimTime(10000);
        unawaited(Simulator.run());
        try {
          await tick(2);
          reset.inject(0);
          await tick();
          await access(0x10, 1);
          switch (scenario) {
            case 'register transfers':
              await access(0x04, 0xa55a);
              await access(0x05, 0x1234);
              expect(await access(0x04), 0xa55a);
              expect(await access(0x05), 0x1234);
              // Consecutive qualified edges are two distinct transfers.
              address.inject(0x04);
              wdata.inject(0x55);
              write.inject(1);
              request.inject(1);
              await tick();
              address.inject(0x05);
              wdata.inject(0x66);
              await tick();
              request.inject(0);
              expect(await access(0x04), 0x55);
              expect(await access(0x05), 0x66);
              expect(dm.generateSynth(), contains('dmi_request'));
            case 'idle address has no side effect':
              address.inject(0x17);
              write.inject(1);
              wdata.inject(command);
              await tick(8);
              expect(dm.regRead.value.toBool(), isFalse);
              expect(dm.dmBusy.value.toBool(), isFalse);
              address.inject(0x10);
              wdata.inject(0x80000001);
              await tick(4);
              expect(dm.haltReq.value.toBool(), isFalse);
            case 'abstract command ownership':
              await access(0x17, command);
              await tick(2);
              expect(dm.regRead.value.toBool(), isTrue);
              await access(0x17, command + 1);
              expect(dm.regAddr.value.toInt(), 0x100b);
              expect(((await access(0x16)) >> 8) & 7, 1);
              ready.inject(1);
              await tick(3);
              expect(await access(0x04), 0x1234);
              expect(dm.regRead.value.toBool(), isFalse);
              await access(0x16, 0x700);
              expect(((await access(0x16)) >> 8) & 7, 0);
            case 'resume completion persists':
              await access(0x10, 0x40000001);
              expect((await access(0x11)) & 0x30000, 0);
              halted.inject(0);
              await tick(2);
              halted.inject(1);
              await access(0x10, 0x80000001);
              expect((await access(0x11)) & 0x30000, 0x30000);
              expect(dm.resumeReq.value.toBool(), isFalse);
            case 'halt dominance':
              await access(0x10, 0xc0000001);
              expect(dm.haltReq.value.toBool(), isTrue);
              expect(dm.resumeReq.value.toBool(), isFalse);
              await access(0x10, 1);
              expect(dm.haltReq.value.toBool(), isFalse);
            case 'SBA busy includes an accepted start':
              // Capture the same pre-edge value a synchronous frontend sees.
              address.inject(0x3c);
              wdata.inject(0x55);
              write.inject(1);
              request.inject(1);
              await tick();
              address.inject(0x38);
              write.inject(0);
              await tick();
              request.inject(0);
              expect(
                sampledResponse.value.toInt() & (1 << 21),
                1 << 21,
                reason:
                    'the following DMI access must see the pending SBA operation',
              );
            case 'reset and ndmreset':
              await access(0x04, 0xabcd);
              await access(0x10, 3);
              expect(dm.ndmreset.value.toBool(), isTrue);
              expect(
                await access(0x04),
                0xabcd,
                reason: 'ndmreset excludes the DM',
              );
              await access(0x10, 1);
              expect(dm.ndmreset.value.toBool(), isFalse);
              reset.inject(1);
              await tick(2);
              reset.inject(0);
              await tick(2);
              expect(await access(0x04), 0);
              expect(dm.regRead.value.toBool(), isFalse);
              expect(dm.regWrite.value.toBool(), isFalse);
          }
        } finally {
          await Simulator.endSimulation();
          await Simulator.simulationEnded;
        }
      });
    }
  }
}
