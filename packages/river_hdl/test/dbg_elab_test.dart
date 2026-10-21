import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

void main() {
  final cfg = WishboneConfig(addressWidth: 64, dataWidth: 64, selWidth: 8);

  test('RiverDebugSubsystem elaborates', () async {
    final sub = RiverDebugSubsystem(cfg, xlen: 64);
    await sub.build();
    final sv = sub.generateSynth();
    expect(sv.contains('RiverDebugModule'), isTrue);
    expect(sv.contains('SbaWaistAdapter'), isTrue);
  });

  test('no FPGA target defaults to the ECP5 JTAGG tap', () async {
    final sub = RiverDebugSubsystem(cfg, xlen: 64);
    await sub.build();
    final sv = sub.generateSynth();
    expect(sv.contains('JTAGG'), isTrue);
    expect(sv.contains('BSCANE2'), isFalse);
  });

  test('Xilinx target taps BSCANE2 on USER1, not JTAGG', () async {
    final sub = RiverDebugSubsystem(
      cfg,
      xlen: 64,
      target: const HarborFpgaTarget.spartan7(
        device: 'xc7s50',
        package: 'csga324',
      ),
    );
    await sub.build();
    final sv = sub.generateSynth();
    expect(sv.contains('BSCANE2'), isTrue);
    // USER4 (openocd's bscan tunnel hardcodes USER4).
    expect(sv.contains('JTAG_CHAIN(4)'), isTrue);
    expect(sv.contains('JTAGG'), isFalse);
  });

  test('ECP5 target taps the JTAGG', () async {
    final sub = RiverDebugSubsystem(
      cfg,
      xlen: 64,
      target: const HarborFpgaTarget.ecp5(
        device: 'lfe5u-25f',
        package: 'CSFBGA285',
      ),
    );
    await sub.build();
    final sv = sub.generateSynth();
    expect(sv.contains('JTAGG'), isTrue);
    expect(sv.contains('BSCANE2'), isFalse);
  });

  test(
    'Verilator target exposes a raw TAP, no vendor primitive, no tunnel',
    () async {
      final sub = RiverDebugSubsystem(
        cfg,
        xlen: 64,
        target: const HarborSimTarget(),
      );
      await sub.build();
      final sv = sub.generateSynth();
      // Verilator cannot compile either config-JTAG primitive, and with no user
      // register to ride there is nothing for the bscan tunnel to decode.
      expect(sv.contains('JTAGG'), isFalse);
      expect(sv.contains('BSCANE2'), isFalse);
      expect(sv.contains('JtagBscanTunnel'), isFalse);
      // The TAP is driven straight off top-level pins that the generated C++
      // remote_bitbang server bit-bangs.
      for (final p in ['jtag_tck', 'jtag_tms', 'jtag_tdi', 'jtag_trst']) {
        expect(
          sub.tryInput(p),
          isNotNull,
          reason: '$p must be a top-level input',
        );
      }
      expect(sub.tryOutput('jtag_tdo'), isNotNull);
      // The debug module itself is unchanged.
      expect(sv.contains('RiverDebugModule'), isTrue);
    },
  );
}
