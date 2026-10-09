import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

// TEMPORARY: reproduces the equiv() structure (lanes=1 THEN lanes=2 in ONE
// process) with a small cycle cap, to catch a cross-run hang the isolated runs
// miss.
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
  int lastPc = -1;
  int stall = 0;
  int lastMoveCycle = 0;
  for (var i = 0; i < maxCycles; i++) {
    await clk.nextPosedge;
    final pcv = core.pipeline.nextPc.value;
    final pc = pcv.isValid ? pcv.toInt() : -2;
    if (pc == parkPc) {
      parked = true;
      print('  PARKED run@cycle=$i pc=0x${pc.toRadixString(16)}');
      break;
    }
    if (pc == lastPc) {
      stall++;
      if (stall == 600) {
        print(
          '  STALL run: pc stuck at 0x${pc.toRadixString(16)} for 600 cycles '
          '(cycle $i, lastMove@$lastMoveCycle) done=${core.pipeline.done.value} '
          'counter=${core.pipeline.counter.value.toInt()}',
        );
        break;
      }
    } else {
      stall = 0;
      lastPc = pc;
      lastMoveCycle = i;
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
  final aluWords = <int>[
    itype(0x123, 0, 0x0, 3, 0x13),
    itype(-5, 1, 0x0, 4, 0x13),
    rtype(0x00, 2, 1, 0x0, 5, 0x33),
    rtype(0x20, 2, 1, 0x0, 6, 0x33),
    rtype(0x00, 2, 1, 0x1, 7, 0x33),
    rtype(0x00, 2, 1, 0x2, 8, 0x33),
    rtype(0x00, 2, 1, 0x3, 9, 0x33),
    rtype(0x00, 2, 1, 0x4, 10, 0x33),
    rtype(0x00, 2, 1, 0x5, 11, 0x33),
    rtype(0x20, 2, 1, 0x5, 12, 0x33),
    rtype(0x00, 2, 1, 0x6, 13, 0x33),
    rtype(0x00, 2, 1, 0x7, 14, 0x33),
    itype(0x0F, 1, 0x7, 15, 0x13),
    itype(0x0F, 1, 0x6, 16, 0x13),
    itype(0x0F, 1, 0x4, 17, 0x13),
    itype(3, 1, 0x1, 18, 0x13),
    itype(2, 1, 0x5, 19, 0x13),
    utype(0x12345, 20, 0x37),
    rtype(0x00, 2, 1, 0x0, 21, 0x3B),
    rtype(0x20, 2, 1, 0x0, 22, 0x3B),
    itype(7, 1, 0x0, 23, 0x1B),
    jSelf,
  ];
  test(
    'combined lanes1 then lanes2',
    timeout: Timeout(Duration(minutes: 8)),
    () async {
      final parkPc = (aluWords.length - 1) * 4;
      print('=== RUN lanes=1 ===');
      final p1 = await run(
        cfg(1),
        asm(aluWords),
        parkPc: parkPc,
        maxCycles: 8000,
        initRegisters: {Register.x1: 0xF0, Register.x2: 0x0C},
      );
      print('lanes=1 parked=$p1');
      print('=== RUN lanes=2 ===');
      final p2 = await run(
        cfg(2),
        asm(aluWords),
        parkPc: parkPc,
        maxCycles: 8000,
        initRegisters: {Register.x1: 0xF0, Register.x2: 0x0C},
      );
      print('lanes=2 parked=$p2');
      expect(p1, isTrue, reason: 'lanes=1 hung');
      expect(p2, isTrue, reason: 'lanes=2 hung');
    },
  );
}
