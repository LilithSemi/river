import 'dart:async';
import 'package:river/river.dart';
import 'package:river_hdl/src/core/physical_l1.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final width in [32, 64]) {
    test(
      'physical stage $width drains a store exactly once across flush',
      () async {
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic()..inject(1), valid = Logic()..inject(0);
        final flush = Logic()..inject(0), ack = Logic()..inject(0);
        final stage = RiverPhysicalL1(
          clk,
          reset,
          valid,
          Const(0x105, width: width),
          Const(1),
          Const(0xab, width: width),
          Const(0, width: 3),
          Const(0),
          Const(0),
          flush,
          ack,
          Const(0),
          Const(0, width: width),
          config: const HarborL1CacheConfig.unified(
            HarborL1dCacheConfig(size: 64, ways: 1, lineSize: 16),
          ),
          pma: const HarborPmaConfig(
            regions: [HarborPmaRegion.memory(start: 0x100, size: 0x100)],
          ),
        );
        await stage.build();
        Future<void> tick() async {
          await clk.nextNegedge;
        }

        final bytes = width ~/ 8, lane = 0x105 % (width ~/ 8);
        List<BigInt> bus() => [
          for (final name in ['cyc', 'we', 'addr', 'sel', 'data'])
            stage.output(name).value.toBigInt(),
        ];
        Simulator.setMaxSimTime(10000);
        unawaited(Simulator.run());
        try {
          await tick();
          await tick();
          reset.inject(0);
          valid.inject(1);
          for (var i = 0; i < 50 && !stage.output('cyc').value.toBool(); i++) {
            await tick();
          }
          final request = [
            BigInt.one,
            BigInt.one,
            BigInt.from(0x105 & ~(bytes - 1)),
            BigInt.one << lane,
            BigInt.from(0xab) << (lane * 8),
          ];
          expect(bus(), request);
          flush.inject(1);
          await tick();
          flush.inject(0);
          for (var i = 0; i < 4; i++) {
            expect(
              bus(),
              request,
              reason: 'accepted bus metadata survives cache flush',
            );
            expect(stage.output('response_ack').value.toBool(), isFalse);
            expect(stage.output('response_error').value.toBool(), isFalse);
            await tick();
          }
          // The backend acknowledges the accepted write once, after the flush.
          ack.inject(1);
          await tick();
          ack.inject(0);
          var completed = false;
          for (var i = 0; i < 50; i++) {
            expect(
              stage.output('cyc').value.toBool(),
              isFalse,
              reason: 'no duplicate store may be issued',
            );
            expect(stage.output('response_error').value.toBool(), isFalse);
            if (stage.output('response_ack').value.toBool()) {
              await clk.nextPosedge;
              await tick();
              completed = true;
              valid.inject(0);
              break;
            }
            await tick();
          }
          expect(completed, isTrue);
          for (var i = 0; i < 8; i++) {
            await tick();
            expect(stage.output('cyc').value.toBool(), isFalse);
          }
        } finally {
          await Simulator.endSimulation();
          await Simulator.simulationEnded;
        }
      },
    );
  }
}
