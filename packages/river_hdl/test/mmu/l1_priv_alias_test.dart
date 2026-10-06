import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Both L1 caches sit in FRONT of the MMU. The pipeline gives the cache a
/// VIRTUAL address, and only a MISS goes on to the MMU, which translates it and
/// checks the PTE permissions. A HIT is decided by the tag and the valid bit
/// alone. [HarborL1DCache] and [HarborL1ICache] had no privilege input at all.
///
/// So a line that one privilege mode is allowed to touch stayed usable by the
/// other mode, which the page table says must not touch it. The privilege change
/// itself does not invalidate the line: the MMU has DTLBFC (`dtlbFlushOnPriv`)
/// for its own data TLB, but that signal does not reach the L1s.
///
/// Every test below uses ONE address space (satp is written once). Only the
/// privilege mode changes, so no satp write and no sfence.vma can be claimed to
/// have covered the case.
///
/// The cache tag is also narrower than the virtual address. Both L1s are built
/// with `physAddrBits: 32`, so the tag is VA[31:tagLo] and VA[63:32] is not
/// compared at all. A supervisor-half Sv39 address and a user-half address that
/// share their low 32 bits are the SAME line.
///
/// Each test asserts the privilege mode at every step and the exact trap cause,
/// so a run that fell back to machine mode (where paging is off and no
/// permission check is expected) cannot pass as either a fault or a leak.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Privilege mode encodings, as the core drives its `mode` register.
  const user = 0;
  const supervisor = 1;
  const machine = 3;

  // Exception causes.
  const ecallFromUser = 8;
  const instructionPageFault = 12;
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

  /// What the core did, as seen from outside: every bus read with the privilege
  /// mode that made it, and every exception with the mode that took it.
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
    int resetPriv = supervisor,
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
      resetPrivilege: resetPriv,
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

  test(
    'rc1-f: a user load must not hit a D-cache line a supervisor load filled',
    timeout: Timeout(Duration(minutes: 45)),
    () async {
      // Supervisor code at VA 0 reads VA 0x80000000, a supervisor-only page
      // (PTE.U=0). That fills D-cache line 0 (index = addr[7:3]).
      //
      //   csrw satp,a0      a0 = Sv39 | root 0x10
      //   ld a1,0(a5)       a5 = 0x80000000, fills the line
      //   csrw sepc,a7      a7 = 0xC0000000, the user entry
      //   csrw sstatus,x0   SPP = 0 (return to user) and SUM = 0
      //   sret              -> user mode at VA 0xC0000000
      //
      // The user code reads the SAME virtual address. PTE.U is clear, so the
      // access must take a load page fault whatever SUM says. The value it would
      // read is a pointer into the user page, and the user dereferences it, so a
      // successful read shows as a bus read of 0xC0001000 that a faulting run
      // can never produce.
      await run(
        {
          0x00: [
            0x18051073, // csrw satp,a0
            0x0007B583, // ld a1,0(a5)
            0x14189073, // csrw sepc,a7
            0x10001073, // csrw sstatus,x0
            0x10200073, // sret
          ],
          0x80000000: [0xC0001000, 0], // the supervisor-only value
          0xC0000000: [
            0x0007B603, // ld a2,0(a5)   must page-fault
            0x00063683, // ld a3,0(a2)   only reached if it did not
            0x0000006F, // j .
          ],
        },
        {
          rootEntry(0): [megapage(0, leafS), 0], // VA 0-1GB, kernel code
          rootEntry(2): [megapage(0x80000000, leafS), 0], // VA 2-3GB, kernel
          rootEntry(3): [megapage(0xC0000000, leafU), 0], // VA 3-4GB, user
        },
        {
          10: satp, // a0
          15: 0x80000000, // a5
          17: 0xC0000000, // a7
        },
      );

      expect(
        sawRead(rootEntry(2)),
        isTrue,
        reason:
            'the MMU never walked the page table, so paging was not on\n${report()}',
      );
      expect(
        sawRead(0x80000000, inMode: supervisor),
        isTrue,
        reason:
            'no supervisor-mode load reached memory, so no line was filled\n${report()}',
      );
      expect(
        sawRead(0xC0000000, inMode: user),
        isTrue,
        reason:
            'the core never fetched the user code in user mode\n${report()}',
      );
      expect(
        sawRead(0xC0001000, inMode: user),
        isFalse,
        reason:
            'PRIVILEGE LEAK: the user-mode load of VA 0x80000000 was answered '
            'from the D-cache line the supervisor load left behind. The page is '
            'PTE.U=0, so the access must take a load page fault. The L1 D-cache '
            'is in front of the MMU and decides a hit from the tag alone, so no '
            'permission check ever ran.\n${report()}',
      );
      expect(
        sawTrap(loadPageFault, inMode: user),
        isTrue,
        reason: 'no load page fault was taken in user mode\n${report()}',
      );
    },
  );

  test(
    'rc1-f: a user load must not alias a supervisor-half D-cache line',
    timeout: Timeout(Duration(minutes: 45)),
    () async {
      // The Linux-shaped case. Supervisor and user virtual addresses are in
      // opposite halves of the Sv39 space, so they never collide on a full
      // 64-bit tag. The tag is only VA[31:8], so they DO collide: kernel VA
      // 0xFFFFFFC080000000 and user VA 0x80000000 are one line.
      //
      // Both addresses are legally mapped, to DIFFERENT physical pages:
      //   kernel VA 0xFFFFFFC080000000 -> PA 0x80000000    U=0
      //   user   VA 0x80000000         -> PA 0x100000000   U=1
      //
      // The kernel reads its own address, then drops to user. The user reads its
      // own, entirely legal, address, so nothing here may fault. It must get
      // PA 0x100000000. The value at each physical page is a distinct pointer
      // the user then dereferences, so which page answered is visible.
      await run(
        {
          0x00: [
            0x18051073, // csrw satp,a0
            0x00073583, // ld a1,0(a4)   a4 = 0xFFFFFFC080000000
            0x14189073, // csrw sepc,a7
            0x10001073, // csrw sstatus,x0
            0x10200073, // sret
          ],
          0x80000000: [0xC0001000, 0], // kernel-only value
          0x100000000: [0xC0002000, 0], // the user's own value
          0xC0000000: [
            0x0007B603, // ld a2,0(a5)   a5 = 0x80000000, a legal user address
            0x00063683, // ld a3,0(a2)
            0x0000006F, // j .
          ],
        },
        {
          rootEntry(0): [megapage(0, leafS), 0], // VA 0-1GB, kernel code
          rootEntry(2): [megapage(0x100000000, leafU), 0], // user data page
          rootEntry(3): [megapage(0xC0000000, leafU), 0], // user code page
          // VPN[2] of 0xFFFFFFC080000000 is 0x102.
          rootEntry(0x102): [megapage(0x80000000, leafS), 0],
        },
        {
          10: satp, // a0
          14: 0xFFFFFFC080000000, // a4
          15: 0x80000000, // a5
          17: 0xC0000000, // a7
        },
      );

      expect(
        sawRead(rootEntry(0x102)),
        isTrue,
        reason:
            'the MMU never walked the kernel mapping, so paging was not on\n${report()}',
      );
      expect(
        sawRead(0x80000000, inMode: supervisor),
        isTrue,
        reason:
            'no supervisor-mode load reached memory, so no line was filled\n${report()}',
      );
      expect(
        sawRead(0xC0000000, inMode: user),
        isTrue,
        reason:
            'the core never fetched the user code in user mode\n${report()}',
      );
      expect(
        sawRead(0xC0001000, inMode: user),
        isFalse,
        reason:
            'KERNEL MEMORY DISCLOSURE: the user load of its own legal address '
            'VA 0x80000000 was answered from the line the kernel load of VA '
            '0xFFFFFFC080000000 left behind. The L1 tag is only VA[31:8], so '
            'the two halves of the Sv39 space alias onto one line.\n${report()}',
      );
      expect(
        sawRead(0x100000000, inMode: user),
        isTrue,
        reason:
            'the user load never reached its own physical page, so it was '
            'answered from the cache instead of being translated\n${report()}',
      );
      expect(
        sawTrap(loadPageFault),
        isFalse,
        reason:
            'every access here is legal, so nothing may page-fault\n${report()}',
      );
    },
  );

  test(
    'rc1-f: a supervisor load with SUM clear must not hit a user D-cache line',
    timeout: Timeout(Duration(minutes: 45)),
    () async {
      // The reverse direction. A user page (PTE.U=1) is read in user mode, which
      // fills the line. The supervisor then reads the SAME virtual address with
      // sstatus.SUM clear, which must take a load page fault.
      //
      // Machine mode sets this up because the test needs medeleg (to send the
      // user ecall to the supervisor handler) and mtvec.
      //   csrw satp,a0     a0 = Sv39 | root 0x10
      //   csrw medeleg,a1  a1 = 0xFFFF, delegate every exception to S
      //   csrw stvec,a2    a2 = 0x40, the supervisor handler
      //   csrw mepc,a3     a3 = 0x20, the supervisor entry
      //   csrw mstatus,a4  a4 = 0x800, MPP = S, and SUM/MXR/MPRV all clear
      //   mret
      await run(
        {
          0x00: [
            0x18051073, // csrw satp,a0
            0x30259073, // csrw medeleg,a1
            0x10561073, // csrw stvec,a2
            0x34169073, // csrw mepc,a3
            0x30071073, // csrw mstatus,a4
            0x30200073, // mret
          ],
          // Supervisor entry: drop to user at VA 0xC0000000 with SUM clear.
          0x20: [
            0x14189073, // csrw sepc,a7
            0x10001073, // csrw sstatus,x0
            0x10200073, // sret
          ],
          // Supervisor trap handler. The user page read here is the same VA the
          // user just read, and SUM is clear, so it must page-fault. The value
          // is a pointer into the kernel page, so a successful read shows as a
          // bus read of 0x88000000.
          0x40: [
            0x00083683, // ld a3,0(a6)   a6 = 0xC0001000, must page-fault
            0x0006B703, // ld a4,0(a3)   only reached if it did not
            0x0000006F, // j .
          ],
          0xC0000000: [
            0x00083603, // ld a2,0(a6)   legal in user mode, fills the line
            0x00000073, // ecall         -> the supervisor handler
            0x0000006F, // j .
          ],
          0xC0001000: [0x88000000, 0], // the user's value
        },
        {
          rootEntry(0): [megapage(0, leafS), 0], // VA 0-1GB, kernel code
          rootEntry(2): [megapage(0x80000000, leafS), 0], // VA 2-3GB, kernel
          rootEntry(3): [megapage(0xC0000000, leafU), 0], // VA 3-4GB, user
        },
        {
          10: satp, // a0
          11: 0xFFFF, // a1, medeleg
          12: 0x40, // a2, stvec
          13: 0x20, // a3, mepc
          14: 0x800, // a4, mstatus MPP=S
          16: 0xC0001000, // a6
          17: 0xC0000000, // a7
        },
        resetPriv: machine,
      );

      expect(
        sawRead(0xC0001000, inMode: user),
        isTrue,
        reason:
            'no user-mode load reached memory, so no line was filled\n${report()}',
      );
      expect(
        sawTrap(ecallFromUser, inMode: user),
        isTrue,
        reason:
            'the user ecall never happened, so the handler was never entered\n${report()}',
      );
      expect(
        sawRead(0x40, inMode: supervisor),
        isTrue,
        reason:
            'the supervisor trap handler never ran, so nothing was tested\n${report()}',
      );
      expect(
        sawRead(0x88000000, inMode: supervisor),
        isFalse,
        reason:
            'SUM BYPASS: the supervisor load of user address VA 0xC0001000 with '
            'sstatus.SUM clear was answered from the D-cache line the user-mode '
            'load left behind, so the SUM check never ran.\n${report()}',
      );
      expect(
        sawTrap(loadPageFault, inMode: supervisor),
        isTrue,
        reason: 'no load page fault was taken in supervisor mode\n${report()}',
      );
    },
  );

  test(
    'rc1-f: user fetch must not hit an I-cache line a supervisor fetch filled',
    timeout: Timeout(Duration(minutes: 45)),
    () async {
      // The same question for the I-cache and the X permission. A supervisor
      // routine lives at VA 0x80000000 on a supervisor page (PTE.U=0), so user
      // mode must take an instruction page fault when it jumps there.
      //
      //   csrw satp,a0
      //   jalr ra,0(a6)     a6 = 0x80000000, fills the I-cache line
      //   csrw sepc,a7      a7 = 0xC0000020
      //   csrw sstatus,x0
      //   sret
      //
      // The routine loads through a2 and returns. The supervisor points a2 at
      // the kernel page and the user points it at the user page, so which mode
      // ran the routine is visible as two different bus reads.
      //
      // The user code sits at VA 0xC0000020, NOT at 0xC0000000. The I-cache is
      // 64B over 8 lines of 8B, so its index is addr[5:3] and VA 0xC0000000
      // shares line 0 with the routine at VA 0x80000000. User code there evicts
      // the routine before the user can jump to it, and the test proves nothing.
      // 0xC0000020 is line 4.
      await run(
        {
          0x00: [
            0x18051073, // csrw satp,a0
            0x000800E7, // jalr ra,0(a6)
            0x14189073, // csrw sepc,a7
            0x10001073, // csrw sstatus,x0
            0x10200073, // sret
          ],
          0x80000000: [
            0x00063683, // ld a3,0(a2)
            0x00008067, // ret
          ],
          0xC0000020: [
            0x00070613, // mv a2,a4      a4 = 0xC0002000
            0x000800E7, // jalr ra,0(a6) must take an instruction page fault
            0x0000006F, // j .
          ],
        },
        {
          rootEntry(0): [megapage(0, leafS), 0], // VA 0-1GB, kernel code
          rootEntry(2): [megapage(0x80000000, leafS), 0], // VA 2-3GB, kernel
          rootEntry(3): [megapage(0xC0000000, leafU), 0], // VA 3-4GB, user
        },
        {
          10: satp, // a0
          12: 0x88000000, // a2, the kernel data the routine reads in S-mode
          14: 0xC0002000, // a4, the user data it would read in U-mode
          16: 0x80000000, // a6, the routine
          17: 0xC0000020, // a7
        },
      );

      expect(
        sawRead(0x80000000, inMode: supervisor),
        isTrue,
        reason:
            'the supervisor never fetched the routine, so no line was filled\n${report()}',
      );
      expect(
        sawRead(0x88000000, inMode: supervisor),
        isTrue,
        reason: 'the supervisor never ran the routine\n${report()}',
      );
      expect(
        sawRead(0xC0000020, inMode: user),
        isTrue,
        reason:
            'the core never fetched the user code in user mode\n${report()}',
      );
      // Qualified by user mode. After the fault the trap goes to machine mode
      // (medeleg is 0 and mtvec is 0), which restarts the program untranslated
      // and runs the routine legitimately, so an unqualified read of the user
      // data address is NOT evidence of anything.
      expect(
        sawRead(0xC0002000, inMode: user),
        isFalse,
        reason:
            'USER EXECUTION OF A SUPERVISOR PAGE: the user jump to VA '
            '0x80000000 was answered from the I-cache line the supervisor fetch '
            'left behind. The page is PTE.U=0, so the fetch must take an '
            'instruction page fault.\n${report()}',
      );
      expect(
        sawTrap(instructionPageFault, inMode: user),
        isTrue,
        reason: 'no instruction page fault was taken in user mode\n${report()}',
      );
    },
  );
}
