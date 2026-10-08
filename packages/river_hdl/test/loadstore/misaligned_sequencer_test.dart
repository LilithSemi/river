import 'dart:async';

import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:river_hdl/src/core/misaligned_load.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class Rig {
  final int width;
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic()..inject(1);
  final enable = Logic()..inject(0);
  final size = Logic(width: 3)..inject(1);
  final misaligned = Logic()..inject(1);
  final response = Logic()..inject(0);
  final responseValid = Logic()..inject(0);
  final pageFault = Logic()..inject(0);
  late final address = Logic(width: width)..inject(0);
  late final readData = Logic(width: width)..inject(0);
  late final dut = MisalignedLoad(
    clk,
    reset,
    enable,
    address,
    size,
    misaligned,
    response,
    responseValid,
    readData,
    pageFault,
  );
  Rig(this.width);

  Future<void> tick() => clk.nextNegedge;
  Future<void> start() async {
    await dut.build();
    Simulator.setMaxSimTime(10000);
    unawaited(Simulator.run());
    await tick();
    await tick();
    reset.inject(0);
  }

  Future<void> issue(int at) async {
    address.inject(at);
    size.inject(1);
    enable.inject(1);
    await tick();
    expect(dut.readEnable.value.toBool(), isTrue);
    expect(dut.readAddress.value.toInt(), at & ~(width ~/ 8 - 1));
    expect(dut.done.value.toBool(), isFalse);
  }

  Future<void> respond(BigInt data) async {
    readData.inject(LogicValue.ofBigInt(data, width));
    responseValid.inject(1);
    response.inject(1);
    await tick();
  }

  Future<void> clearResponse() async {
    response.inject(0);
    responseValid.inject(0);
    await tick();
  }

  Future<void> freshLoad() async {
    await issue(0x301);
    await respond(BigInt.from(0x123400));
    expect(dut.done.value.toBool(), isTrue);
    expect(dut.valid.value.toBool(), isTrue);
    expect(dut.data.value.toBigInt(), BigInt.from(0x1234));
    expect(dut.accessFault.value.toBool(), isFalse);
    for (var i = 0; i < 3; i++) {
      await tick();
      expect(dut.done.value.toBool(), isTrue);
      expect(dut.readEnable.value.toBool(), isFalse);
      expect(dut.data.value.toBigInt(), BigInt.from(0x1234));
    }
  }
}

void main() {
  tearDown(Simulator.reset);
  for (final kind in [
    'overlap',
    'host overflow overlap',
    'negative',
    'empty',
    'beyond XLEN',
  ]) {
    test('reject invalid PMA: $kind', () {
      final high = kind == 'host overflow overlap';
      final xlen = high ? RiscVMxlen.rv64 : RiscVMxlen.rv32;
      final regions = switch (kind) {
        'overlap' => const [
          HarborPmaRegion.memory(start: 0x1000, size: 4096),
          HarborPmaRegion.io(start: 0x1800, size: 256),
        ],
        'host overflow overlap' => [
          HarborPmaRegion.memory(start: 1 << 62, size: 1 << 62),
          HarborPmaRegion.io(start: (1 << 62) + 4096, size: 256),
        ],
        'negative' => const [HarborPmaRegion.memory(start: -1, size: 4096)],
        'empty' => const [HarborPmaRegion.memory(start: 0, size: 0)],
        _ => const [HarborPmaRegion.memory(start: 0xfffffff0, size: 64)],
      };
      expect(
        () => RiverCore(
          RiverCoreConfig(
            mxlen: xlen,
            type: RiverCoreType.general,
            extensions: [rv32i, if (high) rv64i],
            interrupts: [],
            mmu: HarborMmuConfig(
              mxlen: xlen,
              pagingModes: const [RiscVPagingMode.bare],
              pmp: HarborPmpConfig.none,
              pma: HarborPmaConfig(regions: regions),
            ),
            clock: const HarborClockConfig(
              name: 'test',
              rate: HarborFixedClockRate(100000000),
            ),
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains(kind.contains('overlap') ? 'Overlapping' : 'Invalid'),
          ),
        ),
      );
    });
  }
  for (final width in [32, 64]) {
    for (final operation in [
      'cancel first',
      'cancel second',
      'reset first',
      'reset second',
      'back-to-back',
      'wrap',
      'oversized',
    ]) {
      test('rv$width $operation', () async {
        final r = Rig(width);
        await r.start();
        try {
          final bytes = width ~/ 8;
          if (operation == 'wrap' || operation == 'oversized') {
            final at = operation == 'wrap'
                ? (BigInt.one << width) - BigInt.one
                : BigInt.from(0x101);
            r.address.inject(LogicValue.ofBigInt(at, width));
            r.size.inject(operation == 'oversized' ? bytes.bitLength : 1);
            r.enable.inject(1);
            await r.tick();
            expect(r.dut.readEnable.value.toBool(), isFalse);
            expect(r.dut.done.value.toBool(), isTrue);
            expect(r.dut.valid.value.toBool(), isFalse);
            expect(r.dut.accessFault.value.toBool(), isTrue);
            expect(r.dut.faultAddress.value.toBigInt(), at);
            r.enable.inject(0);
            await r.tick();
            await r.tick();
            await r.freshLoad();
          } else {
            await r.issue(0x100 + bytes - 1);
            if (operation.endsWith('second') || operation == 'back-to-back') {
              await r.respond(BigInt.from(0xa1) << (width - 8));
              expect(r.dut.done.value.toBool(), isFalse);
              expect(r.dut.readEnable.value.toBool(), isFalse);
              // A stretched terminal response must not become the next beat.
              await r.tick();
              expect(r.dut.readEnable.value.toBool(), isFalse);
              await r.clearResponse();
              expect(r.dut.readEnable.value.toBool(), isTrue);
              expect(r.dut.readAddress.value.toInt(), 0x100 + bytes);
            }
            if (operation.startsWith('cancel')) {
              final oldAddress = r.dut.readAddress.value;
              r.enable.inject(0);
              for (var i = 0; i < 3; i++) {
                await r.tick();
                expect(r.dut.done.value.toBool(), isFalse);
                expect(r.dut.readEnable.value.toBool(), isTrue);
                expect(r.dut.readAddress.value, oldAddress);
              }
              // Present the next load before the old transaction drains.
              r.address.inject(0x301);
              r.enable.inject(1);
              await r.respond(BigInt.from(0xffff));
              expect(r.dut.done.value.toBool(), isFalse);
              expect(r.dut.valid.value.toBool(), isFalse);
              await r.clearResponse();
              await r.freshLoad();
            } else if (operation.startsWith('reset')) {
              r.reset.inject(1);
              r.enable.inject(0);
              r.response.inject(0);
              await r.tick();
              expect(r.dut.done.value.toBool(), isFalse);
              expect(r.dut.readEnable.value.toBool(), isFalse);
              r.reset.inject(0);
              await r.freshLoad();
            } else {
              await r.respond(BigInt.from(0xb2));
              expect(r.dut.done.value.toBool(), isTrue);
              expect(r.dut.valid.value.toBool(), isTrue);
              expect(r.dut.data.value.toBigInt(), BigInt.from(0xb2a1));
              r.enable.inject(0);
              await r.tick();
              await r.clearResponse();
              await r.freshLoad();
            }
          }
        } finally {
          await Simulator.endSimulation();
          await Simulator.simulationEnded;
        }
      });
    }
  }
}
