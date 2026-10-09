import 'dart:async';

import 'package:harbor/src/clock/wishbone_cdc.dart';
import 'package:harbor/src/clock/wishbone_cdc_fifo.dart';
import 'package:harbor/src/clock/wishbone_downsizer.dart';
import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Sim bisection of the creek execute-from-DRAM corruption, one cut below the
/// core. The core-only sim (rv32+rv64, latency memory, no CDC) is clean, so the
/// bug is in the downsizer/CDC/DDR path. The EXISTING ifetch_load_deadlock_test
/// has two gaps vs creek: it uses HarborWishboneCdcBridge (creek/ddr3Fast uses
/// HarborWishboneCdcFifoBridge) and only a few loads. This runs a SUSTAINED
/// icache-thrashing load-sum blob (code >> the rc1-s 64B icache, so the icache
/// refills from DRAM the whole time while the dcache loads) through the REAL
/// creek chain: core(64) -> downsizer(64->32) -> CDC bridge -> fast 32b memory,
/// and CHECKS the summed result (stored back to DRAM). Runs both bridge kinds so
/// a FIFO-only corruption is obvious.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // rv64 rc1-s (matches creek's core+caches exactly).
  RiverCoreConfig cfg() => RiverCoreConfigV1.small(
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

  // Program: sum N loads of K from a data region, store the low 32 bits back to
  // DRAM at resultAddr. Code is long enough to thrash the 64B icache.
  const dataBase = 0x400;
  const resultAddr = 0x780;
  const k = 0x5A5A5A5A;
  const n = 8;
  // encoders
  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  int lw(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (0x2 << 12) | (rd << 7) | 0x03;
  int add(int rd, int rs1, int rs2) =>
      (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33;
  int sw(int rs2, int rs1, int imm) =>
      (((imm >> 5) & 0x7F) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (0x2 << 12) |
      ((imm & 0x1F) << 7) |
      0x23;
  const nop = 0x00000013;

  final program = <int>[
    addi(3, 0, dataBase), // x3 = data base
    addi(2, 0, 0), // x2 = 0 (accumulator)
    for (var i = 0; i < n; i++) ...[
      lw(1, 3, 0), // x1 = [x3]
      add(2, 2, 1), // x2 += x1
      addi(3, 3, 8), // x3 += 8 (new 8B line each -> dcache miss)
    ],
    addi(5, 0, resultAddr), // x5 = result addr
    sw(2, 5, 0), // [x5] = x2 (store the sum back to DRAM)
    nop,
    nop,
  ];
  final expected = (n * k) & 0xFFFFFFFF; // low 32 bits of the sum

  /// core -> downsizer(64->32) -> [bridge] -> 32b fast memory. bridgeKind picks
  /// the real creek FIFO bridge vs the legacy gray-counter bridge. Returns the
  /// 32b word stored at resultAddr (null if never written) and whether it stalled.
  Future<({int? result, bool stalled, int maxAddr})> run(
    String bridgeKind, {
    int sPeriod = 40,
    int mPeriod = 10,
    int memLatency = 6,
    int maxCycles = 6000,
  }) async {
    await Simulator.reset();
    final config = cfg();
    final xlen = config.mxlen.size;
    final sClk = SimpleClockGenerator(sPeriod).clk;
    final mClk = SimpleClockGenerator(mPeriod).clk;
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

    const narrow = 32;
    final ds = HarborWishboneDownsizer(
      addressWidth: xlen,
      wideWidth: xlen,
      narrowWidth: narrow,
      paceCycles: 8,
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

    // Pick the bridge. Both are port-compatible.
    late final Module bridge;
    if (bridgeKind == 'fifo') {
      bridge = HarborWishboneCdcFifoBridge(
        addressWidth: xlen,
        dataWidth: narrow,
        selWidth: narrow ~/ 8,
        depth: 16,
      );
    } else {
      bridge = HarborWishboneCdcBridge(addressWidth: xlen, dataWidth: narrow);
    }
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

    final storage = SparseMemoryStorage(
      addrWidth: xlen,
      dataWidth: narrow,
      alignAddress: (addr) => addr,
      onInvalidRead: (addr, dataWidth) =>
          LogicValue.filled(dataWidth, LogicValue.zero),
    );
    final memRead = DataPortInterface(narrow, xlen);
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

    // Load program @0 and data (K) @dataBase.
    final sb = StringBuffer('@0\n');
    for (final w in program) {
      for (var b = 0; b < 4; b++) {
        sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    sb.write('\n@${dataBase.toRadixString(16)}\n');
    for (var i = 0; i < n * 2 + 4; i++) {
      // fill dataBase..+ generously with K (every 32b word)
      for (var b = 0; b < 4; b++) {
        sb.write(((k >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    storage.loadMemString('${sb.toString().trimRight()}\n');
    reset.inject(0);
    await sClk.nextPosedge;

    var maxAddr = 0;
    var lastProgress = 0;
    for (var i = 0; i < maxCycles; i++) {
      if (wbCyc.value == LogicValue.one &&
          wbStb.value == LogicValue.one &&
          wbWe.value == LogicValue.zero) {
        final a = wbAdr.value.toInt();
        if (a < 0x400 && a > maxAddr) {
          maxAddr = a;
          lastProgress = i;
        }
      }
      final res = storage.getData(LogicValue.ofInt(resultAddr, xlen))?.toInt();
      if (res != null && res != 0) {
        await Simulator.endSimulation();
        return (result: res, stalled: false, maxAddr: maxAddr);
      }
      if (i - lastProgress > 1500 && wbCyc.value == LogicValue.one) {
        await Simulator.endSimulation();
        return (result: null, stalled: true, maxAddr: maxAddr);
      }
      await sClk.nextPosedge;
    }
    final res = storage.getData(LogicValue.ofInt(resultAddr, xlen))?.toInt();
    await Simulator.endSimulation();
    return (result: res, stalled: false, maxAddr: maxAddr);
  }

  for (final kind in ['gray', 'fifo']) {
    test(
      'sustained ifetch+load through the $kind CDC bridge sums correctly',
      timeout: Timeout(Duration(seconds: 240)),
      () async {
        final r = await run(kind);
        expect(
          r.stalled,
          isFalse,
          reason:
              '$kind bridge: core stalled at fetch '
              '0x${r.maxAddr.toRadixString(16)} (never stored the sum)',
        );
        expect(
          r.result,
          equals(expected),
          reason:
              '$kind bridge: sum came back '
              '0x${r.result?.toRadixString(16)} not 0x${expected.toRadixString(16)} '
              '- execute-from-DRAM corruption reproduced in sim',
        );
      },
    );
  }

  // REAL creek clock ratio: sys 25MHz / ctrl 50MHz = 2:1 phase-locked (one MMCM),
  // vs the 4:1 above. The FIFO bridge exists because phase-locked clocks hit a
  // pathological fixed phase; the arbitrary 4:1 may dodge the phase the 2:1
  // mesochronous pair lands on. If THIS corrupts, the bug is the CDC bridge under
  // the real clock phase.
  for (final mp in [20, 16, 12]) {
    test(
      'fifo bridge at ${(40 / mp).toStringAsFixed(2)}:1 clock ratio (mPeriod=$mp)',
      timeout: Timeout(Duration(seconds: 300)),
      () async {
        final r = await run('fifo', sPeriod: 40, mPeriod: mp);
        expect(
          r.stalled,
          isFalse,
          reason: 'stalled at 0x${r.maxAddr.toRadixString(16)}',
        );
        expect(
          r.result,
          equals(expected),
          reason:
              'ratio 40:$mp sum=0x${r.result?.toRadixString(16)} not '
              '0x${expected.toRadixString(16)} - i+d corruption reproduced',
        );
      },
    );
  }
}
