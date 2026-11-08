import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Increment 4 integration: drive the core's EXPOSED multiple-outstanding fetch
/// port (fetchReq_*/fetchRsp_*) from an external pipelined fetch memory, and
/// confirm (a) it executes correctly and (b) it hides fetch latency in-core,
/// recovering toward the alloc-cadence floor where the single-outstanding
/// prefetch fetcher sags. The external memory drives the handshake (async
/// pattern); the core makes no latency assumption.
void main() {
  RiverCoreConfig mk({int fetchOutstanding = 1}) => RiverCoreConfig(
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
    prefetchDepth: fetchOutstanding > 1 ? 8 : 2,
    fetchOutstanding: fetchOutstanding,
  );

  int iimm(int imm, int rs1, int f3, int rd) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;

  // 24 independent addi then a self-loop terminator (jal x0, 0) so the sim
  // settles at nextPc once the 24th commits.
  final program = <int>[
    for (var i = 0; i < 24; i++) iimm((i & 0x3F) + 1, 0, 0x0, (i % 30) + 1),
    0x0000006F, // jal x0, 0
  ];
  const nextPc = 24 * 4;

  String memString(List<int> words) {
    final sb = StringBuffer('@0\n');
    for (final w in words) {
      for (var b = 0; b < 4; b++) {
        sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return sb.toString();
  }

  /// Run [config]. When [fetchLatency] != null the core's exposed fetch port is
  /// driven by an external [PipelinedFetchMemory] at that read latency; else
  /// fetch goes over the bus at [busLatency]. Returns cycles to reach nextPc.
  Future<int> run(
    RiverCoreConfig config, {
    int busLatency = 0,
    int? fetchLatency,
  }) async {
    await Simulator.reset();
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic();
    final aw = config.mxlen.size;
    final wbConfig = WishboneConfig(
      addressWidth: aw,
      dataWidth: aw,
      selWidth: aw ~/ 8,
    );
    final core = RiverCore(config, busConfig: wbConfig);
    core.input('clk').srcConnection! <= clk;
    core.input('reset').srcConnection! <= reset;

    // External pipelined fetch memory on the exposed port (async-pattern).
    if (fetchLatency != null) {
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
        initWords: program,
        words: 64,
        readLatency: fetchLatency,
      );
    }

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
      [wrapReadForRegisterFile(memRead, clk: clk, readLatency: busLatency)],
      readLatency: busLatency,
      storage: storage,
    );
    final wbCyc = core.output('dataBus_CYC');
    final wbStb = core.output('dataBus_STB');
    final wbWe = core.output('dataBus_WE');
    final wbAdr = core.output('dataBus_ADR');
    final wbDatMosi = core.output('dataBus_DAT_MOSI');
    memRead.en <= wbCyc & wbStb & ~wbWe;
    memRead.addr <= wbAdr;
    memWrite.en <= wbCyc & wbStb & wbWe;
    memWrite.addr <= wbAdr;
    memWrite.data <= wbDatMosi;
    final wbAckReg = Logic(name: 'wbAck');
    final readyForAck = wbWe | memRead.valid;
    Sequential(clk, [
      If(
        reset,
        then: [wbAckReg < 0],
        orElse: [
          If(
            wbCyc & wbStb & ~wbAckReg & readyForAck,
            then: [wbAckReg < 1],
            orElse: [wbAckReg < 0],
          ),
        ],
      ),
    ]);
    core.input('dataBus_ACK').srcConnection! <= wbAckReg;
    core.input('dataBus_DAT_MISO').srcConnection! <= memRead.data;

    reset.inject(1);
    Simulator.registerAction(20, () {
      reset.put(0);
      storage.loadMemString(memString(program));
    });
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    while (reset.value.toBool()) {
      await clk.nextPosedge;
    }
    var cycles = 0;
    var reached = false;
    for (var i = 0; i < 20000; i++) {
      await clk.nextPosedge;
      cycles++;
      final pc = core.pipeline.nextPc.value;
      if (pc.isValid && pc.toInt() == nextPc) {
        reached = true;
        break;
      }
    }
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
    expect(reached, isTrue, reason: 'core did not reach nextPc');
    return cycles;
  }

  tearDown(() async {
    await Simulator.reset();
  });

  // Correctness first: the exposed-port + external-memory path executes the
  // program and reaches nextPc.
  test(
    'multi-outstanding fetch executes correctly via the exposed port',
    () async {
      final c = await run(mk(fetchOutstanding: 3), fetchLatency: 2);
      expect(c, greaterThan(0));
    },
    timeout: Timeout(Duration(seconds: 120)),
  );

  // In-core win: at a fetch latency, multi-outstanding (external pipelined
  // memory) should beat the single-outstanding prefetch fetcher over the bus at
  // the same latency, recovering toward the alloc floor.
  test('multi-outstanding fetch hides latency in-core', () async {
    const lat = 4;
    final single = await run(mk(), busLatency: lat); // prefetch over bus
    final multi = await run(mk(fetchOutstanding: 5), fetchLatency: lat);
    // ignore: avoid_print
    print(
      '\n=== in-core fetch latency $lat: single-outstanding=$single cyc, '
      'multi-outstanding=$multi cyc (${(single / multi).toStringAsFixed(2)}x) ===\n',
    );
    expect(
      multi,
      lessThan(single),
      reason: 'multi-outstanding should hide fetch latency in-core',
    );
  }, timeout: Timeout(Duration(seconds: 200)));
}
