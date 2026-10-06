import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

import '../adversarial_memory.dart';

/// Software writes a page-table entry, then immediately uses the page that
/// entry maps. Can the page-table walker read the OLD entry and fault on a page
/// software has just mapped?
///
/// The question is not academic. On the Arty S7 the kernel took an instruction
/// page fault (cause 12) at an address whose entry its own software walk found
/// valid, readable and executable. The page-table walker has no cache in front
/// of it: both L1s sit in FRONT of the MMU, so the walker's reads go straight to
/// the bus, while the kernel's entry store goes through the write-through
/// D-cache. Store and walk are therefore ordered by the bus and the memory
/// system alone.
///
/// Every other harness drives a memory that is instantaneous and perfectly
/// ordered, so it CANNOT produce a stale entry no matter what the core does.
/// These tests use the adversarial memory, which acknowledges a write and then
/// keeps it invisible for a set number of cycles.
///
/// Root table at PA 0x10000. Entry 0 identity-maps VA 0-1GB, which carries the
/// program, the root table itself and the stack of the walk. Entry 2, which
/// covers VA 2GB-3GB, starts ABSENT. The program writes it and then touches
/// VA 0x80000000. A walker that reads the old entry sees V=0 and faults.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Sv39 leaf: V|R|W|X|A|D. A and D are pre-set, so no hardware A/D writeback
  // adds bus traffic.
  int megapage(int pa) => ((pa >> 12) << 10) | 0xCF;

  // Registers the programs read.
  const regSatp = 10; // a0
  const regPteAddr = 11; // a1
  const regPteValue = 12; // a2
  const regTarget = 13; // a3

  const csrwSatpA0 = 0x18051073; // csrw satp,a0
  const sdA2A1 = 0x00C5B023; // sd a2,0(a1)
  const ldA5A3 = 0x0006B783; // ld a5,0(a3)
  const jalrA3 = 0x00068067; // jalr x0,0(a3)
  const nop = 0x00000013;
  const selfLoop = 0x0000006F; // j .

  RiverCoreConfig rc1f() => RiverCoreConfigV1.full(
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
      hasSupervisorUserMemory: true,
      hasMakeExecutableReadable: true,
    ),
    clock: const HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
  );

  String memImage(Map<int, List<int>> words) {
    final sb = StringBuffer();
    final addrs = words.keys.toList()..sort();
    for (final a in addrs) {
      sb.writeln('@${a.toRadixString(16)}');
      for (final w in words[a]!) {
        for (var i = 0; i < 4; i++) {
          sb.write(((w >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }
      sb.writeln();
    }
    return sb.toString();
  }

  /// Runs one scenario and reports what the bus and the pipeline did.
  ///
  /// [gapNops] nops sit between the entry store and the access, so the distance
  /// between the write and the walk can be varied.
  Future<Map<String, Object>> run({
    required AdversarialMemory behaviour,
    required int gapNops,
    required bool fetchVariant,
    bool cacheableTables = false,
  }) async {
    // Two layouts. With [cacheableTables] the root table sits in the region the
    // D-cache caches, so the entry store goes through the write-through cache,
    // which is where Linux really keeps its tables. Otherwise the table is low
    // and uncached, which isolates the bus from the cache.
    final rootTable = cacheableTables ? 0x80010000 : 0x10000;
    final entryIndex = cacheableTables ? 3 : 2;
    final entryAddr = rootTable + entryIndex * 8;
    final satp = 0x8000000000000000 | (rootTable >> 12);
    final newPage = cacheableTables ? 0xC0000000 : 0x80000000;

    final config = rc1f();
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic(name: 'reset');
    final xlen = config.mxlen.size;
    final wbConfig = WishboneConfig(
      addressWidth: xlen,
      dataWidth: xlen,
      selWidth: xlen ~/ 8,
    );

    final prfSeedMode = Logic(name: 'prfSeedMode');
    final core = RiverCore(
      config,
      busConfig: wbConfig,
      prfSeedMode: prfSeedMode,
      resetPrivilege: PrivilegeMode.supervisor.id,
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
    final wbAdr = core.output('dataBus_ADR');

    final seedGate = Logic(name: 'seedGate');
    final ack = Logic(name: 'advAck');
    final miso = Logic(name: 'advMiso', width: xlen);
    final slave = attachAdversarialMemory(
      clk: clk,
      reset: reset,
      storage: storage,
      dataWidth: xlen,
      cyc: wbCyc,
      stb: wbStb,
      we: wbWe,
      adr: wbAdr,
      datMosi: core.output('dataBus_DAT_MOSI'),
      sel: core.output('dataBus_SEL'),
      ack: ack,
      miso: miso,
      behaviour: behaviour,
    );
    core.input('dataBus_ACK').srcConnection! <= ack & ~seedGate;
    core.input('dataBus_DAT_MISO').srcConnection! <= miso;

    // csrw satp,a0 ; sd a2,0(a1) ; <gapNops> ; access ; j .
    final program = <int>[
      csrwSatpA0,
      sdA2A1,
      for (var i = 0; i < gapNops; i++) nop,
      fetchVariant ? jalrA3 : ldA5A3,
      selfLoop,
    ];
    final accessPc = (2 + gapNops) * 4;
    final haltPc = fetchVariant ? newPage : accessPc + 4;

    final image = memImage({
      0x00: program,
      // Entry 0 maps the program. The entry the program writes is deliberately
      // ABSENT, so a walk that reads the pre-store memory finds V=0 and faults.
      rootTable: [megapage(0), 0],
      if (cacheableTables)
        rootTable + 2 * 8: [megapage(0x80000000), 0], // the table's own page
      // The load variant reads this. The fetch variant executes it.
      newPage: fetchVariant ? [selfLoop, nop] : [0xDEADBEEF, 0],
    });

    reset.inject(1);
    seedGate.inject(1);
    prfSeedMode.inject(1);
    Simulator.registerAction(20, () {
      reset.put(0);
      storage.loadMemString(image);
    });
    Simulator.setMaxSimTime(8000000);
    unawaited(Simulator.run());

    final seeds = {
      regSatp: satp,
      regPteAddr: entryAddr,
      regPteValue: megapage(newPage),
      regTarget: newPage,
    };
    for (final e in seeds.entries) {
      await clk.nextPosedge;
      core.regWritePort.en.inject(1);
      core.regWritePort.addr.inject(LogicValue.ofInt(e.key, 5));
      core.regWritePort.data.inject(LogicValue.ofInt(e.value, xlen));
    }
    await clk.nextPosedge;
    core.regWritePort.en.inject(0);
    seedGate.inject(0);
    prfSeedMode.inject(0);
    while (reset.value.toBool()) {
      await clk.nextPosedge;
    }

    var sawEntryWrite = false;
    var sawWalkOfEntry = false;
    // The vacuity guard for the ordered runs. The walk read must be SEEN to ask
    // for the entry while the store is still posted, otherwise the memory
    // committed early and the run proved nothing.
    var walkRacedPendingWrite = false;
    var sawNewPageAccess = false;
    var trapCause = -1;
    var reached = false;
    var lastPc = -1;

    for (var i = 0; i < 40000; i++) {
      await clk.nextPosedge;
      final adr = wbAdr.value;
      final active = wbCyc.value.toBool() && wbStb.value.toBool();
      if (active && adr.isValid) {
        final a = adr.toInt();
        final isWrite = wbWe.value.toBool();
        if (isWrite && a == entryAddr) sawEntryWrite = true;
        if (!isWrite && a == entryAddr) {
          sawWalkOfEntry = true;
          if (slave.pendingWrites > 0) walkRacedPendingWrite = true;
        }
        if (!isWrite && a == newPage) sawNewPageAccess = true;
      }
      final t = core.pipeline.trap.value;
      if (trapCause < 0 && t.isValid && t.toBool()) {
        final c = core.pipeline.trapCause.value;
        if (c.isValid) trapCause = c.toInt();
      }
      final p = core.pipeline.nextPc.value;
      if (p.isValid) lastPc = p.toInt();
      // The fetch variant halts AT the new page, and nextPc reaches that value
      // the moment the jalr resolves, before the fetch itself goes out. Wait
      // for the fetch to reach the bus, or the run stops before the walk.
      if (p.isValid &&
          p.toInt() == haltPc &&
          (!fetchVariant || sawNewPageAccess)) {
        reached = true;
        break;
      }
    }

    slave.flush();
    await Simulator.endSimulation();
    await Simulator.simulationEnded;

    return {
      'sawEntryWrite': sawEntryWrite,
      'sawWalkOfEntry': sawWalkOfEntry,
      'walkRacedPendingWrite': walkRacedPendingWrite || slave.staleReads > 0,
      'sawNewPageAccess': sawNewPageAccess,
      'trapCause': trapCause,
      'reached': reached,
      'lastPc': lastPc,
      'staleReads': slave.staleReads,
    };
  }

  /// The memory the store is still travelling through when the walk is issued.
  /// Reads may overtake writes to OTHER addresses, which is what a queueing
  /// memory really does, but a read of the entry itself is still ordered.
  ///
  /// The commit delay grows with the gap, so the store is guaranteed to be
  /// still in flight when the walk asks for it. A delay that is too short makes
  /// the run vacuous, and the run says so rather than passing quietly.
  AdversarialMemory postedFor(int gapNops) => AdversarialMemory(
    readLatency: 2,
    writeLatency: 1,
    postedWriteCycles: 600 + gapNops * 300,
    postedWriteDepth: 16,
    readsPassPendingWrites: true,
  );

  /// The same memory with same-address ordering BROKEN. This is a memory that
  /// is wrong, not merely slow, and it exists to prove the checks can fail.
  const hostile = AdversarialMemory(
    readLatency: 2,
    writeLatency: 1,
    postedWriteCycles: 400,
    postedWriteDepth: 16,
    readsPassPendingWrites: true,
    hostileReadPassesSameAddress: true,
  );

  void assertMapped(Map<String, Object> r, {required String what}) {
    expect(
      r['sawEntryWrite'],
      isTrue,
      reason: 'the entry store never reached the bus',
    );
    expect(
      r['sawWalkOfEntry'],
      isTrue,
      reason:
          'NO PAGE-TABLE WALK of the entry that was written, so this run says '
          'nothing about walk ordering',
    );
    expect(
      r['walkRacedPendingWrite'],
      isTrue,
      reason:
          'VACUOUS: the entry store had already committed by the time the walk '
          'read it, so no ordering was tested',
    );
    expect(
      r['trapCause'],
      -1,
      reason:
          'SPURIOUS FAULT: the walk read a superseded page-table entry and '
          'faulted on a page software had already mapped ($what)',
    );
    expect(
      r['sawNewPageAccess'],
      isTrue,
      reason: 'translation never produced the new physical page',
    );
    expect(
      r['reached'],
      isTrue,
      reason:
          'the program did not finish, last pc 0x'
          '${(r['lastPc']! as int).toRadixString(16)}',
    );
  }

  for (final gap in [0, 1, 4, 16]) {
    test(
      'rc1-f: a load through a just-written PTE is ordered, $gap nop gap',
      timeout: const Timeout(Duration(minutes: 20)),
      () async {
        final r = await run(
          behaviour: postedFor(gap),
          gapNops: gap,
          fetchVariant: false,
        );
        assertMapped(r, what: 'load');
      },
    );
  }

  for (final gap in [0, 4]) {
    test(
      'rc1-f: a fetch from a just-written PTE is ordered, $gap nop gap',
      timeout: const Timeout(Duration(minutes: 20)),
      () async {
        final r = await run(
          behaviour: postedFor(gap),
          gapNops: gap,
          fetchVariant: true,
        );
        assertMapped(r, what: 'fetch');
      },
    );
  }

  for (final gap in [0, 4]) {
    test(
      'rc1-f: a load through a just-written PTE in a CACHED table is ordered, '
      '$gap nop gap',
      timeout: const Timeout(Duration(minutes: 20)),
      () async {
        // The table now lives where the D-cache caches, so the entry store
        // travels through the write-through cache while the walk still reads
        // the bus directly. This is the layout Linux uses.
        final r = await run(
          behaviour: postedFor(gap),
          gapNops: gap,
          fetchVariant: false,
          cacheableTables: true,
        );
        assertMapped(r, what: 'load through a cached table');
      },
    );
  }

  test(
    'MUTATION: a memory that lets a read pass a write to the SAME address does '
    'produce the spurious fault',
    timeout: const Timeout(Duration(minutes: 20)),
    () async {
      // Same program, same timing, only the memory ordering rule is broken.
      // The fault this raises is the symptom seen on the board, which is what
      // makes the ordered runs above a real check and not a vacuous one.
      final r = await run(behaviour: hostile, gapNops: 0, fetchVariant: false);
      expect(r['sawEntryWrite'], isTrue);
      expect(r['sawWalkOfEntry'], isTrue);
      expect(
        r['staleReads'],
        greaterThan(0),
        reason: 'the hostile memory never actually returned a stale value',
      );
      expect(
        r['trapCause'],
        isNot(-1),
        reason:
            'the walk read a stale entry and did NOT fault, so the checks above '
            'cannot detect a stale walk',
      );
    },
  );
}
