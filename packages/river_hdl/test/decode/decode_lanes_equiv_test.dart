import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

// Decode-lane equivalence: the microcode decoder packs `microcodeDecodeLanes`
// pattern-ROM rows per word and priority-selects the lowest-index match per
// cycle. lanes==1 is the classic one-row-per-cycle scan and is the proven
// reference. lanes==2 must decode every RV64GC instruction identically. This
// test runs the same program through a lanes==1 core and a lanes==2 core and
// asserts the architectural result is bit-identical. A divergence names the
// exact opcode the packed decode mishandles (the rc1-f flood hypothesis).

/// RV64GC-microcode config identical in every respect except decode lanes.
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
    rvFExtra,
    rvDExtra,
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

// ---- instruction encoders (RV64) ----
int rtype(int f7, int rs2, int rs1, int f3, int rd, int op) =>
    (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
int itype(int imm, int rs1, int f3, int rd, int op) =>
    ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
int stype(int imm, int rs2, int rs1, int f3, int op) =>
    (((imm >> 5) & 0x7F) << 25) |
    (rs2 << 20) |
    (rs1 << 15) |
    (f3 << 12) |
    ((imm & 0x1F) << 7) |
    op;
int btype(int imm, int rs2, int rs1, int f3) =>
    (((imm >> 12) & 0x1) << 31) |
    (((imm >> 5) & 0x3F) << 25) |
    (rs2 << 20) |
    (rs1 << 15) |
    (f3 << 12) |
    (((imm >> 1) & 0xF) << 8) |
    (((imm >> 11) & 0x1) << 7) |
    0x63;
int utype(int imm, int rd, int op) => ((imm & 0xFFFFF) << 12) | (rd << 7) | op;
int jal(int imm, int rd) =>
    (((imm >> 20) & 0x1) << 31) |
    (((imm >> 1) & 0x3FF) << 21) |
    (((imm >> 11) & 0x1) << 20) |
    (((imm >> 12) & 0xFF) << 12) |
    (rd << 7) |
    0x6F;

const int jSelf = 0x0000006F; // jal x0, 0 (park)

/// Assemble a list of (widthBytes, value) into a @0 mem string.
String asm(List<List<int>> insns) {
  final sb = StringBuffer('@0\n');
  for (final ins in insns) {
    final width = ins[0];
    final value = ins[1];
    for (var i = 0; i < width; i++) {
      sb.write(((value >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
  }
  return '$sb\n';
}

List<int> w32(int v) => [4, v];
List<int> w16(int v) => [2, v];

/// Run a program and return {gpr index -> value} for x1..x31, plus a snapshot
/// of the scratch memory words we might touch. Parks on a jal-to-self at
/// [parkPc] (must be present in the program).
Future<Map<String, int>> run(
  RiverCoreConfig config,
  String memString, {
  required int parkPc,
  Map<Register, int> initRegisters = const {},
  List<int> memProbe = const [],
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
  // readLatency MUST match on both sides. MemoryModel defaults to 1 while
  // wrapReadForRegisterFile defaults to 0, so leaving it out drives `valid` a
  // cycle before the model has data and the core latches an X instruction.
  // ignore: unused_local_variable
  final mem = MemoryModel(
    clk,
    reset,
    [wrapWriteForRegisterFile(memWrite)],
    [wrapReadForRegisterFile(memRead)],
    readLatency: 0,
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
  Simulator.setMaxSimTime(20000000);
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
  for (var i = 0; i < 400000; i++) {
    await clk.nextPosedge;
    final pc = core.pipeline.nextPc.value;
    if (pc.isValid && pc.toInt() == parkPc) {
      parked = true;
      break;
    }
  }

  final regs = <String, int>{};
  regs['__parked'] = parked ? 1 : 0;
  for (var r = 1; r < 32; r++) {
    final v = core.regs.getData(LogicValue.ofInt(r, 5));
    regs['x$r'] = (v != null && v.isValid) ? v.toInt() : -1;
  }
  for (final a in memProbe) {
    final v = storage.getData(LogicValue.ofInt(a, config.mxlen.size));
    regs['m$a'] = (v != null && v.isValid) ? v.toInt() : -1;
  }
  await Simulator.endSimulation();
  await Simulator.simulationEnded;
  return regs;
}

/// Assert lanes==1 and lanes==2 produce an identical architectural result.
Future<void> equiv(
  String name,
  List<List<int>> insns, {
  Map<Register, int> initRegisters = const {},
  List<int> memProbe = const [],
}) async {
  // parkPc = address of the trailing jal-to-self (last instruction).
  var pc = 0;
  for (var i = 0; i < insns.length - 1; i++) {
    pc += insns[i][0];
  }
  final memString = asm(insns);
  final r1 = await run(
    cfg(1),
    memString,
    parkPc: pc,
    initRegisters: initRegisters,
    memProbe: memProbe,
  );
  final r2 = await run(
    cfg(2),
    memString,
    parkPc: pc,
    initRegisters: initRegisters,
    memProbe: memProbe,
  );
  expect(r1['__parked'], 1, reason: '$name: lanes=1 did not reach park');
  expect(r2['__parked'], 1, reason: '$name: lanes=2 did not reach park');
  final diffs = <String>[];
  for (final k in r1.keys) {
    if (r1[k] != r2[k]) {
      diffs.add(
        '$k: lanes1=0x${r1[k]!.toRadixString(16)} '
        'lanes2=0x${r2[k]!.toRadixString(16)}',
      );
    }
  }
  expect(
    diffs,
    isEmpty,
    reason: '$name: lanes=1 vs lanes=2 DIVERGE:\n${diffs.join('\n')}',
  );
}

// Budgets measured 2026-09-03, serially (-j 1) on an idle 128-core aarch64 box:
// alu 8m30, m-ext 11m35, branch 14m14, load/store 34m02, compressed 15m12.
// The old 8-minute timeout was under half what the slowest case needs, so
// branch/m-ext/load-store failed as TimeoutException in every run regardless of
// machine load. 60 minutes gives the 34-minute worst case real headroom.
// These are slow because microcode decode is slow, which is a known perf item,
// not a correctness one.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Integer register-register + register-immediate ALU sweep. x1=0xF0,x2=0x0C
  // seeded; every op writes a distinct dest so a mis-decode shows up as one
  // wrong register.
  test('alu integer ops', timeout: Timeout(Duration(minutes: 60)), () async {
    await equiv(
      'alu',
      [
        w32(itype(0x123, 0, 0x0, 3, 0x13)), // addi x3, x0, 0x123
        w32(itype(-5, 1, 0x0, 4, 0x13)), // addi x4, x1, -5
        w32(rtype(0x00, 2, 1, 0x0, 5, 0x33)), // add  x5, x1, x2
        w32(rtype(0x20, 2, 1, 0x0, 6, 0x33)), // sub  x6, x1, x2
        w32(rtype(0x00, 2, 1, 0x1, 7, 0x33)), // sll  x7, x1, x2
        w32(rtype(0x00, 2, 1, 0x2, 8, 0x33)), // slt  x8, x1, x2
        w32(rtype(0x00, 2, 1, 0x3, 9, 0x33)), // sltu x9, x1, x2
        w32(rtype(0x00, 2, 1, 0x4, 10, 0x33)), // xor  x10, x1, x2
        w32(rtype(0x00, 2, 1, 0x5, 11, 0x33)), // srl  x11, x1, x2
        w32(rtype(0x20, 2, 1, 0x5, 12, 0x33)), // sra  x12, x1, x2
        w32(rtype(0x00, 2, 1, 0x6, 13, 0x33)), // or   x13, x1, x2
        w32(rtype(0x00, 2, 1, 0x7, 14, 0x33)), // and  x14, x1, x2
        w32(itype(0x0F, 1, 0x7, 15, 0x13)), // andi x15, x1, 0xF
        w32(itype(0x0F, 1, 0x6, 16, 0x13)), // ori  x16, x1, 0xF
        w32(itype(0x0F, 1, 0x4, 17, 0x13)), // xori x17, x1, 0xF
        w32(itype(3, 1, 0x1, 18, 0x13)), // slli x18, x1, 3
        w32(itype(2, 1, 0x5, 19, 0x13)), // srli x19, x1, 2
        w32(utype(0x12345, 20, 0x37)), // lui  x20, 0x12345
        w32(rtype(0x00, 2, 1, 0x0, 21, 0x3B)), // addw x21, x1, x2
        w32(rtype(0x20, 2, 1, 0x0, 22, 0x3B)), // subw x22, x1, x2
        w32(itype(7, 1, 0x0, 23, 0x1B)), // addiw x23, x1, 7
        w32(jSelf),
      ],
      initRegisters: {Register.x1: 0xF0, Register.x2: 0x0C},
    );
  });

  // M-extension: mul/div/rem in all widths.
  test('m-ext ops', timeout: Timeout(Duration(minutes: 60)), () async {
    await equiv(
      'm',
      [
        w32(rtype(0x01, 2, 1, 0x0, 3, 0x33)), // mul   x3, x1, x2
        w32(rtype(0x01, 2, 1, 0x1, 4, 0x33)), // mulh  x4, x1, x2
        w32(rtype(0x01, 2, 1, 0x3, 5, 0x33)), // mulhu x5, x1, x2
        w32(rtype(0x01, 2, 1, 0x4, 6, 0x33)), // div   x6, x1, x2
        w32(rtype(0x01, 2, 1, 0x5, 7, 0x33)), // divu  x7, x1, x2
        w32(rtype(0x01, 2, 1, 0x6, 8, 0x33)), // rem   x8, x1, x2
        w32(rtype(0x01, 2, 1, 0x7, 9, 0x33)), // remu  x9, x1, x2
        w32(rtype(0x01, 2, 1, 0x0, 10, 0x3B)), // mulw  x10, x1, x2
        w32(rtype(0x01, 2, 1, 0x4, 11, 0x3B)), // divw  x11, x1, x2
        w32(rtype(0x01, 2, 1, 0x6, 12, 0x3B)), // remw  x12, x1, x2
        w32(jSelf),
      ],
      initRegisters: {Register.x1: 1000, Register.x2: 7},
    );
  });

  // Branches: the flood site is a bltu. Exercise every branch, taken and not.
  // Each branch guards an addi so a wrong branch decode changes the counter.
  test('branch ops', timeout: Timeout(Duration(minutes: 60)), () async {
    await equiv(
      'branch',
      [
        w32(itype(0, 0, 0x0, 5, 0x13)), // addi x5, x0, 0      @0x00
        w32(btype(8, 2, 1, 0x6)), // bltu x1, x2, +8    @0x04 (taken: 3<7)
        w32(itype(1, 5, 0x0, 5, 0x13)), // addi x5, x5, 1     @0x08 (skipped)
        w32(itype(2, 5, 0x0, 5, 0x13)), // addi x5, x5, 2     @0x0C
        w32(
          btype(8, 1, 2, 0x6),
        ), // bltu x2, x1, +8    @0x10 (not taken: 7<3 false)
        w32(itype(4, 5, 0x0, 5, 0x13)), // addi x5, x5, 4     @0x14 (executed)
        w32(btype(8, 1, 1, 0x0)), // beq  x1, x1, +8    @0x18 (taken)
        w32(itype(8, 5, 0x0, 5, 0x13)), // addi x5, x5, 8     @0x1C (skipped)
        w32(
          btype(8, 1, 2, 0x4),
        ), // blt  x2, x1, +8    @0x20 not taken (7<3 signed false)
        w32(itype(16, 5, 0x0, 5, 0x13)), // addi x5,x5,16    @0x24 executed
        w32(jSelf), // @0x28
      ],
      initRegisters: {Register.x1: 3, Register.x2: 7},
    );
  });

  // Store/load roundtrip through a scratch region (base x1 = 0x400, above the
  // program). Covers sd/sw/sh/sb + ld/lw/lh/lb/lhu/lbu/lwu.
  test('load/store ops', timeout: Timeout(Duration(minutes: 60)), () async {
    await equiv(
      'ldst',
      [
        w32(stype(0, 2, 1, 0x3, 0x23)), // sd   x2, 0(x1)
        w32(stype(8, 2, 1, 0x2, 0x23)), // sw   x2, 8(x1)
        w32(stype(16, 2, 1, 0x1, 0x23)), // sh   x2, 16(x1)
        w32(stype(24, 2, 1, 0x0, 0x23)), // sb   x2, 24(x1)
        w32(itype(0, 1, 0x3, 3, 0x03)), // ld   x3, 0(x1)
        w32(itype(8, 1, 0x2, 4, 0x03)), // lw   x4, 8(x1)
        w32(itype(8, 1, 0x6, 5, 0x03)), // lwu  x5, 8(x1)
        w32(itype(16, 1, 0x1, 6, 0x03)), // lh   x6, 16(x1)
        w32(itype(16, 1, 0x5, 7, 0x03)), // lhu  x7, 16(x1)
        w32(itype(24, 1, 0x0, 8, 0x03)), // lb   x8, 24(x1)
        w32(itype(24, 1, 0x4, 9, 0x03)), // lbu  x9, 24(x1)
        w32(jSelf),
      ],
      initRegisters: {Register.x1: 0x400, Register.x2: 0x1122334455667788},
      memProbe: [0x400, 0x408, 0x410, 0x418],
    );
  });

  // Compressed ops: mixed 16/32-bit stream. The flood code is mixed RVC, so
  // any RVC packed-decode error surfaces here. c.li/c.addi/c.mv/c.add/c.sub/
  // c.and/c.or/c.xor/c.slli/c.andi/c.srli.
  test('compressed ops', timeout: Timeout(Duration(minutes: 60)), () async {
    await equiv(
      'rvc',
      [
        w16(0x4291), // c.li  x5, 4       (li rd=x5, imm=4)
        w16(0x02a1), // c.addi x5, x5, 8
        w16(
          0x832d,
        ), // c.mv  x6, x11 ... (placeholder-ish; decode-diff is what matters)
        w16(0x8e0d), // c.sub x12, x11
        w16(0x8e6d), // c.and x12, x11
        w16(0x8e4d), // c.or  x12, x11
        w16(0x8e2d), // c.xor x12, x11
        w16(0x050a), // c.slli x10, 2
        w32(itype(0, 0, 0x0, 0, 0x13)), // addi x0,x0,0 (align to word)
        w32(jSelf),
      ],
      initRegisters: {Register.x10: 0x20, Register.x11: 0x3C},
    );
  });
}
