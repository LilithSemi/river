import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Drives the prefetch fetcher as a free-running consumer (advance whenever a
/// head is delivered) and records the delivered (pc, instruction) stream.
Future<List<(int, int)>> runPrefetch(
  String memString, {
  int count = 8,
  int latency = 0,
  int? redirectAfter,
  int? redirectPc,
}) async {
  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();
  final enable = Logic();
  final advance = Logic();
  final redirect = Logic();
  final redirectPcL = Logic(width: 32);

  final memRead = DataPortInterface(32, 32);
  final storage = SparseMemoryStorage(
    addrWidth: 32,
    dataWidth: 32,
    alignAddress: (addr) => addr,
    onInvalidRead: (addr, dataWidth) =>
        LogicValue.filled(dataWidth, LogicValue.zero),
  );
  // ignore: unused_local_variable
  final mem = MemoryModel(
    clk,
    reset,
    [],
    [wrapReadForRegisterFile(memRead, clk: clk, readLatency: latency)],
    readLatency: latency,
    storage: storage,
  );

  final fetcher = PrefetchFetchUnit(
    clk,
    reset,
    enable,
    Const(0, width: 32),
    memRead,
    advance: advance,
    redirect: redirect,
    redirectPc: redirectPcL,
  );
  await fetcher.build();

  reset.inject(1);
  enable.inject(0);
  advance.inject(0);
  redirect.inject(0);
  redirectPcL.inject(0);

  // Load AFTER reset releases: MemoryModel clears its storage while reset is
  // asserted, so an earlier load would be wiped.
  Simulator.registerAction(15, () {
    reset.put(0);
    enable.put(1);
    storage.loadMemString(memString);
  });

  Simulator.setMaxSimTime(20000 + latency * 200);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  while (reset.value.toBool()) {
    await clk.nextPosedge;
  }

  final collected = <(int, int)>[];
  var guard = 0;
  while (collected.length < count && guard < 4000 + latency * 100) {
    await clk.nextPosedge;
    guard++;
    if (redirectAfter != null && collected.length == redirectAfter) {
      // Fire a one-cycle redirect, then keep consuming.
      redirect.inject(1);
      redirectPcL.inject(redirectPc!);
      advance.inject(0);
      await clk.nextPosedge;
      redirect.inject(0);
      redirectAfter = null; // only once
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
  return collected;
}

String progAt(Map<int, List<int>> blocks) {
  final sb = StringBuffer();
  for (final entry in blocks.entries) {
    sb.write('@${entry.key.toRadixString(16)}\n');
    for (final word in entry.value) {
      for (var i = 0; i < 4; i++) {
        sb.write(((word >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    sb.write('\n');
  }
  return sb.toString();
}

/// Drives the prefetch fetcher against a GENERIC single-outstanding response-
/// PULSE read port, the contract the real MMU and AXI/TileLink adapters present
/// (NOT the level-held pipe of wrapReadForRegisterFile). Holding en+addr, the
/// responder waits `latency` cycles then asserts done&valid for exactly ONE
/// cycle with the word, then a one-cycle gap before it can launch the next read.
/// This is the interconnect-neutral portability test. `mem` is byteAddr->word.
Future<List<(int, int)>> runPrefetchPulse(
  Map<int, int> mem, {
  int count = 8,
  int latency = 1,
  int depth = 2,
  int? redirectAfter,
  int? redirectPc,
}) async {
  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();
  final enable = Logic();
  final advance = Logic();
  final redirect = Logic();
  final redirectPcL = Logic(width: 32);
  final memRead = DataPortInterface(32, 32);

  Logic wordOf(Logic addr) {
    Logic r = Const(0, width: 32);
    for (final e in mem.entries) {
      r = mux(addr.eq(Const(e.key, width: 32)), Const(e.value, width: 32), r);
    }
    return r;
  }

  final st = Logic(name: 'rstate', width: 2); // 0 idle, 1 counting, 2 gap
  final cnt = Logic(name: 'rcnt', width: 16);
  final capAddr = Logic(name: 'rcap', width: 32);
  final doneR = Logic(name: 'rdone');
  final validR = Logic(name: 'rvalid');
  final dataR = Logic(name: 'rdata', width: 32);
  memRead.done <= doneR;
  memRead.valid <= validR;
  memRead.data <= dataR;
  Sequential(clk, [
    If(
      reset,
      then: [st < 0, cnt < 0, capAddr < 0, doneR < 0, validR < 0, dataR < 0],
      orElse: [
        doneR < 0,
        validR < 0,
        If.block([
          Iff(st.eq(0) & memRead.en, [
            capAddr < memRead.addr,
            if (latency == 0) ...[
              doneR < 1,
              validR < 1,
              dataR < wordOf(memRead.addr),
              st < 2,
            ] else ...[
              cnt < Const(latency - 1, width: 16),
              st < 1,
            ],
          ]),
          Iff(st.eq(1), [
            If(
              cnt.eq(0),
              then: [doneR < 1, validR < 1, dataR < wordOf(capAddr), st < 2],
              orElse: [cnt < cnt - 1],
            ),
          ]),
          Iff(st.eq(2), [st < 0]),
        ]),
      ],
    ),
  ]);

  final fetcher = PrefetchFetchUnit(
    clk,
    reset,
    enable,
    Const(0, width: 32),
    memRead,
    advance: advance,
    redirect: redirect,
    redirectPc: redirectPcL,
    depth: depth,
  );
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
  Simulator.setMaxSimTime(40000 + latency * 400);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  while (reset.value.toBool()) {
    await clk.nextPosedge;
  }
  final collected = <(int, int)>[];
  var guard = 0;
  while (collected.length < count && guard < 8000 + latency * 200) {
    await clk.nextPosedge;
    guard++;
    if (redirectAfter != null && collected.length == redirectAfter) {
      redirect.inject(1);
      redirectPcL.inject(redirectPc!);
      advance.inject(0);
      await clk.nextPosedge;
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
  return collected;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // 8 distinct non-compressed words at 0x00, 0x04, ...
  final seq = [for (var i = 0; i < 12; i++) (0x00000013 | ((i + 1) << 20))];

  test('sequential stream delivers each instr with its PC', () async {
    final got = await runPrefetch(progAt({0: seq}), count: 8);
    expect(got.length, 8);
    for (var i = 0; i < 8; i++) {
      expect(got[i], (i * 4, seq[i]), reason: 'instr $i');
    }
  });

  // NOTE: only latency 0 is exercised here. The read engine holds `en` and waits
  // for the bus to drop `valid` on an address change (the real MMU/Wishbone fetch
  // contract). The MemoryModel's wrapReadForRegisterFile drives `valid` as a pipe
  // keyed to `en` continuity (NOT to the address), which is only faithful to the
  // real bus at latency 0 (valid = en, data combinational on addr). Higher
  // latencies are covered by the in-pipeline test (core_prefetch_test) where the
  // fetch port is the real MMU. See project_hdl_prefetch.
  for (final latency in [0]) {
    test('sequential stream correct at latency $latency', () async {
      final got = await runPrefetch(
        progAt({0: seq}),
        count: 8,
        latency: latency,
      );
      expect(got.length, 8);
      for (var i = 0; i < 8; i++) {
        expect(got[i], (i * 4, seq[i]), reason: 'instr $i lat $latency');
      }
    }, timeout: Timeout(Duration(seconds: 30 + latency)));
  }

  test('redirect mid-stream resteers to the new PC', () async {
    // Target block at 0x40 with distinct values.
    final tgt = [for (var i = 0; i < 8; i++) (0x00000093 | ((i + 1) << 20))];
    final got = await runPrefetch(
      progAt({0: seq, 0x40: tgt}),
      count: 7,
      redirectAfter: 3,
      redirectPc: 0x40,
    );
    // First 3 from the @0 stream.
    for (var i = 0; i < 3; i++) {
      expect(got[i], (i * 4, seq[i]), reason: 'pre-redirect $i');
    }
    // Remaining from the @0x40 stream.
    for (var i = 3; i < got.length; i++) {
      final j = i - 3;
      expect(got[i], (0x40 + j * 4, tgt[j]), reason: 'post-redirect $j');
    }
  });

  // ── Interconnect portability: the generic response-PULSE contract ──────────
  // These exercise the read engine against a single-outstanding response-pulse
  // port (the contract the real MMU and AXI/TileLink adapters present), across
  // latencies, proving the fetcher is not tied to any one interconnect's timing.
  final memMap = {for (var i = 0; i < seq.length; i++) i * 4: seq[i]};

  for (final latency in [0, 1, 2, 4, 8]) {
    test('pulse port: sequential stream correct at latency $latency', () async {
      final got = await runPrefetchPulse(memMap, count: 8, latency: latency);
      expect(got.length, 8);
      for (var i = 0; i < 8; i++) {
        expect(got[i], (i * 4, seq[i]), reason: 'instr $i lat $latency');
      }
    }, timeout: Timeout(Duration(seconds: 40 + latency * 2)));
  }

  // Deeper FIFO (power-of-two): correctness must hold at any depth (the depth
  // is a buffering knob; it does not change which instructions are delivered).
  for (final d in [4, 8]) {
    test('pulse port: depth $d delivers the correct stream', () async {
      final got = await runPrefetchPulse(
        memMap,
        count: 8,
        latency: 3,
        depth: d,
      );
      expect(got.length, 8);
      for (var i = 0; i < 8; i++) {
        expect(got[i], (i * 4, seq[i]), reason: 'instr $i depth $d');
      }
    }, timeout: Timeout(Duration(seconds: 40)));
  }

  for (final latency in [1, 4]) {
    test('pulse port: redirect mid-stream at latency $latency', () async {
      final tgt = [for (var i = 0; i < 8; i++) (0x00000093 | ((i + 1) << 20))];
      final mem = {
        ...memMap,
        for (var i = 0; i < tgt.length; i++) 0x40 + i * 4: tgt[i],
      };
      final got = await runPrefetchPulse(
        mem,
        count: 7,
        latency: latency,
        redirectAfter: 3,
        redirectPc: 0x40,
      );
      for (var i = 0; i < 3; i++) {
        expect(got[i], (i * 4, seq[i]), reason: 'pre-redirect $i lat $latency');
      }
      for (var i = 3; i < got.length; i++) {
        final j = i - 3;
        expect(got[i], (
          0x40 + j * 4,
          tgt[j],
        ), reason: 'post-redirect $j lat $latency');
      }
    }, timeout: Timeout(Duration(seconds: 40 + latency * 2)));
  }
}
