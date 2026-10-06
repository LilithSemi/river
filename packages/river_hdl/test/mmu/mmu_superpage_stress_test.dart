import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Spurious instruction-page-fault hunt on a VALID 2MB superpage.
///
/// Hardware symptom these tests bracket: on Arty S7 the kernel took cause 12
/// (instruction page fault) at a kernel-text address that its own software
/// page-table walk resolved without trouble. The leaf was a level-1 (2MB) PTE
/// with V R X G A D set, so no fault was architecturally due.
///
/// The MMU has ONE Wishbone master, ONE walk state machine and ONE `isFetchWalk`
/// flag shared by the instruction port and the data port. A data-side fault
/// reported on the fetch port would produce exactly that symptom, so most of
/// these tests make one port fault ON PURPOSE and require the fault to arrive
/// only on the port that earned it.
///
/// Every test also counts the page-table reads, so none of them can pass by
/// never translating anything.
/// The MMU under test plus every handle a test drives it with.
typedef Rig = ({
  RiverMmu mmu,
  Logic clk,
  Logic reset,
  Logic ifetchEn,
  Logic ifetchAddr,
  Logic dportEn,
  Logic dportAddr,
  Logic dportWe,
  Logic satpMode,
  Logic satpRoot,
  Logic priv,
  Logic tlbFlush,
  Logic ackDelay,
  Logic misoSrc,
});

/// One recorded bus transaction, with the privilege mode it ran at.
typedef Txn = ({int addr, bool isWrite, int priv});

/// What one run observed.
typedef Result = ({
  List<Txn> bus,
  int ifetchFaults,
  int dportFaults,
  int ifetchOk,
  int dportOk,
  Set<int> ifetchData,
  Set<int> dportData,
});

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // The Sv39 tables from the board dump.
  //   satp root PPN 0x8fdfc  -> pgd at 0x8fdfc000
  //   pgd[510] = 0x23f7f401  -> pointer, next table 0x8fdfd000
  //   pmd[3]   = 0x22d000eb  -> LEAF, PPN 0x8b400, V R X G A D (2MB superpage)
  // VA 0xffffffff807ae81c -> PA 0x8b5ae81c.
  const satpRootPpn = 0x8FDFC;
  const pgdBase = 0x8FDFC000;
  const pmdBase = 0x8FDFD000;
  const pgdSlot = pgdBase + 510 * 8;
  const pgdEntry = 0x23F7F401;
  const pmdSlot3 = pmdBase + 3 * 8;
  const pmdEntry3 = 0x22D000EB; // V R X G A D, PPN 0x8b400
  const textVa = 0xFFFFFFFF807AE81C;
  const textPa = 0x8B5AE81C;

  // pmd[4]: a second executable 2MB superpage, so a test can miss the
  // single-entry fetch TLB on purpose. VA 0xffffffff80800000 -> PA 0x8b600000.
  const pmdSlot4 = pmdBase + 4 * 8;
  const pmdEntry4 = 0x22D800EB; // PPN 0x8b600, V R X G A D
  const textVa2 = 0xFFFFFFFF8080012C;
  const textPa2 = 0x8B60012C;

  // pmd[5]: a data superpage, V R W A D, no X. A load may use it, a fetch may
  // not. VA 0xffffffff80a00000 -> PA 0x8b800000.
  const pmdSlot5 = pmdBase + 5 * 8;
  const pmdEntry5 = 0x22E000E7; // PPN 0x8b800, V R W A D
  const dataVa = 0xFFFFFFFF80A00040;
  const dataPa = 0x8B800040;

  // pmd[6]: nothing at all. Any access through it is a real page fault.
  const holeVa = 0xFFFFFFFF80C00080;

  // pmd[7]: a read-only data superpage (V R A D). A store through it faults, a
  // load does not. VA 0xffffffff80e00000 -> PA 0x8ba00000.
  const pmdSlot7 = pmdBase + 7 * 8;
  const pmdEntry7 = 0x22E800C3; // PPN 0x8ba00, V R A D
  const roVa = 0xFFFFFFFF80E000C0;

  const instrWord = 0x0000806700000013; // nop ; ret
  const dataWord = 0x0123456789ABCDEF;

  Map<int, int> baseMemory() => {
    pgdSlot: pgdEntry,
    pmdSlot3: pmdEntry3,
    pmdSlot4: pmdEntry4,
    pmdSlot5: pmdEntry5,
    pmdSlot7: pmdEntry7,
    textPa & ~7: instrWord,
    textPa2 & ~7: instrWord,
    dataPa & ~7: dataWord,
  };

  HarborMmuConfig mmuConfig() => HarborMmuConfig(
    mxlen: RiscVMxlen.rv64,
    pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
    hasSupervisorUserMemory: true,
    hasMakeExecutableReadable: true,
  );

  /// Builds the MMU with a mock Wishbone slave.
  ///
  /// The slave answers after `ackDelay + 1` cycles, so a test can stretch the
  /// bus latency the way DRAM does and move every internal race around.
  ///
  /// [stickyAck] makes the slave hold ACK for TWO cycles instead of one. That
  /// breaks classic Wishbone, and the Harbor register slice never does it, but
  /// it is the failure a future fabric change could introduce. The MMU must
  /// ignore an ACK that arrives when it is not driving a transaction.
  Future<Rig> buildMmu({bool stickyAck = false, bool userProbe = false}) async {
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic(name: 'reset');
    final ifetchEn = Logic(name: 'ifetchEn');
    final ifetchAddr = Logic(name: 'ifetchAddr', width: 64);
    final dportEn = Logic(name: 'dportEn');
    final dportAddr = Logic(name: 'dportAddr', width: 64);
    final dportWe = Logic(name: 'dportWe');
    final satpMode = Logic(name: 'satpMode', width: 4);
    final satpRoot = Logic(name: 'satpRoot', width: 64);
    final priv = Logic(name: 'priv', width: 3);
    final tlbFlush = Logic(name: 'tlbFlush');
    final ackDelay = Logic(name: 'ackDelay', width: 4);
    final ackSrc = Logic(name: 'ackSrc');
    final misoSrc = Logic(name: 'misoSrc', width: 64);

    final wbConfig = WishboneConfig(
      addressWidth: 64,
      dataWidth: 64,
      selWidth: 8,
    );

    final mmu = RiverMmu(
      clk,
      reset,
      ifetchEn,
      ifetchAddr,
      dportEn,
      dportAddr,
      dportWe,
      Const(0, width: 64),
      Const(3, width: 3),
      ackSrc,
      misoSrc,
      mmuConfig: mmuConfig(),
      busConfig: wbConfig,
      satpMode: satpMode,
      satpRoot: satpRoot,
      privMode: priv,
      sum: Const(0),
      mxr: Const(0),
      translateFetch: true,
      tlbFlush: tlbFlush,
      userProbe: userProbe,
    );
    await mmu.build();

    // Latency slave: counts down while CYC and STB are up, then pulses ACK for
    // exactly one cycle, which is what the pipelined Harbor fabric presents.
    // With [stickyAck] the pulse is held for a second cycle, after the MMU has
    // already dropped CYC.
    final ackReg = Logic(name: 'ackReg');
    final wait = Logic(name: 'wait', width: 4);
    final hold = Logic(name: 'hold');
    Sequential(clk, [
      If(
        reset,
        then: [ackReg < 0, wait < 0, hold < 0],
        orElse: [
          ackReg < 0,
          hold < 0,
          If(
            stickyAck ? hold : Const(0),
            then: [ackReg < 1],
            orElse: [
              If(
                mmu.wbCyc & mmu.wbStb & ~ackReg,
                then: [
                  If(
                    wait.gte(ackDelay),
                    then: [ackReg < 1, wait < 0, hold < 1],
                    orElse: [wait < wait + 1],
                  ),
                ],
                orElse: [wait < 0],
              ),
            ],
          ),
        ],
      ),
    ]);
    ackSrc <= ackReg;

    return (
      mmu: mmu,
      clk: clk,
      reset: reset,
      ifetchEn: ifetchEn,
      ifetchAddr: ifetchAddr,
      dportEn: dportEn,
      dportAddr: dportAddr,
      dportWe: dportWe,
      satpMode: satpMode,
      satpRoot: satpRoot,
      priv: priv,
      tlbFlush: tlbFlush,
      ackDelay: ackDelay,
      misoSrc: misoSrc,
    );
  }

  /// Runs [rig] for [cycles] clocks over [memory], letting [drive] set the port
  /// enables each cycle, and returns the bus trace and the fault counts.
  ///
  /// The mock memory is written by a dport store as well as read, so a test can
  /// edit a PTE from the data port and watch what the next walk reads.
  Future<Result> run(
    Rig h,
    Map<int, int> memory,
    int cycles,
    void Function(int cycle) drive, {
    int ackDelay = 0,
  }) async {
    final mmu = h.mmu;
    final bus = <Txn>[];
    var ifetchFaults = 0;
    var dportFaults = 0;
    var ifetchOk = 0;
    var dportOk = 0;
    final ifetchData = <int>{};
    final dportData = <int>{};

    h.reset.inject(1);
    h.ifetchEn.inject(0);
    h.ifetchAddr.inject(0);
    h.dportEn.inject(0);
    h.dportAddr.inject(0);
    h.dportWe.inject(0);
    h.satpMode.inject(8);
    h.satpRoot.inject(satpRootPpn);
    h.priv.inject(PrivilegeMode.supervisor.id);
    h.tlbFlush.inject(0);
    h.ackDelay.inject(ackDelay);
    h.misoSrc.inject(0);

    Simulator.setMaxSimTime(40000000);
    unawaited(Simulator.run());

    await h.clk.nextPosedge;
    h.reset.inject(0);
    await h.clk.nextPosedge;

    var lastLive = false;
    for (var i = 0; i < cycles; i++) {
      drive(i);
      // The mock memory answers combinationally off the registered address, so
      // present the data on the low phase, well before the ACK edge.
      await h.clk.nextNegedge;
      final adrV = mmu.wbAdr.value;
      if (adrV.isValid) {
        h.misoSrc.inject(
          LogicValue.ofBigInt(
            BigInt.from(memory[adrV.toInt()] ?? 0).toUnsigned(64),
            64,
          ),
        );
      }
      await h.clk.nextPosedge;

      // Record each transaction once, on its first cycle.
      final live = mmu.wbCyc.value.toBool() && mmu.wbStb.value.toBool();
      if (live && !lastLive && mmu.wbAdr.value.isValid) {
        bus.add((
          addr: mmu.wbAdr.value.toInt(),
          isWrite: mmu.wbWe.value.toBool(),
          priv: h.priv.value.toInt(),
        ));
      }
      lastLive = live;

      if (mmu.ifetchFault.value.toBool()) ifetchFaults++;
      if (mmu.dportFault.value.toBool()) dportFaults++;
      if (mmu.ifetchDone.value.toBool() && mmu.ifetchValid.value.toBool()) {
        ifetchOk++;
        if (mmu.ifetchRdata.value.isValid) {
          ifetchData.add(mmu.ifetchRdata.value.toInt());
        }
      }
      if (mmu.dportDone.value.toBool() && mmu.dportValid.value.toBool()) {
        dportOk++;
        if (mmu.dportRdata.value.isValid) {
          dportData.add(mmu.dportRdata.value.toInt());
        }
      }
    }

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
    return (
      bus: bus,
      ifetchFaults: ifetchFaults,
      dportFaults: dportFaults,
      ifetchOk: ifetchOk,
      dportOk: dportOk,
      ifetchData: ifetchData,
      dportData: dportData,
    );
  }

  /// Fails when the run never read the root page table, which would make every
  /// other check in the test vacuous.
  void expectRealWalk(Result r, {int atLeast = 1}) {
    expect(
      r.bus.where((t) => t.addr == pgdSlot && !t.isWrite).length,
      greaterThanOrEqualTo(atLeast),
      reason:
          'VACUOUS TEST: the MMU never read the root page table at '
          '0x${pgdSlot.toRadixString(16)}, so nothing was translated. '
          'bus=${r.bus.take(12).map((t) => t.addr.toRadixString(16)).toList()}',
    );
    expect(
      r.bus.every((t) => t.priv == PrivilegeMode.supervisor.id),
      isTrue,
      reason: 'a bus access ran at a privilege other than supervisor',
    );
  }

  /// The fetch port asks for [va] every cycle; the data port pulses.
  void Function(int) fetchAndPulsedLoad(Rig h, int fetchVa, int loadVa) =>
      (int i) {
        h.ifetchEn.inject(1);
        h.ifetchAddr.inject(LogicValue.ofBigInt(BigInt.from(fetchVa), 64));
        // The data port must not request every cycle: it outranks the fetch
        // port, so a permanently asserted dport starves instruction fetch
        // outright. Pulsing it lands the data walk at every possible offset
        // against the fetch walk instead.
        h.dportEn.inject((i % 5) == 0 ? 1 : 0);
        h.dportAddr.inject(LogicValue.ofBigInt(BigInt.from(loadVa), 64));
        h.dportWe.inject(0);
      };

  test('a lone superpage fetch really walks and never faults', () async {
    final h = await buildMmu();
    final r = await run(h, baseMemory(), 300, (i) {
      h.ifetchEn.inject(1);
      h.ifetchAddr.inject(LogicValue.ofBigInt(BigInt.from(textVa), 64));
      h.dportEn.inject(0);
    });

    expectRealWalk(r);
    expect(
      r.bus.any((t) => t.addr == pmdSlot3),
      isTrue,
      reason: 'the walk never descended to the level-1 superpage leaf',
    );
    expect(r.ifetchFaults, 0, reason: 'spurious instruction page fault');
    expect(r.ifetchOk, greaterThan(0), reason: 'no fetch ever completed');
    expect(
      r.bus.any((t) => t.addr == (textPa & ~7)),
      isTrue,
      reason:
          'the translated fetch never reached PA 0x${textPa.toRadixString(16)}',
    );
    expect(r.ifetchData, {instrWord});
  });

  for (final delay in [0, 1, 4]) {
    test(
      'superpage fetch with a contending load never faults (ack delay $delay)',
      () async {
        final h = await buildMmu();
        final r = await run(
          h,
          baseMemory(),
          4000,
          fetchAndPulsedLoad(h, textVa, dataVa),
          ackDelay: delay,
        );

        expectRealWalk(r);
        expect(r.ifetchOk, greaterThan(0), reason: 'no fetch ever completed');
        expect(r.dportOk, greaterThan(0), reason: 'no load ever completed');
        expect(
          r.ifetchFaults,
          0,
          reason:
              'SPURIOUS instruction page fault on a valid executable superpage '
              'while the data port contended for the shared walk hardware',
        );
        expect(r.dportFaults, 0, reason: 'spurious load page fault');
        expect(r.ifetchData, {instrWord});
        expect(r.dportData, {dataWord});
      },
    );
  }

  test(
    'fetch alternating between two superpages under load contention',
    () async {
      // Every alternation misses the single-entry fetch TLB, so the walk machine
      // restarts over and over while the data port keeps taking the bus.
      final h = await buildMmu();
      final r = await run(h, baseMemory(), 6000, (i) {
        final second = (i ~/ 7).isOdd;
        h.ifetchEn.inject(1);
        h.ifetchAddr.inject(
          LogicValue.ofBigInt(BigInt.from(second ? textVa2 : textVa), 64),
        );
        h.dportEn.inject((i % 5) == 0 ? 1 : 0);
        h.dportAddr.inject(LogicValue.ofBigInt(BigInt.from(dataVa), 64));
        h.dportWe.inject(0);
      });

      expectRealWalk(r, atLeast: 4);
      expect(r.ifetchFaults, 0, reason: 'SPURIOUS instruction page fault');
      expect(r.dportFaults, 0, reason: 'spurious load page fault');
      expect(
        r.bus.any((t) => t.addr == (textPa & ~7)) &&
            r.bus.any((t) => t.addr == (textPa2 & ~7)),
        isTrue,
        reason: 'both superpages must have been fetched from',
      );
    },
  );

  test('a data-side page fault never lands on the fetch port', () async {
    // The fetch address is a valid executable superpage. The load address
    // goes through pmd[6], which does not exist, so every data walk MUST
    // fault. The MMU shares one walk state machine and one isFetchWalk flag
    // between the ports; if the routing ever slips, the fetch port takes the
    // data port's fault, which is the board symptom exactly.
    final h = await buildMmu();
    final r = await run(
      h,
      baseMemory(),
      4000,
      fetchAndPulsedLoad(h, textVa, holeVa),
    );

    expectRealWalk(r);
    expect(
      r.dportFaults,
      greaterThan(0),
      reason: 'the unmapped load never faulted, so nothing was routed',
    );
    expect(r.ifetchOk, greaterThan(0), reason: 'no fetch ever completed');
    expect(
      r.ifetchFaults,
      0,
      reason:
          'MISROUTED FAULT: the data port faulted on an unmapped address and '
          'the fetch port reported an instruction page fault for a valid '
          'executable superpage',
    );
    expect(r.ifetchData, {instrWord});
  });

  test('a store-permission fault never lands on the fetch port', () async {
    // pmd[7] is read-only, so the store faults on the W bit at the leaf. That
    // exercises leafPermFault with isFetchWalk=0 and reqWe=1 while a fetch
    // walk for an X page is being started and finished around it.
    final h = await buildMmu();
    final r = await run(h, baseMemory(), 4000, (i) {
      h.ifetchEn.inject(1);
      h.ifetchAddr.inject(LogicValue.ofBigInt(BigInt.from(textVa), 64));
      h.dportEn.inject((i % 5) == 0 ? 1 : 0);
      h.dportAddr.inject(LogicValue.ofBigInt(BigInt.from(roVa), 64));
      h.dportWe.inject(1);
    });

    expectRealWalk(r);
    expect(
      r.dportFaults,
      greaterThan(0),
      reason: 'the store to a read-only page never faulted',
    );
    expect(
      r.ifetchFaults,
      0,
      reason:
          'MISROUTED FAULT: a store-permission fault was reported as an '
          'instruction page fault',
    );
    expect(r.ifetchOk, greaterThan(0), reason: 'no fetch ever completed');
  });

  test('a fetch-side page fault never lands on the data port', () async {
    // The mirror case: the fetch goes through pmd[5], which is R/W but NOT
    // executable, so every fetch walk faults on the X bit. The load is valid
    // and must keep completing.
    final h = await buildMmu();
    final r = await run(
      h,
      baseMemory(),
      4000,
      fetchAndPulsedLoad(h, dataVa, dataVa),
    );

    expectRealWalk(r);
    expect(
      r.ifetchFaults,
      greaterThan(0),
      reason: 'the fetch of a non-executable page never faulted',
    );
    expect(r.dportOk, greaterThan(0), reason: 'no load ever completed');
    expect(
      r.dportFaults,
      0,
      reason:
          'MISROUTED FAULT: an instruction-fetch X-permission fault was '
          'reported as a load page fault',
    );
  });

  test(
    'a PTE rewritten from the data port is honoured by the next walk',
    () async {
      // Mechanism: a walk read bypasses the L1 D-cache, so it must observe a
      // page-table entry the data port wrote moments before. The mock memory is
      // written through the same port the D-cache write-through uses, so a walk
      // that passed an in-flight write to the same address would keep the old
      // leaf and translate to the old physical page.
      final memory = baseMemory();
      final h = await buildMmu();

      // Start with pmd[4] absent, then install it from the data port. Nothing
      // may fault after the install plus a TLB flush.
      memory.remove(pmdSlot4);
      var installed = false;
      var faultsAfterInstall = 0;
      var installCycle = -1;

      final r = await run(h, memory, 4000, (i) {
        if (i == 400) {
          // Model the store landing in memory the cycle the MMU drives it.
          memory[pmdSlot4] = pmdEntry4;
          installed = true;
          installCycle = i;
        }
        // sfence.vma right after the install, as software must issue.
        h.tlbFlush.inject(i == 402 ? 1 : 0);
        h.ifetchEn.inject(i > 402 ? 1 : 0);
        h.ifetchAddr.inject(LogicValue.ofBigInt(BigInt.from(textVa2), 64));
        h.dportEn.inject((i % 5) == 0 ? 1 : 0);
        h.dportAddr.inject(LogicValue.ofBigInt(BigInt.from(dataVa), 64));
        h.dportWe.inject(0);
        if (installed && i > 410 && h.mmu.ifetchFault.value.toBool()) {
          faultsAfterInstall++;
        }
      });

      expect(installed, isTrue);
      expect(installCycle, 400);
      expectRealWalk(r);
      expect(
        r.bus.any((t) => t.addr == pmdSlot4 && !t.isWrite),
        isTrue,
        reason: 'the walk never read the newly installed pmd entry',
      );
      expect(
        faultsAfterInstall,
        0,
        reason:
            'the fetch kept faulting after the page-table entry was installed '
            'and the TLB was flushed: the walk read stale memory',
      );
      expect(
        r.bus.any((t) => t.addr == (textPa2 & ~7)),
        isTrue,
        reason: 'the fetch never reached the newly mapped physical page',
      );
    },
  );

  test(
    'an sfence.vma pulsed on every cycle never turns a valid fetch into a fault',
    () async {
      // sfence.vma clears the fetch TLB but must not disturb a walk already in
      // flight. Pulsing it continuously keeps every fetch on the walk path.
      final h = await buildMmu();
      final r = await run(h, baseMemory(), 3000, (i) {
        h.tlbFlush.inject((i % 3) == 0 ? 1 : 0);
        h.ifetchEn.inject(1);
        h.ifetchAddr.inject(LogicValue.ofBigInt(BigInt.from(textVa), 64));
        h.dportEn.inject((i % 5) == 0 ? 1 : 0);
        h.dportAddr.inject(LogicValue.ofBigInt(BigInt.from(dataVa), 64));
        h.dportWe.inject(0);
      });

      expectRealWalk(r, atLeast: 4);
      expect(r.ifetchFaults, 0, reason: 'SPURIOUS instruction page fault');
      expect(r.dportFaults, 0, reason: 'spurious load page fault');
      expect(r.ifetchOk, greaterThan(0), reason: 'no fetch ever completed');
    },
  );

  test(
    'the U bit denies a supervisor page to user mode, both fetch and load',
    () async {
      // Not a defect: this pins the ONE check that denies a fetch AND a load on
      // a leaf whose V R X A D bits are all correct. The kernel superpage has
      // U=0, so if the core ever presents priv=user the MMU raises cause 12 at
      // the fetch address and a load of the same page faults too. The oops dump
      // (valid executable pmd, instruction fault, and the code dump unable to
      // read the same page) has that shape.
      final h = await buildMmu();
      final r = await run(h, baseMemory(), 600, (i) {
        h.priv.inject(PrivilegeMode.user.id);
        h.ifetchEn.inject(i < 300 ? 1 : 0);
        h.ifetchAddr.inject(LogicValue.ofBigInt(BigInt.from(textVa), 64));
        h.dportEn.inject(i >= 300 ? 1 : 0);
        h.dportAddr.inject(LogicValue.ofBigInt(BigInt.from(textVa), 64));
        h.dportWe.inject(0);
      });

      expect(
        r.bus.where((t) => t.addr == pgdSlot).length,
        greaterThanOrEqualTo(1),
        reason: 'VACUOUS TEST: no walk happened',
      );
      expect(
        r.ifetchFaults,
        greaterThan(0),
        reason: 'a user-mode fetch of a U=0 page must raise cause 12',
      );
      expect(
        r.dportFaults,
        greaterThan(0),
        reason: 'a user-mode load of the same U=0 page must fault as well',
      );
      expect(
        r.bus.any((t) => t.addr == (textPa & ~7)),
        isFalse,
        reason: 'the denied access must never reach the physical page',
      );
    },
  );

  test(
    'a privilege change mid-walk never faults an access requested in S-mode',
    () async {
      // A trap or an xRET moves the privilege mode while a walk the MMU already
      // accepted is still on the bus. leafPermFault reads the LIVE privilege at
      // the cycle the leaf comes back, not the privilege the requester held when
      // the MMU took the request, so a mode change mid-walk turns a legal
      // supervisor access into a page fault on a page whose V R X A D bits are
      // all correct. That is the board signature exactly.
      //
      // Both ports are held OFF during the user-mode cycles, so every request
      // the MMU accepts is made in supervisor mode at a supervisor page. No
      // fault is architecturally due on ANY of them.
      final h = await buildMmu();
      final r = await run(h, baseMemory(), 4000, (i) {
        // A one-cycle user excursion, at a period coprime with the walk length,
        // so it sweeps across every phase of the walk.
        final user = (i % 23) == 11;
        h.priv.inject(
          user ? PrivilegeMode.user.id : PrivilegeMode.supervisor.id,
        );
        // Empty the fetch TLB constantly so EVERY fetch takes the walk path.
        // Without this almost every fetch is answered from the cached leaf at
        // grant time, where the privilege is the requester's own, and the late
        // check at the end of a walk is never reached.
        h.tlbFlush.inject((i % 7) == 3 ? 1 : 0);
        h.ifetchEn.inject(user ? 0 : 1);
        h.ifetchAddr.inject(LogicValue.ofBigInt(BigInt.from(textVa), 64));
        h.dportEn.inject(!user && (i % 5) == 0 ? 1 : 0);
        h.dportAddr.inject(LogicValue.ofBigInt(BigInt.from(dataVa), 64));
        h.dportWe.inject(0);
      });

      expect(
        r.bus.where((t) => t.addr == pgdSlot && !t.isWrite).length,
        greaterThanOrEqualTo(1),
        reason: 'VACUOUS TEST: the MMU never read the root page table',
      );
      expect(r.ifetchOk, greaterThan(0), reason: 'no fetch ever completed');
      expect(
        r.ifetchFaults,
        0,
        reason:
            'SPURIOUS instruction page fault. Every fetch was requested in '
            'supervisor mode at a valid executable supervisor superpage, but a '
            'privilege change while the walk was in flight made the leaf '
            'permission check run against the NEW privilege. The U bit then '
            'denied a page that the requester was entitled to.',
      );
      expect(
        r.dportFaults,
        0,
        reason:
            'SPURIOUS load page fault from the same late permission check on '
            'the data port',
      );
    },
  );

  test('an ACK held past the transaction is ignored, not taken as a PTE', () async {
    // Classic Wishbone terminates a transfer on a single ACK. The walk FSM
    // accepted an ACK on `busActive & wbAck` with no check that it still owned
    // a live transaction, so a second ACK cycle was consumed as the NEXT PTE.
    // The walk then descended a level on data it had already used: the level-1
    // pointer was re-read as if it were the level-0 entry, so the MMU read
    // pmd[VPN0] instead of the leaf it had just resolved, found nothing, and
    // raised an instruction page fault on a valid executable superpage.
    //
    // The Harbor WishboneRegisterStage pulses ACK for one cycle, so the shipped
    // fabric never triggers this. The guard makes the MMU safe against a fabric
    // that does not.
    final h = await buildMmu(stickyAck: true);
    final r = await run(h, baseMemory(), 400, (i) {
      h.ifetchEn.inject(1);
      h.ifetchAddr.inject(LogicValue.ofBigInt(BigInt.from(textVa), 64));
      h.dportEn.inject(0);
    });

    final reads = r.bus.where((t) => !t.isWrite).map((t) => t.addr).toSet();
    expect(
      reads,
      contains(pgdSlot),
      reason: 'VACUOUS TEST: the MMU never read the root page table',
    );
    expect(
      reads,
      contains(pmdSlot3),
      reason:
          'the walk never reached the level-1 leaf. It descended on a repeated '
          'ACK and read the wrong table entry instead: '
          '${reads.map((a) => a.toRadixString(16)).toList()}',
    );
    expect(
      reads.any((a) => a > pmdBase && a != pmdSlot3 && a < pmdBase + 4096),
      isFalse,
      reason:
          'the walk read a level-1 entry that is not part of this translation, '
          'so it consumed a stale ACK as a fresh PTE: '
          '${reads.map((a) => a.toRadixString(16)).toList()}',
    );
    expect(
      r.ifetchFaults,
      0,
      reason:
          'SPURIOUS instruction page fault: an ACK held past the end of the '
          'transaction was taken as the next PTE',
    );
    expect(r.ifetchOk, greaterThan(0), reason: 'no fetch ever completed');
    expect(r.ifetchData, {instrWord});
  });

  test(
    'a walk granted in user mode is denied even if the mode returns to S',
    () async {
      // THE DELTA BOOT REGRESSION, reduced to its mechanism.
      //
      // The walk latches the privilege at the grant. If the core is in USER
      // mode when the MMU accepts the request and returns to SUPERVISOR before
      // the leaf PTE comes back, the leaf check runs against USER and the U bit
      // denies the supervisor page. The previous code checked the LIVE
      // privilege, which was supervisor again by then, so it PERMITTED the
      // access.
      //
      // Every page here is U=0 and R=1, which is what Linux swapper_pg_dir
      // holds. No user page is involved. The only moving part is the mode. So a
      // core that takes even a brief user-mode excursion sees loads of ordinary
      // kernel pages denied at legitimate addresses. Denying is
      // architecturally right, the access really was issued in user mode, but
      // it means this MMU stops masking an upstream privilege bug that the old
      // leniency hid.
      final h = await buildMmu();
      var sawRootRead = false;
      final r = await run(h, baseMemory(), 400, (i) {
        final adr = h.mmu.wbAdr.value;
        if (!sawRootRead &&
            h.mmu.wbCyc.value.toBool() &&
            adr.isValid &&
            adr.toInt() == pgdSlot) {
          sawRootRead = true;
        }
        // User at the grant, supervisor again once the walk is on the bus.
        h.priv.inject(
          sawRootRead ? PrivilegeMode.supervisor.id : PrivilegeMode.user.id,
        );
        h.ifetchEn.inject(0);
        h.dportEn.inject(1);
        h.dportAddr.inject(LogicValue.ofBigInt(BigInt.from(dataVa), 64));
        h.dportWe.inject(0);
      });

      expect(sawRootRead, isTrue, reason: 'VACUOUS TEST: no walk started');
      expect(
        r.dportFaults,
        greaterThan(0),
        reason:
            'a load granted in user mode against a U=0 page must be denied, '
            'whatever the mode is by the time the leaf arrives',
      );
    },
  );

  test('the same load never faults when the mode stays supervisor', () async {
    // Control for the test above. Same page, same walk, mode held at
    // supervisor. This is what pins the user-mode excursion, and not the page
    // or the walk, as the cause of the fault.
    final h = await buildMmu();
    final r = await run(h, baseMemory(), 400, (i) {
      h.priv.inject(PrivilegeMode.supervisor.id);
      h.ifetchEn.inject(0);
      h.dportEn.inject(1);
      h.dportAddr.inject(LogicValue.ofBigInt(BigInt.from(dataVa), 64));
      h.dportWe.inject(0);
    });

    expect(
      r.bus.any((t) => t.addr == pgdSlot && !t.isWrite),
      isTrue,
      reason: 'VACUOUS CONTROL: no walk happened',
    );
    expect(r.dportFaults, 0, reason: 'the control load must not fault');
    expect(
      r.dportOk,
      greaterThan(0),
      reason: 'the control load never completed',
    );
  });

  test(
    'the user-mode probe catches an excursion that leaves no other trace',
    () async {
      // The instrument for the hardware question "does this core ever enter user
      // mode during early boot". A transient excursion is invisible afterwards:
      // any later trap is taken FROM supervisor, so sstatus.SPP reads 1. These
      // bits set once and never clear, so they survive to be read over JTAG.
      final h = await buildMmu(userProbe: true);
      var sawRootRead = false;
      await run(h, baseMemory(), 400, (i) {
        final adr = h.mmu.wbAdr.value;
        if (!sawRootRead &&
            h.mmu.wbCyc.value.toBool() &&
            adr.isValid &&
            adr.toInt() == pgdSlot) {
          sawRootRead = true;
        }
        h.priv.inject(
          sawRootRead ? PrivilegeMode.supervisor.id : PrivilegeMode.user.id,
        );
        h.ifetchEn.inject(0);
        h.dportEn.inject(1);
        h.dportAddr.inject(LogicValue.ofBigInt(BigInt.from(dataVa), 64));
        h.dportWe.inject(0);
      });

      final probe = h.mmu.probe.value.toInt();
      expect(probe & 0x1, 1, reason: 'everUser must be set');
      expect(
        probe & 0x4,
        0x4,
        reason:
            'latchMismatch must be set: a walk was accepted in user mode and its '
            'leaf returned after the core left user mode. That is the exact '
            'condition under which the grant-time latch differs from the live '
            'privilege check it replaced.',
      );
      expect(probe & 0x8, 0x8, reason: 'userFault must be set');
    },
  );

  test(
    'the user-mode probe stays clear when the core never leaves S',
    () async {
      final h = await buildMmu(userProbe: true);
      final r = await run(h, baseMemory(), 400, (i) {
        h.priv.inject(PrivilegeMode.supervisor.id);
        h.ifetchEn.inject(0);
        h.dportEn.inject(1);
        h.dportAddr.inject(LogicValue.ofBigInt(BigInt.from(dataVa), 64));
        h.dportWe.inject(0);
      });
      expect(
        r.bus.any((t) => t.addr == pgdSlot && !t.isWrite),
        isTrue,
        reason: 'VACUOUS: no walk happened',
      );
      expect(
        h.mmu.probe.value.toInt(),
        0,
        reason: 'the probe must not report an excursion that did not happen',
      );
    },
  );
}
