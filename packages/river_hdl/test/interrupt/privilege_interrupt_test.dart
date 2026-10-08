import 'dart:async';

import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:test/test.dart';

import '../adversarial_memory.dart';

int csr(int address, int source, int funct3, int dest) =>
    (address << 20) | (source << 15) | (funct3 << 12) | (dest << 7) | 0x73;
int addi(int dest, int value) => ((value & 0xfff) << 20) | (dest << 7) | 0x13;

RiverCoreConfig configuration(bool microcoded, RiscVMxlen xlen) =>
    RiverCoreConfig(
      resetVector: 0,
      clock: const HarborClockConfig(
        name: 'test',
        rate: HarborFixedClockRate(12000000),
      ),
      mxlen: xlen,
      extensions: [if (xlen == RiscVMxlen.rv64) rv64i, rv32i, rvPriv, rvZicsr],
      microcodeMode: microcoded ? MicrocodeMode.full : MicrocodeMode.none,
      interrupts: [],
      mmu: HarborMmuConfig(
        mxlen: xlen,
        pagingModes: const [RiscVPagingMode.bare],
        tlbLevels: const [],
        pmp: HarborPmpConfig.none,
      ),
      type: RiverCoreType.general,
    );

/// Enter the tested privilege through MRET with pending sources already set.
/// MIE stays zero until MRET; MPIE supplies the requested post-return MIE.
Map<int, int> program({
  required int mode,
  required int enabled,
  required int pending,
  int delegated = 0,
  bool mie = false,
  bool sie = false,
  bool wfi = false,
}) {
  final boot = <int>[];
  void load(int value) {
    boot.add(((value + 0x800) & 0xfffff000) | (5 << 7) | 0x37);
    boot.add(((value & 0xfff) << 20) | (5 << 15) | (5 << 7) | 0x13);
  }

  void write(int address, int value) {
    load(value);
    boot.add(csr(address, 5, 1, 0));
  }

  write(0x305, 0x400);
  write(0x105, 0x500);
  write(0x341, 0x100);
  write(0x303, delegated);
  write(0x304, enabled);
  write(0x344, pending & ((1 << 1) | (1 << 5) | (1 << 9)));
  write(0x300, (mode << 11) | (mie ? 1 << 7 : 0) | (sie ? 1 << 1 : 0));
  boot.add(0x30200073);
  return {
    for (var i = 0; i < boot.length; i++) i * 4: boot[i],
    0x100: addi(30, 1), // entered the test body
    0x104: wfi ? 0x10500073 : 0x0000006f,
    0x108: addi(29, 1), // resumed after WFI
    0x10c: 0x0000006f,
    for (final handler in [
      (0x400, 0x342, 0x341, 3),
      (0x500, 0x142, 0x141, 1),
    ]) ...{
      handler.$1: csr(handler.$2, 0, 2, 21),
      handler.$1 + 4: csr(handler.$3, 0, 2, 22),
      handler.$1 + 8: addi(24, handler.$4),
      handler.$1 + 12: addi(31, 1),
      handler.$1 + 16: 0x0000006f,
    },
  };
}

String memoryImage(Map<int, int> words) {
  final out = StringBuffer();
  for (final entry in words.entries) {
    out.write('@${entry.key.toRadixString(16)}\n');
    for (var byte = 0; byte < 4; byte++) {
      out.write(
        '${((entry.value >> (8 * byte)) & 255).toRadixString(16).padLeft(2, '0')} ',
      );
    }
    out.writeln();
  }
  return out.toString();
}

Future<void> runProgram(
  bool microcoded,
  RiscVMxlen xlen,
  Map<int, int> words, {
  required int pending,
  required FutureOr<void> Function(RiverCore core, List<Logic> lines, int cycle)
  observe,
  required void Function(RiverCore core) check,
  bool delayed = false,
}) async {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic()..inject(1);
  // MEI, MTI, MSI, SEI. Supervisor software/timer bits are set by the program.
  final lines = List.generate(4, (i) => Logic(name: 'irq$i')..inject(0));
  const bits = [11, 7, 3, 9];
  final core = RiverCore(
    configuration(microcoded, xlen),
    busConfig: WishboneConfig(
      addressWidth: xlen.size,
      dataWidth: xlen.size,
      selWidth: xlen.size ~/ 8,
    ),
    srcIrqs: {'external': lines[0]},
    timerPending: lines[1],
    swPending: lines[2],
    supervisorExternalPending: lines[3],
  );
  core.input('clk').srcConnection! <= clk;
  core.input('reset').srcConnection! <= reset;
  await core.build();
  final storage = SparseMemoryStorage(
    addrWidth: xlen.size,
    dataWidth: xlen.size,
    alignAddress: (address) => address,
    onInvalidRead: (_, width) => LogicValue.filled(width, LogicValue.zero),
  );
  final ack = Logic();
  final data = Logic(width: xlen.size);
  attachAdversarialMemory(
    clk: clk,
    reset: reset,
    storage: storage,
    dataWidth: xlen.size,
    cyc: core.output('dataBus_CYC'),
    stb: core.output('dataBus_STB'),
    we: core.output('dataBus_WE'),
    adr: core.output('dataBus_ADR'),
    datMosi: core.output('dataBus_DAT_MOSI'),
    sel: core.output('dataBus_SEL'),
    ack: ack,
    miso: data,
    behaviour: const AdversarialMemory(readLatency: 1),
  );
  core.input('dataBus_ACK').srcConnection! <= ack;
  core.input('dataBus_DAT_MISO').srcConnection! <= data;
  Simulator.setMaxSimTime(30000);
  unawaited(Simulator.run());
  try {
    await clk.nextNegedge;
    await clk.nextNegedge;
    reset.inject(0);
    storage.loadMemString(memoryImage(words));
    if (!delayed) {
      for (var i = 0; i < lines.length; i++) {
        lines[i].inject((pending >> bits[i]) & 1);
      }
    }
    for (var cycle = 0; cycle < 1800; cycle++) {
      await clk.nextNegedge;
      await observe(core, lines, cycle);
      if (reg(core, 31) == 1) break;
    }
    check(core);
  } finally {
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }
}

int reg(RiverCore core, int number) =>
    core.regs.getData(LogicValue.ofInt(number, 5))!.toInt();

void main() {
  tearDown(Simulator.reset);
  for (final microcoded in [false, true]) {
    for (final xlen in [RiscVMxlen.rv32, RiscVMxlen.rv64]) {
      group('${microcoded ? "microcoded" : "static"} RV${xlen.size}', () {
        // (name, source bit, current privilege, delegated, MIE, SIE, target).
        // target=0 means no eligible interrupt, not a U-mode trap.
        for (final c in [
          ('undelegated SSI in M', 1, 3, false, true, false, 3),
          ('undelegated STI in M', 5, 3, false, true, false, 3),
          ('undelegated SEI in M', 9, 3, false, true, false, 3),
          (
            'undelegated STI masks with MIE not SIE',
            5,
            3,
            false,
            false,
            true,
            0,
          ),
          (
            'undelegated STI preempts S with globals off',
            5,
            1,
            false,
            false,
            false,
            3,
          ),
          (
            'undelegated STI preempts U with globals off',
            5,
            0,
            false,
            false,
            false,
            3,
          ),
          ('delegated STI stays masked in M', 5, 3, true, true, true, 0),
          ('delegated STI in S', 5, 1, true, false, true, 1),
          ('delegated STI masks with SIE not MIE', 5, 1, true, true, false, 0),
          (
            'delegated STI preempts U with SIE off',
            5,
            0,
            true,
            false,
            false,
            1,
          ),
          ('MEI in M', 11, 3, false, true, false, 3),
          ('MTI preempts S with globals off', 7, 1, false, false, false, 3),
          ('MSI preempts U with globals off', 3, 0, false, false, false, 3),
          ('delegated hardware SEI in S', 9, 1, true, false, true, 1),
        ]) {
          test(c.$1, () async {
            final pending = 1 << c.$2;
            await runProgram(
              microcoded,
              xlen,
              program(
                mode: c.$3,
                enabled: pending,
                pending: pending,
                delegated: c.$4 ? pending : 0,
                mie: c.$5,
                sie: c.$6,
              ),
              pending: pending,
              observe: (_, __, ___) {},
              check: (core) {
                expect(reg(core, 24), c.$7, reason: 'wrong handler privilege');
                if (c.$7 == 0) {
                  expect(reg(core, 30), 1, reason: 'main body never reached');
                  expect(reg(core, 31), 0, reason: 'masked source trapped');
                } else {
                  expect(reg(core, 31), 1, reason: 'handler did not finish');
                  expect(reg(core, 21), (1 << (xlen.size - 1)) | c.$2);
                  expect(reg(core, 22), isIn([0x100, 0x104]));
                }
              },
            );
          }, timeout: const Timeout(Duration(minutes: 3)));
        }
        for (final source in [3, 7, 11, 9]) {
          test('WFI wakes for source $source with globals off', () async {
            var sent = false;
            var parkedCycles = 0;
            await runProgram(
              microcoded,
              xlen,
              program(
                mode: 3,
                enabled: 1 << source,
                pending: 0,
                delegated: source == 9 ? 1 << source : 0,
                wfi: true,
              ),
              pending: 0,
              delayed: true,
              observe: (core, lines, cycle) {
                if (reg(core, 30) == 1 && ++parkedCycles == 80) {
                  lines[[11, 7, 3, 9].indexOf(source)].inject(1);
                  sent = true;
                }
              },
              check: (core) {
                expect(sent, isTrue, reason: 'never entered test body');
                expect(reg(core, 29), 1, reason: 'did not resume after WFI');
                expect(reg(core, 31), 0, reason: 'wake fabricated a trap');
              },
            );
          }, timeout: const Timeout(Duration(minutes: 3)));
        }
      });
    }
  }
}
