import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Multi-interconnect support: the River core emits a Wishbone master; Harbor's
/// bridges convert it to AXI4 or TileLink. These tests run a real program with
/// the core's bus routed through each interconnect (via the Harbor bridges) into
/// a memory slave, and check the architectural result is identical, proving the
/// core works over Wishbone, AXI4, and TileLink. See project_hdl_prefetch /
/// Harbor bus infra.
enum Interconnect { wishbone, axi4, tilelink }

/// Wire a Wishbone MASTER interface `wb` to a MemoryModel-backed slave.
void wishboneMemorySlave(
  WishboneInterface wb,
  Logic clk,
  Logic reset,
  SparseMemoryStorage storage,
  int dataWidth,
  int addrWidth,
) {
  final memRead = DataPortInterface(dataWidth, addrWidth);
  final memWrite = DataPortInterface(dataWidth, addrWidth);
  // ignore: unused_local_variable
  final mem = MemoryModel(
    clk,
    reset,
    [wrapWriteForRegisterFile(memWrite)],
    [wrapReadForRegisterFile(memRead, clk: clk, readLatency: 0)],
    readLatency: 0,
    storage: storage,
  );
  memRead.en <= wb.cyc & wb.stb & ~wb.we;
  memRead.addr <= wb.adr;
  memWrite.en <= wb.cyc & wb.stb & wb.we;
  memWrite.addr <= wb.adr;
  memWrite.data <= wb.datMosi;
  final ackReg = Logic(name: 'slaveAck');
  final readyForAck = wb.we | memRead.valid;
  Sequential(clk, [
    If(
      reset,
      then: [ackReg < 0],
      orElse: [
        If(
          wb.cyc & wb.stb & ~ackReg & readyForAck,
          then: [ackReg < 1],
          orElse: [ackReg < 0],
        ),
      ],
    ),
  ]);
  wb.ack <= ackReg;
  wb.datMiso <= memRead.data;
}

Future<void> interconnectTest(
  String memString,
  Map<Register, int> regStates,
  RiverCoreConfig config,
  Interconnect ic, {
  Map<int, int> memStates = const {},
  int nextPc = 4,
}) async {
  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();
  final addrWidth = config.mxlen.size;
  final dataWidth = config.mxlen.size;
  final wbConfig = WishboneConfig(
    addressWidth: addrWidth,
    dataWidth: dataWidth,
    selWidth: dataWidth ~/ 8,
  );
  final core = RiverCore(config, busConfig: wbConfig);
  core.input('clk').srcConnection! <= clk;
  core.input('reset').srcConnection! <= reset;
  await core.build();

  final storage = SparseMemoryStorage(
    addrWidth: addrWidth,
    dataWidth: dataWidth,
    alignAddress: (addr) => addr,
    onInvalidRead: (addr, w) => LogicValue.filled(w, LogicValue.zero),
  );

  // Reconstruct the core's Wishbone master from its exposed ports.
  final coreWb = WishboneInterface(wbConfig);
  coreWb.cyc <= core.output('dataBus_CYC');
  coreWb.stb <= core.output('dataBus_STB');
  coreWb.we <= core.output('dataBus_WE');
  coreWb.adr <= core.output('dataBus_ADR');
  coreWb.datMosi <= core.output('dataBus_DAT_MOSI');
  coreWb.sel <= core.output('dataBus_SEL');
  core.input('dataBus_ACK').srcConnection! <= coreWb.ack;
  core.input('dataBus_DAT_MISO').srcConnection! <= coreWb.datMiso;

  switch (ic) {
    case Interconnect.wishbone:
      wishboneMemorySlave(coreWb, clk, reset, storage, dataWidth, addrWidth);
    case Interconnect.tilelink:
      // core WB -> TileLink -> WB memory (round-trip through both TL bridges).
      final tlConfig = TileLinkConfig(
        addressWidth: addrWidth,
        dataWidth: dataWidth,
      );
      final tl = TileLinkInterface(tlConfig);
      WishboneToTileLinkBridge(coreWb, tl, clk: clk, reset: reset);
      final memWb = WishboneInterface(wbConfig);
      TileLinkToWishboneBridge(tl, memWb, clk: clk, reset: reset);
      wishboneMemorySlave(memWb, clk, reset, storage, dataWidth, addrWidth);
    case Interconnect.axi4:
      // core WB -> AXI4 -> AXI4 memory slave.
      // user/sideband channels are unused by the bridge; keep them 0-width
      // (rohd_hcl caps *userWidth at 16).
      final axiRead = Axi4ReadInterface(
        addrWidth: addrWidth,
        dataWidth: dataWidth,
        aruserWidth: 0,
        ruserWidth: 0,
      );
      final axiWrite = Axi4WriteInterface(
        addrWidth: addrWidth,
        dataWidth: dataWidth,
        awuserWidth: 0,
        wuserWidth: 0,
        buserWidth: 0,
      );
      WishboneToAxi4Bridge(coreWb, axiRead, axiWrite, clk: clk, reset: reset);
      _axi4MemorySlave(
        axiRead,
        axiWrite,
        clk,
        reset,
        storage,
        dataWidth,
        addrWidth,
      );
  }

  reset.inject(1);
  Simulator.registerAction(20, () {
    reset.put(0);
    storage.loadMemString(memString);
  });
  Simulator.setMaxSimTime(100000);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  while (reset.value.toBool()) {
    await clk.nextPosedge;
  }
  for (var i = 0; i < 5000; i++) {
    await clk.nextPosedge;
    final pc = core.pipeline.nextPc.value;
    if (pc.isValid && pc.toInt() == nextPc) break;
  }
  await Simulator.endSimulation();
  await Simulator.simulationEnded;

  for (final regState in regStates.entries) {
    final value = core.regs.getData(LogicValue.ofInt(regState.key.value, 5))!;
    expect(value.toInt(), regState.value, reason: '${regState.key}=$value');
  }
  for (final memState in memStates.entries) {
    expect(
      storage.getData(LogicValue.ofInt(memState.key, dataWidth))!.toInt(),
      memState.value,
    );
  }
}

/// A minimal single-beat AXI4 memory slave backed by a MemoryModel.
void _axi4MemorySlave(
  Axi4ReadInterface axiRead,
  Axi4WriteInterface axiWrite,
  Logic clk,
  Logic reset,
  SparseMemoryStorage storage,
  int dataWidth,
  int addrWidth,
) {
  final memRead = DataPortInterface(dataWidth, addrWidth);
  final memWrite = DataPortInterface(dataWidth, addrWidth);
  // ignore: unused_local_variable
  final mem = MemoryModel(
    clk,
    reset,
    [wrapWriteForRegisterFile(memWrite)],
    [wrapReadForRegisterFile(memRead, clk: clk, readLatency: 0)],
    readLatency: 0,
    storage: storage,
  );

  // Read channel: always ready to accept AR; one-cycle later return R.
  axiRead.arReady <= Const(1);
  memRead.en <= axiRead.arValid;
  memRead.addr <= axiRead.arAddr.getRange(0, addrWidth);
  final rValidReg = Logic(name: 'axiRValid');
  final rDataReg = Logic(name: 'axiRData', width: dataWidth);
  Sequential(clk, [
    If(
      reset,
      then: [rValidReg < 0, rDataReg < 0],
      orElse: [
        // Pulse R the cycle after a valid read request (latency-0 memory).
        rValidReg < (axiRead.arValid & ~(rValidReg & axiRead.rReady)),
        rDataReg < memRead.data,
      ],
    ),
  ]);
  axiRead.rValid <= rValidReg;
  axiRead.rData <= rDataReg.zeroExtend(axiRead.dataWidth);
  if (axiRead.rResp != null) axiRead.rResp! <= Const(0, width: 2);
  if (axiRead.rId != null) axiRead.rId! <= Const(0, width: axiRead.idWidth);
  if (axiRead.rLast != null) axiRead.rLast! <= Const(1);

  // Write channel: accept AW+W, commit, then B.
  axiWrite.awReady <= Const(1);
  axiWrite.wReady <= Const(1);
  final doWrite = axiWrite.awValid & axiWrite.wValid;
  memWrite.en <= doWrite;
  memWrite.addr <= axiWrite.awAddr.getRange(0, addrWidth);
  memWrite.data <= axiWrite.wData.getRange(0, dataWidth);
  final bValidReg = Logic(name: 'axiBValid');
  Sequential(clk, [
    If(
      reset,
      then: [bValidReg < 0],
      orElse: [bValidReg < (doWrite & ~(bValidReg & axiWrite.bReady))],
    ),
  ]);
  axiWrite.bValid <= bValidReg;
  if (axiWrite.bResp != null) axiWrite.bResp! <= Const(0, width: 2);
  if (axiWrite.bId != null) axiWrite.bId! <= Const(0, width: axiWrite.idWidth);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig cfg() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv32,
    extensions: [rv32i, rvZicsr, rvZifencei],
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv32,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
    executionMode: ExecutionMode.inOrder,
  );

  // A store + load + register ops: exercises bus READ (fetch + load) and WRITE
  // (store) over the interconnect. sw x5,0(x10); lw x6,0(x10).
  //   addi x10,x0,0x100 ; addi x5,x0,0x123 ; sw x5,0(x10) ;
  //   nop nop ; lw x6,0(x10) ; nop tail
  int iimm(int imm, int rs1, int f3, int rd) =>
      (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
  int s(int imm, int rs2, int rs1, int f3) =>
      (((imm >> 5) & 0x7F) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (f3 << 12) |
      ((imm & 0x1F) << 7) |
      0x23;
  int lw(int imm, int rs1, int rd) =>
      (imm << 20) | (rs1 << 15) | (0x2 << 12) | (rd << 7) | 0x03;
  String prog(List<int> words) {
    final sb = StringBuffer('@0\n');
    for (final w in words) {
      for (var i = 0; i < 4; i++) {
        sb.write(((w >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return '$sb\n';
  }

  final program = prog([
    iimm(0x100, 0, 0x0, 10),
    iimm(0x123, 0, 0x0, 5),
    s(0, 5, 10, 0x2),
    0x00000013,
    0x00000013,
    lw(0, 10, 6),
    ...List.filled(6, 0x00000013),
  ]);
  final expectedRegs = {
    Register.x10: 0x100,
    Register.x5: 0x123,
    Register.x6: 0x123,
  };
  const expectedNextPc = 0x2C;
  final expectedMem = {0x100: 0x123};

  for (final ic in Interconnect.values) {
    test(
      'core runs over ${ic.name} interconnect',
      timeout: Timeout(Duration(seconds: 60)),
      () async {
        await interconnectTest(
          program,
          expectedRegs,
          cfg(),
          ic,
          nextPc: expectedNextPc,
          memStates: expectedMem,
        );
      },
    );
  }
}
