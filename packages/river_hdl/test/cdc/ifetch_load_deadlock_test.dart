import 'dart:async';

import 'package:harbor/src/clock/wishbone_cdc.dart';
import 'package:harbor/src/clock/wishbone_downsizer.dart';
import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Deterministic repro for the creek #131 hardware hang: a blocking DRAM LOAD
/// issued while the core fetches instructions from DRAM wedges the core. On
/// hardware the DRAM sits behind a 12->48MHz HarborWishboneCdcBridge; the
/// single-clock latency model does NOT reproduce it (latency alone lets the core
/// progress), so this puts the REAL CDC bridge between the real RiverCore and a
/// fast-clock memory and runs a fetch+load loop across the clock domains.
///
/// Result is the highest instruction-fetch address the core reaches before a
/// stall: a healthy run climbs to the trailing nop; a deadlock freezes far
/// below (the on-hardware symptom: wedges on the first load).
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  /// Build core (slow clk) -> HarborWishboneCdcBridge -> MemoryModel (fast clk),
  /// load [program] at 0, run, and return (maxFetchAddr, stalled?). [sPeriod]/
  /// [mPeriod] set the core/memory clock periods (creek = 12MHz core / 48MHz
  /// dram ~= 4:1).
  Future<({int maxAddr, bool stalled, int? probed, Map<int, int> written})>
  run({
    required List<int> program,
    int sPeriod = 40,
    int mPeriod = 10,
    int memLatency = 12, // fast-side DDR-like multi-cycle read latency
    int maxCycles = 3500,
    int probeAddr =
        -1, // >=0: return the 32b memory word at this addr after run
    List<int> scanAddrs = const [], // addrs to snapshot from memory after run
  }) async {
    await Simulator.reset();
    final config = RiverCoreConfigV1.small(
      mmu: HarborMmuConfig(
        mxlen: RiscVMxlen.rv64,
        pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
        tlbLevels: const [],
        pmp: HarborPmpConfig.none,
      ),
      interrupts: const [],
      clock: HarborClockConfig(
        name: 'sysclk',
        rate: HarborFixedClockRate(48000000),
      ),
    );
    final xlen = config.mxlen.size;

    final sClk = SimpleClockGenerator(sPeriod).clk; // core (slow)
    final mClk = SimpleClockGenerator(mPeriod).clk; // memory (fast)
    final reset = Logic(name: 'reset');

    final wbConfig = WishboneConfig(
      addressWidth: xlen,
      dataWidth: xlen,
      selWidth: xlen ~/ 8,
    );
    final core = RiverCore(config, busConfig: wbConfig);
    core.input('clk').srcConnection! <= sClk;
    core.input('reset').srcConnection! <= reset;
    await core.build();

    final wbCyc = core.output('dataBus_CYC');
    final wbStb = core.output('dataBus_STB');
    final wbWe = core.output('dataBus_WE');
    final wbAdr = core.output('dataBus_ADR');

    // The real creek DRAM face order: core(64) -> downsizer(64->32, core clk) ->
    // CDC bridge(32, core clk slave / mem clk master) -> memory(32, mem clk).
    const narrow = 32;
    final ds = HarborWishboneDownsizer(
      addressWidth: xlen,
      wideWidth: xlen,
      narrowWidth: narrow,
      paceCycles: 8, // matches ddr.dart
    );
    ds.input('clk').srcConnection! <= sClk;
    ds.input('reset').srcConnection! <= reset;
    ds.input('s_cyc').srcConnection! <= wbCyc;
    ds.input('s_stb').srcConnection! <= wbStb;
    ds.input('s_we').srcConnection! <= wbWe;
    ds.input('s_adr').srcConnection! <= wbAdr;
    ds.input('s_dat_w').srcConnection! <= core.output('dataBus_DAT_MOSI');
    ds.input('s_sel').srcConnection! <= core.output('dataBus_SEL');
    core.input('dataBus_ACK').srcConnection! <= ds.output('s_ack');
    core.input('dataBus_DAT_MISO').srcConnection! <= ds.output('s_dat_r');

    final bridge = HarborWishboneCdcBridge(
      addressWidth: xlen,
      dataWidth: narrow,
    );
    bridge.input('s_clk').srcConnection! <= sClk;
    bridge.input('s_reset').srcConnection! <= reset;
    bridge.input('m_clk').srcConnection! <= mClk;
    bridge.input('m_reset').srcConnection! <= reset;
    bridge.input('s_cyc').srcConnection! <= ds.output('m_cyc');
    bridge.input('s_stb').srcConnection! <= ds.output('m_stb');
    bridge.input('s_we').srcConnection! <= ds.output('m_we');
    bridge.input('s_adr').srcConnection! <= ds.output('m_adr');
    bridge.input('s_dat_w').srcConnection! <= ds.output('m_dat_w');
    bridge.input('s_sel').srcConnection! <= ds.output('m_sel');
    ds.input('m_ack').srcConnection! <= bridge.output('s_ack');
    ds.input('m_err').srcConnection! <= Const(0);
    ds.input('m_dat_r').srcConnection! <= bridge.output('s_dat_r');

    // Fast-side 32-bit memory holding the program.
    final storage = SparseMemoryStorage(
      addrWidth: xlen,
      dataWidth: narrow,
      alignAddress: (addr) => addr,
      onInvalidRead: (addr, dataWidth) =>
          LogicValue.filled(dataWidth, LogicValue.zero),
    );
    final memRead = DataPortInterface(narrow, xlen); // (dataWidth, addrWidth)
    final memWrite = DataPortInterface(narrow, xlen);
    // ignore: unused_local_variable
    final mem = MemoryModel(
      mClk,
      reset,
      [wrapWriteForRegisterFile(memWrite)],
      [wrapReadForRegisterFile(memRead, clk: mClk, readLatency: memLatency)],
      readLatency: memLatency,
      storage: storage,
    );
    final mCyc = bridge.output('m_cyc');
    final mStb = bridge.output('m_stb');
    final mWe = bridge.output('m_we');
    memRead.en <= mCyc & mStb & ~mWe;
    memRead.addr <= bridge.output('m_adr');
    memWrite.en <= mCyc & mStb & mWe;
    memWrite.addr <= bridge.output('m_adr');
    memWrite.data <= bridge.output('m_dat_w');
    bridge.input('m_ack').srcConnection! <=
        (mCyc & mStb & (mWe | memRead.valid));
    bridge.input('m_dat_r').srcConnection! <= memRead.data;

    reset.inject(1);
    Simulator.setMaxSimTime(1000000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await sClk.nextPosedge;
    }

    final sb = StringBuffer('@0\n');
    for (final w in program) {
      for (var b = 0; b < 4; b++) {
        sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    storage.loadMemString('${sb.toString().trimRight()}\n');
    reset.inject(0);
    await sClk.nextPosedge;

    var maxAddr = 0;
    var lastProgressCycle = 0;
    for (var i = 0; i < maxCycles; i++) {
      if (wbCyc.value == LogicValue.one &&
          wbStb.value == LogicValue.one &&
          wbWe.value == LogicValue.zero) {
        final a = wbAdr.value.toInt();
        if (a < 0x1000 && a > maxAddr) {
          maxAddr = a;
          lastProgressCycle = i;
        }
      }
      // Stall = the core has held a request but made no fetch progress for a
      // long stretch (1000 core cycles >> any microcode instruction latency).
      if (i - lastProgressCycle > 1000 && wbCyc.value == LogicValue.one) {
        final p = probeAddr < 0
            ? null
            : storage.getData(LogicValue.ofInt(probeAddr, xlen))?.toInt();
        await Simulator.endSimulation();
        return (
          maxAddr: maxAddr,
          stalled: true,
          probed: p,
          written: <int, int>{},
        );
      }
      await sClk.nextPosedge;
    }
    final probed = probeAddr < 0
        ? null
        : storage.getData(LogicValue.ofInt(probeAddr, xlen))?.toInt();
    final written = <int, int>{};
    for (final a in scanAddrs) {
      final v = storage.getData(LogicValue.ofInt(a, xlen))?.toInt();
      if (v != null) written[a] = v;
    }
    await Simulator.endSimulation();
    return (maxAddr: maxAddr, stalled: false, probed: probed, written: written);
  }

  // x3 = 0x800 (data region), then a run of `lw x1, 0(x3)` so the core fetches
  // AND loads every iteration, ending at a trailing nop.
  const liX3 = 0x80000193; // addi x3, x0, 0x800
  const lwX1 = 0x0001a083; // lw x1, 0(x3)
  const nop = 0x00000013;
  final program = <int>[liX3, ...List.filled(6, lwX1), nop];
  final nopAddr = (program.length - 1) * 4;

  test(
    'fetch+load loop across the real CDC bridge must not deadlock',
    () async {
      final r = await run(program: program);
      expect(
        r.stalled,
        isFalse,
        reason:
            'core wedged at fetch addr 0x${r.maxAddr.toRadixString(16)} '
            '(nop at 0x${nopAddr.toRadixString(16)}): reproduces the creek '
            'ifetch+load CDC deadlock',
      );
      expect(
        r.maxAddr,
        greaterThanOrEqualTo(nopAddr - 4),
        reason: 'should fetch through to the nop',
      );
    },
  );

  // ---- L1 dcache data-correctness across the real CDC bridge ----
  // NB: RV64 `lui rd,0x80000` sign-extends bit 31 to 0xFFFFFFFF80000000, so build
  // the DRAM base 0x80000000 as (1<<31): addi x3,x0,1 ; slli x3,x3,31.
  const swX1 = 0x0011a023; //   sw   x1, 0(x3)      (cacheable write-through)
  const lwX2 = 0x0001a103; //   lw   x2, 0(x3)      (cacheable fill)
  const li1X3 = 0x00100193; //  addi x3, x0, 1
  const slli31X3 = 0x01f19193; // slli x3, x3, 31   -> x3 = 0x80000000
  const luiX1 = 0x123450b7; //  lui  x1, 0x12345
  const addiX1 = 0x67808093; // addi x1, x1, 0x678  -> x1 = 0x12345678
  const swX2o64 = 0x0421a023; // sw  x2, 64(x3)

  test('dcache write-through lands correct data in DRAM', () async {
    final prog = <int>[li1X3, slli31X3, luiX1, addiX1, swX1, nop];
    final r = await run(program: prog, maxCycles: 1500, probeAddr: 0x80000000);
    expect(
      r.probed,
      equals(0x12345678),
      reason:
          'write-through wrote 0x${r.probed?.toRadixString(16)} not '
          '0x12345678 to DRAM (data corruption)',
    );
  });

  // S-mode Bare load must not hang the core (the Ferrite read-sweep hangs on the
  // first S-mode load of 0x80000000; this checks whether that is CORE logic or
  // hardware). mret into S-mode (MPP=S), then load 0x80000000 with satp=Bare.
  // If the core treats an S-mode Bare load like an M-mode one (it should: no
  // translation/walk/perm-check when satp=0), it fetches through to the tail.
  test('S-mode Bare load does not hang the core', () async {
    final prog = <int>[
      0x00100593, // addi x11, x0, 1
      0x00b59593, // slli x11, x11, 11    -> x11 = 0x800 (mstatus.MPP = S)
      0x30059073, // csrw mstatus, x11
      0x02000613, // addi x12, x0, 0x20   (S-mode entry PC)
      0x34161073, // csrw mepc, x12
      0x30200073, // mret                 -> S-mode @ 0x20
      0x00000013, // nop (0x18)
      0x00000013, // nop (0x1c)
      0x00100193, // addi x3, x0, 1       (0x20, S-mode)
      0x01f19193, // slli x3, x3, 31      -> x3 = 0x80000000
      0x0001a203, // lw   x4, 0(x3)       (the load that hangs on hardware)
      0x00000013, // nop (0x2c)
    ];
    final r = await run(program: prog, maxCycles: 1500);
    expect(
      r.stalled,
      isFalse,
      reason:
          'S-mode Bare load wedged the core at fetch '
          '0x${r.maxAddr.toRadixString(16)} (load is at 0x28): the hang is '
          'core logic, not hardware',
    );
    expect(
      r.maxAddr,
      greaterThanOrEqualTo(0x28),
      reason: 'should fetch past the S-mode load',
    );
  });

  // Store to DRAM, load it back (fill), then store the loaded value to a 2nd
  // DRAM address so we can observe what the fill returned (the FSBL copy+verify
  // pattern). Catches a fill returning wrong/stale data.
  test('dcache round-trip store->fill->store preserves data', () async {
    final prog = <int>[
      li1X3,
      slli31X3,
      luiX1,
      addiX1,
      swX1,
      lwX2,
      swX2o64,
      nop,
    ];
    final r = await run(program: prog, maxCycles: 1500, probeAddr: 0x80000040);
    expect(
      r.probed,
      equals(0x12345678),
      reason:
          'fill returned 0x${r.probed?.toRadixString(16)} not 0x12345678 '
          '(read-back corruption)',
    );
  });

  // Round-trip at a 4-aligned (NOT 8-aligned) DRAM address. The dcache fills the
  // 8-byte line word, so if exec's byte extraction disagrees with the line
  // alignment, an unaligned load reads the wrong half. sw/lw at offset 4.
  const swX1o4 = 0x0011a223; //  sw x1, 4(x3)
  const lwX2o4 = 0x0041a103; //  lw x2, 4(x3)
  test('dcache round-trip at 4-aligned addr preserves data', () async {
    final prog = <int>[
      li1X3, slli31X3, luiX1, addiX1,
      swX1o4, // DRAM[0x80000004] = 0x12345678
      lwX2o4, // x2 = DRAM[0x80000004] (fill of the 0x80000000 line, extract hi)
      swX2o64, // DRAM[0x80000040] = x2
      nop,
    ];
    final r = await run(program: prog, maxCycles: 1500, probeAddr: 0x80000040);
    expect(
      r.probed,
      equals(0x12345678),
      reason:
          'unaligned fill returned 0x${r.probed?.toRadixString(16)} not '
          '0x12345678 (line-alignment vs exec-extract mismatch)',
    );
  });
}
