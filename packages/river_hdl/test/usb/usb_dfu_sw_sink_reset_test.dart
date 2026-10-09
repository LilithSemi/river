import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sw_sink_harness.dart';

// A reset pulsing on only one of RiverDfuSwSink's two clock domains must
// not wedge the ready handshake forever (see the class doc comment on
// RiverDfuSwSink for the recovery policy this exercises).

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  /// Pushes and acks one byte so both the producer and consumer toggles
  /// land on the same (nonzero) value, a realistic "idle, last byte
  /// acked" steady state before a reset.
  Future<void> settleOneByte(SwSinkFixture f) async {
    await pushByteWhenReady(f, 0x01);
    await waitRxValid(f);
    await pulseAdvance(f);
    await waitReady(f);
  }

  test('a usb-only reset recovers ready', () async {
    final f = await buildSwSinkFixture();
    await settleOneByte(f);

    f.usbReset.inject(1);
    for (var i = 0; i < 5; i++) {
      await f.usbClk.nextPosedge;
    }
    f.usbReset.inject(0);

    // bus_reset was never touched: the bus domain's consumerToggle keeps
    // whatever it held before the usb-only reset.
    await waitReady(f, maxCycles: 200);

    await pushByteWhenReady(f, 0x22);
    await waitRxValid(f);
    expect(f.dut.output('rx_data').value.toInt(), equals(0x22));

    await Simulator.endSimulation();
  });

  test('a bus-only reset recovers ready', () async {
    final f = await buildSwSinkFixture();
    await settleOneByte(f);

    f.busReset.inject(1);
    for (var i = 0; i < 5; i++) {
      await f.busClk.nextPosedge;
    }
    f.busReset.inject(0);

    // usb_reset was never touched: the usb domain's producerToggle keeps
    // whatever it held before the bus-only reset.
    await waitReady(f, maxCycles: 200);

    await pushByteWhenReady(f, 0x33);
    await waitRxValid(f);
    expect(f.dut.output('rx_data').value.toInt(), equals(0x33));

    await Simulator.endSimulation();
  });

  test(
    'a usb-only reset with a byte pending drops it and still recovers '
    '(probe C, m-B)',
    () async {
      final f = await buildSwSinkFixture();
      await settleOneByte(f);
      await pushByteWhenReady(f, 0x02);
      await waitRxValid(f);
      // Do not advance: the byte is still held when the reset hits.

      f.usbReset.inject(1);
      for (var i = 0; i < 5; i++) {
        await f.usbClk.nextPosedge;
      }
      f.usbReset.inject(0);
      for (var i = 0; i < 40; i++) {
        await f.busClk.nextPosedge;
      }

      // m-B: a seen usb-only reset is treated like `clear`, so the
      // pending byte is dropped rather than left looking captured
      // forever with no producer left to ever ack it.
      expect(f.dut.output('rx_valid').value.toBool(), isFalse);
      expect(f.dut.output('cleared').value.toBool(), isTrue);

      // An advance arriving in or after this window must not wedge
      // ready either: it is gated on rxValid, now 0.
      await pulseAdvance(f);
      for (var i = 0; i < 20; i++) {
        await f.busClk.nextPosedge;
      }
      await waitReady(f, maxCycles: 200);

      await Simulator.endSimulation();
    },
  );

  test('a bus-only reset also clears the register file', () async {
    final f = await buildSwSinkFixture();
    await pushByteWhenReady(f, 0x44);
    await waitRxValid(f);

    f.busReset.inject(1);
    for (var i = 0; i < 5; i++) {
      await f.busClk.nextPosedge;
    }
    expect(f.dut.output('rx_valid').value.toBool(), isFalse);
    expect(f.dut.output('bytes_count').value.toInt(), equals(0));
    f.busReset.inject(0);

    await waitReady(f, maxCycles: 200);
    await Simulator.endSimulation();
  });

  test(
    'cleared reads 0 after a full reset (Minor 4): only a real clear or '
    'a usb-only reset seen at runtime sets it',
    () async {
      final f = await buildSwSinkFixture();
      // buildSwSinkFixture already did a full (both-domain) reset and let
      // the recovery window settle; it must not have left cleared set.
      expect(f.dut.output('cleared').value.toBool(), isFalse);
      await Simulator.endSimulation();
    },
  );

  test(
    'cleared reads 0 after a bus-only reset (Minor 4)',
    () async {
      final f = await buildSwSinkFixture();
      await settleOneByte(f);

      f.busReset.inject(1);
      for (var i = 0; i < 5; i++) {
        await f.busClk.nextPosedge;
      }
      f.busReset.inject(0);
      for (var i = 0; i < 40; i++) {
        await f.busClk.nextPosedge;
      }

      expect(
        f.dut.output('cleared').value.toBool(),
        isFalse,
        reason: 'a bus-only reset is not a usb-only reset seen at '
            'runtime, and must not look like an aborted download',
      );
      await waitReady(f, maxCycles: 200);

      await Simulator.endSimulation();
    },
  );
}
