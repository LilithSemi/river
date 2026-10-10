import 'dart:async';

import 'package:river/river.dart';
import 'package:river_hdl/src/core/physical_l1.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() => instructionOnlyStageTests();

void instructionOnlyStageTests({
  HarborL1CacheConfig? config,
  HarborPmaConfig? pma,
  List<int> widths = const [32, 64],
}) {
  final cache =
      config ??
      const HarborL1CacheConfig.instructionOnly(
        HarborL1iCacheConfig(size: 64, ways: 1, lineSize: 16),
      );
  final lineSize = cache.i!.lineSize;
  tearDown(Simulator.reset);
  for (final width in widths) {
    test(
      'instruction-only $width-bit stage caches fetches but never data',
      () async {
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic()..inject(1), valid = Logic()..inject(0);
        final address = Logic(width: width)..inject(0);
        final write = Logic()..inject(0), fetch = Logic()..inject(0);
        final wdata = Logic(width: width)..inject(0);
        final flush = Logic()..inject(0), ack = Logic()..inject(0);
        final error = Logic()..inject(0),
            rdata = Logic(width: width)..inject(0);
        final bytes = width ~/ 8;
        final stage = RiverPhysicalL1(
          clk,
          reset,
          valid,
          address,
          write,
          wdata,
          Const(bytes.bitLength - 1, width: 3),
          fetch,
          Const(0),
          flush,
          ack,
          error,
          rdata,
          config: cache,
          pma:
              pma ??
              const HarborPmaConfig(
                regions: [
                  HarborPmaRegion.memory(start: 0x10000, size: 0x10000),
                ],
              ),
        );
        await stage.build();
        final memory = <int, int>{0x10000: 0x11111111};
        final reads = <int>[];
        var stores = 0;
        int? failingAddress;
        Future<void> tick() async {
          await clk.nextNegedge;
          if (ack.value.toBool() || error.value.toBool()) {
            ack.inject(0);
            error.inject(0);
            return;
          }
          if (!stage.output('cyc').value.toBool()) return;
          final a = stage.output('addr').value.toInt();
          expect(stage.output('sel').value.toInt(), (1 << bytes) - 1);
          if (stage.output('we').value.toBool()) {
            stores++;
            memory[a] = stage.output('data').value.toInt();
          } else {
            reads.add(a);
            rdata.inject(memory[a] ?? a);
          }
          ack.inject(1);
          error.inject(a == failingAddress ? 1 : 0);
        }

        Future<(bool, int)> access(
          int a, {
          bool instruction = false,
          int? store,
        }) async {
          address.inject(a);
          fetch.inject(instruction ? 1 : 0);
          write.inject(store == null ? 0 : 1);
          wdata.inject(store ?? 0);
          valid.inject(1);
          for (var cycle = 0; cycle < 200; cycle++) {
            await tick();
            final failed = stage.output('response_error').value.toBool();
            if (failed || stage.output('response_ack').value.toBool()) {
              final value = stage.output('response_data').value.toInt();
              valid.inject(0);
              await tick();
              await tick();
              return (failed, value);
            }
          }
          fail('bounded request did not complete');
        }

        Simulator.setMaxSimTime(30000);
        unawaited(Simulator.run());
        try {
          await tick();
          await tick();
          reset.inject(0);
          await tick();
          expect(await access(0x10000, instruction: true), (false, 0x11111111));
          expect(reads.length, lineSize ~/ bytes);
          final coldReads = reads.length;
          memory[0x10000] = 0x22222222;
          expect(await access(0x10000, instruction: true), (false, 0x11111111));
          expect(reads.length, coldReads, reason: 'warm I-cache hit');
          expect(await access(0x10000), (false, 0x22222222));
          memory[0x10000] = 0x33333333;
          expect(await access(0x10000), (false, 0x33333333));
          expect(
            reads.length,
            coldReads + 2,
            reason: 'both RAM data reads bypass',
          );
          expect((await access(0x10000, store: 0x44444444)).$1, isFalse);
          expect(stores, 1);
          expect(await access(0x10000), (false, 0x44444444));
          expect(await access(0x10000, instruction: true), (false, 0x11111111));
          final beforeFlush = reads.length;
          flush.inject(1);
          await tick();
          flush.inject(0);
          await tick();
          expect(await access(0x10000, instruction: true), (false, 0x44444444));
          expect(reads.length - beforeFlush, lineSize ~/ bytes);
          // A failed refill beat must not install a usable instruction line.
          failingAddress = 0x10020 + (lineSize > bytes ? bytes : 0);
          expect((await access(0x10020, instruction: true)).$1, isTrue);
          failingAddress = null;
          final beforeRetry = reads.length;
          expect(await access(0x10020, instruction: true), (false, 0x10020));
          expect(reads.length - beforeRetry, lineSize ~/ bytes);
          final filled = reads.length;
          expect(await access(0x10020, instruction: true), (false, 0x10020));
          expect(reads.length, filled);
          // Instruction addresses outside declared RAM must bypass as well.
          final beforeBypass = reads.length;
          expect(await access(0x30000, instruction: true), (false, 0x30000));
          memory[0x30000] = 0x55555555;
          expect(await access(0x30000, instruction: true), (false, 0x55555555));
          expect(reads.length - beforeBypass, 2);
          failingAddress = 0x10080;
          expect((await access(0x10080)).$1, isTrue);
          failingAddress = null;
          expect(await access(0x10080), (false, 0x10080));
          final rtl = stage.generateSynth();
          expect(rtl, contains('module HarborL1ICache'));
          expect(rtl, isNot(contains('module HarborL1DCache')));
        } finally {
          await Simulator.endSimulation();
          await Simulator.simulationEnded;
        }
      },
    );
  }
}
