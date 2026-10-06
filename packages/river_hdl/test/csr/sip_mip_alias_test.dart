import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// sip and sie are NOT registers. The privileged spec makes them restricted
/// VIEWS of mip and mie, narrowed to the supervisor interrupt set and to what
/// mideleg delegates. mip.SEIP itself reads as the OR of the interrupt
/// controller line and the software-writable bit.
///
/// River had three independent registers, and mip had no path from the PLIC
/// supervisor-external line at all. So with the line asserted and the interrupt
/// actually being taken, `csrr sip` read 0: software could not see the
/// interrupt it was handling, and could not tell which source raised it.
///
/// A separate sie was just as bad in the other direction: S-mode enabled an
/// interrupt in a register that the delivery path never reads back out of mie.
///
/// Every test below reads the state back through the OTHER name, so three
/// separate registers cannot pass.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const seip = 1 << 9; // mip/mie bit 9: supervisor external.

  RiverCoreConfig rc1s() => RiverCoreConfigV1.small(
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
      hasSupervisorUserMemory: true,
      hasMakeExecutableReadable: true,
    ),
    interrupts: [],
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(12000000),
    ),
    resetVector: 0,
  );

  // Emit ONE contiguous block from @0, gaps filled with nop. A per-word `@addr`
  // form makes SparseMemoryStorage take sub-8-byte writes that mis-pack a word
  // holding zero bytes, so a zero-heavy instruction reads back corrupted.
  String memString(Map<int, int> words) {
    const nop = 0x00000013;
    final maxAddr = words.keys.reduce((a, b) => a > b ? a : b);
    final sb = StringBuffer('@0\n');
    for (var addr = 0; addr <= maxAddr + 4; addr += 4) {
      final w = words[addr] ?? nop;
      for (var b = 0; b < 4; b++) {
        sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return sb.toString();
  }

  /// Run [program] with the PLIC supervisor-external line held at [seiLine],
  /// seeding [regs] into the register file first. Returns the architectural
  /// register file once the core reaches [parkPc], plus whether it got there.
  Future<({Map<int, BigInt> regs, bool parked})> run(
    Map<int, int> program,
    Map<int, int> regs, {
    required bool seiLine,
    required int parkPc,
    int maxCycles = 30000,
  }) async {
    final config = rc1s();
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic();
    final addrWidth = config.mxlen.size;
    final wbConfig = WishboneConfig(
      addressWidth: addrWidth,
      dataWidth: config.mxlen.size,
      selWidth: config.mxlen.size ~/ 8,
    );

    final sei = Logic(name: 'seiLine');
    final prfSeedMode = Logic(name: 'prfSeedMode');
    final core = RiverCore(
      config,
      busConfig: wbConfig,
      prfSeedMode: prfSeedMode,
      supervisorExternalPending: sei,
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

    memRead.en <= wbCyc & wbStb & ~wbWe;
    memRead.addr <= wbAdr;
    memWrite.en <= wbCyc & wbStb & wbWe;
    memWrite.addr <= wbAdr;
    memWrite.data <= core.output('dataBus_DAT_MOSI');

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

    reset.inject(1);
    seedGate.inject(1);
    prfSeedMode.inject(1);
    // The line is held for the WHOLE run, the way a level-sensitive PLIC output
    // behaves until software claims the source.
    sei.inject(seiLine ? 1 : 0);
    Simulator.registerAction(20, () {
      reset.put(0);
      storage.loadMemString(memString(program));
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

    var parked = false;
    for (var i = 0; i < maxCycles; i++) {
      await clk.nextPosedge;
      final pc = core.pipeline.nextPc.value;
      if (pc.isValid && pc.toInt() == parkPc) {
        parked = true;
        break;
      }
    }
    // Let the last csr read retire into the register file.
    for (var i = 0; i < 20; i++) {
      await clk.nextPosedge;
    }

    final out = <int, BigInt>{};
    for (var r = 1; r < 32; r++) {
      out[r] = core.regs.getData(LogicValue.ofInt(r, 5))!.toBigInt();
    }
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
    return (regs: out, parked: parked);
  }

  test(
    'the PLIC supervisor-external line is visible in mip.SEIP and sip.SEIP',
    () async {
      await Simulator.reset();
      // Machine mode, interrupts globally off, so nothing is taken and the
      // program runs straight through. Delegate SEI, then look at the bit
      // through BOTH names, and enable it through sie and read mie back.
      //   csrw mideleg,x11   x11 = SEIP
      //   csrr x5,sip        must show the line
      //   csrr x6,mip        must show the line
      //   csrw sie,x12       x12 = SEIP, written through the S name
      //   csrr x7,sie
      //   csrr x8,mie        must show what the sie write did
      final program = <int, int>{
        0x00: 0x30359073, // csrw mideleg,x11
        0x04: 0x144022f3, // csrr x5,sip
        0x08: 0x34402373, // csrr x6,mip
        0x0c: 0x10461073, // csrw sie,x12
        0x10: 0x104023f3, // csrr x7,sie
        0x14: 0x30402473, // csrr x8,mie
        0x18: 0x0000006F, // j .
      };
      final r = await run(
        program,
        {11: seip, 12: seip},
        seiLine: true,
        parkPc: 0x18,
      );
      expect(r.parked, isTrue, reason: 'the program never reached its park');
      expect(
        r.regs[5],
        BigInt.from(seip),
        reason:
            'csrr sip read 0 with the supervisor-external line ASSERTED. '
            'Software cannot see the interrupt it is handling.',
      );
      expect(
        r.regs[6],
        BigInt.from(seip),
        reason:
            'csrr mip did not show the line. mip.SEIP must read as the OR of '
            'the hardware line and the software-writable bit.',
      );
      expect(r.regs[7], BigInt.from(seip), reason: 'sie did not read back');
      expect(
        r.regs[8],
        BigInt.from(seip),
        reason:
            'a write to sie never reached mie, so sie is still a register of '
            'its own. The delivery path enables from mie.',
      );
    },
    timeout: Timeout(Duration(minutes: 10)),
  );

  test(
    'supervisor cannot clear the PLIC line through sip.SEIP',
    () async {
      await Simulator.reset();
      // sip.SEIP is READ-ONLY to supervisor: the bit software sees is the
      // interrupt controller's wire, and only claiming the source at the PLIC
      // lowers it. A csrc that could clear it would let a handler lose an
      // interrupt that is still asserted.
      //   csrw mideleg,x11   x11 = SEIP
      //   csrr x9,mideleg    the delegation the rest of this test depends on
      //   csrc sip,x13       x13 = SEIP, an attempt to clear the line
      //   csrr x5,sip        must STILL show it
      //   csrr x6,mip        must STILL show it
      final program = <int, int>{
        0x00: 0x30359073, // csrw mideleg,x11
        0x04: 0x303024f3, // csrr x9,mideleg
        0x08: 0x14463073, // csrc sip,x13
        0x0c: 0x144022f3, // csrr x5,sip
        0x10: 0x34402373, // csrr x6,mip
        0x14: 0x0000006F, // j .
      };
      final r = await run(
        program,
        {11: seip, 13: seip},
        seiLine: true,
        parkPc: 0x14,
      );
      expect(r.parked, isTrue, reason: 'the program never reached its park');
      expect(
        r.regs[9],
        BigInt.from(seip),
        reason:
            'mideleg did not take the delegation, so the rest of this test '
            'would prove nothing',
      );
      expect(
        r.regs[5],
        BigInt.from(seip),
        reason:
            'a csrc of sip.SEIP changed what sip shows. The bit is the PLIC '
            'wire, so it must stay set until the source is claimed.',
      );
      expect(
        r.regs[6],
        BigInt.from(seip),
        reason: 'mip.SEIP must show the line whatever software writes',
      );
    },
    timeout: Timeout(Duration(minutes: 10)),
  );

  test(
    'an undelegated interrupt reads as zero through sip and sie',
    () async {
      await Simulator.reset();
      // mideleg stays 0. The spec says a cause that is not delegated reads as
      // zero in sip/sie and is not writable there. This is the same mideleg the
      // trap-target choice uses, so the two models cannot disagree.
      //   csrr x5,sip        line asserted, but SEI is NOT delegated -> 0
      //   csrw sie,x12       must not reach mie
      //   csrr x8,mie
      final program = <int, int>{
        0x00: 0x144022f3, // csrr x5,sip
        0x04: 0x10461073, // csrw sie,x12
        0x08: 0x30402473, // csrr x8,mie
        0x0c: 0x0000006F, // j .
      };
      final r = await run(program, {12: seip}, seiLine: true, parkPc: 0x0c);
      expect(r.parked, isTrue, reason: 'the program never reached its park');
      expect(
        r.regs[5],
        BigInt.zero,
        reason: 'an undelegated interrupt must read as zero through sip',
      );
      expect(
        r.regs[8],
        BigInt.zero,
        reason: 'sie must not write an interrupt mideleg does not delegate',
      );
    },
    timeout: Timeout(Duration(minutes: 10)),
  );

  test(
    'the line delivered through the sip view actually vectors to stvec',
    () async {
      await Simulator.reset();
      // The end-to-end guard: the CSR view is what the take decision reads, so
      // a cosmetic read that no longer feeds delivery would fail here.
      //   csrw mideleg,x11   x11 = SEIP
      //   csrw stvec,x13     x13 = 0x80
      //   csrs sie,x12       x12 = SEIP
      //   csrw mepc,x10      x10 = 0x40
      //   csrw mstatus,x14   x14 = MPP=S | SIE
      //   mret               -> S at 0x40, where the line is already asserted
      //   0x40 j .           the interrupt must break this spin
      //   0x80 csrr x5,scause / csrr x6,sip
      final program = <int, int>{
        0x00: 0x30359073, // csrw mideleg,x11
        0x04: 0x10569073, // csrw stvec,x13
        0x08: 0x10462073, // csrs sie,x12
        0x0c: 0x34151073, // csrw mepc,x10
        0x10: 0x30071073, // csrw mstatus,x14
        0x14: 0x30200073, // mret
        0x40: 0x0000006F, // j .
        0x80: 0x142022f3, // csrr x5,scause
        0x84: 0x14402373, // csrr x6,sip
        0x88: 0x0000006F, // j .
      };
      final r = await run(
        program,
        {11: seip, 12: seip, 13: 0x80, 10: 0x40, 14: 0x802},
        seiLine: true,
        parkPc: 0x88,
      );
      expect(
        r.parked,
        isTrue,
        reason:
            'the core never vectored to stvec, so the supervisor-external '
            'interrupt was not delivered',
      );
      expect(
        r.regs[5],
        (BigInt.one << 63) | BigInt.from(9),
        reason: 'scause must be interrupt|9 (supervisor external)',
      );
      expect(
        r.regs[6],
        BigInt.from(seip),
        reason:
            'the handler could not see WHICH interrupt it was handling: '
            'csrr sip read 0 inside the handler for that interrupt',
      );
    },
    timeout: Timeout(Duration(minutes: 10)),
  );
}
