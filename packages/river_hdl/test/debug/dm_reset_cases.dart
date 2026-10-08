import 'dart:async';
import 'package:river_hdl/src/core/debug.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Mock backends retain ownership until their explicit completion. Counters
/// represent external effects and deliberately do not reset with dmactive.
class ResetHarness {
  final int width;
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic()..inject(1);
  final halted = Logic()..inject(1);
  final ready = Logic()..inject(0);
  final ack = Logic()..inject(0);
  late final Logic regData = Logic(width: width)..inject(0x1111);
  late final Logic busData = Logic(width: width)..inject(0x1111);
  late RiverDebugModule dm;
  late Future<int> Function(int, int?) access;
  Future<void> Function()? resetTransport;
  final regEffects = Logic(width: 8), busEffects = Logic(width: 8);
  final regCompletions = Logic(width: 8), busCompletions = Logic(width: 8);
  final lastRegAddress = Logic(width: 16);
  late final lastRegData = Logic(width: width);
  late final lastBusAddress = Logic(width: width);
  late final lastBusData = Logic(width: width);

  ResetHarness(this.width);

  Future<void> tick([int count = 1]) async {
    for (var i = 0; i < count; i++) {
      await clk.nextNegedge;
    }
  }

  Future<void> start() async {
    final oldReg = Logic(), oldBus = Logic();
    final regRequest = dm.regRead | dm.regWrite;
    Sequential(clk, [
      If(
        reset,
        then: [
          oldReg < 0,
          oldBus < 0,
          regEffects < 0,
          busEffects < 0,
          regCompletions < 0,
          busCompletions < 0,
          lastRegAddress < 0,
          lastRegData < 0,
          lastBusAddress < 0,
          lastBusData < 0,
        ],
        orElse: [
          oldReg < regRequest,
          oldBus < dm.sbaReq,
          If(
            regRequest & ~oldReg,
            then: [
              regEffects < regEffects + 1,
              lastRegAddress < dm.regAddr,
              lastRegData < dm.regWdata,
            ],
          ),
          If(
            dm.sbaReq & ~oldBus,
            then: [
              busEffects < busEffects + 1,
              lastBusAddress < dm.sbaAddr,
              lastBusData < dm.sbaWdata,
            ],
          ),
          If(regRequest & ready, then: [regCompletions < regCompletions + 1]),
          If(dm.sbaReq & ack, then: [busCompletions < busCompletions + 1]),
        ],
      ),
    ]);
    await dm.build();
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await tick(2);
    reset.inject(0);
    await tick(2);
  }

  Future<int> read(int address) => access(address, null);
  Future<void> write(int address, int data) async {
    await access(address, data);
  }

  Future<void> activate() async {
    await write(0x10, 1);
    expect((await read(0x10)) & 1, 1);
  }

  Future<void> inactive() async {
    for (var i = 0; i < 20; i++) {
      if (((await read(0x10)) & 1) == 0) return;
    }
    fail('DM did not finish deactivating after its backends completed');
  }

  int command(bool write, [int register = 0x100b]) =>
      ((width == 64 ? 3 : 2) << 20) |
      (1 << 17) |
      (write ? 1 << 16 : 0) |
      register;
}

void resetCases(String transport, Future<ResetHarness> Function(int) create) {
  tearDown(Simulator.reset);
  for (final width in [32, 64]) {
    for (final scenario in [
      'inactive admission',
      'idle reset',
      'pending abstract read',
      'pending abstract write',
      'active abstract read',
      'active abstract write',
      'SBA read',
      'SBA write',
    ]) {
      test('rv$width $transport DM reset $scenario', () async {
        final h = await create(width);
        try {
          if (scenario == 'inactive admission') {
            h.ready.inject(1);
            await h.write(0x04, 0x99);
            await h.write(0x17, h.command(true));
            await h.tick(4);
            expect(h.regEffects.value.toInt(), 0);
            expect((await h.read(0x10)) & 1, 0);
            await h.activate();
            await h.write(0x04, 0x55);
            await h.write(0x17, h.command(true));
            await h.tick(4);
            expect(h.regEffects.value.toInt(), 1);
            expect(h.lastRegData.value.toInt(), 0x55);
            return;
          }
          await h.activate();
          if (scenario == 'idle reset') {
            await h.write(0x17, 0xff000000);
            expect(((await h.read(0x16)) >> 8) & 7, 2);
            await h.write(0x10, 0x80000003);
            await h.write(0x38, (2 << 17) | (1 << 16) | (1 << 15));
            await h.write(0x10, 0);
            await h.inactive();
            expect(h.dm.haltReq.value.toBool(), isFalse);
            expect(h.dm.ndmreset.value.toBool(), isFalse);
            await h.activate();
            expect(((await h.read(0x16)) >> 8) & 7, 0);
            expect((await h.read(0x11)) & 0x30000, 0);
            expect(
              (await h.read(0x38)) & 0x1f8000,
              (width == 64 ? 3 : 2) << 17,
            );
            return;
          }
          final write = scenario.endsWith('write');
          if (scenario.contains('abstract')) {
            await h.write(0x04, 0x55);
            await h.write(0x17, h.command(write));
            if (scenario.startsWith('active')) await h.tick(4);
            if (h.resetTransport != null) await h.resetTransport!();
            await h.write(0x10, 0);
            // All further work, including early reactivation, is ignored while
            // deactivation drains the old command. This is our drain policy,
            // not a universal requirement to delay dmactive in all DMs.
            await h.write(0x10, 1);
            await h.write(0x04, 0x99);
            await h.write(0x17, h.command(write, 0x100c));
            expect((await h.read(0x10)) & 1, 1);
            expect(h.dm.regAddr.value.toInt(), 0x100b);
            expect(h.dm.regWdata.value.toInt(), 0x55);
            expect(h.regEffects.value.toInt(), 1);
            expect(h.regCompletions.value.toInt(), 0);
            h.ready.inject(1);
            await h.tick(2);
            h.ready.inject(0);
            await h.inactive();
            expect(h.regCompletions.value.toInt(), 1);
            await h.activate();
            expect(
              await h.read(0x04),
              0,
              reason:
                  'implementation-defined reset data, not the old completion',
            );
            h.regData.inject(0x2222);
            await h.write(0x04, 0x77);
            await h.write(0x17, h.command(write, 0x100c));
            await h.tick(4);
            expect(h.dm.regAddr.value.toInt(), 0x100c);
            h.ready.inject(1);
            await h.tick(2);
            h.ready.inject(0);
            expect(h.regEffects.value.toInt(), 2);
            expect(h.regCompletions.value.toInt(), 2);
            expect(h.lastRegAddress.value.toInt(), 0x100c);
            if (write) {
              expect(h.lastRegData.value.toInt(), 0x77);
            } else {
              expect(await h.read(0x04), 0x2222);
            }
          } else {
            await h.write(0x38, (2 << 17) | (write ? 0 : 1 << 20));
            await h.write(0x39, 0x200);
            if (write) await h.write(0x3c, 0x55);
            await h.tick(3);
            expect(h.dm.sbaReq.value.toBool(), isTrue);
            if (h.resetTransport != null) await h.resetTransport!();
            await h.write(0x10, 0);
            await h.write(0x10, 1);
            await h.write(0x38, 3 << 17);
            await h.write(0x39, 0x999);
            await h.write(0x3c, 0x99);
            expect((await h.read(0x10)) & 1, 1);
            expect(h.dm.sbaAddr.value.toInt(), 0x200);
            expect(h.dm.sbaSize.value.toInt(), 2);
            if (write) expect(h.dm.sbaWdata.value.toInt(), 0x55);
            expect(h.busEffects.value.toInt(), 1);
            expect(h.busCompletions.value.toInt(), 0);
            h.ack.inject(1);
            await h.tick(4);
            expect(h.dm.sbaReq.value.toBool(), isFalse);
            expect(h.busCompletions.value.toInt(), 1);
            // A stretched old response cannot become a response to a new epoch.
            expect((await h.read(0x10)) & 1, 1);
            h.ack.inject(0);
            await h.tick(3);
            await h.inactive();
            await h.activate();
            expect(await h.read(0x39), 0);
            expect(await h.read(0x3c), 0);
            h.busData.inject(0x2222);
            await h.write(0x38, (2 << 17) | (write ? 0 : 1 << 20));
            await h.write(0x39, 0x300);
            if (write) await h.write(0x3c, 0x77);
            await h.tick(3);
            expect(h.busEffects.value.toInt(), 2);
            expect(h.lastBusAddress.value.toInt(), 0x300);
            if (write) expect(h.lastBusData.value.toInt(), 0x77);
            h.ack.inject(1);
            await h.tick();
            h.ack.inject(0);
            await h.tick(2);
            expect(h.busCompletions.value.toInt(), 2);
            if (!write) expect(await h.read(0x3c), 0x2222);
          }
        } finally {
          await Simulator.endSimulation();
          await Simulator.simulationEnded;
        }
      });
    }
  }
}
