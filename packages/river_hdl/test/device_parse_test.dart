import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

void main() {
  group('Device.parse - legacy device forms', () {
    test('type:addr', () {
      final d = Device.parse('uart:0x10000000');
      expect(d.type, 'uart');
      expect(d.name, 'uart');
      expect(d.address, 0x10000000);
      expect(d.size, isNull);
      expect(d.effectiveSize, 0x1000); // uart class default
    });

    test('type:addr:compat', () {
      final d = Device.parse('uart:0x10000000:ns16550a');
      expect(d.type, 'uart');
      expect(d.address, 0x10000000);
      expect(d.compatible, 'ns16550a');
      expect(d.board, isNull);
    });

    test('name=type:addr:compat', () {
      final d = Device.parse('myuart=uart:0x10000000:ns16550a');
      expect(d.name, 'myuart');
      expect(d.type, 'uart');
      expect(d.address, 0x10000000);
      expect(d.compatible, 'ns16550a');
    });

    test('clint with class-default size', () {
      final d = Device.parse('clint:0x02000000');
      expect(d.type, 'clint');
      expect(d.effectiveSize, 0x10000);
    });
  });

  group('Device.parse - memory-backed forms', () {
    test('sram addr:size', () {
      final d = Device.parse('sram:0x08000000:64K');
      expect(d.type, 'sram');
      expect(d.address, 0x08000000);
      expect(d.size, 64 * 1024);
      expect(d.isMemoryBacked, isTrue);
    });

    test('flash addr:size:board', () {
      final d = Device.parse('flash:0x20000000:16M:arty-s7');
      expect(d.type, 'flash');
      expect(d.address, 0x20000000);
      expect(d.size, 16 * 1024 * 1024);
      expect(d.board, 'arty-s7');
      expect(d.flashBoard, isNotNull);
    });

    test('second bare number becomes size', () {
      final d = Device.parse('sram:0x08000000:65536');
      expect(d.address, 0x08000000);
      expect(d.size, 65536);
    });

    test('dram addr:size:board (no params)', () {
      final d = Device.parse('dram:0x80000000:128M:arty-s7-x8');
      expect(d.type, 'dram');
      expect(d.address, 0x80000000);
      expect(d.size, 128 * 1024 * 1024);
      expect(d.board, 'arty-s7-x8');
      expect(d.ddrBoard, isNotNull);
      expect(d.params, isNull);
    });
  });

  group('Device.parse - params', () {
    test('dram with ddr clock params', () {
      final d = Device.parse(
        'dram:0x80000000:128M:arty-s7-x8:clockfreq=200000000',
      );
      expect(d.board, 'arty-s7-x8');
      expect(d.params, isNotNull);
      expect(d.params!.clockFreq, 200000000);
    });

    test('train=hw|runtime is the only training-related key', () {
      final hw = Device.parse('dram:0x80000000:256M:arty-s7:train=hw');
      expect(hw.params!.runtimeTrain, isFalse);
      final runtime = Device.parse(
        'dram:0x80000000:256M:arty-s7:train=runtime',
      );
      expect(runtime.params!.runtimeTrain, isTrue);
    });

    test('train only accepts hw or runtime', () {
      expect(
        () => Device.parse('dram:0x80000000:256M:arty-s7:train=bogus'),
        throwsA(isA<FormatException>()),
      );
    });

    test('every key the deleted old DDR stack read is now rejected, not '
        'silently ignored', () {
      for (final key in const [
        'trainable=true',
        'cmdslot=2',
        'wrshift=-1',
        'wrbeat=0',
        'readtap=40',
        'readslack=1',
        'readretry=6',
        'window=5',
        'writeverify=true',
        'readlevel=true',
        'selftest=true',
        'laprobe=true',
        'mpr=true',
        'ddr3fast=true',
        'ddr3v2=true',
        'dqsgate=true',
        'readclextra=1',
      ]) {
        expect(
          () => Device.parse('dram:0x80000000:256M:arty-s7:$key'),
          throwsA(isA<FormatException>()),
          reason: '"$key" must be rejected, not parsed-and-ignored',
        );
      }
    });

    test('ctrlgear=2 selects the CK/8 gearbox controller', () {
      final d = Device.parse('dram:0x80000000:256M:arty-s7:ctrlgear=2');
      expect(d.params!.ctrlGear, 2);
    });

    test(
      'ctrlgear absent defaults to null (= gearRatio 1, byte-identical)',
      () {
        final d = Device.parse('dram:0x80000000:256M:arty-s7');
        expect(d.params, isNull);
      },
    );

    test('ctrlgear only accepts 1 or 2', () {
      expect(
        () => Device.parse('dram:0x80000000:256M:arty-s7:ctrlgear=3'),
        throwsA(isA<FormatException>()),
      );
    });

    test('usb-dfu with mode', () {
      final d = Device.parse('usb-dfu:0x0C000000:mode=software');
      expect(d.type, 'usb-dfu');
      expect(d.address, 0x0C000000);
      expect(d.params!.mode, 'software');
    });

    test('flash-firmware offset + path (addr is the flash offset)', () {
      final d = Device.parse('flash-firmware:0x100000:path=weir-fsbl.bin');
      expect(d.type, 'flash-firmware');
      expect(d.address, 0x100000);
      expect(d.params!.path, 'weir-fsbl.bin');
    });
  });

  group('Device.parse - addressless', () {
    test('debug-jtag is type only', () {
      final d = Device.parse('debug-jtag');
      expect(d.type, 'debug-jtag');
      expect(d.address, isNull);
      expect(d.size, isNull);
      expect(d.board, isNull);
      expect(d.params, isNull);
    });
  });

  group('Device.parse - validation', () {
    test('memory-backed type without size throws', () {
      expect(() => Device.parse('sram:0x08000000'), throwsFormatException);
    });

    test('memory-backed type without address throws', () {
      expect(() => Device.parse('dram'), throwsFormatException);
    });

    test('unknown dram board throws', () {
      expect(
        () => Device.parse('dram:0x80000000:128M:no-such-board'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('dram size mismatch against the part throws', () {
      expect(
        () => Device.parse('dram:0x80000000:64M:arty-s7-x8'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('bad usb-dfu mode throws', () {
      expect(
        () => Device.parse('usb-dfu:0x0C000000:mode=bogus'),
        throwsFormatException,
      );
    });

    test('unknown param key throws', () {
      expect(
        () => Device.parse('dram:0x80000000:128M:arty-s7-x8:nonsense=1'),
        throwsFormatException,
      );
    });

    test('a bare word in the board slot is treated as a board name', () {
      // `mode` (no '=') is not a param; on a dram it is read as a board name,
      // which is unknown -> ArgumentError. This is why params always need '='.
      expect(
        () => Device.parse('dram:0x80000000:128M:mode'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('DDR clock-tree agreement (buildSoC validation)', () {
    test('two dram controllers disagreeing on clockfreq throws', () {
      final config = RiverGenIpConfig(
        name: 'two_dram',
        cores: const ['rc1-s'],
        devices: [
          Device.parse('dram:0x80000000:128M:arty-s7-x8:clockfreq=200000000'),
          Device.parse('dram:0x90000000:128M:arty-s7-x8:clockfreq=333333333'),
          Device.parse('uart:0x10000000:ns16550a'),
        ],
      );
      expect(config.buildSoC(), throwsA(isA<ArgumentError>()));
    });
  });

  group('--board (HarborBoard wiring)', () {
    RiverGenIpConfig cfg() => RiverGenIpConfig(
      name: 'b',
      cores: const ['rc1-s'],
      boardName: 'arty-s7-50',
      devices: [Device.parse('uart:0x10000000:ns16550a')],
    );

    test('board synthesises the target when --target is unset', () {
      final t = cfg().effectiveTarget;
      expect(t, isA<FpgaTarget>());
      final f = t as FpgaTarget;
      expect(f.vendor, 'spartan7'); // openXc7 board -> spartan7 target path
      expect(f.device, 'xc7s50');
      expect(f.package, 'csga324');
    });

    test('explicit --target wins over the board target', () {
      final config = RiverGenIpConfig(
        name: 'b',
        cores: const ['rc1-s'],
        boardName: 'arty-s7-50',
        target: Target.parse('ecp5:lfe5u-25f:CSFBGA285'),
        devices: [Device.parse('uart:0x10000000:ns16550a')],
      );
      expect((config.effectiveTarget as FpgaTarget).vendor, 'ecp5');
    });

    test('board catalog uart_tx binds to the uart device port', () {
      final tx = cfg().effectivePins.firstWhere(
        (p) => p.externalName == 'uart_tx',
      );
      expect(tx.isDevicePin, isTrue);
      expect(tx.deviceName, 'uart');
      expect(tx.portName, 'tx');
    });

    test('board catalog clk is a simple (non-device) pin in fpgaPinMap', () {
      final config = cfg();
      final clk = config.effectivePins.firstWhere(
        (p) => p.externalName == 'clk',
      );
      expect(clk.isDevicePin, isFalse);
      expect(config.fpgaPinMap['clk'], startsWith('R2'));
    });

    test('explicit --pin overrides the board catalog entry', () {
      final config = RiverGenIpConfig(
        name: 'b',
        cores: const ['rc1-s'],
        boardName: 'arty-s7-50',
        pins: [PinAssignment.parse('clk=Z99')],
        devices: [Device.parse('uart:0x10000000:ns16550a')],
      );
      expect(config.fpgaPinMap['clk'], 'Z99');
    });

    test('spi device iface=pmod@ja binds the four SPI pads to JA sites', () {
      final config = RiverGenIpConfig(
        name: 'b',
        cores: const ['rc1-s'],
        boardName: 'arty-s7-50',
        devices: [Device.parse('spi:0x10001000:iface=pmod@ja')],
      );
      // Each SPI pad is a device pin on the spi controller, at the Digilent
      // Pmod-SPI JA sites (JA1=L17 cs, JA2=L18 mosi, JA3=M14 miso, JA4=N14 sck).
      final byName = {for (final p in config.effectivePins) p.externalName: p};
      expect(byName['spi_cs']?.deviceName, 'spi');
      expect(byName['spi_cs']?.portName, 'spi_cs_n');
      expect(config.fpgaPinMap['spi_cs'], startsWith('L17'));
      expect(config.fpgaPinMap['spi_mosi'], startsWith('L18'));
      expect(config.fpgaPinMap['spi_miso'], startsWith('M14'));
      expect(config.fpgaPinMap['spi_sck'], startsWith('N14'));
    });

    test('spi dma=true adds a second fabric master + harbor,dma DT prop', () async {
      final config = RiverGenIpConfig(
        name: 'dma_spi_soc',
        cores: const ['rc1-n'],
        clockFrequency: 48000000,
        oscFrequency: 48000000,
        devices: [
          // 4K = 1024 words on this 32-bit bus, the most HarborSram builds
          // without a `target`. These tests assert fabric wiring, not capacity.
          Device.parse('sram:0x80000000:4K'),
          Device.parse('uart:0x10000000:ns16550a'),
          Device.parse('spi:0x10001000:sdcard=true,dma=true'),
        ],
      );
      // The dma param parses off the device string.
      final spiDev = config.devices.firstWhere((d) => d.type == 'spi');
      expect(spiDev.params?.dma, isTrue);

      final soc = await config.buildSoC();
      // Core + the SPI's integrated DMA engine = two bus masters on the fabric.
      expect(soc.masters.length, equals(2), reason: 'core + spi dma master');

      await soc.build();
      // The device tree advertises the integrated DMA so firmware uses the fast
      // DMA_ADDR/LEN/CTRL path instead of byte-by-byte PIO.
      expect(soc.generateDts(), contains('harbor,dma'));
    });

    test('spi without dma stays a single-master, no harbor,dma prop', () async {
      final config = RiverGenIpConfig(
        name: 'pio_spi_soc',
        cores: const ['rc1-n'],
        clockFrequency: 48000000,
        oscFrequency: 48000000,
        devices: [
          // 4K = 1024 words on this 32-bit bus, the most HarborSram builds
          // without a `target`. These tests assert fabric wiring, not capacity.
          Device.parse('sram:0x80000000:4K'),
          Device.parse('uart:0x10000000:ns16550a'),
          Device.parse('spi:0x10001000:sdcard=true'),
        ],
      );
      final soc = await config.buildSoC();
      expect(soc.masters.length, equals(1), reason: 'core only');
      await soc.build();
      expect(soc.generateDts(), isNot(contains('harbor,dma')));
    });

    test('iface= on a non-spi device throws', () {
      final config = RiverGenIpConfig(
        name: 'b',
        cores: const ['rc1-s'],
        boardName: 'arty-s7-50',
        devices: [Device.parse('uart:0x10000000:iface=pmod@ja')],
      );
      expect(() => config.effectivePins, throwsArgumentError);
    });
  });
}
