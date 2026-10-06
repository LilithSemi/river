import 'dart:async';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart' as adl;
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _romBase = 0x1000;
const _romWords = 256;
const _uartBase = 0x10000000;
const _plicBase = 0x0C000000;

/// The source number the UART must get. It is the number the generated device
/// tree reports for the first interrupt-sourcing peripheral, so this test fails
/// if the hardware wiring and the tables ever disagree.
const _uartSource = 1;

/// The trap handler's address: after the leading jump and the landing pad.
const _handlerAddr = _romBase + 8;

/// One PLIC context's register block, at the SiFive offsets.
///
/// Context 0 is the hart's machine context and context 1 its supervisor
/// context, the same order the SoC wires `ext_irq_0`/`ext_irq_1` and the device
/// tree lists in `interrupts-extended`.
class _Context {
  final int index;
  const _Context(this.index);

  int get enable => _plicBase + 0x2000 + index * 0x80;
  int get threshold => _plicBase + 0x200000 + index * 0x1000;
  int get claim => threshold + 4;
}

const _mContext = _Context(0);
const _sContext = _Context(1);

/// Which privilege level the program runs at, and the CSRs it drives.
enum _Level {
  machine(
    context: _mContext,
    tvec: CsrAddress.mtvec,
    ie: CsrAddress.mie,
    status: CsrAddress.mstatus,
    // mie.MEIE(11) and mstatus.MIE(3).
    ieBit: 11,
    statusBit: 3,
  ),
  supervisor(
    context: _sContext,
    tvec: CsrAddress.stvec,
    ie: CsrAddress.sie,
    status: CsrAddress.sstatus,
    // sie.SEIE(9) and sstatus.SIE(1).
    ieBit: 9,
    statusBit: 1,
  );

  const _Level({
    required this.context,
    required this.tvec,
    required this.ie,
    required this.status,
    required this.ieBit,
    required this.statusBit,
  });

  final _Context context;
  final CsrAddress tvec;
  final CsrAddress ie;
  final CsrAddress status;
  final int ieBit;
  final int statusBit;
}

/// Bare-metal program that exercises the whole external-interrupt path for one
/// privilege level.
///
/// A leading jump over the landing pad and the handler puts both at fixed
/// addresses, which the level's trap vector and mepc can then point at.
///
/// Main sets up ONE PLIC context for source [_uartSource], enables external
/// interrupts at that level, then makes the UART raise its interrupt by
/// enabling the transmit-holding-empty source. The handler claims from the same
/// context and writes the claimed number back to the complete register, which
/// the test reads off the core data bus.
class _PlicIrqProgram extends adl.Module {
  @override
  final RiscVIsaConfig isa;

  _PlicIrqProgram({required this.isa, required _Level level}) {
    final main = label('main');
    jal(main);

    // The post-mret landing pad at [_romBase] + 4. The supervisor run spins
    // here, in S-mode, waiting for the device. The machine run never gets here.
    final pad = label('pad');
    jal(pad);

    // The trap handler at [_handlerAddr].
    final claimBase = li(level.context.claim);
    final claimed = lw(claimBase);
    sw(claimBase, claimed);
    final handlerSpin = label('handler_spin');
    jal(handlerSpin);

    placeLabel(main);

    // Setup runs in machine mode, the way firmware does it. An interrupt is
    // delivered to S-mode only when mideleg says so, so the supervisor run
    // delegates the supervisor external interrupt first. Without this the trap
    // targets machine mode and vectors through mtvec, not stvec.
    if (level == _Level.supervisor) {
      csrrw(CsrAddress.mideleg.address, li(1 << 9));
    }

    // Trap vector = handler, direct mode (the low two bits are zero).
    csrrw(level.tvec.address, li(_handlerAddr));

    // Give the source a nonzero priority, then enable it for THIS context only
    // and let everything through that context's threshold. The other context is
    // left untouched, so its line must stay low.
    sw(li(_plicBase + 4), li(1));
    sw(li(level.context.enable), li(1 << _uartSource));
    sw(li(level.context.threshold), zero);

    // External-interrupt enable, then the level's global enable.
    csrrs(level.ie.address, li(1 << level.ieBit));
    csrrs(level.status.address, li(1 << level.statusBit));

    // The device raises its interrupt: UART IER bit 1 is transmit-holding
    // empty, which is true out of reset, so the line goes high at once.
    sb(li(_uartBase), li(0x02), offset: 1);

    if (level == _Level.supervisor) {
      // Drop to supervisor mode at the landing pad. mstatus.MIE stays clear, so
      // the machine level cannot take this interrupt, and the supervisor level
      // only can once the mret lands. The interrupt is already asserted here,
      // which is exactly the case privilege gating has to get right.
      csrrw(CsrAddress.mepc.address, li(_romBase + 4));
      csrrc(CsrAddress.mstatus.address, li(0x1800));
      csrrs(CsrAddress.mstatus.address, li(0x800));
      mret();
    } else {
      final spin = label('spin');
      jal(spin);
    }
  }
}

/// Packs [bytes] into [wordCount] little-endian words of [wordBytes] bytes.
List<int> _toWords(List<int> bytes, int wordBytes, int wordCount) {
  final words = List<int>.filled(wordCount, 0);
  for (var i = 0; i < bytes.length; i++) {
    final w = i ~/ wordBytes;
    if (w >= wordCount) break;
    words[w] |= bytes[i] << (8 * (i % wordBytes));
  }
  return words;
}

typedef _Dut = ({
  HarborSoC soc,
  RiverCore core,
  HarborPlic plic,
  Logic mExtIrq,
  Logic sExtIrq,
  _Level level,
});

/// A minimal River SoC: core, boot ROM, UART and a two-context PLIC on one
/// Wishbone fabric.
///
/// The source wiring is the same [HarborInterruptRouting] call genip makes, and
/// the context order is the same one genip turns into `interrupts-extended`, so
/// this exercises the production path and not a copy of it.
Future<_Dut> _buildSoC({
  required bool connectInterrupts,
  required _Level level,
}) async {
  final sysclk = HarborClockConfig(
    name: 'sysclk',
    rate: HarborFixedClockRate(50000000),
  );
  final busConfig = WishboneConfig(
    addressWidth: 64,
    dataWidth: 64,
    selWidth: 8,
  );

  final coreConfig = RiverCoreConfigV1.small(
    hartId: 0,
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    interrupts: const [],
    clock: sysclk,
    resetVector: _romBase,
  );

  const contexts = [
    HarborInterruptContext.machine(0),
    HarborInterruptContext.supervisor(0),
  ];

  final soc = HarborSoC(
    name: 'irq_test_soc',
    compatible: 'lilith,irq-test-soc',
    busConfig: busConfig,
    interruptContexts: contexts,
    cpus: [HarborCpu(hartId: 0, isa: coreConfig.isa.implementsString)],
  );

  final program = _PlicIrqProgram(isa: coreConfig.isa, level: level);
  await program.build();
  soc.addPeripheral(
    HarborMaskRom(
      baseAddress: _romBase,
      initialData: _toWords(program.generateBinary(), 8, _romWords),
      dataWidth: 64,
      busAddressWidth: 64,
      busDataWidth: 64,
    ),
  );
  final uart = soc.addPeripheral(
    HarborUart(
      baseAddress: _uartBase,
      clockFrequency: 50000000,
      busAddressWidth: 64,
      busDataWidth: 64,
    ),
  );
  // Idle serial line. On a board this is a pad; here it must be driven or the
  // receive sampler holds X and poisons the interrupt output.
  uart.input('rx').srcConnection! <= Const(1);
  final plic = soc.addPeripheral(
    HarborPlic(
      baseAddress: _plicBase,
      sources: 4,
      contexts: contexts.length,
      busAddressWidth: 64,
      busDataWidth: 64,
    ),
  );

  final mExtIrq = Logic(name: 'core0_ext_pending');
  final sExtIrq = Logic(name: 'core0_sei_pending');
  final core = RiverCore(
    coreConfig,
    busConfig: busConfig,
    srcIrqs: {'extPending': mExtIrq},
    supervisorExternalPending: sExtIrq,
  );
  soc.addMaster(core, busInterfaceName: 'dataBus');

  if (connectInterrupts) {
    final routing = HarborInterruptRouting.forSoC(soc)!;
    routing.connectSoCSources(soc);
    mExtIrq <= routing.hartInterrupt(0);
    sExtIrq <= routing.hartInterrupt(1);
  } else {
    // The defect these tests guard against: the PLIC sources dangle and the
    // core has no external interrupt line.
    for (var i = 0; i < plic.sources; i++) {
      plic.input('src_irq_$i').srcConnection! <= Const(0);
    }
    mExtIrq <= Const(0);
    sExtIrq <= Const(0);
  }

  soc.buildFabric();
  return (
    soc: soc,
    core: core,
    plic: plic,
    mExtIrq: mExtIrq,
    sExtIrq: sExtIrq,
    level: level,
  );
}

typedef _Result = ({
  bool mIrqSeen,
  bool sIrqSeen,
  bool handlerReached,
  int? completeWritten,
  int cycles,
});

/// Runs the SoC and reports what the interrupt path did.
Future<_Result> _run(_Dut dut, {int maxCycles = 12000}) async {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'tb_reset');
  dut.soc.port('clk').getsLogic(clk);
  dut.soc.port('reset').getsLogic(reset);

  await dut.soc.build();

  reset.inject(1);
  Simulator.setMaxSimTime(4000000);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.put(0);

  final core = dut.core;
  final cyc = core.output('dataBus_CYC');
  final stb = core.output('dataBus_STB');
  final we = core.output('dataBus_WE');
  final adr = core.output('dataBus_ADR');
  final sel = core.output('dataBus_SEL');
  final datMosi = core.output('dataBus_DAT_MOSI');
  final completeAddr = dut.level.context.claim - 4;

  var mIrqSeen = false;
  var sIrqSeen = false;
  var handlerReached = false;
  int? completeWritten;
  var cycles = 0;

  for (var i = 0; i < maxCycles; i++) {
    await clk.nextPosedge;
    cycles = i;

    if (dut.mExtIrq.value.isValid && dut.mExtIrq.value.toInt() == 1) {
      mIrqSeen = true;
    }
    if (dut.sExtIrq.value.isValid && dut.sExtIrq.value.toInt() == 1) {
      sIrqSeen = true;
    }

    final pc = core.pipeline.nextPc.value;
    if (pc.isValid && pc.toInt() == _handlerAddr) handlerReached = true;

    // The handler writes the claimed source number back to the complete
    // register. That write proves the core took the interrupt AND read the
    // right source out of its own context window.
    //
    // The 64-bit bus puts claim/complete in the upper word lane of the word
    // that also holds the threshold register, so the byte selects tell the two
    // registers apart.
    final active =
        cyc.value.isValid &&
        stb.value.isValid &&
        we.value.isValid &&
        sel.value.isValid &&
        adr.value.isValid &&
        cyc.value.toInt() == 1 &&
        stb.value.toInt() == 1 &&
        we.value.toInt() == 1 &&
        (sel.value.toInt() & 0xF0) != 0;
    if (active && adr.value.toInt() == completeAddr) {
      completeWritten = (datMosi.value.toInt() >> 32) & 0xFFFFFFFF;
      break;
    }
  }

  await Simulator.endSimulation();
  return (
    mIrqSeen: mIrqSeen,
    sIrqSeen: sIrqSeen,
    handlerReached: handlerReached,
    completeWritten: completeWritten,
    cycles: cycles,
  );
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const long = Timeout(Duration(minutes: 25));

  // The budget the negative case runs to. Both positive cases assert they fire
  // well inside it, so a dangling-source run that reaches the end really did
  // have the time to show something, and the negative test cannot go vacuous.
  const deadCycles = 6000;

  test('a UART interrupt reaches the core as a machine interrupt', () async {
    final result = await _run(
      await _buildSoC(connectInterrupts: true, level: _Level.machine),
    );

    expect(result.mIrqSeen, isTrue, reason: 'PLIC never raised ext_irq_0');
    expect(result.handlerReached, isTrue, reason: 'core never took the trap');
    expect(result.completeWritten, equals(_uartSource));
    // Only the machine context was enabled, so the supervisor context must have
    // stayed quiet. A shared enable or threshold block would light both.
    expect(result.sIrqSeen, isFalse, reason: 'S context is not independent');
    expect(result.cycles, lessThan(deadCycles));
  }, timeout: long);

  test('a UART interrupt reaches the core as a supervisor interrupt', () async {
    final result = await _run(
      await _buildSoC(connectInterrupts: true, level: _Level.supervisor),
    );

    expect(result.sIrqSeen, isTrue, reason: 'PLIC never raised ext_irq_1');
    expect(result.handlerReached, isTrue, reason: 'core never took the trap');
    expect(result.completeWritten, equals(_uartSource));
    expect(result.mIrqSeen, isFalse, reason: 'M context is not independent');
    expect(result.cycles, lessThan(deadCycles));
  }, timeout: long);

  test('nothing reaches the core when the sources dangle', () async {
    for (final level in _Level.values) {
      final result = await _run(
        await _buildSoC(connectInterrupts: false, level: level),
        maxCycles: deadCycles,
      );

      expect(result.mIrqSeen, isFalse);
      expect(result.sIrqSeen, isFalse);
      expect(result.handlerReached, isFalse);
      expect(result.completeWritten, isNull);
      await Simulator.reset();
    }
  }, timeout: long);
}
