import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sw_sink_harness.dart';

// Exercises RiverDfuSwSink's own handshake directly (see the harness file
// for why this drives the `dfu` interface instead of a real USB
// transaction). Clocks run at an odd ratio (9/23) throughout, the way
// Harbor's own sink tests use a non-integer USB/bus clock ratio.

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('byte stream', () {
    test('rx_data/bytes_count round-trip with advance delays 0..many', () async {
      final f = await buildSwSinkFixture();
      final delays = [0, 1, 2, 5, 20];

      for (var i = 0; i < delays.length; i++) {
        final data = 0x10 + i;
        await pushByteWhenReady(f, data);
        await waitRxValid(f);
        expect(f.dut.output('rx_data').value.toInt(), equals(data));
        expect(f.dut.output('bytes_count').value.toInt(), equals(i + 1));

        for (var c = 0; c < delays[i]; c++) {
          await f.busClk.nextPosedge;
        }
        await pulseAdvance(f);
        await f.busClk.nextPosedge;
        expect(f.dut.output('rx_valid').value.toBool(), isFalse);
      }

      await Simulator.endSimulation();
    });

    test('back-to-back blocks stream without dropping a byte', () async {
      final f = await buildSwSinkFixture();
      final image = List.generate(40, (i) => (i * 7 + 3) & 0xFF);
      final seen = <int>[];

      for (final byte in image) {
        await pushByteWhenReady(f, byte);
        await waitRxValid(f);
        seen.add(f.dut.output('rx_data').value.toInt());
        await pulseAdvance(f);
      }

      expect(seen, equals(image));
      expect(f.dut.output('bytes_count').value.toInt(), equals(image.length));

      await Simulator.endSimulation();
    });

    test(
      'an end marker that arrives while the last byte is unacked is '
      'handed over once ready returns, and busy/done report it',
      () async {
        final f = await buildSwSinkFixture();

        // Push a byte but do not advance: ready drops low.
        await pushByteWhenReady(f, 0x42);
        await waitRxValid(f);

        // The zero-length DNLOAD's end marker has no backpressure of its
        // own: fire it now, while ready is still low.
        await pulseEnd(f);
        await f.usbClk.nextPosedge;
        expect(
          f.dut.output('busy_out').value.toBool(),
          isTrue,
          reason: 'busy rises the instant the end marker is seen',
        );

        // Ack the byte. ready returns, and the latched end marker is
        // handed over as the next captured entry.
        await pulseAdvance(f);
        await waitRxValid(f);
        expect(f.dut.output('dnload_done').value.toBool(), isTrue);

        // Ack the end marker. busy/done complete the handshake.
        await pulseAdvance(f);
        var sawDone = false;
        for (var i = 0; i < 200; i++) {
          if (f.dut.output('done_out').value.toBool()) sawDone = true;
          if (!f.dut.output('busy_out').value.toBool()) break;
          await f.usbClk.nextPosedge;
        }
        expect(sawDone, isTrue, reason: 'done pulsed once the end was acked');
        expect(f.dut.output('busy_out').value.toBool(), isFalse);

        await Simulator.endSimulation();
      },
    );
  });

  group('clear', () {
    test('clear with a byte pending releases ready', () async {
      final f = await buildSwSinkFixture();

      await pushByteWhenReady(f, 0x55);
      await waitRxValid(f);
      // Do not advance: ready stays low (producer != consumer).
      await f.usbClk.nextPosedge;
      expect(f.dut.output('ready_out').value.toBool(), isFalse);

      await pulseClear(f);
      var sawClearDone = false;
      for (var i = 0; i < 300; i++) {
        if (f.dut.output('clear_done_out').value.toBool()) sawClearDone = true;
        await f.usbClk.nextPosedge;
      }
      expect(sawClearDone, isTrue);
      await waitReady(f);
      expect(f.dut.output('cleared').value.toBool(), isTrue);
      expect(f.dut.output('dnload_done').value.toBool(), isFalse);

      // The sink is fully usable again.
      await pushByteWhenReady(f, 0x66);
      await waitRxValid(f);
      expect(f.dut.output('rx_data').value.toInt(), equals(0x66));

      await Simulator.endSimulation();
    });

    test(
      'clear with the end marker pending releases ready and does not '
      'wedge busy',
      () async {
        final f = await buildSwSinkFixture();

        await pushByteWhenReady(f, 0x11);
        await waitRxValid(f);
        await pulseAdvance(f);
        await waitReady(f);

        await pulseEnd(f);
        await waitRxValid(f);
        expect(f.dut.output('dnload_done').value.toBool(), isTrue);
        expect(f.dut.output('busy_out').value.toBool(), isTrue);
        // Do not advance over the end marker: it is left pending.

        await pulseClear(f);
        var sawClearDone = false;
        for (var i = 0; i < 300; i++) {
          if (f.dut.output('clear_done_out').value.toBool()) {
            sawClearDone = true;
          }
          await f.usbClk.nextPosedge;
        }
        expect(sawClearDone, isTrue);
        await waitReady(f);
        expect(f.dut.output('cleared').value.toBool(), isTrue);
        expect(f.dut.output('dnload_done').value.toBool(), isFalse);
        expect(
          f.dut.output('busy_out').value.toBool(),
          isFalse,
          reason: 'clear must not leave busy wedged with no done ever due',
        );

        await Simulator.endSimulation();
      },
    );

    test(
      'clear while the end marker is latched behind an unacked byte never '
      'delivers it into the next image (N2, probe D)',
      () async {
        final f = await buildSwSinkFixture();

        await pushByteWhenReady(f, 0x42);
        await waitRxValid(f);
        // Do not advance: the byte is still held, so ready is low when the
        // end marker arrives and endPendingUsb latches it.
        await pulseEnd(f);
        await pulseClear(f);
        for (var i = 0; i < 100; i++) {
          await f.busClk.nextPosedge;
        }
        expect(
          f.dut.output('dnload_done').value.toBool(),
          isFalse,
          reason: 'the latched end marker must not survive into the image '
              'this clear starts',
        );
        expect(f.dut.output('rx_valid').value.toBool(), isFalse);
        await waitReady(f);

        await Simulator.endSimulation();
      },
    );

    test('clear_ack (W1C) clears the cleared sticky bit', () async {
      final f = await buildSwSinkFixture();
      await pulseClear(f);
      for (var i = 0; i < 20; i++) {
        await f.busClk.nextPosedge;
      }
      expect(f.dut.output('cleared').value.toBool(), isTrue);

      await pulseClearAck(f);
      await f.busClk.nextPosedge;
      expect(f.dut.output('cleared').value.toBool(), isFalse);

      await Simulator.endSimulation();
    });

    test(
      'a single spurious advance with nothing pending does not flip the '
      'toggle (N1)',
      () async {
        final f = await buildSwSinkFixture();

        // Exactly one advance, with nothing ever pushed: gating advance on
        // rxValid means this must not flip consumerToggle, or ready would
        // wedge low waiting for a producer flip that already matches.
        await pulseAdvance(f);
        for (var i = 0; i < 20; i++) {
          await f.busClk.nextPosedge;
        }
        await waitReady(f);
        expect(f.dut.output('rx_valid').value.toBool(), isFalse);
        expect(f.dut.output('dnload_done').value.toBool(), isFalse);
        expect(f.dut.output('bytes_count').value.toInt(), equals(0));

        // The sink still works normally afterward.
        await pushByteWhenReady(f, 0x77);
        await waitRxValid(f);
        expect(f.dut.output('rx_data').value.toInt(), equals(0x77));

        await Simulator.endSimulation();
      },
    );

    test(
      'an advance that lands after a clear already released the byte it '
      'was meant to ack does not wedge ready (probe B)',
      () async {
        final f = await buildSwSinkFixture();

        await pushByteWhenReady(f, 0x55);
        await waitRxValid(f);
        await pulseClear(f);
        for (var i = 0; i < 40; i++) {
          await f.busClk.nextPosedge;
        }
        // The CPU had read rx_valid=1 before the clear landed; its advance
        // arrives after rx_valid has already been dropped by the clear.
        await pulseAdvance(f);
        for (var i = 0; i < 20; i++) {
          await f.busClk.nextPosedge;
        }
        await waitReady(f);

        await Simulator.endSimulation();
      },
    );
  });
}
