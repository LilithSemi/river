import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// The L1 D-cache is in FRONT of the MMU, so it is virtually indexed AND
/// virtually tagged. Its tag used to be sized from a 32-bit PHYSICAL map width,
/// so it held VA[31:tagLo] and never compared VA[63:32].
///
/// Under Sv39 the kernel puts the linear map, vmalloc (where VMAP_STACK keeps
/// kernel stacks) and kernel text at different VA[38:32] with overlapping low
/// bits. Two such addresses were one cache line, so a load of one was answered
/// with the other page's data. On the board that showed as
/// `list_add corruption. prev->next should be next but was 0`, which looks
/// exactly like a store that never landed but is really a bad read.
///
/// This runs rc1-f with real Sv39 page tables. Both addresses are SUPERVISOR
/// pages reached in SUPERVISOR mode from one satp, and they are mapped to
/// DIFFERENT physical frames. No privilege change and no flush happens, so
/// neither the context tag nor the satp flush can be credited with the result:
/// only the address tag can separate these two.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const supervisor = 1;

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

  /// Memory image from 32-bit words. A 64-bit value is two entries, low first.
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

  // Sv39 leaf: V|R|W|X|A|D with U clear, a supervisor page. A and D are pre-set
  // so no hardware writeback adds bus traffic to filter out.
  const leafS = 0xCF;
  int megapage(int pa, int leaf) => ((pa >> 12) << 10) | leaf;

  // Sv39, root PPN 0x10 -> root table at PA 0x10000. Root entry i covers the
  // 1 GB of virtual space at VA[38:30] == i.
  const satp = 0x8000000000000010;
  int rootEntry(int i) => 0x10000 + i * 8;

  // Two SUPERVISOR virtual addresses from the RISC-V Sv39 kernel layout that
  // share their low 32 bits and differ only in VA[38:32]: a linear-map address
  // and a vmalloc address. VA[38:30] picks the root entry, VA[29:0] is the
  // offset inside the 1 GB megapage.
  const vaLinear = 0xFFFFFFD602087000; // root 0x158, offset 0x2087000
  const vaVmalloc = 0xFFFFFFD002087000; // root 0x140, same offset
  const rootLinear = 0x158;
  const rootVmalloc = 0x140;
  const pageOffset = 0x2087000;

  // Different physical frames, so the two pages hold different data.
  const paLinearBase = 0x40000000;
  const paVmallocBase = 0x80000000;
  const paLinear = paLinearBase + pageOffset;
  const paVmalloc = paVmallocBase + pageOffset;

  // What each page holds: a pointer the program dereferences, so which value
  // the second load actually received shows up as a bus read address.
  const markerLinear = 0x5000;
  const markerVmalloc = 0x6000;

  final reads = <List<int>>[];

  bool sawRead(int addr, {int? inMode}) =>
      reads.any((r) => r[0] == addr && (inMode == null || r[1] == inMode));
  String report() =>
      'reads (addr@mode): '
      '${reads.map((r) => '0x${r[0].toRadixString(16)}@${r[1]}').join(', ')}';

  Future<void> run(
    Map<int, List<int>> program,
    Map<int, List<int>> pageTables,
    Map<int, int> regs, {
    int cycles = 4000,
  }) async {
    reads.clear();
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
      resetPrivilege: supervisor,
    );
    core.input('clk').srcConnection! <= clk;
    core.input('reset').srcConnection! <= reset;
    await core.build();

    final modeSig = core.internalSignals.firstWhere((s) => s.name == 'mode');

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
    }

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }

  test(
    'rc1-f: a vmalloc load must not hit the linear-map D-cache line',
    timeout: Timeout(Duration(minutes: 45)),
    () async {
      // Supervisor code at VA 0:
      //
      //   csrw satp,a0     a0 = Sv39 | root 0x10
      //   ld a1,0(a5)      a5 = linear-map VA, fills the line
      //   ld a2,0(a6)      a6 = vmalloc VA, SAME low 32 bits, different page
      //   ld a3,0(a2)      dereference what the second load returned
      //   j .
      //
      // The two pages hold different pointers, so the address of that last bus
      // read says which page the second load was actually served from.
      await run(
        {
          0x00: [
            0x18051073, // csrw satp,a0
            0x0007B583, // ld a1,0(a5)
            0x00083603, // ld a2,0(a6)
            0x00063683, // ld a3,0(a2)
            0x0000006F, // j .
          ],
          paLinear: [markerLinear, 0],
          paVmalloc: [markerVmalloc, 0],
        },
        {
          // VA 0-1GB identity, so the code and the dereferenced pointers map.
          rootEntry(0): [megapage(0, leafS), 0],
          rootEntry(rootLinear): [megapage(paLinearBase, leafS), 0],
          rootEntry(rootVmalloc): [megapage(paVmallocBase, leafS), 0],
        },
        {
          10: satp, // a0
          15: vaLinear, // a5
          16: vaVmalloc, // a6
        },
      );

      expect(
        sawRead(rootEntry(rootLinear)),
        isTrue,
        reason:
            'the MMU never walked the linear-map root entry, so paging was '
            'not on and the test proves nothing\n${report()}',
      );
      expect(
        sawRead(paLinear, inMode: supervisor),
        isTrue,
        reason:
            'the first load never reached memory, so no D-cache line was '
            'filled\n${report()}',
      );
      expect(
        sawRead(paVmalloc, inMode: supervisor),
        isTrue,
        reason:
            'TAG ALIAS: the vmalloc load never reached memory. It HIT the line '
            'the linear-map load filled, because the D-cache tag holds no '
            'address bit above 31 and the two addresses share their low 32 '
            'bits\n${report()}',
      );
      expect(
        sawRead(markerVmalloc, inMode: supervisor),
        isTrue,
        reason:
            'the vmalloc load did not return the vmalloc page pointer\n'
            '${report()}',
      );
      expect(
        sawRead(markerLinear, inMode: supervisor),
        isFalse,
        reason:
            'TAG ALIAS: the vmalloc load was served the LINEAR-MAP page data. '
            'Two different physical frames, one privilege context, one satp, '
            'no flush: only the address tag can separate them, and it does '
            'not compare VA[38:32]\n${report()}',
      );
    },
  );
}
