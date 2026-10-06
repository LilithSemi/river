import 'dart:async';
import 'dart:io';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// An AMO must be indivisible with respect to an async interrupt.
///
/// #91: the core took a timer interrupt in the middle of a microcoded AMO. The
/// whole read-modify-write runs at mopStep==0, so mopStep alone is not a clean
/// instruction boundary. On silicon the posted write commits, but rd and the PC
/// do not retire, so the instruction runs again and applies the operation twice.
/// A ticket spinlock then skips a ticket and deadlocks. exec.dart:988 now gates
/// the interrupt on `mopStep==0 & ~memRead.en & ~memWrite.en & ~rdWrite.en`.
///
/// [amo_ticket_lost_test] proves the AMO alone keeps its increments, but it runs
/// with `interrupts: []` and never fires one. This test fires a timer interrupt
/// REPEATEDLY, at drifting offsets, while an amoadd loop runs through the REAL
/// D-cache with real memory latency. One run therefore lands the interrupt at
/// many different points of the RMW window. The counter must end at exactly N:
/// less than N is a lost increment, more than N is a split RMW applied twice.
///
///   0x00 csrw mtvec, x5        ; x5 = 0x200
///   0x04 csrw mie, x6          ; x6 = MTIE
///   0x08 csrs mstatus, x7      ; x7 = MIE
///   0x0c addi x28, x0, 1       ; increment
///   0x10 addi x29, x0, N       ; count
///   0x14 loop: amoadd.w x30, x28, (x10)   ; x10 = 0x80001000 (cached)
///   0x18 addi x29, x29, -1
///   0x1c bnez x29, loop
///   0x20 jal x0, 0             ; park
///   0x200 mret                 ; handler
Future<Map<String, int>> runLrscIrq({
  required int n,
  required int memLatency,
  required int irqGap,
  int maxCycles = 120000,
}) async {
  await Simulator.reset();

  final config = RiverCoreConfigV1.full(
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    clock: const HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
  );

  const handlerPc = 0x200;
  const parkPc = 0x28;
  const counterAddr = 0x80001000;

  final words = <int, int>{
    0x00: 0x30529073, // csrw mtvec, x5
    0x04: 0x30431073, // csrw mie, x6
    0x08: 0x3003a073, // csrs mstatus, x7
    0x0c: ((n & 0xFFF) << 20) | (29 << 7) | 0x13, // addi x29, x0, N
    // outer: the cmpxchg-shaped retry loop Linux uses.
    0x10: 0x1005332f, // retry: lr.d  x6, (x10)
    0x14: 0x00130313, //        addi  x6, x6, 1
    0x18: 0x186533af, //        sc.d  x7, x6, (x10)
    0x1c: 0xfe039ae3, //        bnez  x7, retry
    0x20: 0xfffe8e93, //        addi  x29, x29, -1
    0x24: 0xfe0e96e3, //        bnez  x29, outer
    0x28: 0x0000006f, // park
    handlerPc: 0x30200073, // mret (touches nothing)
  };

  final bytes = <int, int>{};
  words.forEach((addr, w) {
    for (var b = 0; b < 4; b++) {
      bytes[addr + b] = (w >> (b * 8)) & 0xFF;
    }
  });
  final maxA = bytes.keys.reduce((a, b) => a > b ? a : b);
  final sb = StringBuffer('@0\n');
  for (var a = 0; a <= maxA + 1; a++) {
    sb.write((bytes[a] ?? 0).toRadixString(16).padLeft(2, '0'));
    sb.write(' ');
  }

  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();
  final timerIrq = Logic(name: 'timerIrq');

  final addrWidth = config.mxlen.size;
  final wbConfig = WishboneConfig(
    addressWidth: addrWidth,
    dataWidth: config.mxlen.size,
    selWidth: config.mxlen.size ~/ 8,
  );

  final prfSeedMode = Logic(name: 'prfSeedMode');
  final core = RiverCore(
    config,
    busConfig: wbConfig,
    prfSeedMode: prfSeedMode,
    timerPending: timerIrq,
  );

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
    [wrapReadForRegisterFile(memRead, clk: clk, readLatency: memLatency)],
    readLatency: memLatency,
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

  final initRegisters = {
    Register.x5: handlerPc, // mtvec
    Register.x6: 1 << 7, // MTIE
    Register.x7: 1 << 3, // MIE
    Register.x10: counterAddr,
  };

  reset.inject(1);
  timerIrq.inject(0);
  seedGate.inject(1);
  prfSeedMode.inject(1);

  Simulator.registerAction(20, () {
    reset.put(0);
    storage.loadMemString(sb.toString());
  });

  Simulator.setMaxSimTime(40000000);
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

  // Fire the timer again and again, with a gap that drifts, so the interrupt
  // lands at many different points of the AMO read-modify-write window. The
  // handler is one mret and cannot clear MTIP itself, so the testbench lowers
  // the line as soon as the handler is reached.
  var irqHigh = false;
  var taken = 0;
  var nextRaise = 60;
  var gapIndex = 0;
  var reachedPark = false;

  for (var i = 0; i < maxCycles; i++) {
    await clk.nextPosedge;

    if (!irqHigh && i >= nextRaise) {
      timerIrq.inject(1);
      irqHigh = true;
    }

    final pc = core.pipeline.nextPc.value;
    if (!pc.isValid) continue;
    final p = pc.toInt();

    if (irqHigh && p == handlerPc) {
      timerIrq.inject(0);
      irqHigh = false;
      taken++;
      // A drifting gap (coprime steps) walks the raise point across the whole
      // AMO window instead of locking onto one alignment.
      gapIndex++;
      // The gap MUST exceed one amoadd iteration or the loop never advances:
      // microcode decode is slow here, so an iteration is hundreds of cycles
      // and a short gap re-interrupts the same AMO forever. A drifting gap in
      // the 400 to 800 range leaves room for progress and still walks the raise
      // point across the read-modify-write window.
      nextRaise = i + irqGap + (gapIndex * 7) % 11;
    }

    if (p == parkPc) {
      reachedPark = true;
      break;
    }
  }

  for (var i = 0; i < 40; i++) {
    await clk.nextPosedge;
  }

  final counter = storage
      .getData(LogicValue.ofInt(counterAddr, config.mxlen.size))
      ?.toInt();
  final x29 = core.regs
      .getData(LogicValue.ofInt(Register.x29.value, 5))
      ?.toInt();
  final x30 = core.regs
      .getData(LogicValue.ofInt(Register.x30.value, 5))
      ?.toInt();

  await Simulator.endSimulation();
  await Simulator.simulationEnded;

  return {
    'reachedPark': reachedPark ? 1 : 0,
    'taken': taken,
    'counter': counter ?? -1,
    'x29': x29 ?? -1,
    'x30': x30 ?? -1,
  };
}

void main() {
  // Does clearing the reservation on EVERY trap livelock a cmpxchg loop?
  //
  // exec.dart now drops the LR/SC reservation on any trap. That is what makes
  // an interrupted cmpxchg fail correctly instead of destroying the handler's
  // write. But if an interrupt lands inside the lr -> sc window MORE OFTEN than
  // the window completes, the SC can never succeed and the loop spins forever.
  // On delta the microcode decode is slow, so that window is long.
  //
  // Each case runs N successful increments through a retry loop while the timer
  // fires every `irqGap` cycles. Small gaps are the dangerous ones. Reaching the
  // park PC means the loop still makes progress.
  for (final gap in [400, 200, 100, 50, 25]) {
    test(
      'cmpxchg retry loop still completes with a timer IRQ every ~$gap cycles',
      timeout: Timeout(Duration(minutes: 20)),
      () async {
        const n = 4;
        final r = await runLrscIrq(n: n, memLatency: 0, irqGap: gap);
        expect(
          r['reachedPark'],
          1,
          reason:
              'LIVELOCK: counter=${r['counter']} after ${r['taken']} IRQs '
              'at gap=$gap; the sc.d never succeeded',
        );
        expect(r['counter'], n, reason: 'lost or doubled an increment');
      },
    );
  }
}
