// Boots the exact creek SoC gateware (rc1-s core + maskrom hello program +
// SRAM + ns16550a UART + wishbone fabric) in a ROHD simulation with a
// passthrough clock and external reset (NO target, so the EHXPLLL/POR/LOCK
// path is deliberately out of the picture). This partitions the "dead silent
// on OrangeCrab" bug: if the banner decodes out of uart_tx here, the gateware
// logic is correct and the silence is the physical PLL clock path. If it does
// NOT, the bug is in the core/maskrom/SRAM/UART/bus logic.
import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

void main() {
  // NOTE: this boots the full SoC and runs ~27k cycles of the microcode core,
  // which the interpreted ROHD simulator cannot push fast enough (>15 min). The
  // fast, definitive integration proof is the Verilator harness driven by
  // `bin/gen_sim_sv.dart` (see that file): it streams "Hello from River!" out of
  // uart_tx in ~0.1s. The two silicon fixes this exercised are locked in by fast
  // unit tests: river_adl li zero-extension, mmu sub-word load lane-shift, and
  // harbor sram SEL byte-store. Kept here, skipped, to document the flow.
  test(
    'creek hello banner streams out of uart_tx (logic-only, no PLL)',
    skip:
        'too slow for ROHD sim; use the Verilator harness (bin/gen_sim_sv.dart)',
    () async {
      // Small clock so the baked UART divisor (clockHz / 115200) is tiny and the
      // banner streams in a few thousand sim cycles. The logic under test is
      // identical to the 24 MHz build; only the divisor immediate differs.
      const clockHz = 1152000; // divisor = 1152000 / 115200 = 10
      const divisor = clockHz ~/ 115200;

      final config = RiverGenIpConfig(
        name: 'creek_v1',
        cores: const ['rc1-s'],
        clockFrequency: clockHz,
        oscFrequencyOverride: clockHz, // equal -> passthrough clock in sim
        devices: [
          Device.parse('flash:0x20000000:16M'),
          Device.parse('sram:0x80000000:32K'),
          Device.parse('clint:0x02000000'),
          Device.parse('plic:0x04000000'),
          Device.parse('uart:0x10000000:ns16550a'),
        ],
        // Expose uart tx/rx at the top so the testbench can read them. The
        // FPGA pin names are irrelevant with no target.
        pins: [
          PinAssignment.parse('uart_tx=uart@tx:N17'),
          PinAssignment.parse('uart_rx=uart@rx:M18'),
        ],
        // no target -> sim passthrough clock + real external reset pin
        bootProgram: 'hello',
      );

      final soc = await config.buildSoC();

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');

      soc.input('clk').srcConnection! <= clk;
      soc.input('reset').srcConnection! <= reset;
      // UART RX idle-high so the receive engine stays quiet.
      soc.input('uart_rx').srcConnection! <= Const(1);

      await soc.build();

      final tx = soc.output('uart_tx');

      reset.inject(1);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());

      // Hold reset a few cycles, then release.
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);

      // Decode the 8N1 serial stream on uart_tx. Sample once per sysclk; on a
      // falling edge (start bit) wait 1.5 bit-periods to land mid-bit0, then read
      // 8 data bits LSB-first spaced one bit-period apart.
      final received = <int>[];
      final sb = StringBuffer();
      var prev = 1;
      const maxCycles = 200000;
      for (var cycle = 0; cycle < maxCycles; cycle++) {
        await clk.nextPosedge;
        final cur = tx.value.isValid ? tx.value.toInt() : 1;
        if (prev == 1 && cur == 0) {
          // Start bit detected. Advance to the middle of bit 0.
          for (var w = 0; w < divisor + divisor ~/ 2; w++) {
            await clk.nextPosedge;
            cycle++;
          }
          var byte = 0;
          for (var b = 0; b < 8; b++) {
            final bit = tx.value.isValid ? tx.value.toInt() & 1 : 1;
            byte |= bit << b;
            for (var w = 0; w < divisor; w++) {
              await clk.nextPosedge;
              cycle++;
            }
          }
          received.add(byte);
          if (byte >= 0x20 && byte < 0x7f) {
            sb.writeCharCode(byte);
          } else {
            sb.write('[${byte.toRadixString(16).padLeft(2, '0')}]');
          }
          prev = tx.value.isValid ? tx.value.toInt() : 1;
          // Stop once we have enough to recognize the banner.
          if (received.length >= 19) break;
          continue;
        }
        prev = cur;
      }

      await Simulator.endSimulation();
      await Simulator.simulationEnded;

      // ignore: avoid_print
      print('UART bytes (${received.length}): $sb');

      final text = String.fromCharCodes(
        received.where((b) => b >= 0x20 && b < 0x7f),
      );
      expect(
        text,
        contains('Hello from River!'),
        reason: 'decoded uart_tx stream was: $sb',
      );
    },
  );
}
