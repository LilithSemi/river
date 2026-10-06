import 'dart:async';

import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// A terminal response must withdraw EN on the SAME edge that consumes DONE.
// Leaving it high until instruction delivery lets an MMU with a one-cycle
// completion bubble accept a duplicate walk, which can survive a trap redirect.
void main() {
  tearDown(Simulator.reset);
  for (final width in [32, 64]) {
    for (final straddle in [false, true]) {
      for (final outcome in ['data', 'page-fault', 'retry']) {
        test('terminal fetch width=$width straddle=$straddle $outcome', () async {
          final clk = SimpleClockGenerator(20).clk;
          final reset = Logic()..inject(1);
          final enable = Logic()..inject(0);
          final pc = Logic(width: width)..inject(straddle ? width ~/ 8 - 2 : 0);
          final fault = Logic()..inject(0);
          final port = DataPortInterface(width, width);
          port.done.inject(0);
          port.valid.inject(0);
          port.data.inject(0);
          final fetch = FetchUnit(
            clk,
            reset,
            enable,
            pc,
            port,
            hasCompressed: straddle,
            fault: fault,
          );
          await fetch.build();
          Simulator.setMaxSimTime(10000);
          unawaited(Simulator.run());
          try {
            await clk.nextNegedge;
            reset.inject(0);
            enable.inject(1);

            Future<void> waitRequest(int address) async {
              for (var i = 0; i < 20; i++) {
                await clk.nextNegedge;
                if (port.en.value.isValid && port.en.value.toBool()) {
                  expect(port.addr.value.toInt(), address);
                  return;
                }
              }
              fail('No request for $address');
            }

            Future<void> respond(int data, {bool valid = true}) async {
              // Delay long enough that a duplicate request cannot be mistaken
              // for an immediate/combinational response in this witness.
              for (var i = 0; i < 7; i++) {
                await clk.nextNegedge;
                expect(port.en.value.toBool(), isTrue);
              }
              port.data.inject(data);
              port.valid.inject(valid ? 1 : 0);
              port.done.inject(1);
              await clk.nextNegedge; // Response has now been consumed.
              port.done.inject(0);
              port.valid.inject(0);
            }

            await waitRequest(0);
            if (straddle) {
              await respond(0x8293 << (width - 16));
              // The upper half is a NEW beat, not a terminal completion.
              expect(port.en.value.toBool(), isTrue);
              expect(port.addr.value.toInt(), width ~/ 8);
            }
            if (outcome == 'retry') {
              await respond(0, valid: false);
              expect(port.en.value.toBool(), isTrue);
              expect(port.addr.value.toInt(), straddle ? width ~/ 8 : 0);
            }
            final isFault = outcome.endsWith('fault');
            fault.inject(outcome == 'page-fault' ? 1 : 0);
            await respond(straddle ? 0x00a0 : 0x00a08293, valid: !isFault);
            expect(
              port.en.value.toBool(),
              isFalse,
              reason:
                  'terminal DONE must not leave a duplicate request enabled',
            );
            fault.inject(0);
            for (var i = 0; i < 5; i++) {
              await clk.nextNegedge;
              expect(port.en.value.toBool(), isFalse);
              expect(fetch.done.value.toBool(), isTrue);
              expect(fetch.valid.value.toBool(), isTrue);
              expect(fetch.fetchFault.value.toBool(), isFault);
              expect(fetch.result.value.toInt(), isFault ? 0x13 : 0x00a08293);
            }

            // Model lockstep trap/branch redirection through the enable bubble.
            enable.inject(0);
            pc.inject(0x4000);
            await clk.nextNegedge;
            enable.inject(1);
            await waitRequest(0x4000);
            await respond(0x13);
            expect(port.en.value.toBool(), isFalse);
            await clk.nextNegedge;
            expect(fetch.pcOut.value.toInt(), 0x4000);
            expect(fetch.fetchFault.value.toBool(), isFalse);
            expect(fetch.result.value.toInt(), 0x13);
          } finally {
            await Simulator.endSimulation();
            await Simulator.simulationEnded;
          }
        });
      }
    }
  }
}
