import 'dart:async';

import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart' as emu;
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

import 'adversarial_memory.dart';
import 'matrix_configs.dart';

/// Shared engine for the River test matrix. A matrix FILE is one config; it calls
/// [runMatrix] with the config and the list of instruction [MatrixCell]s that
/// apply to it. The config's HDL core is elaborated ONCE (setUpAll), then every
/// cell runs as an emulator-vs-HDL parity check against that single built core,
/// so the expensive ROHD build is amortized across all the cells.
///
/// Ordering matters: the emulator goldens are computed in setUpAll BEFORE the HDL
/// Simulator is started. Running the emulator (whose async fetch/cycle awaits)
/// while the microtask-driven ROHD Simulator is live would interleave and desync
/// the HDL clock control, so the golden pass is done up front, pure Dart.
class MatrixCell {
  /// Test-case name, e.g. 'mul' or 'amocas.d (match)'. Becomes the cell name.
  final String name;

  /// Instruction words at 0, 4, 8, ... (end with a nop at [nextPc]).
  final List<int> program;

  /// Backdoor-seeded GPRs before the program runs.
  final Map<Register, int> seed;

  /// Pre-loaded data memory: address -> words.
  final Map<int, List<int>> dataMem;

  /// GPRs to compare HDL vs golden.
  final List<Register> checkRegs;

  /// 64-bit memory words to compare HDL vs golden.
  final List<int> checkMem;

  /// PC the program halts at (the trailing nop).
  final int nextPc;

  const MatrixCell(
    this.name,
    this.program, {
    this.seed = const {},
    this.dataMem = const {},
    this.checkRegs = const [],
    this.checkMem = const [],
    required this.nextPc,
  });
}

/// Register the matrix cells for one [config] as a single test named [label],
/// building the HDL core once and running every cell against it.
///
/// IMPORTANT: this is ONE test(), not a group of per-cell tests. The HDL
/// Simulator is started with `unawaited(Simulator.run())`, and its microtask-
/// driven clock only advances within the async context that started it. Spread
/// across separate test() cases (via setUpAll), `clk.nextPosedge` in a later
/// test never completes and the cell hangs. Keeping the build + all cell runs in
/// one async body keeps the clock alive. Per-cell localization is preserved in
/// the failure message, which names every broken cell.
void runMatrix(
  String label,
  RiverCoreConfig config,
  List<MatrixCell> cells, {
  Object? skip,
  int? highMemBase,
  int highMemSize = 0x10000,
  Duration timeout = const Duration(minutes: 10),
  // Memory behaviour. Null takes RIVER_MEM_* from the environment, and with no
  // RIVER_MEM_* set the harness keeps the instantaneous MemoryModel it always
  // had. See adversarial_memory.dart.
  AdversarialMemory? memory,
}) {
  test(label, skip: skip, () async {
    // Emulator goldens FIRST (pure Dart, before the Simulator starts).
    final goldens = <String, _Golden>{};
    for (final cell in cells) {
      goldens[cell.name] = await _emulatorGolden(
        config,
        cell,
        highMemBase: highMemBase,
        highMemSize: highMemSize,
      );
    }
    // Build the HDL core ONCE (starts the Simulator in this body's context).
    final mc = await _MatrixCore.build(config, memory: memory);
    // Run every cell against the one built core; collect, don't throw, so all
    // cells run and the message lists every failure.
    final failures = <String>[];
    for (final cell in cells) {
      final err = await mc.runHdl(cell, goldens[cell.name]!);
      if (err != null) failures.add('  ${cell.name}: $err');
    }
    await mc.dispose();
    expect(
      failures,
      isEmpty,
      reason:
          '${failures.length}/${cells.length} cells failed:\n'
          '${failures.join('\n')}',
    );
  }, timeout: Timeout(timeout));
}

/// Golden architectural state for a cell (computed by the emulator).
class _Golden {
  final Map<Register, int> regs;
  final Map<int, int> mem;
  _Golden(this.regs, this.mem);
}

/// A golden vector: a program with HAND-VERIFIED expected results (independent
/// truth, NOT emulator-computed). [runGolden] asserts BOTH the emulator AND the
/// HDL match these expected values. This closes the gap the matrix cells leave
/// open: matrix cells check emulator-vs-HDL parity, so a bug PRESENT IN BOTH
/// (or where one is accidentally right) can hide; the golden group pins each
/// engine to external truth (it is exactly what would have independently caught
/// the emulator bltu/bgeu bug) and confirms emulator<->HDL determinism.
class GoldenCell {
  final String name;
  final List<int> program;
  final Map<Register, int> seed;
  final Map<int, List<int>> dataMem;
  final Map<Register, int> expectedRegs;
  final Map<int, int> expectedMem;
  final int nextPc;

  const GoldenCell(
    this.name,
    this.program, {
    this.seed = const {},
    this.dataMem = const {},
    this.expectedRegs = const {},
    this.expectedMem = const {},
    required this.nextPc,
  });

  MatrixCell get _asCell => MatrixCell(
    name,
    program,
    seed: seed,
    dataMem: dataMem,
    checkRegs: expectedRegs.keys.toList(),
    checkMem: expectedMem.keys.toList(),
    nextPc: nextPc,
  );
}

/// Architectural equality on the low [xlen] bits (mask = -1/all-ones at 64).
bool _archEq(int a, int b, int xlen) {
  final mask = xlen >= 64 ? -1 : (1 << xlen) - 1;
  return (a & mask) == (b & mask);
}

/// Register the golden vectors for one [config] as a single test named [label].
/// Each cell is checked TWICE against its hand-verified expected values: once on
/// the emulator (pins the golden ISS) and once on the built HDL (pins the RTL).
/// Failures are tagged [emu] or [hdl] so a divergence localizes to the engine.
void runGolden(
  String label,
  RiverCoreConfig config,
  List<GoldenCell> cells, {
  int? highMemBase,
  int highMemSize = 0x10000,
  Duration timeout = const Duration(minutes: 10),
  AdversarialMemory? memory,
}) {
  test(label, () async {
    final xlen = config.mxlen.size;
    final failures = <String>[];
    // 1. Pin the EMULATOR against the hand-verified golden (run before the
    //    Simulator starts, same ordering rule as the matrix).
    for (final gc in cells) {
      final emu = await _emulatorGolden(
        config,
        gc._asCell,
        highMemBase: highMemBase,
        highMemSize: highMemSize,
      );
      gc.expectedRegs.forEach((r, want) {
        final got = emu.regs[r] ?? 0;
        if (!_archEq(got, want, xlen)) {
          failures.add('  [emu] ${gc.name}: $r emu=$got want=$want');
        }
      });
      gc.expectedMem.forEach((a, want) {
        final got = emu.mem[a] ?? 0;
        if (!_archEq(got, want, xlen)) {
          failures.add(
            '  [emu] ${gc.name}: mem[0x${a.toRadixString(16)}] emu=$got want=$want',
          );
        }
      });
    }
    // 2. Pin the HDL against the SAME golden (reuses the matrix runner, which
    //    already masks to xlen bits).
    final mc = await _MatrixCore.build(config, memory: memory);
    for (final gc in cells) {
      final err = await mc.runHdl(
        gc._asCell,
        _Golden(gc.expectedRegs, gc.expectedMem),
      );
      if (err != null) failures.add('  [hdl] ${gc.name}: $err');
    }
    await mc.dispose();
    expect(
      failures,
      isEmpty,
      reason:
          '${failures.length} golden checks failed:\n'
          '${failures.join('\n')}',
    );
  }, timeout: Timeout(timeout));
}

/// Run [cell] on the emulator (golden ISS) and capture the observed reg/mem
/// state. Pure Dart, MUST be called before the HDL Simulator starts.
Future<_Golden> _emulatorGolden(
  RiverCoreConfig config,
  MatrixCell cell, {
  int? highMemBase,
  int highMemSize = 0x10000,
}) async {
  final clockHz = (config.clock.rate as HarborFixedClockRate).frequency;
  final sram = emu.Sram(
    RiverDevice(
      name: 'sram',
      compatible: 'river,sram',
      range: BusAddressRange(0, 0xFFFFF),
      clockFrequency: clockHz,
    ),
  );
  // Optional second window at [highMemBase]. The HDL side needs nothing (its
  // SparseMemoryStorage covers the whole space), but the emulator only answers
  // inside a mapped device. The D-cache allocates ONLY at or above its
  // cacheableBase (0x80000000), so a cell that must fill and hit a data line
  // keeps its data up here instead of in the low SRAM.
  final highSram = highMemBase == null
      ? null
      : emu.Sram(
          RiverDevice(
            name: 'dram',
            compatible: 'river,sram',
            range: BusAddressRange(highMemBase, highMemSize),
            clockFrequency: clockHz,
          ),
        );
  final highBase = highMemBase ?? 0;

  emu.Sram bank(int addr) =>
      (highSram != null && addr >= highBase) ? highSram : sram;
  int offset(int addr) =>
      (highSram != null && addr >= highBase) ? addr - highBase : addr;

  void ww(int addr, int value) {
    final data = bank(addr).data;
    final off = offset(addr);
    for (var i = 0; i < 4; i++) {
      data[off + i] = (value >> (i * 8)) & 0xFF;
    }
  }

  int rd64(int addr) {
    final data = bank(addr).data;
    final off = offset(addr);
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v |= data[off + i] << (i * 8);
    }
    return v;
  }

  final ecore = emu.RiverCore(
    config,
    memDevices: Map.fromEntries([
      sram.mem!,
      if (highSram != null) highSram.mem!,
    ]),
  );
  for (var i = 0; i < cell.program.length; i++) {
    ww(i * 4, cell.program[i]);
  }
  // A paged config starts at the prologue, not at the cell program, so the
  // emulator gets the same prologue, page tables and satp seed. The map is an
  // identity map, so the architectural results do not change.
  if (config.mmu.hasPaging) {
    for (var i = 0; i < matrixPagedPrologue.length; i++) {
      ww(config.resetVector + i * 4, matrixPagedPrologue[i]);
    }
    matrixPageTable().forEach((addr, words) {
      for (var j = 0; j < words.length; j++) {
        ww(addr + j * 4, words[j]);
      }
    });
    ecore.xregs[matrixSatpSeedReg] = matrixSatp;
  }
  cell.dataMem.forEach((addr, words) {
    for (var j = 0; j < words.length; j++) {
      ww(addr + j * 4, words[j]);
    }
  });
  cell.seed.forEach((r, v) => ecore.xregs[r] = v);
  var pc = config.resetVector;
  for (var s = 0; s < 5000 && pc != cell.nextPc; s++) {
    final instr = await ecore.fetch(pc);
    pc = await ecore.cycle(pc, instr);
  }
  expect(
    pc,
    cell.nextPc,
    reason: 'emulator did not reach nextPc=${cell.nextPc} (got $pc)',
  );
  return _Golden(
    {for (final r in cell.checkRegs) r: ecore.xregs[r] ?? 0},
    {for (final a in cell.checkMem) a: rd64(a)},
  );
}

/// A built-once HDL core, reusable across many programs (build-once-run-many).
class _MatrixCore {
  final RiverCoreConfig config;
  final int xlen;
  final Logic clk;
  final Logic reset;
  final Logic seedGate;
  final RiverCore core;
  final SparseMemoryStorage storage;

  /// The adversarial slave, or null when the harness runs on the instantaneous
  /// MemoryModel it always used.
  final AdversarialWishboneSlave? adversary;

  /// The bus request lines, kept so a paged run can watch for the page-table
  /// walk that proves translation is actually active.
  final Logic busCyc;
  final Logic busStb;
  final Logic busWe;
  final Logic busAdr;

  _MatrixCore._(
    this.config,
    this.xlen,
    this.clk,
    this.reset,
    this.seedGate,
    this.core,
    this.storage,
    this.adversary,
    this.busCyc,
    this.busStb,
    this.busWe,
    this.busAdr,
  );

  static Future<_MatrixCore> build(
    RiverCoreConfig config, {
    AdversarialMemory? memory,
  }) async {
    final behaviour = memory ?? AdversarialMemory.fromEnvironment();
    await Simulator.reset();
    final xlen = config.mxlen.size;
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic(name: 'reset');
    final wbConfig = WishboneConfig(
      addressWidth: xlen,
      dataWidth: xlen,
      selWidth: xlen ~/ 8,
    );
    // Translation applies only in S/U mode, so a paged config must leave reset
    // in supervisor rather than the M-mode default.
    final core = RiverCore(
      config,
      busConfig: wbConfig,
      resetPrivilege: config.mmu.hasPaging ? PrivilegeMode.supervisor.id : null,
    );
    core.input('clk').srcConnection! <= clk;
    core.input('reset').srcConnection! <= reset;
    await core.build();

    final storage = SparseMemoryStorage(
      addrWidth: xlen,
      dataWidth: xlen,
      alignAddress: (addr) => addr,
      onInvalidRead: (addr, dataWidth) =>
          LogicValue.filled(dataWidth, LogicValue.zero),
    );
    final wbCyc = core.output('dataBus_CYC');
    final wbStb = core.output('dataBus_STB');
    final wbWe = core.output('dataBus_WE');
    final seedGate = Logic(name: 'seedGate');
    AdversarialWishboneSlave? adversary;
    if (behaviour != null) {
      // A memory that is allowed to be slow, to queue and to post. The seam is
      // the same three signals the MemoryModel path drives.
      final ack = Logic(name: 'advAck');
      final miso = Logic(name: 'advMiso', width: xlen);
      adversary = attachAdversarialMemory(
        clk: clk,
        reset: reset,
        storage: storage,
        dataWidth: xlen,
        cyc: wbCyc,
        stb: wbStb,
        we: wbWe,
        adr: core.output('dataBus_ADR'),
        datMosi: core.output('dataBus_DAT_MOSI'),
        sel: core.output('dataBus_SEL'),
        ack: ack,
        miso: miso,
        behaviour: behaviour,
      );
      core.input('dataBus_ACK').srcConnection! <= ack & ~seedGate;
      core.input('dataBus_DAT_MISO').srcConnection! <= miso;
    } else {
      final memRead = DataPortInterface(xlen, xlen);
      // A MASKED write port, so the model applies the Wishbone SEL byte enables
      // instead of writing the whole bus word. A plain port made every sub-word
      // store (sb/sh/sw) overwrite the other bytes of the containing 64-bit word.
      // That hid a whole class of defect: an error in the SEL mask or in the
      // write-data lane shift is invisible in simulation, but on silicon it
      // corrupts the bytes next to the store.
      final memWrite = MaskedDataPortInterface(xlen, xlen);
      // ignore: unused_local_variable
      final mem = MemoryModel(
        clk,
        reset,
        [memWrite],
        [wrapReadForRegisterFile(memRead, clk: clk, readLatency: 0)],
        readLatency: 0,
        storage: storage,
      );
      memRead.en <= wbCyc & wbStb & ~wbWe;
      memRead.addr <= core.output('dataBus_ADR');
      memWrite.en <= wbCyc & wbStb & wbWe;
      memWrite.addr <= core.output('dataBus_ADR');
      memWrite.data <= core.output('dataBus_DAT_MOSI');
      // One mask bit per data byte, which is exactly the Wishbone SEL contract.
      // The MMU makes SEL from the access size and shifts it into the byte lane,
      // and it shifts DAT_MOSI the same way, so the two line up bit for bit.
      memWrite.mask <= core.output('dataBus_SEL');
      final wbAckReg = Logic(name: 'wbAck');
      Sequential(clk, [
        If(
          reset,
          then: [wbAckReg < 0],
          orElse: [
            If(
              wbCyc & wbStb & ~wbAckReg & (wbWe | memRead.valid),
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
    seedGate.inject(0);
    Simulator.setMaxSimTime(100000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    return _MatrixCore._(
      config,
      xlen,
      clk,
      reset,
      seedGate,
      core,
      storage,
      adversary,
      wbCyc,
      wbStb,
      wbWe,
      core.output('dataBus_ADR'),
    );
  }

  String _memString(List<int> program, Map<int, List<int>> dataMem) {
    String wordsAt(int addr, List<int> words) {
      final sb = StringBuffer('@${addr.toRadixString(16)}\n');
      for (final w in words) {
        for (var b = 0; b < 4; b++) {
          sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }
      return '${sb.toString().trimRight()}\n';
    }

    final sb = StringBuffer(wordsAt(0, program));
    dataMem.forEach((addr, words) => sb.write(wordsAt(addr, words)));
    if (config.mmu.hasPaging) {
      sb.write(wordsAt(config.resetVector, matrixPagedPrologue));
      matrixPageTable().forEach(
        (addr, words) => sb.write(wordsAt(addr, words)),
      );
    }
    return sb.toString();
  }

  /// Run [cell] on the shared built HDL core and compare to the [golden].
  /// Returns null on match, or a human-readable mismatch description on failure
  /// (returned, not thrown, so the caller can run every cell).
  Future<String?> runHdl(MatrixCell cell, _Golden golden) async {
    // Reset clears the regfile / pipeline / CSR state from the prior cell.
    // The prologue reads satp out of a GPR, so a paged config always seeds.
    final seed = config.mmu.hasPaging
        ? {...cell.seed, matrixSatpSeedReg: matrixSatp}
        : cell.seed;
    reset.inject(1);
    seedGate.inject(seed.isNotEmpty ? 1 : 0);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    storage.loadMemString(_memString(cell.program, cell.dataMem));
    reset.inject(0);
    await clk.nextPosedge;
    for (final e in seed.entries) {
      core.regWritePort.en.inject(1);
      core.regWritePort.addr.inject(LogicValue.ofInt(e.key.value, 5));
      core.regWritePort.data.inject(LogicValue.ofInt(e.value, xlen));
      await clk.nextPosedge;
    }
    core.regWritePort.en.inject(0);
    seedGate.inject(0);
    while (reset.value.toBool()) {
      await clk.nextPosedge;
    }
    var reached = false;
    var lastPc = -1;
    // A paged run must be SEEN to translate. Without this the variant is
    // vacuous: if the core stayed in bare mode the cells would pass on the
    // untranslated addresses and prove nothing. A read inside the root page
    // table is the page-table walker doing its job.
    var sawWalk = false;
    var trapCause = -1;
    // Generous cap: the microcode (DynamicExecutionUnit) path is ~10x slower
    // per instruction (a multi-cycle linear pattern search per decode), so long
    // multi-instruction cells (e.g. the seeded INT_MIN edge cells, ~14 instrs
    // plus a 64-cycle divide) need a few thousand cycles. Fast paths break out
    // as soon as nextPc is reached, so the higher cap costs them nothing.
    for (var i = 0; i < 4000; i++) {
      await clk.nextPosedge;
      final adr = busAdr.value;
      if (busCyc.value.toBool() &&
          busStb.value.toBool() &&
          !busWe.value.toBool() &&
          adr.isValid &&
          adr.toInt() >= matrixRootTable &&
          adr.toInt() < matrixRootTable + 32) {
        sawWalk = true;
      }
      final t = core.pipeline.trap.value;
      if (trapCause < 0 && t.isValid && t.toBool()) {
        final c = core.pipeline.trapCause.value;
        if (c.isValid) trapCause = c.toInt();
      }
      final p = core.pipeline.nextPc.value;
      lastPc = p.isValid ? p.toInt() : -1;
      if (p.isValid && p.toInt() == cell.nextPc) {
        reached = true;
        break;
      }
    }

    if (!reached) {
      return 'did not reach nextPc=0x${cell.nextPc.toRadixString(16)} '
          '(stuck at pc=0x${lastPc.toRadixString(16)}'
          '${trapCause < 0 ? '' : ', trapCause=$trapCause'})';
    }
    if (config.mmu.hasPaging && !sawWalk) {
      return 'NO PAGE-TABLE WALK: the core never read the root page table at '
          '0x${matrixRootTable.toRadixString(16)}, so it did not translate and '
          'this cell proves nothing about the MMU';
    }
    // A trap is also a way to lose translation without losing the cell. The
    // trap goes to M-mode, where paging is off, so the rest of the cell runs on
    // untranslated addresses and still reaches nextPc with the right answers.
    // The identity map faults on nothing, so any trap here is a real defect.
    if (config.mmu.hasPaging && trapCause >= 0) {
      return 'UNEXPECTED TRAP (cause=$trapCause) under Sv39. The identity map '
          'permits every access these cells make, and the trap drops the core '
          'into M-mode where translation stops';
    }
    // A posted write is acknowledged but not yet in storage. Commit the queue
    // so a pending write is not read back as a lost one.
    adversary?.flush();
    // Compare the architectural low-xlen bits. The HDL regfile/memory values are
    // xlen-bit unsigned; the emulator goldens are signed Dart ints. On rv64 they
    // coincide (Dart int is 64-bit two's complement); on rv32 a negative result
    // reads as 0xFFFFFFF8 from the HDL vs -8 from the emulator. Masking both to
    // xlen bits normalizes the representation (mask = -1 / all-ones for xlen>=64).
    final mask = xlen >= 64 ? -1 : (1 << xlen) - 1;
    for (final e in golden.regs.entries) {
      final v = core.regs.getData(LogicValue.ofInt(e.key.value, 5))!.toInt();
      if ((v & mask) != (e.value & mask)) {
        return '${e.key} HDL=$v golden=${e.value}';
      }
    }
    for (final e in golden.mem.entries) {
      final v = storage.getData(LogicValue.ofInt(e.key, xlen))!.toInt();
      if ((v & mask) != (e.value & mask)) {
        return 'mem[0x${e.key.toRadixString(16)}] HDL=$v golden=${e.value}';
      }
    }
    return null;
  }

  Future<void> dispose() async {
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }
}
