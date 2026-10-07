import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// End-to-end: the single DDR3 stack threads `ctrlgear` from the device
/// param through the DDR MMCM (CLKOUT5 = CK/8) and the HarborDdr3 two-clock
/// interface. gearRatio 1 (absent) stays byte-identical (no gearbox, no
/// serdes clock, no CLKOUT5); gearRatio 2 elaborates with all three present.
void main() {
  Future<String> genDdr3Sv({required bool geared, bool withDram = true}) async {
    final gearSuffix = geared ? ':ctrlgear=2' : '';
    final config = RiverGenIpConfig(
      name: geared ? 'gear2_soc' : 'gear1_soc',
      cores: const ['rc1-s'],
      clockFrequency: 33333333,
      oscFrequency: 100000000, // single-osc DDR3 MMCM path
      target: Target.parse('spartan7:xc7s50:csga324'),
      devices: [
        Device.parse('flash:0x20000000:16M:arty-s7'),
        Device.parse('sram:0x08000000:64K'),
        Device.parse('clint:0x02000000'),
        Device.parse('plic:0x04000000'),
        Device.parse('uart:0x10000000:ns16550a'),
        if (withDram)
          Device.parse(
            'dram:0x80000000:256M:arty-s7:clockfreq=300000000$gearSuffix',
          ),
      ],
      pins: [
        PinAssignment.parse('clk=R2 SSTL135'),
        PinAssignment.parse('uart_tx=uart@tx:R12'),
        PinAssignment.parse('uart_rx=uart@rx:V12'),
      ],
    );
    final soc = await config.buildSoC();
    await soc.build();
    return soc.generateSynth();
  }

  test(
    'CONTROL: the same FPGA SoC WITHOUT the dram builds',
    () async {
      // Isolates whether the mmioDevices/buildSoC path is broken by unrelated WIP
      // (a build failure here == pre-existing, independent of the DDR gearing).
      final sv = await genDdr3Sv(geared: false, withDram: false);
      expect(sv, contains('module'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'ctrlgear absent (gearRatio 1) is byte-identical: no gearbox/serdes/CK8',
    () async {
      final sv = await genDdr3Sv(geared: false);
      expect(sv, isNot(contains('ddr3_gearbox')));
      expect(sv, isNot(contains('ddr_serdes_clk')));
      // No spare CLKOUT5 on the DDR MMCM.
      expect(sv, isNot(contains('.CLKOUT5_DIVIDE(')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'ctrlgear=2 wires the CK/8 controller + CK/4 serdes + gearbox',
    () async {
      final sv = await genDdr3Sv(geared: true);
      // The DDR MMCM emits CK/8 on CLKOUT5.
      expect(sv, contains('.CLKOUT5_DIVIDE('));
      // HarborDdr3 gained its second (serdes) clock port and the gearbox module.
      expect(sv, contains('ddr_serdes_clk'));
      expect(sv, contains('ddr3_gearbox'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
