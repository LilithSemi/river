import 'dart:async';

import 'package:river/river.dart';
import 'package:river_hdl/src/core/physical_l1.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final width in [32, 64]) {
    for (final capacity in [4096, 8192, 16384]) {
      test(
        'physical $width-bit $capacity-byte D-cache retains each 4KiB bank',
        () async {
          final clk = SimpleClockGenerator(10).clk;
          final reset = Logic()..inject(1), valid = Logic()..inject(0);
          final address = Logic(width: width)..inject(0);
          final flush = Logic()..inject(0), ack = Logic()..inject(0);
          final data = Logic(width: width)..inject(0);
          final bytes = width ~/ 8;
          final stage = RiverPhysicalL1(
            clk,
            reset,
            valid,
            address,
            Const(0),
            Const(0, width: width),
            Const(bytes.bitLength - 1, width: 3),
            Const(0),
            Const(0),
            flush,
            ack,
            Const(0),
            data,
            config: HarborL1CacheConfig.unified(
              HarborL1dCacheConfig(size: capacity, ways: 1, lineSize: 16),
            ),
            pma: const HarborPmaConfig(
              regions: [HarborPmaRegion.memory(start: 0x10000, size: 0x10000)],
            ),
          );
          await stage.build();
          final reads = <int>[];
          BigInt value(int a) =>
              BigInt.from(a) |
              (width == 64 ? BigInt.from(a ^ 0x55aa) << 32 : BigInt.zero);
          Future<void> tick() async {
            await clk.nextNegedge;
            if (ack.value.toBool()) {
              ack.inject(0);
            } else if (stage.output('cyc').value.toBool()) {
              final a = stage.output('addr').value.toInt();
              expect(stage.output('we').value.toBool(), isFalse);
              reads.add(a);
              data.inject(value(a));
              ack.inject(1);
            }
          }

          Future<void> load(int a, {required bool hit}) async {
            final before = reads.length;
            address.inject(a);
            valid.inject(1);
            var completed = false;
            for (var i = 0; i < 200; i++) {
              await tick();
              expect(stage.output('response_error').value.toBool(), isFalse);
              if (stage.output('response_ack').value.toBool()) {
                expect(
                  stage.output('response_data').value.toBigInt(),
                  value(a),
                );
                completed = true;
                break;
              }
            }
            expect(completed, isTrue, reason: 'bounded request completion');
            valid.inject(0);
            await tick();
            await tick();
            expect(reads.length - before, hit ? 0 : 16 ~/ bytes);
            if (!hit) {
              expect(reads.sublist(before), [
                for (var beat = 0; beat < 16; beat += bytes) (a & ~15) + beat,
              ]);
            }
          }

          Simulator.setMaxSimTime(50000);
          unawaited(Simulator.run());
          try {
            await tick();
            await tick();
            reset.inject(0);
            await tick();
            final addresses = [
              for (var bank = 0; bank < capacity ~/ 4096; bank++)
                0x10000 + bank * 4096 + 4096 - bytes,
            ];
            for (final a in addresses) {
              await load(a, hit: false);
            }
            for (final a in addresses.reversed) {
              await load(a, hit: true);
            }
            // Full-address tags must distinguish the next capacity-sized region.
            await load(addresses.first + capacity, hit: false);
            await load(addresses.first, hit: false);
            for (final a in addresses) {
              await load(a, hit: true);
            }
            flush.inject(1);
            await tick();
            flush.inject(0);
            await tick();
            for (final a in addresses) {
              await load(a, hit: false);
            }
          } finally {
            await Simulator.endSimulation();
            await Simulator.simulationEnded;
          }
        },
      );
    }
  }
}
