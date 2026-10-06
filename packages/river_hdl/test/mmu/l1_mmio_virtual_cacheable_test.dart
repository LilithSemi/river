import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Is a device register still uncached once paging is on?
///
/// The L1 D-cache decides cacheability with
/// `cacheableOf(a) => a.gte(cacheableBase)` (harbor l1_cache.dart), and `a` is
/// `req_addr`, the address the pipeline presents. The cache sits in FRONT of
/// the MMU, so with paging on that address is a VIRTUAL one. `cacheableBase` is
/// 0x80000000, the DRAM base, which is a PHYSICAL landmark.
///
/// Under Sv39 every kernel virtual address is in the upper half
/// (0xFFFFFFC000000000 and up), so every kernel address compares at or above
/// 0x80000000 whatever it translates to. A device mapped by `ioremap` therefore
/// looks cacheable to the D-cache, and its status register can be answered from
/// a line instead of from the device.
///
/// This test maps a device physical address (0x10000000, far below
/// `cacheableBase`) at a kernel virtual address and reads it twice. The bus log
/// says how many times the device was actually read.
///
/// D-cache line arithmetic (256 B, 8-byte lines, direct mapped, xlen 64):
/// index = VA[7:3]. deviceVa 0xFFFFFFD010000000 -> index 0, and it is at or
/// above `cacheableBase`, so it takes the CACHED path.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const supervisor = 1;

  RiverCoreConfig rc1f() => RiverCoreConfigV1.full(
    interrupts: [],
    regfileReadLatency: 1,
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

  // Sv39 leaf: V|R|W|X|A|D with U clear, a supervisor page.
  const leafS = 0xCF;
  int megapage(int pa) => ((pa >> 12) << 10) | leafS;

  const satp = 0x8000000000000000 | 0x10;
  int rootEntry(int i) => 0x10000 + i * 8;

  // A kernel virtual address for a device that lives at a low physical
  // address. VA[38:30] == 0x140 selects the root entry; the entry maps that
  // 1 GB of virtual space onto physical 0.
  const rootDevice = 0x140;
  const deviceVa = 0xFFFFFFD010000000;
  const devicePa = 0x10000000;

  final reads = <int>[];
  int countRead(int addr) => reads.where((r) => r == addr).length;
  String report() =>
      'bus reads: ${reads.map((r) => '0x${r.toRadixString(16)}').join(', ')}';

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
      final adr = wbAdr.value;
      if (wbCyc.value.toBool() &&
          wbStb.value.toBool() &&
          !wbWe.value.toBool() &&
          adr.isValid) {
        final a = adr.toInt();
        if (reads.isEmpty || reads.last != a) reads.add(a);
      }
    }

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }

  test(
    'a device mapped at a kernel virtual address is read every time',
    timeout: const Timeout(Duration(minutes: 45)),
    // KNOWN FAILURE, kept as the record of it. The run reads the device ONCE
    // for two loads.
    //
    // The fix is not in the cache. The cache is in front of the MMU, so it
    // cannot know the physical address and cannot decide cacheability from it.
    // The core must tell it: either give HarborL1DCache a `req_cacheable`
    // input that the MMU drives from the TRANSLATED address, or move the
    // D-cache behind the MMU. Until then `cacheableBase` only works with
    // paging off, which is why creek (bare mode, VA == PA) never showed this.
    //
    // Remove the skip with the fix.
    skip:
        'the D-cache reads cacheability off the VIRTUAL address, so every '
        'Sv39 kernel mapping of a device looks cacheable. Needs a physical '
        'cacheability signal from the MMU, which is a core change.',
    () async {
      // Supervisor code at VA 0:
      //
      //   csrw satp,a0     a0 = Sv39 | root 0x10
      //   ld a1,0(a5)      a5 = the device virtual address
      //   ld a2,0(a5)      the SAME device register again
      //   j .
      //
      // A device register must be read from the device every time. Two reads
      // of one register that reach the bus once means the second was answered
      // from a cache line, which is how a driver spins forever on a status bit
      // that already changed.
      await run(
        {
          0x00: [
            0x18051073, // csrw satp,a0
            0x0007B583, // ld a1,0(a5)
            0x0007B603, // ld a2,0(a5)
            0x0000006F, // j .
          ],
          devicePa: [0x1234, 0],
        },
        {
          // VA 0-1GB identity, so the code runs.
          rootEntry(0): [megapage(0), 0],
          // The device 1 GB window at a kernel virtual address.
          rootEntry(rootDevice): [megapage(0), 0],
        },
        {
          10: satp, // a0
          15: deviceVa, // a5
        },
      );

      expect(
        reads.contains(rootEntry(rootDevice)),
        isTrue,
        reason:
            'the MMU never walked the device root entry, so paging was not on '
            'and the test proves nothing\n${report()}',
      );
      expect(
        countRead(devicePa),
        equals(2),
        reason:
            'MMIO CACHED UNDER PAGING: the device register was read '
            '${countRead(devicePa)} time(s) for two loads. The D-cache decides '
            'cacheability from the VIRTUAL address (cacheableOf in harbor '
            'l1_cache.dart), and every Sv39 kernel virtual address is above '
            'the 0x80000000 DRAM base, so an ioremapped device looks '
            'cacheable\n${report()}',
      );
    },
  );
}
