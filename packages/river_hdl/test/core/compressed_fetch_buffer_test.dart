import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// A single instruction in a synthetic stream: its raw encoding and length in
/// halfwords (1 = compressed/16-bit, 2 = 32-bit).
class _Instr {
  final int value;
  final int halves; // 1 or 2
  const _Instr(this.value, this.halves);
}

/// A compressed (16-bit) instruction: low 2 bits must NOT be 0b11.
_Instr _comp(int v) {
  assert(v & 0x3 != 0x3, 'compressed encoding must have low bits != 11');
  return _Instr(v & 0xFFFF, 1);
}

/// A 32-bit instruction: low 2 bits == 0b11.
_Instr _w32(int v) {
  assert(v & 0x3 == 0x3, '32-bit encoding must have low bits == 11');
  return _Instr(v & 0xFFFFFFFF, 2);
}

/// Lay a stream of variable-length instructions into the 2-byte-aligned halfword
/// stream and return (expected (pc, value) list, word memory map keyed by byte
/// address). Words are [dataWidth] bits ([dataWidth]/16 halfwords each).
/// Instructions start at [base].
(List<(int, int)>, Map<int, int>) _layout(
  List<_Instr> stream, {
  int base = 0,
  int dataWidth = 64,
}) {
  final wordHalves = dataWidth ~/ 16;
  final wordBytes = dataWidth ~/ 8;
  final expected = <(int, int)>[];
  final halfwords = <int>[]; // flat little-endian halfword stream
  var pc = base;
  for (final ins in stream) {
    expected.add((pc, ins.value));
    halfwords.add(ins.value & 0xFFFF);
    if (ins.halves == 2) halfwords.add((ins.value >> 16) & 0xFFFF);
    pc += ins.halves * 2;
  }
  // Pad to a whole word with NOPs (c.nop = 0x0001).
  while (halfwords.length % wordHalves != 0) {
    halfwords.add(0x0001);
  }
  final mem = <int, int>{};
  for (var wi = 0; wi * wordHalves < halfwords.length; wi++) {
    var word = 0;
    for (var h = 0; h < wordHalves; h++) {
      word |= (halfwords[wi * wordHalves + h] & 0xFFFF) << (16 * h);
    }
    mem[base ~/ wordBytes * wordBytes + wi * wordBytes] = word;
  }
  return (expected, mem);
}

/// Run the [CompressedFetchBuffer] over a 64-bit response-pulse memory (the
/// interconnect-neutral contract) and collect the (pc, instr) stream it
/// delivers, consuming up to two instructions per cycle.
/// Returns (delivered stream, split index) where the split index is the number
/// of instructions delivered before a redirect fired (== collected.length when
/// no redirect).
Future<(List<(int, int)>, int)> runBuffer(
  Map<int, int> mem, {
  required int count,
  int latency = 0,
  int depth = 4,
  int startPc = 0,
  int dataWidth = 64,
  int consumeStride = 1, // cycles to wait between consumes (>1 = slow consumer)
  int? redirectAfter,
  int? redirectPc,
}) async {
  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();
  final enable = Logic();
  final redirect = Logic();
  final redirectPcL = Logic(width: dataWidth);
  final consume0 = Logic();
  final consume1 = Logic();
  final memRead = DataPortInterface(dataWidth, dataWidth);

  Logic wordOf(Logic addr) {
    Logic r = Const(0, width: dataWidth);
    for (final e in mem.entries) {
      r = mux(
        addr.eq(Const(e.key, width: dataWidth)),
        Const(e.value, width: dataWidth),
        r,
      );
    }
    return r;
  }

  // Single-outstanding response-pulse responder (held en+addr; after `latency`
  // cycles assert done&valid for one cycle, then a one-cycle gap).
  final st = Logic(name: 'rstate', width: 2);
  final cnt = Logic(name: 'rcnt', width: 16);
  final capAddr = Logic(name: 'rcap', width: dataWidth);
  final doneR = Logic(name: 'rdone');
  final validR = Logic(name: 'rvalid');
  final dataR = Logic(name: 'rdata', width: dataWidth);
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

  final buf = CompressedFetchBuffer(
    clk,
    reset,
    enable,
    Const(startPc, width: dataWidth),
    memRead,
    redirect: redirect,
    redirectPc: redirectPcL,
    consume0: consume0,
    consume1: consume1,
    depth: depth,
  );
  await buf.build();

  reset.inject(1);
  enable.inject(0);
  redirect.inject(0);
  redirectPcL.inject(0);
  consume0.inject(0);
  consume1.inject(0);
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
  var splitIndex = -1;
  var guard = 0;
  while (collected.length < count && guard < 9000 + latency * 300) {
    await clk.nextPosedge;
    guard++;

    if (redirectAfter != null && collected.length >= redirectAfter) {
      splitIndex =
          collected.length; // exact boundary (may exceed redirectAfter)
      redirect.inject(1);
      redirectPcL.inject(redirectPc!);
      consume0.inject(0);
      consume1.inject(0);
      await clk.nextPosedge;
      redirect.inject(0);
      redirectAfter = null;
      continue;
    }

    // Slow consumer: only consume every `consumeStride` cycles. With stride > 1
    // the FIFO fills to `depth` and sits full, the regression case for the
    // wordCount*wordHalves width-overflow that made a full buffer read as empty.
    final mayConsume = (guard % consumeStride == 0);
    final v0 = buf.valid0.value;
    final v1 = buf.valid1.value;
    if (mayConsume && v0.isValid && v0.toBool()) {
      collected.add((buf.pc0.value.toInt(), buf.instr0.value.toInt()));
      consume0.inject(1);
      if (v1.isValid && v1.toBool() && collected.length < count) {
        collected.add((buf.pc1.value.toInt(), buf.instr1.value.toInt()));
        consume1.inject(1);
      } else {
        consume1.inject(0);
      }
    } else {
      consume0.inject(0);
      consume1.inject(0);
    }
  }

  await Simulator.endSimulation();
  await Simulator.simulationEnded;
  return (collected, splitIndex < 0 ? collected.length : splitIndex);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // A mixed variable-length stream (compressed + 32-bit interleaved). Distinct
  // values so each delivered instruction is identifiable.
  final stream = <_Instr>[
    _comp(0x4505), // c.li x10,1
    _w32(0x00100513), // addi x10,x0,1
    _comp(0x4585), // c.li x11,1
    _comp(0x4609), // c.li x12,2
    _w32(0x00200593), // addi x11,x0,2
    _w32(0x00300613), // addi x12,x0,3
    _comp(0x4685), // c.li x13,1
    _w32(0x00400693), // addi x13,x0,4
    _comp(0x4709), // c.li x14,2
    _comp(0x4789), // c.li x15,2
    _w32(0x00500713), // addi x14,x0,5
    _comp(0x4805), // c.li x16,1
  ];

  test('all-compressed stream delivers each instr with PC += 2', () async {
    final s = [for (var i = 0; i < 12; i++) _comp(0x4501 | (i << 7))];
    final (expected, mem) = _layout(s);
    final (got, _) = await runBuffer(mem, count: 12);
    expect(got.length, 12);
    for (var i = 0; i < 12; i++) {
      expect(got[i], expected[i], reason: 'compressed instr $i');
    }
  });

  test('all-32-bit stream delivers each instr with PC += 4', () async {
    final s = [for (var i = 0; i < 10; i++) _w32(0x00000013 | ((i + 1) << 20))];
    final (expected, mem) = _layout(s);
    final (got, _) = await runBuffer(mem, count: 10);
    expect(got.length, 10);
    for (var i = 0; i < 10; i++) {
      expect(got[i], expected[i], reason: '32-bit instr $i');
    }
  });

  test(
    'mixed variable-length stream delivers correct PCs and values',
    () async {
      final (expected, mem) = _layout(stream);
      final (got, _) = await runBuffer(mem, count: stream.length);
      expect(got.length, stream.length);
      for (var i = 0; i < stream.length; i++) {
        expect(got[i], expected[i], reason: 'mixed instr $i');
      }
    },
  );

  for (final latency in [0, 1, 2, 4]) {
    test('mixed stream correct at memory latency $latency', () async {
      final (expected, mem) = _layout(stream);
      final (got, _) = await runBuffer(
        mem,
        count: stream.length,
        latency: latency,
      );
      expect(got.length, stream.length);
      for (var i = 0; i < stream.length; i++) {
        expect(got[i], expected[i], reason: 'mixed instr $i lat $latency');
      }
    }, timeout: Timeout(Duration(seconds: 40 + latency * 2)));
  }

  for (final d in [4, 8]) {
    test('mixed stream correct at FIFO depth $d', () async {
      final (expected, mem) = _layout(stream);
      final (got, _) = await runBuffer(
        mem,
        count: stream.length,
        depth: d,
        latency: 2,
      );
      expect(got.length, stream.length);
      for (var i = 0; i < stream.length; i++) {
        expect(got[i], expected[i], reason: 'mixed instr $i depth $d');
      }
    }, timeout: Timeout(Duration(seconds: 40)));
  }

  // 32-bit fetch port (wordHalves=2), the RV32 dual-dispatch regression width.
  // The window must span up to 3 words at this width, so this proves the narrow
  // path the in-pipeline integration depends on.
  test('32-bit port: mixed variable-length stream correct', () async {
    final (expected, mem) = _layout(stream, dataWidth: 32);
    final (got, _) = await runBuffer(
      mem,
      count: stream.length,
      dataWidth: 32,
      latency: 1,
    );
    expect(got.length, stream.length);
    for (var i = 0; i < stream.length; i++) {
      expect(got[i], expected[i], reason: '32-bit port mixed instr $i');
    }
  });

  test('32-bit port: all-32-bit stream correct (RV32I-like)', () async {
    final s = [for (var i = 0; i < 10; i++) _w32(0x00000013 | ((i + 1) << 20))];
    final (expected, mem) = _layout(s, dataWidth: 32);
    final (got, _) = await runBuffer(mem, count: 10, dataWidth: 32, latency: 2);
    expect(got.length, 10);
    for (var i = 0; i < 10; i++) {
      expect(got[i], expected[i], reason: '32-bit port 32-bit instr $i');
    }
  });

  // Slow consumer drives the FIFO to FULL and holds it there. Regression for
  // the width-overflow bug: wordCount (ptrBits+1 bits) * wordHalves overflowed
  // its width when the FIFO was full, collapsing validHalves to 0 so a full
  // buffer falsely reported empty and the stream stalled.
  for (final dw in [32, 64]) {
    for (final stride in [3, 5]) {
      test(
        '${dw}b port: full FIFO (slow consumer x$stride) keeps streaming',
        () async {
          final (expected, mem) = _layout(stream, dataWidth: dw);
          final (got, _) = await runBuffer(
            mem,
            count: stream.length,
            dataWidth: dw,
            depth: 4,
            consumeStride: stride,
          );
          expect(got.length, stream.length);
          for (var i = 0; i < stream.length; i++) {
            expect(got[i], expected[i], reason: '${dw}b full-FIFO instr $i');
          }
        },
        timeout: Timeout(Duration(seconds: 40)),
      );
    }
  }

  test(
    'redirect to a mid-word (compressed-aligned) PC resteers correctly',
    () async {
      // Source stream at 0, target stream at 0x40 (8-byte aligned base) but we
      // redirect to 0x42, a 2-byte (mid-word) offset to prove headOff handling.
      final (srcExp, srcMem) = _layout(stream);
      final tgt = [for (var i = 0; i < 8; i++) _comp(0x4401 | (i << 7))];
      // Lay the target so that 0x42 lands on a real compressed instruction: put a
      // filler compressed at 0x40, then the tgt stream from 0x42.
      final tgtStream = [_comp(0x4001), ...tgt];
      final (tgtExpRaw, tgtMem) = _layout(tgtStream, base: 0x40);
      final mem = {...srcMem, ...tgtMem};
      // Expected after redirect: the tgt stream starting at 0x42.
      final tgtExp = tgtExpRaw.where((e) => e.$1 >= 0x42).toList();

      final (got, split) = await runBuffer(
        mem,
        count: 4 + tgt.length,
        redirectAfter: 4,
        redirectPc: 0x42,
      );
      // Everything before the redirect boundary comes from the source stream.
      for (var i = 0; i < split; i++) {
        expect(got[i], srcExp[i], reason: 'pre-redirect $i');
      }
      // Everything after comes from the target stream at 0x42.
      for (var i = split; i < got.length; i++) {
        expect(got[i], tgtExp[i - split], reason: 'post-redirect ${i - split}');
      }
    },
  );
}
