import 'dart:async';
import 'package:river/river.dart';
import 'package:river_hdl/src/core/physical_l1.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final width in [32, 64]) {
    for (final fetch in [false, true]) {
      for (final policy in [
        'RAM',
        'device',
        'unknown',
        'partial line',
        'non-idempotent',
        'unsupported beat',
        'unreadable',
        'non-executable',
        'refill fault',
      ]) {
        test('physical stage $width fetch=$fetch $policy', () async {
          final clk = SimpleClockGenerator(10).clk;
          final reset = Logic()..inject(1), valid = Logic()..inject(0);
          final ack = Logic()..inject(0), error = Logic()..inject(0);
          final rdata = Logic(width: width)..inject(0);
          final bytes = width ~/ 8;
          final requestedBytes = fetch ? bytes : 4;
          final region = HarborPmaRegion(
            start: 0x100,
            size: policy == 'partial line' ? requestedBytes : 0x100,
            memoryType: policy == 'device'
                ? HarborPmaMemoryType.io
                : HarborPmaMemoryType.memory,
            idempotent: policy != 'non-idempotent',
            readable: policy != 'unreadable',
            executable: policy != 'non-executable',
            accessWidths: policy == 'unsupported beat'
                ? const [1]
                : const [1, 2, 4, 8],
          );
          final stage = RiverPhysicalL1(
            clk,
            reset,
            valid,
            Const(0x100, width: width),
            Const(0),
            Const(0, width: width),
            Const(requestedBytes.bitLength - 1, width: 3),
            Const(fetch),
            Const(0),
            Const(0),
            ack,
            error,
            rdata,
            config: HarborL1CacheConfig.split(
              iSize: 64,
              dSize: 64,
              ways: 1,
              lineSize: 16,
            ),
            pma: HarborPmaConfig(regions: policy == 'unknown' ? [] : [region]),
          );
          await stage.build();
          final reads = <(int, int)>[];
          var failBeat = policy == 'refill fault';
          Future<void> tick() async {
            await clk.nextNegedge;
            if (ack.value.toBool() || error.value.toBool()) {
              ack.inject(0);
              error.inject(0);
              return;
            }
            if (!stage.output('cyc').value.toBool()) return;
            final a = stage.output('addr').value.toInt();
            reads.add((a, stage.output('sel').value.toInt()));
            rdata.inject(a + reads.length);
            ack.inject(1);
            if (failBeat && a == 0x100 + bytes) error.inject(1);
          }

          Future<(bool, int)> access() async {
            valid.inject(1);
            for (var i = 0; i < 200; i++) {
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
            fail('physical request did not complete');
          }

          Simulator.setMaxSimTime(20000);
          unawaited(Simulator.run());
          try {
            await tick();
            await tick();
            reset.inject(0);
            await tick();
            if (failBeat) {
              expect(
                (await access()).$1,
                isTrue,
                reason: 'ERR dominates ACK on a refill beat',
              );
              failBeat = false;
              final before = reads.length;
              expect((await access()).$1, isFalse);
              expect(
                reads.length - before,
                16 ~/ bytes,
                reason: 'failed partial line was not exposed as a hit',
              );
              final filled = reads.length;
              expect((await access()).$1, isFalse);
              expect(reads.length, filled);
            } else {
              final first = await access(), second = await access();
              expect(first.$1, isFalse);
              expect(second.$1, isFalse);
              final allocated =
                  policy == 'RAM' || (policy == 'non-executable' && !fetch);
              if (allocated) {
                expect(reads.length, 16 ~/ bytes);
                expect(first.$2, second.$2);
                expect(reads.map((r) => r.$2), everyElement((1 << bytes) - 1));
              } else {
                expect(reads, [
                  (0x100, (1 << requestedBytes) - 1),
                  (0x100, (1 << requestedBytes) - 1),
                ]);
                expect(
                  first.$2,
                  isNot(second.$2),
                  reason: 'bypass must not retain a previous result',
                );
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
  RiverPhysicalL1 construct(
    HarborPmaConfig pma, {
    int width = 64,
    bool largeLine = false,
  }) => RiverPhysicalL1(
    Logic(),
    Logic(),
    Const(0),
    Const(0, width: width),
    Const(0),
    Const(0, width: width),
    Const(2, width: 3),
    Const(0),
    Const(0),
    Const(0),
    Const(0),
    Const(0),
    Const(0, width: width),
    config: HarborL1CacheConfig(
      i: HarborL1iCacheConfig(
        size: largeLine ? 8192 : 64,
        ways: 1,
        lineSize: largeLine ? 8192 : 16,
      ),
      d: const HarborL1dCacheConfig(size: 64, ways: 1, lineSize: 16),
    ),
    pma: pma,
  );
  for (final (name, regions, width) in [
    ('negative', [const HarborPmaRegion.memory(start: -1, size: 16)], 64),
    ('empty', [const HarborPmaRegion.memory(start: 0, size: 0)], 64),
    (
      'overlap',
      [
        const HarborPmaRegion.memory(start: 0, size: 32),
        const HarborPmaRegion.io(start: 16, size: 32),
      ],
      64,
    ),
    (
      'host overflow overlap',
      [
        const HarborPmaRegion.memory(start: 0x7ffffffffffff000, size: 0x2000),
        const HarborPmaRegion.io(start: 0x7ffffffffffff800, size: 16),
      ],
      64,
    ),
    (
      'past address width',
      [const HarborPmaRegion.memory(start: 0xfffffff0, size: 32)],
      32,
    ),
  ]) {
    test('physical stage rejects $name PMAs', () {
      expect(
        () => construct(HarborPmaConfig(regions: regions), width: width),
        throwsArgumentError,
      );
    });
  }
  test(
    'physical stage rejects instruction lines crossing translation pages',
    () {
      expect(
        () => construct(const HarborPmaConfig(), largeLine: true),
        throwsArgumentError,
      );
    },
  );
}
