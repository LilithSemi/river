import 'dart:io';

import 'package:river/river.dart';
import 'package:river_maskrom/river_maskrom.dart';

/// Emit a serial-monitor load frame for the [RiverDdrTest] payload, as hex
/// bytes for `$readmemh` plus the raw payload `.bin` for river_load.
/// Usage: `dart run river_maskrom:emit_ddr_test [out.hex] [dram] [uart] [clockHz]`
Future<void> main(List<String> args) async {
  final out = args.isNotEmpty ? args[0] : '/tmp/ddr_frame.hex';
  final dram = args.length > 1 ? int.parse(args[1]) : 0x90000000;
  final uart = args.length > 2 ? int.parse(args[2]) : 0x10000000;
  final clockHz = args.length > 3 ? int.parse(args[3]) : 48000000;

  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  final payloadProg = RiverDdrTest(
    isa: isa,
    uartBase: uart,
    dramBase: dram,
    clockHz: clockHz,
  );
  await payloadProg.build();
  final payload = payloadProg.generateBytes();

  final sum = payload.fold<int>(0, (a, b) => (a + b) & 0xff);
  final frame = [
    payload.length & 0xff,
    (payload.length >> 8) & 0xff,
    ...payload,
    sum,
  ];
  await File(out).writeAsString(
    frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('\n'),
  );
  final binOut = out.replaceAll(RegExp(r'\.hex$'), '.bin');
  await File(binOut == out ? '$out.bin' : binOut).writeAsBytes(payload);
  stdout.writeln(
    'wrote $out (+ payload .bin): ${payload.length}-byte payload, checksum '
    '0x${sum.toRadixString(16)}, frame ${frame.length} bytes',
  );
}
