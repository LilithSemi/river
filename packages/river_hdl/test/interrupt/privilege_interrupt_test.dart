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
  // One contiguous byte image packs both RV32 and RV64 memory words. Separate
  // four-byte @address records would leave holes inside RV64 fetch beats.
  final out = StringBuffer('@0\n');
  final end = words.keys.reduce((a, b) => a > b ? a : b);
  for (var address = 0; address <= end + 4; address += 4) {
    final word = words[address] ?? 0x13;
    for (var byte = 0; byte < 4; byte++) {
      out.write(
        '${((word >> (8 * byte)) & 255).toRadixString(16).padLeft(2, '0')} ',
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
  // RV64 microcode uses substantially more cycles for the boot CSR sequence.
  // Leave room for the complete handler, not just its first CSR read.
  final maxCycles = microcoded && xlen == RiscVMxlen.rv64 ? 4000 : 1800;
  Simulator.setMaxSimTime((maxCycles + 100) * 10);
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
    for (var cycle = 0; cycle < maxCycles; cycle++) {
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

Iterable<Module> descendants(Module module) sync* {
  yield module;
  for (final child in module.subModules) {
    yield* descendants(child);
  }
}

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
                pending: c.$2 == 9 ? 0 : pending,
                delegated: c.$4 ? pending : 0,
                mie: c.$5,
                sie: c.$6,
              ),
              pending: pending,
              observe: (_, _, _) {},
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
        // Target privilege wins before the source priority within that target.
        for (final c in [
          ('M SSI outranks S SEI', (1 << 1) | (1 << 9), 1 << 9, 1, 3),
          ('M STI outranks S SSI', (1 << 5) | (1 << 1), 1 << 1, 5, 3),
          ('M MEI outranks M MTI', (1 << 11) | (1 << 7), 0, 11, 3),
          ('M SSI outranks M STI', (1 << 1) | (1 << 5), 0, 1, 3),
          (
            'S SEI outranks S SSI',
            (1 << 9) | (1 << 1),
            (1 << 9) | (1 << 1),
            9,
            1,
          ),
        ]) {
          test(c.$1, () async {
            await runProgram(
              microcoded,
              xlen,
              program(
                mode: 1,
                enabled: c.$2,
                pending: c.$2 & ~(1 << 9),
                delegated: c.$3,
                sie: true,
              ),
              pending: c.$2,
              observe: (_, _, _) {},
              check: (core) {
                expect(reg(core, 31), 1, reason: 'handler did not finish');
                expect(reg(core, 24), c.$5);
                expect(reg(core, 21), (1 << (xlen.size - 1)) | c.$4);
                expect(reg(core, 22), isIn([0x100, 0x104]));
              },
            );
          }, timeout: const Timeout(Duration(minutes: 3)));
        }
        for (final source in [1, 5, 7, 9, 11]) {
          test('local enable masks source $source', () async {
            await runProgram(
              microcoded,
              xlen,
              program(
                mode: 3,
                enabled: 0,
                pending: source == 9 ? 0 : 1 << source,
                mie: true,
                sie: true,
              ),
              pending: 1 << source,
              observe: (_, _, _) {},
              check: (core) {
                expect(reg(core, 30), 1);
                expect(reg(core, 31), 0);
                expect(reg(core, 24), 0);
              },
            );
          }, timeout: const Timeout(Duration(minutes: 3)));
        }
        for (final change in [
          'mie',
          'mstatus',
          'mideleg',
          'pending',
          'priority',
        ]) {
          test(
            'revalidate unaccepted candidate after $change changes',
            () async {
              final code = program(
                mode: 3,
                enabled: (1 << 7) | (change == 'priority' ? 1 << 11 : 0),
                pending: 0,
                mie: true,
              );
              final address = switch (change) {
                'mie' => 0x304,
                'mstatus' => 0x300,
                'mideleg' => 0x303,
                _ => 0x340, // scratch CSR supplies a multicycle boundary
              };
              code.addAll({
                0x104: addi(5, change == 'mideleg' ? 1 << 7 : 0),
                0x108: csr(address, 5, 1, 0),
                0x10c: addi(29, 1),
                0x110: 0x0000006f,
              });
              ExecutionUnit? exec;
              RiscVCsrFile? csrs;
              Logic? step;
              var armed = false;
              var candidateSeen = false;
              var changed = false;
              var checked = false;
              await runProgram(
                microcoded,
                xlen,
                code,
                pending: 0,
                delayed: true,
                observe: (core, lines, cycle) {
                  exec ??= descendants(
                    core.pipeline,
                  ).whereType<ExecutionUnit>().single;
                  csrs ??= descendants(core).whereType<RiscVCsrFile>().single;
                  step ??= exec!.internalSignals.singleWhere(
                    (s) => s.name == 'mopStep',
                  );
                  final take = core.pipeline.input('interruptTake');
                  if (!armed &&
                      exec!.currentPc.value.toInt() == 0x108 &&
                      exec!.input('enable').value.toBool() &&
                      step!.value.toInt() != 0 &&
                      exec!.csrRead!.en.value.toBool() &&
                      exec!.csrRead!.addr.value.toInt() == address) {
                    lines[1].inject(1);
                    armed = true;
                  }
                  if (armed && take.value.toBool()) {
                    candidateSeen = true;
                    if ((change == 'pending' || change == 'priority') &&
                        !changed) {
                      lines[change == 'pending' ? 1 : 0].inject(
                        change == 'pending' ? 0 : 1,
                      );
                      changed = true;
                    }
                  }
                  final invalid =
                      armed &&
                      switch (change) {
                        'mie' => csrs!.mie.value[7] == LogicValue.zero,
                        'mstatus' => csrs!.mstatus.value[3] == LogicValue.zero,
                        'mideleg' => csrs!.mideleg.value[7] == LogicValue.one,
                        'priority' =>
                          changed && csrs!.mip.value[11] == LogicValue.one,
                        _ => changed && csrs!.mip.value[7] == LogicValue.zero,
                      };
                  if (invalid) {
                    // This checks the candidate interface, before acceptance;
                    // it does not demand cancellation of an already taken trap.
                    if (change == 'priority') {
                      if (take.value.toBool()) {
                        expect(
                          core.pipeline.input('interruptCause').value.toInt(),
                          11,
                          reason:
                              'lower-priority candidate survived MEI assertion',
                        );
                      }
                    } else {
                      expect(
                        take.value.toBool(),
                        isFalse,
                        reason:
                            '$change changed but candidate remains eligible',
                      );
                    }
                    checked = true;
                  }
                },
                check: (core) {
                  expect(armed, isTrue);
                  expect(
                    candidateSeen,
                    isTrue,
                    reason: 'no registered candidate exercised',
                  );
                  expect(
                    checked,
                    isTrue,
                    reason: 'no eligibility change exercised',
                  );
                  if (change == 'priority') {
                    expect(reg(core, 31), 1);
                    expect(reg(core, 21), (1 << (xlen.size - 1)) | 11);
                    expect(reg(core, 24), 3);
                    expect(reg(core, 22), isIn([0x10c, 0x110]));
                  } else {
                    expect(
                      reg(core, 29),
                      1,
                      reason: 'CSR sequence did not finish',
                    );
                    expect(reg(core, 31), 0, reason: 'stale candidate trapped');
                  }
                },
              );
            },
            timeout: const Timeout(Duration(minutes: 3)),
          );
        }
        test('accepted interrupt completes after pending deasserts', () async {
          var deasserted = false;
          await runProgram(
            microcoded,
            xlen,
            program(mode: 3, enabled: 1 << 7, pending: 0, mie: true),
            pending: 1 << 7,
            observe: (core, lines, cycle) {
              if (core.pipeline.trap.value.toBool() &&
                  core.pipeline.trapInterrupt.value.toBool()) {
                lines[1].inject(0);
                deasserted = true;
              }
            },
            check: (core) {
              expect(deasserted, isTrue);
              expect(reg(core, 31), 1);
              expect(reg(core, 24), 3);
              expect(reg(core, 21), (1 << (xlen.size - 1)) | 7);
            },
          );
        }, timeout: const Timeout(Duration(minutes: 3)));
        // WFI may legally be a NOP (both current executors use that option).
        // Check forward progress without fabricating a globally masked trap;
        // do not require sleeping, or introduce blocking solely for this test.
        for (final source in [3, 7, 11, 9]) {
          test('WFI progresses for source $source with globals off', () async {
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
