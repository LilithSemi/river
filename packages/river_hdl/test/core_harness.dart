import 'dart:async';
import 'dart:io';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

import 'adversarial_memory.dart';

Future<void> coreTest(
  String memString,
  Map<Register, int> regStates,
  RiverCoreConfig config, {
  Map<int, int> memStates = const {},
  Map<Register, int> initRegisters = const {},
  int nextPc = 4,
  int latency = 0,
  int memLatency = 0,
  // Privilege the core holds coming out of reset. Defaults to machine (real
  // RISC-V reset). Set to supervisor/user to exercise paged data translation
  // without a boot-time mret: M-mode data accesses are always physical.
  PrivilegeMode? startPriv,
  // Cycle budget to reach nextPc. A wedged core never reaches it, so a small
  // budget lets a repro fail in seconds instead of grinding the full default.
  int maxCycles = 200000,
  // Raise the machine-timer-pending line (mip.MTIP) at this run-loop cycle to
  // inject an async timer interrupt mid-execution. Null = never (no interrupt
  // input wired, so existing callers are unaffected).
  int? raiseTimerIrqAt,
  // Lower mip.MTIP at this run-loop cycle, modelling the handler clearing the
  // timer (an mtimecmp write) so the interrupt is taken once and does not storm
  // on every mret. Null = leave it asserted (level) once raised.
  int? lowerTimerIrqAt,
  // Repeating machine-timer interrupt. When set, mip.MTIP is raised for
  // [timerIrqHigh] cycles every [timerIrqPeriod] cycles, starting at
  // [timerIrqStart]. A period that does not divide the loop length walks the
  // take across every phase of the instruction stream in ONE simulation, which
  // is what makes a sweep affordable: building this core costs far more than
  // running it. Overrides raiseTimerIrqAt/lowerTimerIrqAt.
  int? timerIrqPeriod,
  int timerIrqHigh = 6,
  int timerIrqStart = 40,
  // Memory behaviour. Null takes RIVER_MEM_* from the environment, and with no
  // RIVER_MEM_* set the harness keeps the instantaneous MemoryModel it always
  // had. See adversarial_memory.dart.
  AdversarialMemory? memory,
}) async {
  final behaviour = memory ?? AdversarialMemory.fromEnvironment();
  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();
  final timerIrq = (raiseTimerIrqAt == null && timerIrqPeriod == null)
      ? null
      : Logic(name: 'timerIrq');

  final addrWidth = config.mxlen.size;
  final wbConfig = WishboneConfig(
    addressWidth: addrWidth,
    dataWidth: config.mxlen.size,
    selWidth: config.mxlen.size ~/ 8,
  );

  // Drives the OoO physical-regfile backdoor seed: while high, a regWritePort
  // write also lands in the OoO prf so initRegisters reaches the OoO read path.
  final prfSeedMode = Logic(name: 'prfSeedMode');

  final core = RiverCore(
    config,
    busConfig: wbConfig,
    prfSeedMode: prfSeedMode,
    resetPrivilege: startPriv?.id,
    timerPending: timerIrq,
  );
  timerIrq?.inject(0);

  core.input('clk').srcConnection! <= clk;
  core.input('reset').srcConnection! <= reset;

  await core.build();

  // Optional VCD dump for debugging (set RIVER_WAVE=/path/to.vcd).
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

  final wbCyc = core.output('dataBus_CYC');
  final wbStb = core.output('dataBus_STB');
  final wbWe = core.output('dataBus_WE');
  final wbAdr = core.output('dataBus_ADR');
  final wbDatMosi = core.output('dataBus_DAT_MOSI');

  // While `seedGate` is high we starve the data-bus acknowledge so the fetcher
  // stalls on its first read and the pipeline cannot retire anything. This lets
  // us backdoor-seed the register file one entry per clock edge (the regfile has
  // a single write port and clears all entries while `reset` is asserted, so the
  // seed must happen post-reset, with the core held) before instructions run.
  final seedGate = Logic(name: 'seedGate');

  AdversarialWishboneSlave? adversary;
  if (behaviour != null) {
    // A memory that is allowed to be slow, to queue and to post. It replaces
    // the MemoryModel and its acknowledge register, and drives the same two
    // core inputs. `memLatency` folds into the read latency.
    final ack = Logic(name: 'advAck');
    final miso = Logic(name: 'advMiso', width: config.mxlen.size);
    adversary = attachAdversarialMemory(
      clk: clk,
      reset: reset,
      storage: storage,
      dataWidth: config.mxlen.size,
      cyc: wbCyc,
      stb: wbStb,
      we: wbWe,
      adr: wbAdr,
      datMosi: wbDatMosi,
      sel: core.output('dataBus_SEL'),
      ack: ack,
      miso: miso,
      behaviour: behaviour,
    );
    core.input('dataBus_ACK').srcConnection! <= ack & ~seedGate;
    core.input('dataBus_DAT_MISO').srcConnection! <= miso;
  } else {
    // Bridge Wishbone master to MemoryModel
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

    memRead.en <= wbCyc & wbStb & ~wbWe;
    memRead.addr <= wbAdr;
    memWrite.en <= wbCyc & wbStb & wbWe;
    memWrite.addr <= wbAdr;
    memWrite.data <= wbDatMosi;

    // wbAck honors the read port's latency: for reads, only acknowledge when the
    // slave actually has data ready (memRead.valid, `done` asserts immediately on
    // `en`, it only means the request was accepted). Writes are combinational, so
    // a one-cycle ack is correct.
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
    core.input('dataBus_ACK').srcConnection! <= wbAckReg & ~seedGate;
    core.input('dataBus_DAT_MISO').srcConnection! <= memRead.data;
  }

  reset.inject(1);
  seedGate.inject(initRegisters.isNotEmpty ? 1 : 0);
  // High through the seed window; the prf write is additionally gated by
  // regWritePort.en (in core.dart) so it only lands on an actual seed write.
  prfSeedMode.inject(initRegisters.isNotEmpty ? 1 : 0);

  Simulator.registerAction(20, () {
    reset.put(0);
    storage.loadMemString(memString);
  });

  Simulator.setMaxSimTime(4000000);
  unawaited(Simulator.run());

  await clk.nextPosedge;

  // Seed the register file one entry per clock edge (single write port). The
  // core is held by `seedGate` (no bus acks), so none of these writes races a
  // pipeline read-back.
  for (final regState in initRegisters.entries) {
    core.regWritePort.en.inject(1);
    core.regWritePort.addr.inject(LogicValue.ofInt(regState.key.value, 5));
    core.regWritePort.data.inject(
      LogicValue.ofInt(regState.value, config.mxlen.size),
    );
    await clk.nextPosedge;
  }

  // Disable register write port and release the core to run.
  core.regWritePort.en.inject(0);
  seedGate.inject(0);
  prfSeedMode.inject(0);

  while (reset.value.toBool()) {
    await clk.nextPosedge;
  }

  final trace = Platform.environment['RIVER_TRACE']?.isNotEmpty ?? false;
  final distinctPcs = <int>[];
  var reached = false;
  for (var i = 0; i < maxCycles; i++) {
    await clk.nextPosedge;
    if (timerIrqPeriod != null) {
      final phase = i - timerIrqStart;
      timerIrq!.inject(
        (phase >= 0 && (phase % timerIrqPeriod) < timerIrqHigh) ? 1 : 0,
      );
    } else {
      if (i == raiseTimerIrqAt) timerIrq!.inject(1);
      if (i == lowerTimerIrqAt) timerIrq!.inject(0);
    }
    final pc = core.pipeline.nextPc.value;
    if (trace && pc.isValid) {
      final v = pc.toInt();
      if (distinctPcs.isEmpty || distinctPcs.last != v) distinctPcs.add(v);
    }
    if (pc.isValid && pc.toInt() == nextPc) {
      reached = true;
      break;
    }
  }
  if (trace && !reached) {
    final tail = distinctPcs.length > 40
        ? distinctPcs.sublist(distinctPcs.length - 40)
        : distinctPcs;
    // ignore: avoid_print
    print(
      '[TRACE] did not reach 0x${nextPc.toRadixString(16)}; last PCs: '
      '${tail.map((p) => '0x${p.toRadixString(16)}').join(' ')}',
    );
    for (final r in [Register.x1, Register.x5, Register.x6, Register.x10]) {
      final rv = core.regs.getData(LogicValue.ofInt(r.value, 5));
      // ignore: avoid_print
      print('[TRACE] $r = 0x${rv?.toInt().toRadixString(16)}');
    }
  }

  // A posted write is acknowledged but not yet in storage. Commit the queue so
  // a pending write is not read back as a lost one.
  adversary?.flush();

  await Simulator.endSimulation();
  await Simulator.simulationEnded;

  expect(core.pipeline.done.value.toBool(), isTrue);
  expect(core.pipeline.nextPc.value.toInt(), nextPc);

  for (final regState in regStates.entries) {
    final value = core.regs.getData(LogicValue.ofInt(regState.key.value, 5))!;
    expect(value.toInt(), regState.value, reason: '${regState.key}=$value');
  }

  for (final memState in memStates.entries) {
    expect(
      storage
          .getData(LogicValue.ofInt(memState.key, config.mxlen.size))!
          .toInt(),
      memState.value,
    );
  }
}
