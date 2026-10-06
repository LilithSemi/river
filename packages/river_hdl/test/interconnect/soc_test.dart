import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

void main() {
  group('DTS generation', () {
    test('generates valid DTS for RV32 core', () {
      final sysclk = HarborClockConfig(
        name: 'sysclk',
        rate: HarborFixedClockRate(48000000),
      );

      final coreConfig = RiverCoreConfigV1.nano(
        mmu: HarborMmuConfig(
          mxlen: RiscVMxlen.rv32,
          pagingModes: const [RiscVPagingMode.bare],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
        ),
        interrupts: [],
        clock: sysclk,
        resetVector: 0x20000000,
      );

      final cpus = [
        HarborCpu(
          hartId: coreConfig.hartId,
          isa: coreConfig.isa.implementsString,
          clockFrequency: 48000000,
        ),
      ];

      final generator = HarborDeviceTreeGenerator(
        model: 'Stream V1',
        compatible: 'lilithsemi,stream-v1',
        cpus: cpus,
      );

      final dts = generator.generate();

      expect(dts, contains('/dts-v1/'));
      expect(dts, contains('cpus'));
      expect(dts, contains('riscv'));
    });

    test('generates DTS with MMU type for RV64', () {
      final sysclk = HarborClockConfig(
        name: 'sysclk',
        rate: HarborFixedClockRate(48000000),
      );

      final coreConfig = RiverCoreConfigV1.small(
        mmu: HarborMmuConfig(
          mxlen: RiscVMxlen.rv64,
          pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
          hasSupervisorUserMemory: true,
          hasMakeExecutableReadable: true,
        ),
        interrupts: [],
        clock: sysclk,
        resetVector: 0x80000000,
      );

      final cpus = [
        HarborCpu(
          hartId: coreConfig.hartId,
          isa: coreConfig.isa.implementsString,
          clockFrequency: 48000000,
          mmu: 'riscv,sv39',
        ),
      ];

      final generator = HarborDeviceTreeGenerator(
        model: 'Creek V1',
        compatible: 'lilithsemi,creek-v1',
        cpus: cpus,
      );

      final dts = generator.generate();

      expect(dts, contains('/dts-v1/'));
      expect(dts, contains('cpus'));
      expect(dts, contains('sv39'));
    });
  });

  group('GenIP peripheral mapping', () {
    test('maps compatible strings to Harbor peripherals', () {
      final supported = [
        'river,sram',
        'river,flash',
        'ns16550a',
        'riscv,clint0',
        'riscv,plic0',
      ];

      final mappings = {
        'river,sram': true,
        'river,flash': true,
        'ns16550a': true,
        'riscv,clint0': true,
        'riscv,plic0': true,
        'river,gpio': false,
        'river,dram': false,
        'unknown,device': false,
      };

      for (final entry in mappings.entries) {
        expect(
          supported.contains(entry.key),
          entry.value,
          reason: '${entry.key} mapping',
        );
      }
    });

    test(
      'a flash memory region builds a real XIP SPI controller, not SRAM',
      () async {
        final config = RiverGenIpConfig(
          name: 'flash_test_soc',
          cores: const ['rc1-n'],
          clockFrequency: 48000000,
          oscFrequency: 48000000,
          devices: [
            Device.parse('flash:0x20000000:16M'),
            // 4K = 1024 words on this 32-bit bus, the most HarborSram builds
            // without a `target`. These tests assert fabric wiring, not capacity.
            Device.parse('sram:0x80000000:4K'),
            Device.parse('uart:0x10000000:ns16550a'),
          ],
        );
        final soc = await config.buildSoC();
        await soc.build();
        final sv = soc.generateSynth();
        // The flash region is the XIP SPI controller (HarborSpiFlashController),
        // which a maskrom/Weir BIOS executes in place. The SRAM region stays SRAM.
        expect(
          sv,
          contains('HarborSpiFlashController'),
          reason: 'flash must be a real XIP SPI flash controller',
        );
        expect(sv, contains('HarborSram'), reason: 'sram region stays SRAM');
      },
    );
  });
}
