import 'dart:async';
import 'package:river_hdl/src/core/debug.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'debug_module_test.dart' show JtagHost;

void main() {
  tearDown(Simulator.reset);
  for (final width in [32, 64]) {
    for (final scenario in [
      'resume acknowledgement waits for completion',
      'halt dominates resume',
      'halt request can be cleared',
      'running resume is not replayed after a later halt',
      'busy command retains request ownership',
      'command error remains sticky',
      'running hart does not lend its register port',
      'data writes cannot modify a busy command',
    ]) {
      test('rv$width JTAG $scenario', () async {
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic()..inject(1);
        final tck = Logic()..inject(0),
            tms = Logic()..inject(1),
            tdi = Logic()..inject(0);
        final halted = Logic()..inject(1), ready = Logic()..inject(0);
        final rdata = Logic(width: width)..inject(0x1234);
        final sbaData = Logic(width: width)..inject(0),
            sbaAck = Logic()..inject(0);
        final dm = RiverDebugModule(
          clk,
          reset,
          tck,
          tms,
          tdi,
          Const(1),
          xlen: width,
          hartHalted: halted,
          regReady: ready,
          regRdata: rdata,
          sbaRdata: sbaData,
          sbaAck: sbaAck,
        );
        await dm.build();
        final host = JtagHost(dm, clk, tck, tms, tdi, sbaData, sbaAck, {});
        var resumes = 0;
        final sub = clk.negedge.listen((_) {
          if (dm.resumeReq.value.isValid && dm.resumeReq.value.toBool()) {
            resumes++;
          }
        });
        Future<void> ticks(int n) async {
          for (var i = 0; i < n; i++) {
            await clk.nextNegedge;
          }
        }

        final command = ((width == 64 ? 3 : 2) << 20) | (1 << 17) | 0x100b;
        Simulator.setMaxSimTime(100000);
        unawaited(Simulator.run());
        try {
          await ticks(2);
          reset.inject(0);
          await host.resetTap();
          await host.scanIr(5, 0x11);
          await host.dmWrite(0x10, 1);
          switch (scenario) {
            case 'resume acknowledgement waits for completion':
              await host.dmWrite(0x10, 0x40000001);
              expect(
                (await host.dmRead(0x11)) & 0x30000,
                0,
                reason: 'a request is not a completed resume',
              );
              halted.inject(0);
              await ticks(3);
              expect((await host.dmRead(0x11)) & 0x30000, 0x30000);
              halted.inject(1);
              await host.dmWrite(0x10, 0x80000001);
              expect(
                (await host.dmRead(0x11)) & 0x30000,
                0x30000,
                reason: 'a later halt must not erase the completed resume',
              );
            case 'halt dominates resume':
              await host.dmWrite(0x10, 0xc0000001);
              expect(dm.haltReq.value.toBool(), isTrue);
              expect(resumes, 0);
            case 'halt request can be cleared':
              await host.dmWrite(0x10, 0x80000001);
              expect(dm.haltReq.value.toBool(), isTrue);
              await host.dmWrite(0x10, 1);
              expect(dm.haltReq.value.toBool(), isFalse);
            case 'running resume is not replayed after a later halt':
              halted.inject(0);
              await ticks(3);
              await host.dmWrite(0x10, 0x40000001);
              halted.inject(1);
              await ticks(5);
              expect(
                resumes,
                0,
                reason: 'resume applies only to harts halted at the write',
              );
            case 'busy command retains request ownership':
              await host.dmWrite(0x17, command);
              expect(dm.regRead.value.toBool(), isTrue);
              expect(dm.regAddr.value.toInt(), 0x100b);
              await host.dmWrite(0x17, command + 1);
              expect(
                dm.regAddr.value.toInt(),
                0x100b,
                reason:
                    'a busy command write must not replace the outstanding regno',
              );
              expect(((await host.dmRead(0x16)) >> 8) & 7, 1);
              ready.inject(1);
              await ticks(4);
              expect(dm.regRead.value.toBool(), isFalse);
              expect(await host.dmRead(0x04), 0x1234);
              expect(((await host.dmRead(0x16)) >> 8) & 7, 1);
            case 'running hart does not lend its register port':
              halted.inject(0);
              await ticks(3);
              await host.dmWrite(0x17, command);
              expect(dm.regRead.value.toBool(), isFalse);
              expect(((await host.dmRead(0x16)) >> 8) & 7, 4);
            case 'data writes cannot modify a busy command':
              await host.dmWrite(0x04, 0x55);
              await host.dmWrite(0x17, command | (1 << 16));
              expect(dm.regWrite.value.toBool(), isTrue);
              expect(dm.regWdata.value.toInt(), 0x55);
              await host.dmWrite(0x04, 0x99);
              expect(((await host.dmRead(0x16)) >> 8) & 7, 1);
              ready.inject(1);
              await ticks(4);
              expect(await host.dmRead(0x04), 0x55);
            case 'command error remains sticky':
              await host.dmWrite(0x17, 0xff000000);
              expect(((await host.dmRead(0x16)) >> 8) & 7, 2);
              await host.dmWrite(0x17, command);
              expect(dm.regRead.value.toBool(), isFalse);
              expect(((await host.dmRead(0x16)) >> 8) & 7, 2);
              await host.dmWrite(0x16, 0x700);
              expect(((await host.dmRead(0x16)) >> 8) & 7, 0);
              await host.dmWrite(0x17, command);
              expect(dm.regRead.value.toBool(), isTrue);
          }
        } finally {
          await sub.cancel();
          await Simulator.endSimulation();
          await Simulator.simulationEnded;
        }
      });
    }
  }
}
