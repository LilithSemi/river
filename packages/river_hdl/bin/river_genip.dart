import 'dart:io' show Platform, Directory, File;

import 'package:args/args.dart';
import 'package:harbor/harbor.dart' show HarborBoard;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:river_hdl/river_hdl.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'name',
      abbr: 'n',
      help: 'SoC top module name',
      defaultsTo: 'river_soc',
    )
    ..addMultiOption(
      'core',
      abbr: 'c',
      help: 'Core model',
      defaultsTo: ['rc1-mi'],
      allowed: ['rc1-n', 'rc1-mi', 'rc1-s', 'rc1-m', 'rc1-f'],
    )
    ..addFlag(
      'instruction-only-cache',
      negatable: false,
      help:
          'Use an instruction-only L1 on scalar in-order cores. '
          'Data stays uncached; physical instruction caching covers '
          'declared SRAM/DRAM only.',
    )
    ..addOption(
      'interconnect',
      abbr: 'i',
      help: 'Bus protocol',
      defaultsTo: 'wishbone',
      allowed: ['wishbone', 'axi', 'tilelink'],
    )
    ..addOption(
      'clock-freq',
      help: 'System clock frequency (Hz)',
      defaultsTo: '48000000',
    )
    ..addOption(
      'osc-freq',
      help: 'External oscillator frequency (Hz)',
      defaultsTo: '12000000',
    )
    ..addMultiOption(
      'device',
      abbr: 'd',
      // Params use commas (key=val,key=val), so do NOT split values on commas;
      // each device is its own -d flag.
      splitCommas: false,
      help:
          'A device in the SoC: [name=]type:addr[:size][:board|compat][:key=val,...]. '
          'Memory-backed regions (sram/flash/dram) need addr+size and may carry a '
          'board + tuning params; MMIO peripherals (uart/clint/plic/gpio) need an '
          'addr; pseudo-devices (usb-dfu/debug-jtag/flash-firmware) drive a '
          'subsystem. Examples: sram:0x08000000:64K | uart:0x10000000:ns16550a | '
          'dram:0x80000000:128M:arty-s7-x8:clockfreq=200000000,train=hw | '
          'usb-dfu:0x0C000000:mode=software | debug-jtag | '
          'flash-firmware:0x100000:path=weir-fsbl.bin',
    )
    ..addOption(
      'target',
      abbr: 't',
      help:
          'Target (FPGA: ecp5:dev:pkg, ice40:dev:pkg; ASIC: sky130:hd, '
          'gf180mcu:3v3; SIM: verilator, verilator:trace)',
    )
    ..addOption(
      'board',
      abbr: 'b',
      help:
          'FPGA board from the Harbor catalog (${HarborBoard.byName.keys.join(', ')}): '
          'supplies the target (when --target is unset) and the board standard '
          'pins (clk/uart/...), so those need not be given as --target/--pin. '
          '--pin still overrides individual signals.',
    )
    ..addOption(
      'pdk-root',
      help: 'PDK installation root (required for ASIC targets)',
    )
    ..addMultiOption(
      'pin',
      abbr: 'p',
      help: 'Pin assignment (name=device@port:pin or name=pin)',
    )
    // Diagnostic, kept global (a build-wide bring-up switch, not board tuning).
    ..addFlag(
      'ddr-single-word',
      help:
          'Diagnostic: the "ddrtest" boot program writes/reads ONLY the first '
          'DRAM word (isolates a broken read path from BL8 DM-mask clobber).',
      defaultsTo: false,
    )
    ..addOption('maskrom-path', help: 'Maskrom binary to bake into SRAM init')
    ..addOption(
      'boot-program',
      help:
          'Bake a built-in program into the boot ROM (SRAM systems: skip '
          'cache-as-RAM, run from ROM, use RAM directly). "hello" prints a '
          'banner; "monitor" loads payloads into RAM over the UART; "hexdump" '
          'hex-dumps two flash windows over the UART (the bitstream preamble at '
          'offset 0 and the firmware slot at 0x100000) straight from ROM, with '
          'no flash-write or maskrom-copy dependency (a SILENT-bring-up probe). '
          '"bundleselftest" mirrors the maskrom flash->SRAM copy+jump from ROM '
          'with per-boundary checkpoints (A/F:/B/S:/C/J) so one boot localizes '
          'whether the flash read, the copy, or the jump is what breaks.',
      allowed: [
        'hello',
        'monitor',
        'hexdump',
        'bundleselftest',
        'trapwfi',
        'ddrtest',
        'ddrprobe',
        'dramexec',
        'dramping',
        'dramstress',
        'dramstress64',
        'dramstresshi',
        'xipboot',
      ],
    )
    ..addOption(
      'output',
      abbr: 'o',
      help: 'Output directory',
      defaultsTo: 'output',
    )
    ..addOption(
      'log',
      help: 'Log level',
      allowed: Level.LEVELS.map((v) => v.name.toLowerCase()).toList(),
    )
    ..addFlag('help', abbr: 'h', help: 'Print usage');

  final args = parser.parse(arguments);

  if (args.flag('help')) {
    print('Usage: ${path.basename(Platform.script.toFilePath())} [options]');
    print('');
    print('River SoC IP generator');
    print('');
    print('Options:');
    print(parser.usage);
    return;
  }

  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  if (args.option('log') != null) {
    Logger.root.level = Level.LEVELS.firstWhere(
      (v) => v.name.toLowerCase() == args.option('log'),
    );
  }

  final config = RiverGenIpConfig(
    name: args.option('name')!,
    cores: args.multiOption('core'),
    instructionOnlyCache: args.flag('instruction-only-cache'),
    interconnect: args.option('interconnect')!,
    clockFrequency: int.parse(args.option('clock-freq')!),
    oscFrequency: int.parse(args.option('osc-freq')!),
    devices: args.multiOption('device').map(Device.parse).toList(),
    target: args.option('target') != null
        ? Target.parse(args.option('target')!)
        : null,
    boardName: args.option('board'),
    pins: args.multiOption('pin').map(PinAssignment.parse).toList(),
    maskromPath: args.option('maskrom-path'),
    pdkRoot: args.option('pdk-root'),
    bootProgram: args.option('boot-program'),
    ddrSingleWord: args.flag('ddr-single-word'),
  );

  print('Generating SoC: ${config.name}');
  print('  Cores: ${config.cores.join(', ')}');
  print('  Interconnect: ${config.interconnect}');
  print('  Clock: ${config.clockFrequency} Hz');
  print('  Memories: ${config.memories.length}');
  print('  Devices: ${config.devices.length}');
  if (config.boardName case final b?) {
    print('  Board: $b');
  }
  if (config.effectiveTarget case final t?) {
    switch (t) {
      case FpgaTarget():
        print('  Target: ${t.vendor} ${t.device} (${t.package})');
      case AsicTarget():
        print('  Target: ${t.pdk} (${t.variant})');
      case SimTarget():
        print('  Target: verilator (sim${t.trace ? ', trace' : ''})');
    }
  }

  final soc = await config.buildSoC();
  final outputDir = Directory(args.option('output')!);
  await soc.generateAll(outputDir);

  // Bundled flash firmware: emit the firmware bytes as a standalone file to be
  // flashed at the firmware offset (the maskrom copies it from there to SRAM).
  if (config.flashFirmwarePath != null) {
    final firmware = await File(config.flashFirmwarePath!).readAsBytes();
    final fwPath = path.join(outputDir.path, 'firmware.bin');
    await File(fwPath).writeAsBytes(firmware);
    print(
      '  Flash firmware (external): ${config.flashFirmwarePath} -> $fwPath '
      '(${firmware.length} bytes, flash offset '
      '0x${config.flashFirmwareOffset.toRadixString(16)})',
    );
  } else if (config.flashFirmware != null) {
    final firmware = await config.buildFlashFirmwareImage();
    final fwPath = path.join(outputDir.path, 'firmware.bin');
    await File(fwPath).writeAsBytes(firmware);
    print(
      '  Flash firmware: ${config.flashFirmware} -> $fwPath '
      '(${firmware.length} bytes, flash offset '
      '0x${config.flashFirmwareOffset.toRadixString(16)})',
    );
  }

  print('Done: ${args.option('output')}');
}
