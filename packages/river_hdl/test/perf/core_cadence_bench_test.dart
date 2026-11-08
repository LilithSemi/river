import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Fast, hang-safe front-end cadence harness. Multi-outstanding fetch from a
/// FULLY-DEFINED ROM (no X), BOUNDED cycle loop (cannot hang), and COMMIT-based
/// measurement (via retire_valid). Isolates the alloc cadence and lets us check
/// correctness at period 1. See project_hdl_frontend_perf.
void main() {
  RiverCoreConfig mk() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv64,
    extensions: [rv64i, rv32i, rvM, rvZicsr, rvZifencei],
    interrupts: const [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
    executionMode: ExecutionMode.outOfOrder,
    speculativeFetch: true,
    prefetchFetch: true,
    prefetchDepth: 8,
    fetchOutstanding: 4,
    // The fast alloc cadence requires the LSQ (memory disambiguation).
    loadStoreQueue: LoadStoreQueue.forwarding,
  );

  int iimm(int imm, int rs1, int f3, int rd) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
  int btype(int imm, int rs2, int rs1, int f3) =>
      (((imm >> 12) & 1) << 31) |
      (((imm >> 5) & 0x3F) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (f3 << 12) |
      (((imm >> 1) & 0xF) << 8) |
      (((imm >> 11) & 1) << 7) |
      0x63;
  int stype(int imm, int rs2, int rs1, int f3) =>
      (((imm >> 5) & 0x7F) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (f3 << 12) |
      ((imm & 0x1F) << 7) |
      0x23;

  /// Build a multi-outstanding core, run [cycles] bounded cycles, return the
  /// commit-cycle list and the data-memory storage (for result checks).
  Future<(List<int>, SparseMemoryStorage)> runCore(
    List<int> program, {
    int cycles = 150,
  }) async {
    await Simulator.reset();
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic();
    const aw = 64;
    final wbConfig = WishboneConfig(
      addressWidth: aw,
      dataWidth: aw,
      selWidth: aw ~/ 8,
    );
    final core = RiverCore(mk(), busConfig: wbConfig);
    core.input('clk').srcConnection! <= clk;
    core.input('reset').srcConnection! <= reset;

    // Pad with `addi x31, x0, imm` (writes x31, reads x0): truly independent.
    // (A real `nop` = addi x0,x0,0 WRITES x0; if x0 isn't special-cased that
    // creates a false read-x0 dependency chain that serialises the stream.)
    final padded = [
      ...program,
      for (var i = program.length; i < 64; i++)
        iimm((i & 0x1F) + 1, 0, 0x0, 31),
    ];
    final link = FetchReadInterface(32, aw);
    link.reqValid <= core.output('fetchReq_valid');
    link.reqAddr <= core.output('fetchReq_addr');
    core.input('fetchReq_ready').srcConnection! <= link.reqReady;
    core.input('fetchRsp_valid').srcConnection! <= link.rspValid;
    core.input('fetchRsp_data').srcConnection! <= link.rspData;
    PipelinedFetchMemory(
      clk,
      reset,
      link,
      initWords: padded,
      words: 64,
      readLatency: 1,
    );

    await core.build();

    final storage = SparseMemoryStorage(
      addrWidth: aw,
      dataWidth: aw,
      alignAddress: (addr) => addr,
      onInvalidRead: (addr, dataWidth) =>
          LogicValue.filled(dataWidth, LogicValue.zero),
    );
    final memRead = DataPortInterface(aw, aw);
    final memWrite = DataPortInterface(aw, aw);
    // ignore: unused_local_variable
    final mem = MemoryModel(
      clk,
      reset,
      [wrapWriteForRegisterFile(memWrite)],
      [wrapReadForRegisterFile(memRead, clk: clk, readLatency: 0)],
      readLatency: 0,
      storage: storage,
    );
    final wbCyc = core.output('dataBus_CYC');
    final wbStb = core.output('dataBus_STB');
    final wbWe = core.output('dataBus_WE');
    memRead.en <= wbCyc & wbStb & ~wbWe;
    memRead.addr <= core.output('dataBus_ADR');
    memWrite.en <= wbCyc & wbStb & wbWe;
    memWrite.addr <= core.output('dataBus_ADR');
    memWrite.data <= core.output('dataBus_DAT_MOSI');
    final wbAckReg = Logic(name: 'wbAck');
    Sequential(clk, [
      If(
        reset,
        then: [wbAckReg < 0],
        orElse: [
          If(
            wbCyc & wbStb & ~wbAckReg & (wbWe | memRead.valid),
            then: [wbAckReg < 1],
            orElse: [wbAckReg < 0],
          ),
        ],
      ),
    ]);
    core.input('dataBus_ACK').srcConnection! <= wbAckReg;
    core.input('dataBus_DAT_MISO').srcConnection! <= memRead.data;

    reset.inject(1);
    Simulator.registerAction(20, () => reset.put(0));
    Simulator.setMaxSimTime(300000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    while (reset.value.toBool()) {
      await clk.nextPosedge;
    }

    final retire = core.pipeline.output('retire_valid');
    bool hi(Logic l) => l.value.isValid && l.value.toBool();
    final commitCycles = <int>[];
    var cyc = 0;
    for (var i = 0; i < cycles; i++) {
      await clk.nextPosedge;
      cyc++;
      if (hi(retire)) commitCycles.add(cyc);
    }
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
    return (commitCycles, storage);
  }

  int rd64(SparseMemoryStorage s, int addr) =>
      s.getData(LogicValue.ofInt(addr, 64))?.toInt() ?? 0;

  tearDown(() async {
    await Simulator.reset();
  });

  test('cadence: commit throughput on straight-line (bounded, no-X)', () async {
    final program = [
      for (var i = 0; i < 24; i++) iimm((i & 0x3F) + 1, 0, 0x0, (i % 30) + 1),
    ];
    final (commits, _) = await runCore(program, cycles: 150);
    final gaps = <int>[];
    for (var i = 1; i < commits.length; i++) {
      gaps.add(commits[i] - commits[i - 1]);
    }
    final steady = gaps.length > 6 ? gaps.sublist(3) : gaps;
    final avg = steady.isEmpty
        ? 0.0
        : steady.reduce((a, b) => a + b) / steady.length;
    // ignore: avoid_print
    print(
      '\n=== CADENCE: commits=${commits.length}/150 cyc, '
      'steady commit period=${avg.toStringAsFixed(2)} '
      '(slow advance ~3.0, fast advance ~1.0) ===\n',
    );
    expect(
      commits.length,
      greaterThan(20),
      reason: 'must retire a steady stream (not wedge)',
    );
    // The LSQ-gated fast advance + independent stream should sustain ~1.0
    // commit/cyc (the full front-end lift). Guard against cadence regressions.
    expect(
      avg,
      lessThan(1.4),
      reason: 'fast cadence should sustain ~1 commit/cyc (got $avg)',
    );
  }, timeout: Timeout(Duration(seconds: 120)));

  // x0 special-casing: a stream of canonical nops (addi x0,x0,0) must NOT
  // false-chain through x0. Without the x0-always-ready fix this serialises to
  // ~1.5 cyc/instr; with it, ~1.0. (Safe: the OoO path is integer-only.)
  test('cadence: canonical nops do not false-chain through x0', () async {
    final program = [for (var i = 0; i < 40; i++) 0x00000013]; // addi x0,x0,0
    final (commits, _) = await runCore(program, cycles: 120);
    final gaps = <int>[];
    for (var i = 1; i < commits.length; i++) {
      gaps.add(commits[i] - commits[i - 1]);
    }
    final steady = gaps.length > 6 ? gaps.sublist(3) : gaps;
    final avg = steady.isEmpty
        ? 0.0
        : steady.reduce((a, b) => a + b) / steady.length;
    // ignore: avoid_print
    print(
      '\n=== NOP cadence: period=${avg.toStringAsFixed(2)} '
      '(no x0 fix ~1.5, with x0 fix ~1.0) ===\n',
    );
    expect(
      avg,
      lessThan(1.4),
      reason: 'nops must not false-chain through x0 (got $avg)',
    );
  }, timeout: Timeout(Duration(seconds: 120)));

  // THE LANDING TEST: a counted loop (backward-branch redirect) must execute
  // CORRECTLY at period 1. Loop 5 times to compute x1=5, store it to mem[0].
  test('correctness: counted loop at period 1 -> mem[0]==5', () async {
    final program = [
      iimm(0, 0, 0x0, 1), // addi x1,x0,0          @0
      iimm(5, 0, 0x0, 2), // addi x2,x0,5          @4
      iimm(1, 1, 0x0, 1), // addi x1,x1,1   (loop) @8
      iimm(-1, 2, 0x0, 2), // addi x2,x2,-1        @12
      btype(-8, 0, 2, 0x1), // bne x2,x0,@8        @16
      stype(0, 1, 0, 0x2), // sw x1,0(x0)          @20
    ];
    final (commits, storage) = await runCore(program, cycles: 120);
    final result = rd64(storage, 0);
    // ignore: avoid_print
    print(
      '\n=== LOOP: commits=${commits.length}, mem[0]=$result (expect 5) ===\n',
    );
    expect(result, 5, reason: 'counted loop must compute x1=5 and store it');
  }, timeout: Timeout(Duration(seconds: 120)));
}
