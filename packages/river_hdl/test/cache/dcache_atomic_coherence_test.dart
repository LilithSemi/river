import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// HW-observed on delta: a ticket spinlock corrupts (a ticket ends up BEHIND the
/// owner) because two `amoadd`s both read the same `next` - the first amoadd's
/// write was not visible to the second read. The core is a single in-order hart
/// with NO async interrupts, so a lost read-after-write can only be the D-cache.
///
/// HarborL1DCache is write-through / no-write-allocate: a store writes straight
/// to memory and INVALIDATES the resident line (l1_cache.dart:807, gated on
/// `storeInv = committedHitOf(reqAddr)`). If that invalidation ever misses (e.g.
/// the store's hit-check races the just-filled line, so storeInv=0 and the stale
/// line survives), a following load returns the pre-store value.
///
/// This drives the REAL D-cache with a latency-bearing memory model through the
/// exact amoadd shape (load A, then store A = loaded+1, repeated) and asserts
/// each load observes the previous store. Conflicting-line traffic forces fills
/// so the store-invalidate-vs-fill timing is exercised. The differential matrix
/// never hits this because it uses a simple MemoryModel, not the D-cache.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  Future<void> run({required int memLatency}) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic();
    final reqAddr = Logic(width: 64);
    final reqValid = Logic();
    final reqWrite = Logic();
    final reqData = Logic(width: 64);
    final reqSize = Logic(width: 3);
    final flush = Logic();
    final memDone = Logic();
    final memValid = Logic();
    final memRdata = Logic(width: 64);

    final dc = HarborL1DCache(
      config: HarborL1CacheConfig.split(
        iSize: 64,
        dSize: 256,
        ways: 1,
        lineSize: 8,
      ).d!,
      xlen: 64,
    );
    dc.input('clk').srcConnection! <= clk;
    dc.input('reset').srcConnection! <= reset;
    dc.input('req_addr').srcConnection! <= reqAddr;
    dc.input('req_valid').srcConnection! <= reqValid;
    dc.input('req_write').srcConnection! <= reqWrite;
    dc.input('req_data').srcConnection! <= reqData;
    dc.input('req_size').srcConnection! <= reqSize;
    dc.input('flush').srcConnection! <= flush;
    dc.input('mem_done').srcConnection! <= memDone;
    dc.input('mem_valid').srcConnection! <= memValid;
    dc.input('mem_rdata').srcConnection! <= memRdata;
    await dc.build();

    // Backing memory (word-addressed by aligned byte addr), with a fixed ack
    // latency to mimic DRAM. The cache's memEn pulses; we respond after N cycles.
    final mem = <int, int>{};
    var pending = 0; // cycles until we answer the current mem op
    var opActive = false;

    reset.inject(1);
    reqValid.inject(0);
    reqWrite.inject(0);
    reqAddr.inject(0);
    reqData.inject(0);
    reqSize.inject(2); // word (.w) -> 4 bytes
    flush.inject(0);
    memDone.inject(0);
    memValid.inject(0);
    memRdata.inject(0);

    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    // Memory responder: runs every cycle off the cache's mem_* outputs.
    void memStep() {
      final en = dc.memEn.value.toInt() == 1;
      if (en && !opActive) {
        opActive = true;
        pending = memLatency;
      }
      if (opActive) {
        if (pending > 0) {
          pending--;
          memDone.inject(0);
          memValid.inject(0);
        } else {
          final we = dc.memWe.value.toInt() == 1;
          final addr = dc.memAddr.value.toInt() & ~0x7; // 8-byte line word
          if (we) {
            // word (4B) write-through: honor size, low 4 bytes at the addr's word.
            final a = dc.memAddr.value.toInt();
            final wd = dc.memWdata.value.toInt();
            final base = a & ~0x7;
            final cur = mem[base] ?? 0;
            // store the 4-byte lane the amoadd targets (addr is 4-aligned).
            if ((a & 0x4) == 0) {
              mem[base] = (cur & ~0xFFFFFFFF) | (wd & 0xFFFFFFFF);
            } else {
              mem[base] = (cur & 0xFFFFFFFF) | ((wd & 0xFFFFFFFF) << 32);
            }
            memRdata.inject(0);
          } else {
            memRdata.inject(mem[addr] ?? 0);
          }
          memDone.inject(1);
          memValid.inject(1);
          opActive = false;
        }
      } else {
        memDone.inject(0);
        memValid.inject(0);
      }
    }

    // Issue one request; drive memStep each cycle; return respData for a load.
    Future<int> req(int addr, {required bool write, int data = 0}) async {
      reqAddr.inject(addr);
      reqWrite.inject(write ? 1 : 0);
      reqData.inject(data);
      reqValid.inject(1);
      // Wait for resp_valid, servicing memory each cycle.
      var guard = 0;
      while (true) {
        memStep();
        await clk.nextPosedge;
        if (dc.respValid.value.toInt() == 1) break;
        if (++guard > 100000) {
          throw StateError(
            'req to 0x${addr.toRadixString(16)} never completed',
          );
        }
      }
      final rd = dc.respData.value.toInt() & 0xFFFFFFFF;
      reqValid.inject(0);
      // one idle cycle between requests (cache drops busy)
      memStep();
      await clk.nextPosedge;
      return rd;
    }

    // The amoadd target and a conflicting address that maps to the SAME line
    // (256B cache, 8B lines => 32 lines; +256 bytes aliases the same index).
    const a = 0x80000040;
    const conflict = 0x80000040 + 256;
    mem[a & ~0x7] = 0; // owner/next both 0
    mem[conflict & ~0x7] = 0xdead;

    // amoadd loop: read A, write A = read+1. Also touch the conflicting line
    // each iter to force A's line to be evicted/refilled (exercises the
    // store-invalidate vs fill timing).
    const iters = 64;
    var expected = 0;
    for (var k = 0; k < iters; k++) {
      final got = await req(a, write: false);
      expect(
        got,
        expected,
        reason:
            'iter $k: load A returned 0x${got.toRadixString(16)}, '
            'expected 0x${expected.toRadixString(16)} '
            '(a lost store => stale cached read = the ticket-lock bug)',
      );
      expected = (got + 1) & 0xFFFFFFFF;
      await req(a, write: true, data: expected); // amoadd write-back
      // conflicting-line access to churn the direct-mapped line
      await req(conflict, write: false);
    }

    // Final memory value must reflect all increments.
    expect(
      mem[a & ~0x7]! & 0xFFFFFFFF,
      iters,
      reason: 'final A in memory should be $iters after $iters increments',
    );

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }

  test('D-cache amoadd read-after-write coherence, memLatency=1', () async {
    await run(memLatency: 1);
  });
  test('D-cache amoadd read-after-write coherence, memLatency=3', () async {
    await run(memLatency: 3);
  });
}
