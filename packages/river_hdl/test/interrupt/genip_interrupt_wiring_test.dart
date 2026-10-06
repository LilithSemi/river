import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// A small SoC built the way the CLI builds one. `rc1-n` has no supervisor mode
/// and `rc1-s` does, which is what decides how many PLIC contexts the SoC gets.
RiverGenIpConfig _config({
  required String core,
  List<String> extraDevices = const [],
}) => RiverGenIpConfig(
  name: 'irq_wiring_soc',
  cores: [core],
  clockFrequency: 48000000,
  oscFrequency: 48000000,
  devices: [
    // 4K = 1024 words, the most HarborSram builds without a `target`.
    Device.parse('sram:0x80000000:4K'),
    Device.parse('uart:0x10000000:ns16550a'),
    Device.parse('clint:0x02000000'),
    Device.parse('plic:0x0C000000'),
    for (final d in extraDevices) Device.parse(d),
  ],
);

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('PLIC contexts', () {
    test(
      'a supervisor-capable core gets a machine AND a supervisor context',
      () async {
        final soc = await _config(core: 'rc1-s').buildSoC();
        final dts = soc.generateDts();

        expect(soc.interruptContexts.length, equals(2));
        expect(soc.interruptContexts[0].cause, equals(11));
        expect(soc.interruptContexts[1].cause, equals(9));
        // An S-mode OS looks for a context whose parent interrupt is supervisor
        // external (cause 9). With only the machine context it finds none and
        // gives up on the controller entirely.
        expect(
          dts,
          contains('interrupts-extended = <&cpu0_intc 0xb>, <&cpu0_intc 0x9>;'),
        );
        expect(dts, contains('interrupt-parent = <&intc0>;'));
      },
    );

    test('a core without supervisor gets only the machine context', () async {
      final soc = await _config(core: 'rc1-n').buildSoC();
      final dts = soc.generateDts();

      expect(soc.interruptContexts.length, equals(1));
      expect(soc.interruptContexts.single.cause, equals(11));
      expect(dts, contains('interrupts-extended = <&cpu0_intc 0xb>;'));
      // No S-mode on this core, so claiming a supervisor context is impossible
      // and advertising one would be a lie.
      expect(dts, isNot(contains('0x9')));
    });

    test(
      'each context drives its own core interrupt line',
      () async {
        final soc = await _config(core: 'rc1-s').buildSoC();
        await soc.build();
        final sv = soc.generateSynth();

        // Context 0 is the hart's machine line and context 1 its supervisor line.
        // Crossing them, or leaving either dangling, is invisible in the tables.
        expect(sv, contains('.ext_irq_0(core0_ext_pending)'));
        expect(sv, contains('.ext_irq_1(core0_sei_pending)'));
        expect(sv, contains('.extPending(core0_ext_pending)'));
        expect(sv, contains('.seiPending(core0_sei_pending)'));
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );

    test(
      'a core without supervisor has no supervisor port',
      () async {
        final soc = await _config(core: 'rc1-n').buildSoC();
        await soc.build();
        final sv = soc.generateSynth();

        expect(sv, contains('.ext_irq_0(core0_ext_pending)'));
        expect(sv, isNot(contains('seiPending')));
        expect(sv, isNot(contains('ext_irq_1')));
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });

  group('device loss', () {
    test('a gpio device becomes real hardware', () async {
      final soc = await _config(
        core: 'rc1-n',
        extraDevices: const ['gpio:0x10002000:pins=4'],
      ).buildSoC();
      final dts = soc.generateDts();

      // It used to be dropped without a word: no RTL, no node, no message.
      expect(soc.peripherals.map((p) => p.name), contains('gpio'));
      expect(dts, contains('gpio@10002000'));
      // And it is a real interrupt source, numbered by the same allocator.
      expect(dts, contains('ngpios = <4>'));
      final gpioNode = dts.substring(dts.indexOf('gpio@10002000'));
      expect(
        gpioNode.substring(0, gpioNode.indexOf('};')),
        contains('interrupts = <'),
      );
    });

    test('an unimplemented device type fails loudly', () async {
      // Silent loss is the fault class that left every PLIC source dangling.
      await expectLater(
        _config(
          core: 'rc1-n',
          extraDevices: const ['i2c:0x10003000'],
        ).buildSoC(),
        throwsArgumentError,
      );
    });
  });
}
