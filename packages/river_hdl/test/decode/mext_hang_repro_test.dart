import 'dart:async';
import 'dart:io';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// TEMPORARY repro (2-stage decode hang). Runs a seeded ALU program through the
/// rc1-f microcode core with a small cycle cap so a hang returns fast, and dumps
/// a VCD when RIVER_WAVE is set.
RiverCoreConfig cfg(int lanes) => RiverCoreConfig(
  clock: HarborClockConfig(
    name: 'sysclk',
    rate: HarborFixedClockRate(48000000),
  ),
  mxlen: RiscVMxlen.rv64,
  extensions: [
    rvC,
    rvZicsr,
    rvZifencei,
    rvM,
    rvA,
    rvF,
    rvD,
    rvPriv,
    rv64i,
    rv32i,
  ],
  interrupts: [],
  mmu: HarborMmuConfig(
    mxlen: RiscVMxlen.rv64,
    pagingModes: const [RiscVPagingMode.bare],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
  ),
  type: RiverCoreType.general,
  executionMode: ExecutionMode.inOrder,
  issueWidth: IssueWidth.single,
  microcodeMode: MicrocodeMode.full,
  microcodeDecodeLanes: lanes,
);

int rtype(int f7, int rs2, int rs1, int f3, int rd, int op) =>
    (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
int itype(int imm, int rs1, int f3, int rd, int op) =>
    ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
int utype(int imm, int rd, int op) => ((imm & 0xFFFFF) << 12) | (rd << 7) | op;
const int jSelf = 0x0000006F;

String asm(List<int> words) {
  final sb = StringBuffer('@0\n');
  for (final w in words) {
    for (var i = 0; i < 4; i++) {
      sb.write(((w >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
  }
  return '$sb\n';
}

Future<bool> run(
  RiverCoreConfig config,
  String memString, {
  required int parkPc,
  required int maxCycles,
  Map<Register, int> initRegisters = const {},
}) async {
  await Simulator.reset();
  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();
  final addrWidth = config.mxlen.size;
  final wbConfig = WishboneConfig(
    addressWidth: addrWidth,
    dataWidth: config.mxlen.size,
    selWidth: config.mxlen.size ~/ 8,
  );
  final prfSeedMode = Logic(name: 'prfSeedMode');
  final core = RiverCore(config, busConfig: wbConfig, prfSeedMode: prfSeedMode);
  core.input('clk').srcConnection! <= clk;
  core.input('reset').srcConnection! <= reset;
  await core.build();

  final wavePath = Platform.environment['RIVER_WAVE'];
  if (wavePath != null && wavePath.isNotEmpty) {
    WaveDumper(core, outputPath: wavePath);
  }

  final storage = SparseMemoryStorage(
    addrWidth: addrWidth,
    dataWidth: config.mxlen.size,
    alignAddress: (addr) => addr,
    onInvalidRead: (addr, dataWidth) =>
        LogicValue.filled(dataWidth, LogicValue.zero),
  );
  final memRead = DataPortInterface(config.mxlen.size, addrWidth);
  final memWrite = DataPortInterface(config.mxlen.size, addrWidth);
  // ignore: unused_local_variable
  final mem = MemoryModel(
    clk,
    reset,
    [wrapWriteForRegisterFile(memWrite)],
    [wrapReadForRegisterFile(memRead)],
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
  final seedGate = Logic(name: 'seedGate');
  core.input('dataBus_ACK').srcConnection! <= wbAckReg & ~seedGate;
  core.input('dataBus_DAT_MISO').srcConnection! <= memRead.data;

  reset.inject(1);
  seedGate.inject(initRegisters.isNotEmpty ? 1 : 0);
  prfSeedMode.inject(initRegisters.isNotEmpty ? 1 : 0);
  Simulator.registerAction(20, () {
    reset.put(0);
    storage.loadMemString(memString);
  });
  Simulator.setMaxSimTime(1 << 30);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  for (final regState in initRegisters.entries) {
    core.regWritePort.en.inject(1);
    core.regWritePort.addr.inject(LogicValue.ofInt(regState.key.value, 5));
    core.regWritePort.data.inject(
      LogicValue.ofInt(regState.value, config.mxlen.size),
    );
    await clk.nextPosedge;
  }
  core.regWritePort.en.inject(0);
  seedGate.inject(0);
  prfSeedMode.inject(0);
  while (reset.value.toBool()) {
    await clk.nextPosedge;
  }

  var parked = false;
  for (var i = 0; i < maxCycles; i++) {
    await clk.nextPosedge;
    final pc = core.pipeline.nextPc.value;
    if (pc.isValid && pc.toInt() == parkPc) {
      parked = true;
      break;
    }
  }
  await Simulator.endSimulation();
  await Simulator.simulationEnded;
  return parked;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // RV64M ops. f7=0x01 selects the M-extension for both 0x33 (mul/div/rem)
  // and 0x3B (word forms). These drive the iterative multiply/divide microcode,
  // the slowest decode paths, so this exercises the 2-stage decode pipeline
  // where the wall-clock decode_lanes_equiv m-ext test starved out under load.
  final mextWords = <int>[
    itype(0x123, 0, 0x0, 3, 0x13), // addi x3, x0, 0x123 (warm-up)
    rtype(0x01, 2, 1, 0x0, 4, 0x33), // mul
    rtype(0x01, 2, 1, 0x1, 5, 0x33), // mulh
    rtype(0x01, 2, 1, 0x2, 6, 0x33), // mulhsu
    rtype(0x01, 2, 1, 0x3, 7, 0x33), // mulhu
    rtype(0x01, 2, 1, 0x4, 8, 0x33), // div
    rtype(0x01, 2, 1, 0x5, 9, 0x33), // divu
    rtype(0x01, 2, 1, 0x6, 10, 0x33), // rem
    rtype(0x01, 2, 1, 0x7, 11, 0x33), // remu
    rtype(0x01, 2, 1, 0x0, 12, 0x3B), // mulw
    rtype(0x01, 2, 1, 0x4, 13, 0x3B), // divw
    rtype(0x01, 2, 1, 0x5, 14, 0x3B), // divuw
    rtype(0x01, 2, 1, 0x6, 15, 0x3B), // remw
    rtype(0x01, 2, 1, 0x7, 16, 0x3B), // remuw
    jSelf,
  ];

  test(
    'm-ext ops repro (lanes=2)',
    timeout: Timeout(Duration(minutes: 8)),
    () async {
      final parkPc = (mextWords.length - 1) * 4;
      final parked = await run(
        cfg(2),
        asm(mextWords),
        parkPc: parkPc,
        // Iterative mul/div microcode is far costlier per op than ALU, so allow a
        // generous cycle budget. Parks (or not) independent of wall-clock load.
        maxCycles: 60000,
        initRegisters: {Register.x1: 0xF0, Register.x2: 0x0C},
      );
      expect(
        parked,
        isTrue,
        reason: 'core hung, did not reach park @0x$parkPc',
      );
    },
  );
}
