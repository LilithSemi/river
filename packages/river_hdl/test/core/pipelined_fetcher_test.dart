import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

import 'pipelined_responder.dart';

/// Drives [PipelinedFetchUnit] (master) wired to [PipelinedReadResponder]
/// (slave, a real pipelined multi-outstanding memory) through one shared
/// [FetchReadInterface]. Free-running consumer: advance whenever a head is
/// delivered. Returns (deliveredStream, cyclesToCollect).
Future<(List<(int, int)>, int)> runPipelined(
  Map<int, int> mem, {
  required int count,
  int latency = 4,
  int maxOutstanding = 4,
  int depth = 8,
  int? redirectAfter,
  int? redirectPc,
}) async {
  // Reset at entry so this harness can be called repeatedly within one test
  // (the throughput benchmark sweeps several configs in a single test body).
  await Simulator.reset();
  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();
  final enable = Logic();
  final advance = Logic();
  final redirect = Logic();
  final redirectPcL = Logic(width: 32);

  final link = FetchReadInterface(32, 32);
  final responder = PipelinedReadResponder(
    clk,
    reset,
    link,
    mem,
    latency: latency,
    maxOutstanding: maxOutstanding,
  );
  final fetcher = PipelinedFetchUnit(
    clk,
    reset,
    enable,
    Const(0, width: 32),
    link,
    advance: advance,
    redirect: redirect,
    redirectPc: redirectPcL,
    depth: depth,
    maxOutstanding: maxOutstanding,
  );
  await responder.build();
  await fetcher.build();

  reset.inject(1);
  enable.inject(0);
  advance.inject(0);
  redirect.inject(0);
  redirectPcL.inject(0);
  Simulator.registerAction(15, () {
    reset.put(0);
    enable.put(1);
  });
  Simulator.setMaxSimTime(60000 + latency * 600);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  while (reset.value.toBool()) {
    await clk.nextPosedge;
  }

  final collected = <(int, int)>[];
  var cycles = 0;
  var guard = 0;
  while (collected.length < count && guard < 8000 + latency * 200) {
    await clk.nextPosedge;
    guard++;
    cycles++;
    if (redirectAfter != null && collected.length == redirectAfter) {
      redirect.inject(1);
      redirectPcL.inject(redirectPc!);
      advance.inject(0);
      await clk.nextPosedge;
      cycles++;
      redirect.inject(0);
      redirectAfter = null;
      continue;
    }
    final d = fetcher.done.value;
    if (d.isValid && d.toBool()) {
      collected.add((
        fetcher.pcOut.value.toInt(),
        fetcher.result.value.toInt(),
      ));
      advance.inject(1);
    } else {
      advance.inject(0);
    }
  }

  await Simulator.endSimulation();
  await Simulator.simulationEnded;
  return (collected, cycles);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  final seq = [for (var i = 0; i < 16; i++) (0x00000013 | ((i + 1) << 20))];
  final mem = {for (var i = 0; i < seq.length; i++) i * 4: seq[i]};

  // Correctness: each instruction delivered with its PC, in order, across
  // latencies and outstanding depths.
  for (final latency in [0, 1, 2, 4, 8]) {
    test('pipelined fetch: in-order stream at latency $latency', () async {
      final (got, _) = await runPipelined(
        mem,
        count: 12,
        latency: latency,
        maxOutstanding: 4,
        depth: 8,
      );
      expect(got.length, 12);
      for (var i = 0; i < 12; i++) {
        expect(got[i], (i * 4, seq[i]), reason: 'instr $i lat $latency');
      }
    }, timeout: Timeout(Duration(seconds: 40 + latency * 2)));
  }

  // The point of the whole exercise: with enough outstanding reads, a multi-
  // cycle fetch latency is hidden. At latency L with maxOutstanding >= L, the
  // steady-state delivery is ~1 instr/cycle, so collecting N takes ~N+L cycles,
  // NOT the N*(L+1) a single-outstanding fetcher needs.
  test('pipelined fetch: hides latency (maxOutstanding >= latency)', () async {
    const count = 12;
    const latency = 4;
    final (got, cycles) = await runPipelined(
      mem,
      count: count,
      latency: latency,
      maxOutstanding: 4,
      depth: 8,
    );
    expect(got.length, count);
    for (var i = 0; i < count; i++) {
      expect(got[i], (i * 4, seq[i]));
    }
    // Single-outstanding would need ~count*(latency+1) = 60; assert we are far
    // below that, proving the reads pipelined.
    expect(
      cycles,
      lessThan(count + latency + 8),
      reason: 'latency not hidden (took $cycles cycles for $count instrs)',
    );
  });

  // maxOutstanding == 1 must reproduce the single-outstanding behaviour exactly
  // (strict superset): still correct, just no latency hiding.
  test(
    'pipelined fetch: maxOutstanding==1 is correct (single-outstanding)',
    () async {
      final (got, _) = await runPipelined(
        mem,
        count: 8,
        latency: 3,
        maxOutstanding: 1,
        depth: 2,
      );
      expect(got.length, 8);
      for (var i = 0; i < 8; i++) {
        expect(got[i], (i * 4, seq[i]), reason: 'single-outstanding instr $i');
      }
    },
  );

  // Quantify the fetchOutstanding knob: same engine, same pipelined memory, only
  // maxOutstanding changes. At a fetch latency L, outstanding=1 needs ~N*(L+1)
  // cycles (the FIFO drains between reads) while outstanding=L hides it to ~N+L.
  test('benchmark: fetchOutstanding hides fetch latency', () async {
    const count = 16;
    final rows = <String>[];
    for (final latency in [1, 2, 4, 8]) {
      final (g1, c1) = await runPipelined(
        mem,
        count: count,
        latency: latency,
        maxOutstanding: 1,
        depth: 2,
      );
      final (gN, cN) = await runPipelined(
        mem,
        count: count,
        latency: latency,
        maxOutstanding: latency,
        depth: 1 << (latency + 1).bitLength,
      );
      expect(g1.length, count);
      expect(gN.length, count);
      final speedup = (c1 / cN).toStringAsFixed(2);
      rows.add(
        'latency=$latency: outstanding=1 -> $c1 cyc,  '
        'outstanding=$latency -> $cN cyc  (${speedup}x)',
      );
      // The knob must help (more so as latency grows) and never hurt.
      expect(
        cN,
        lessThanOrEqualTo(c1),
        reason: 'multi-outstanding slower at latency $latency',
      );
    }
    // ignore: avoid_print
    print(
      '\n=== fetch throughput vs fetchOutstanding (16 instrs) ===\n'
      '${rows.join('\n')}\n',
    );
  }, timeout: Timeout(Duration(seconds: 90)));

  // Redirect mid-stream: flush + drain the in-flight (now stale) responses, then
  // deliver the resteered stream. The hard case for multi-outstanding (several
  // stale responses must be dropped, not delivered).
  for (final latency in [1, 4]) {
    test(
      'pipelined fetch: redirect drains stale responses at latency $latency',
      () async {
        final tgt = [
          for (var i = 0; i < 8; i++) (0x00000093 | ((i + 1) << 20)),
        ];
        final m = {
          ...mem,
          for (var i = 0; i < tgt.length; i++) 0x40 + i * 4: tgt[i],
        };
        final (got, _) = await runPipelined(
          m,
          count: 7,
          latency: latency,
          maxOutstanding: 4,
          depth: 8,
          redirectAfter: 3,
          redirectPc: 0x40,
        );
        for (var i = 0; i < 3; i++) {
          expect(got[i], (
            i * 4,
            seq[i],
          ), reason: 'pre-redirect $i lat $latency');
        }
        for (var i = 3; i < got.length; i++) {
          final j = i - 3;
          expect(got[i], (
            0x40 + j * 4,
            tgt[j],
          ), reason: 'post-redirect $j lat $latency');
        }
      },
      timeout: Timeout(Duration(seconds: 40 + latency * 2)),
    );
  }
}
