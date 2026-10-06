import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// mstatus.SUM lets S-mode read a page whose PTE has U set. Linux sets it
/// through `csrs sstatus` around every copy_to_user/copy_from_user/get_user, so
/// with SUM stuck at 0 no init process can run.
///
/// River read SUM from mstatus[18] but mstatus had no SUM field, and sstatus was
/// a separate register, so the kernel's write went nowhere and SUM was always 0.
///
/// Both tests below run the SAME program on the SAME page tables and differ only
/// in the value written to sstatus. The core starts in supervisor mode, so the
/// load is a real S-mode access to a user page.
///
/// Each test asserts that the page-table root was actually read, so a run with
/// paging off cannot pass, and it tags every bus read and every trap with the
/// privilege mode that made it, so work the core did after falling back to
/// machine mode (where paging is off) cannot be mistaken for the S-mode result.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Privilege mode encodings, as the core drives its `mode` register.
  const supervisor = 1;
  const machine = 3;

  const loadPageFault = 13;

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

  /// Build a memory image string from 32-bit words. A 64-bit value (a PTE) is
  /// two entries, low half first.
  String mem(Map<int, List<int>> words) {
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

  // Sv39 leaf bits: V|R|W|X|A|D with U clear, a supervisor page. A and D are
  // pre-set so no hardware A/D writeback adds bus traffic to filter out.
  const leafS = 0xCF;
  // The same leaf with U set: a user page.
  const leafU = 0xDF;
  int megapage(int pa, int leaf) => ((pa >> 12) << 10) | leaf;

  // Sv39, root PPN 0x10 -> root table at PA 0x10000. Root entry i is at
  // 0x10000 + i*8 and covers 1GB of virtual address space.
  const satp = 0x8000000000000010;
  int rootEntry(int i) => 0x10000 + i * 8;

  // The user page and the pointer it holds.
  const userPage = 0xC0000000;
  const pointerTarget = 0xC0001000;

  /// Every bus read with the privilege mode that made it, and every exception
  /// with the mode that took it.
  final reads = <List<int>>[];
  final traps = <List<int>>[];

  bool sawRead(int addr, {int? inMode}) =>
      reads.any((r) => r[0] == addr && (inMode == null || r[1] == inMode));
  bool sawTrap(int cause, {int? inMode}) =>
      traps.any((t) => t[0] == cause && (inMode == null || t[1] == inMode));
  String report() =>
      'reads (addr@mode): '
      '${reads.map((r) => '0x${r[0].toRadixString(16)}@${r[1]}').join(', ')}\n'
      'traps (cause@mode): '
      '${traps.map((t) => '${t[0]}@${t[1]}').join(', ')}';

  /// Run [program] on rc1-f with [pageTables], seeding [regs] into the register
  /// file first, and fill [reads] and [traps].
  Future<void> run(
    Map<int, List<int>> program,
    Map<int, List<int>> pageTables,
    Map<int, int> regs, {
    int cycles = 4000,
  }) async {
    reads.clear();
    traps.clear();
    final config = rc1f();
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic();
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
      resetPrivilege: PrivilegeMode.supervisor.id,
    );
    core.input('clk').srcConnection! <= clk;
    core.input('reset').srcConnection! <= reset;
    await core.build();

    // The privilege register and the pipeline's exception report. Sampling these
    // is what separates a real permission fault from the core quietly running in
    // machine mode with paging off.
    final modeSig = core.internalSignals.firstWhere((s) => s.name == 'mode');
    final pipe = core.subModules.firstWhere(
      (m) => m.outputs.containsKey('trapCause'),
    );
    final trapSig = pipe.output('trap');
    final trapCauseSig = pipe.output('trapCause');
    final trapIntSig = pipe.output('trapInterrupt');

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
    final model = MemoryModel(
      clk,
      reset,
      [wrapWriteForRegisterFile(memWrite)],
      [wrapReadForRegisterFile(memRead, clk: clk, readLatency: 0)],
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

    // Hold ACK off while the register file is seeded, so the core cannot get
    // past its first fetch before the constants it needs are in place.
    final seedGate = Logic(name: 'seedGate');
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

    final image = mem({...program, ...pageTables});

    reset.inject(1);
    seedGate.inject(1);
    prfSeedMode.inject(1);
    Simulator.registerAction(20, () {
      reset.put(0);
      storage.loadMemString(image);
    });
    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());

    for (final entry in regs.entries) {
      await clk.nextPosedge;
      core.regWritePort.en.inject(1);
      core.regWritePort.addr.inject(LogicValue.ofInt(entry.key, 5));
      core.regWritePort.data.inject(
        LogicValue.ofInt(entry.value, config.mxlen.size),
      );
    }
    await clk.nextPosedge;
    core.regWritePort.en.inject(0);
    seedGate.inject(0);
    prfSeedMode.inject(0);
    while (reset.value.toBool()) {
      await clk.nextPosedge;
    }

    var lastTrap = -1;
    for (var i = 0; i < cycles; i++) {
      await clk.nextPosedge;
      final md = modeSig.value.isValid ? modeSig.value.toInt() : -1;
      final adr = wbAdr.value;
      if (wbCyc.value.toBool() &&
          wbStb.value.toBool() &&
          !wbWe.value.toBool() &&
          adr.isValid) {
        final a = adr.toInt();
        if (reads.isEmpty || reads.last[0] != a) reads.add([a, md]);
      }
      // An exception (not an interrupt), recorded with the mode that took it.
      // The mode register still holds the pre-trap privilege this cycle.
      if (trapSig.value.isValid &&
          trapSig.value.toBool() &&
          !trapIntSig.value.toBool() &&
          trapCauseSig.value.isValid) {
        final c = trapCauseSig.value.toInt();
        if (c != lastTrap) traps.add([c, md]);
        lastTrap = c;
      } else {
        lastTrap = -1;
      }
    }

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }

  // The one program both tests run. It starts in supervisor mode.
  //
  //   csrw satp,a0      a0 = Sv39 | root 0x10
  //   csrw sstatus,a2   a2 = SUM, or 0
  //   ld a1,0(a5)       a5 = 0xC0000000, a USER page read from S-mode
  //   ld a2,0(a1)       dereference what it read
  //   j .
  //
  // The value at the user page is a pointer to 0xC0001000, so a load that SUM
  // allowed shows on the bus as a supervisor read of 0xC0001000. A load that
  // faulted can never produce it.
  final program = <int, List<int>>{
    0x00: [
      0x18051073, // csrw satp,a0
      0x10061073, // csrw sstatus,a2
      0x0007B583, // ld a1,0(a5)
      0x0005B603, // ld a2,0(a1)
      0x0000006F, // j .
    ],
    userPage: [pointerTarget, 0],
    pointerTarget: [0xDEADBEEF, 0],
  };

  // VA 0-1GB identity-maps the kernel code (U clear). VA 3-4GB identity-maps the
  // user page (U set). Nothing else is mapped.
  final pageTables = {
    rootEntry(0): [megapage(0, leafS), 0],
    rootEntry(3): [megapage(userPage, leafU), 0],
  };

  // a0 = satp, a2 = the sstatus value, a5 = the user address.
  Map<int, int> regsWith(int sstatusWord) => {
    10: satp,
    12: sstatusWord,
    15: userPage,
  };

  test(
    'rc1-f: an S-mode load of a user page FAULTS with sstatus.SUM clear',
    timeout: Timeout(Duration(minutes: 45)),
    () async {
      await run(program, pageTables, regsWith(0));

      expect(
        sawRead(rootEntry(3)),
        isTrue,
        reason:
            'the MMU never walked the page table for the user address, so '
            'paging was not on and this result means nothing\n${report()}',
      );
      expect(
        sawTrap(loadPageFault, inMode: supervisor),
        isTrue,
        reason:
            'no load page fault was taken in supervisor mode. With SUM clear an '
            'S-mode load of a PTE.U page MUST fault\n${report()}',
      );
      expect(
        sawRead(pointerTarget, inMode: supervisor),
        isFalse,
        reason:
            'the faulting load still handed a value to the next instruction\n'
            '${report()}',
      );
    },
  );

  test(
    'rc1-f: sstatus.SUM lets an S-mode load read a user page',
    timeout: Timeout(Duration(minutes: 45)),
    () async {
      // Bit 18 is SUM. Linux sets it exactly like this, with a write to sstatus.
      await run(program, pageTables, regsWith(1 << 18));

      expect(
        sawRead(rootEntry(3)),
        isTrue,
        reason:
            'the MMU never walked the page table for the user address, so '
            'paging was not on and this result means nothing\n${report()}',
      );
      expect(
        sawRead(userPage, inMode: supervisor),
        isTrue,
        reason:
            'the supervisor load never reached memory, so SUM did not let it '
            'through\n${report()}',
      );
      expect(
        sawRead(pointerTarget, inMode: supervisor),
        isTrue,
        reason:
            'SUM IS DEAD: the S-mode load of the user page did not deliver its '
            'value, so the dereference never ran. sstatus.SUM must reach '
            'mstatus[18], which is what the MMU checks. Every copy_to_user and '
            'copy_from_user in the kernel needs this\n${report()}',
      );
      expect(
        sawTrap(loadPageFault),
        isFalse,
        reason:
            'a load page fault was taken even though SUM is set\n${report()}',
      );
      expect(
        sawRead(pointerTarget, inMode: machine),
        isFalse,
        reason:
            'the read happened in machine mode, where paging is off, not in '
            'supervisor mode\n${report()}',
      );
    },
  );
}
