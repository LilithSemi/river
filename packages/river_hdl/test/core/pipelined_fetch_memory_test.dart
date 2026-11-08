import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// End-to-end: a real synthesizable [PipelinedFetchMemory] (registered-read,
/// multi-outstanding BRAM) feeding a [PipelinedFetchUnit] through one shared
/// [FetchReadInterface]. The program is loaded over the memory's write port
/// while fetch is disabled, then streamed. Proves the in-core downstream the
/// front-end needs works against the real engine. Returns (stream, cycles).
Future<(List<(int, int)>, int)> runRealMem(
  List<int> prog, {
  required int count,
  int readLatency = 1,
  int maxOutstanding = 2,
  int depth = 4,
  bool useInit = false,
}) async {
  await Simulator.reset();
  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();
  final enable = Logic();
  final advance = Logic();
  final redirect = Logic();
  final redirectPcL = Logic(width: 32);
  final writeEn = Logic();
  final writeAddr = Logic(width: 32);
  final writeData = Logic(width: 32);

  final link = FetchReadInterface(32, 32);
  final mem = PipelinedFetchMemory(
    clk,
    reset,
    link,
    writeEn: writeEn,
    writeAddr: writeAddr,
    writeData: writeData,
    initWords: useInit ? prog : const [],
    words: 64,
    readLatency: readLatency,
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
  await mem.build();
  await fetcher.build();

  reset.inject(1);
  enable.inject(0);
  advance.inject(0);
  redirect.inject(0);
  redirectPcL.inject(0);
  writeEn.inject(0);
  writeAddr.inject(0);
  writeData.inject(0);
  Simulator.setMaxSimTime(60000 + readLatency * 600);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  reset.inject(0);
  await clk.nextPosedge;

  // Load the program over the write port (fetch still disabled), unless the
  // memory was initialised as a ROM at reset.
  if (!useInit) {
    for (var i = 0; i < prog.length; i++) {
      writeEn.inject(1);
      writeAddr.inject(i * 4);
      writeData.inject(prog[i]);
      await clk.nextPosedge;
    }
    writeEn.inject(0);
  }
  enable.inject(1);

  final collected = <(int, int)>[];
  var cycles = 0;
  var guard = 0;
  while (collected.length < count && guard < 8000 + readLatency * 200) {
    await clk.nextPosedge;
    guard++;
    cycles++;
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

  for (final readLatency in [1, 2]) {
    test('real mem: in-order stream at readLatency $readLatency', () async {
      final (got, _) = await runRealMem(
        seq,
        count: 12,
        readLatency: readLatency,
        maxOutstanding: readLatency + 1,
        depth: 1 << (readLatency + 2).bitLength,
      );
      expect(got.length, 12);
      for (var i = 0; i < 12; i++) {
        expect(got[i], (
          i * 4,
          seq[i],
        ), reason: 'instr $i at readLatency $readLatency');
      }
    }, timeout: Timeout(Duration(seconds: 40)));
  }

  // ROM init: contents loaded at reset (no write-port boot), the path the core
  // uses for a tightly-coupled instruction memory.
  test('real mem: ROM-initialised contents stream correctly', () async {
    final (got, _) = await runRealMem(
      seq,
      count: 12,
      readLatency: 1,
      maxOutstanding: 2,
      depth: 4,
      useInit: true,
    );
    expect(got.length, 12);
    for (var i = 0; i < 12; i++) {
      expect(got[i], (i * 4, seq[i]), reason: 'ROM-init instr $i');
    }
  });

  // The real BRAM has a read latency, but with enough outstanding the engine
  // still streams ~1 instr/cycle (a single-outstanding port would pay the
  // latency on every read).
  test('real mem: sustains ~1 instr/cycle despite read latency', () async {
    const count = 12;
    const readLatency = 2;
    final (got, cycles) = await runRealMem(
      seq,
      count: count,
      readLatency: readLatency,
      maxOutstanding: 3,
      depth: 8,
    );
    expect(got.length, count);
    for (var i = 0; i < count; i++) {
      expect(got[i], (i * 4, seq[i]));
    }
    // Single-outstanding would need ~count*(readLatency+1) = 36; assert well under.
    expect(
      cycles,
      lessThan(count + readLatency + 8),
      reason: 'did not sustain throughput (took $cycles cycles)',
    );
  });
}
