import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Wires a real [RiverCore] (with debug enabled) to a [RiverDebugModule] and a
/// memory model, then drives the chain over JTAG the way OpenOCD would. This is
/// the integration counterpart to the isolated debug_module_test: it proves the
/// Debug Module actually halts and resumes the live core.
class DebugRig {
  final RiverCore core;
  final RiverDebugModule dbg;
  final Logic clk;
  final Logic tck, tms, tdi;
  final Logic sbaRdata, sbaAck;
  final MemoryStorage storage;
  final int xlen;
  bool _acked = false;

  DebugRig(
    this.core,
    this.dbg,
    this.clk,
    this.tck,
    this.tms,
    this.tdi,
    this.sbaRdata,
    this.sbaAck,
    this.storage,
    this.xlen,
  );

  Future<void> _tick() async {
    await clk.nextPosedge;
    final req = dbg.sbaReq.value.isValid ? dbg.sbaReq.value.toInt() : 0;
    if (req == 1 && !_acked) {
      final bytes = xlen ~/ 8;
      final addr = dbg.sbaAddr.value.toInt();
      final off = addr % bytes;
      final aligned = LogicValue.ofInt(addr - off, xlen);
      final zero = LogicValue.filled(xlen, LogicValue.zero);
      if (dbg.sbaWe.value.toInt() == 1) {
        storage.setData(aligned, dbg.sbaWdata.value);
      }
      final rd = (storage.getData(aligned) ?? zero).toBigInt() >> (off * 8);
      sbaRdata.inject(LogicValue.ofBigInt(rd, xlen));
      sbaAck.inject(1);
      _acked = true;
    } else {
      sbaAck.inject(0);
      _acked = false;
    }
  }

  Future<void> _clk(int tmsv, [int tdiv = 0]) async {
    tms.inject(tmsv);
    tdi.inject(tdiv);
    tck.inject(1);
    await _tick();
    tck.inject(0);
    await _tick();
  }

  Future<void> idle(int n) async {
    for (var i = 0; i < n; i++) {
      await _clk(0);
    }
  }

  Future<void> resetTap() async {
    for (var i = 0; i < 5; i++) {
      await _clk(1);
    }
    await _clk(0);
  }

  Future<int> scanDr(int bits, int value) async {
    await _clk(1);
    await _clk(0);
    await _clk(0);
    var captured = 0;
    for (var i = 0; i < bits; i++) {
      // Sample combinational TDO before the clock that shifts it.
      if (dbg.tdo.value.toInt() == 1) captured |= 1 << i;
      await _clk(i == bits - 1 ? 1 : 0, (value >> i) & 1);
    }
    await _clk(1);
    await _clk(0);
    return captured;
  }

  Future<int> scanIr(int bits, int value) async {
    await _clk(1);
    await _clk(1);
    await _clk(0);
    await _clk(0);
    var captured = 0;
    for (var i = 0; i < bits; i++) {
      // Sample combinational TDO before the clock that shifts it.
      if (dbg.tdo.value.toInt() == 1) captured |= 1 << i;
      await _clk(i == bits - 1 ? 1 : 0, (value >> i) & 1);
    }
    await _clk(1);
    await _clk(0);
    return captured;
  }

  Future<void> dmWrite(int addr, int data) =>
      scanDr(41, (addr << 34) | ((data & 0xFFFFFFFF) << 2) | 2);

  Future<int> dmRead(int addr) async {
    await scanDr(41, (addr << 34) | 1);
    final captured = await scanDr(41, 0);
    return (captured >> 2) & 0xFFFFFFFF;
  }
}

void main() {
  // Exercise both a combinational regfile (readLatency 0) and a registered-BRAM
  // regfile (readLatency 1, the Xilinx/ECP5 builds). The latency-1 case is a
  // regression guard: debug_reg_ready must lag the abstract read by the regfile
  // read latency, else the Debug Module latches stale GPR data (reads 0 on HW).
  for (final readLatency in [0, 1]) {
    test('Debug Module halts and resumes the live core '
        '(regfile latency $readLatency)', () async {
      await Simulator.reset();
      const xlen = 64;
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');

      final coreConfig = RiverCoreConfigV1.small(
        interrupts: [],
        // Distinctive mhartid so the abstract CSR read below is decisive: the old
        // fall-through read 0 for any CSR; the borrowed-port read returns 0x42.
        hartId: 0x42,
        mmu: HarborMmuConfig(
          mxlen: RiscVMxlen.rv64,
          pagingModes: const [RiscVPagingMode.bare],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
        ),
        clock: const HarborClockConfig(
          name: 'sysclk',
          rate: HarborFixedClockRate(48000000),
        ),
        regfileReadLatency: readLatency == 0 ? null : readLatency,
        resetVector: 0,
      );
      final wbConfig = WishboneConfig(
        addressWidth: xlen,
        dataWidth: xlen,
        selWidth: xlen ~/ 8,
      );

      final storage = SparseMemoryStorage(
        addrWidth: xlen,
        dataWidth: xlen,
        alignAddress: (addr) => addr,
        onInvalidRead: (addr, dataWidth) =>
            LogicValue.filled(dataWidth, LogicValue.zero),
      );
      // Fill low memory with pairs of NOPs (addi x0,x0,0 == 0x13) so a running
      // core marches its PC forward word by word.
      for (var a = 0; a < 0x400; a += 8) {
        storage.setData(
          LogicValue.ofInt(a, xlen),
          LogicValue.ofInt(0x0000001300000013, xlen),
        );
      }

      final core = RiverCore(coreConfig, busConfig: wbConfig, withDebug: true);
      core.input('clk').srcConnection! <= clk;
      // Hart reset = external reset OR the DM's ndmreset (driven after the DM).
      final coreReset = Logic(name: 'coreReset');
      core.input('reset').srcConnection! <= coreReset;
      await core.build();

      final wb = core.interface('dataBus').interface as WishboneInterface;
      final memRead = DataPortInterface(xlen, xlen);
      final memWrite = DataPortInterface(xlen, xlen);
      // ignore: unused_local_variable
      final mem = MemoryModel(
        clk,
        reset,
        [wrapWriteForRegisterFile(memWrite)],
        [wrapReadForRegisterFile(memRead)],
        storage: storage,
      );
      memRead.en <= wb.cyc & wb.stb & ~wb.we;
      memRead.addr <= wb.adr;
      memWrite.en <= wb.cyc & wb.stb & wb.we;
      memWrite.addr <= wb.adr;
      memWrite.data <= wb.datMosi;
      final wbAck = Logic(name: 'wbAck');
      Sequential(clk, [
        If(
          reset,
          then: [wbAck < 0],
          orElse: [
            If(
              wb.cyc & wb.stb & ~wbAck,
              then: [wbAck < 1],
              orElse: [wbAck < 0],
            ),
          ],
        ),
      ]);
      wb.ack <= wbAck;
      wb.datMiso <= memRead.data;

      final tck = Logic(name: 'tck');
      final tms = Logic(name: 'tms');
      final tdi = Logic(name: 'tdi');
      final trstN = Logic(name: 'trst_n');
      final sbaRdata = Logic(name: 'sba_rdata', width: xlen);
      final sbaAck = Logic(name: 'sba_ack');
      final dbg = RiverDebugModule(
        clk,
        reset,
        tck,
        tms,
        tdi,
        trstN,
        hartHalted: core.output('debug_halted'),
        regRdata: core.output('debug_reg_rdata'),
        regReady: core.output('debug_reg_ready'),
        sbaRdata: sbaRdata,
        sbaAck: sbaAck,
        xlen: xlen,
        idcode: 0x10000001,
      );
      await dbg.build();
      core.input('debug_halt_req').srcConnection! <= dbg.haltReq;
      core.input('debug_resume_req').srcConnection! <= dbg.resumeReq;
      core.input('debug_reg_read').srcConnection! <= dbg.regRead;
      core.input('debug_reg_write').srcConnection! <= dbg.regWrite;
      core.input('debug_reg_addr').srcConnection! <= dbg.regAddr;
      core.input('debug_reg_wdata').srcConnection! <= dbg.regWdata;
      coreReset <= reset | dbg.ndmreset;

      reset.inject(1);
      tck.inject(0);
      tms.inject(0);
      tdi.inject(0);
      trstN.inject(1);
      sbaRdata.inject(0);
      sbaAck.inject(0);
      Simulator.setMaxSimTime(500000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      // Let the core run a while so its PC is marching forward.
      for (var i = 0; i < 40; i++) {
        await clk.nextPosedge;
      }

      final rig = DebugRig(
        core,
        dbg,
        clk,
        tck,
        tms,
        tdi,
        sbaRdata,
        sbaAck,
        storage,
        xlen,
      );
      await rig.resetTap();
      await rig.scanIr(5, 0x11);
      await rig.dmWrite(0x10, 1); // Activate before requesting other actions.
      expect((await rig.dmRead(0x10)) & 1, 1);

      // Halt the hart.
      await rig.dmWrite(0x10, (1 << 31) | 1); // dmcontrol: haltreq | dmactive
      await rig.idle(8);
      final dmHalted = await rig.dmRead(0x11);
      expect((dmHalted >> 9) & 1, 1, reason: 'allhalted set after haltreq');
      expect(core.output('debug_halted').value.toInt(), 1);

      // PC must be frozen while halted.
      final pcAtHalt = core.pipeline.nextPc.value.toInt();
      for (var i = 0; i < 30; i++) {
        await clk.nextPosedge;
      }
      expect(
        core.pipeline.nextPc.value.toInt(),
        pcAtHalt,
        reason: 'PC must not advance while halted',
      );

      // Resume and confirm the core runs again.
      await rig.dmWrite(0x10, (1 << 30) | 1); // resumereq | dmactive
      await rig.idle(8);
      expect(
        core.output('debug_halted').value.toInt(),
        0,
        reason: 'halt clears on resume',
      );
      final dmRun = await rig.dmRead(0x11);
      expect((dmRun >> 9) & 1, 0, reason: 'allhalted clears after resume');

      // ---- Abstract command: write a GPR, read it back, read dpc ----
      await rig.dmWrite(0x10, (1 << 31) | 1); // halt again
      await rig.idle(8);

      // command = access-register, aarsize=3 (64-bit), transfer, write, x6.
      const writeX6 = (3 << 20) | (1 << 17) | (1 << 16) | 0x1006;
      const readX6 = (3 << 20) | (1 << 17) | 0x1006;
      await rig.dmWrite(0x04, 0x12345678); // data0 (low 32)
      await rig.dmWrite(0x05, 0xDEADBEEF); // data1 (high 32)
      await rig.dmWrite(0x17, writeX6);
      await rig.idle(6);
      expect(
        core.regs.getData(LogicValue.ofInt(6, 5))!.toBigInt(),
        BigInt.parse('DEADBEEF12345678', radix: 16),
        reason: 'abstract command wrote x6',
      );

      // Read it back into data0/data1.
      await rig.dmWrite(0x17, readX6);
      await rig.idle(6);
      expect(await rig.dmRead(0x04), 0x12345678, reason: 'x6 low readback');
      expect(await rig.dmRead(0x05), 0xDEADBEEF, reason: 'x6 high readback');

      // dpc (CSR 0x7b1) reads the PC captured at halt.
      final dpc = core.output('debug_dpc').value.toBigInt();
      const readDpc = (3 << 20) | (1 << 17) | 0x7b1;
      await rig.dmWrite(0x17, readDpc);
      await rig.idle(6);
      expect(
        await rig.dmRead(0x04),
        (dpc & BigInt.from(0xFFFFFFFF)).toInt(),
        reason: 'dpc low matches the latched halt PC',
      );

      // A general CSR (mhartid, 0xF14) read over the abstract command: the Debug
      // Module borrows the frozen CSR read port. Before this path existed any
      // non-dpc/dcsr/misa CSR fell through to the GPR port and read 0; now it
      // returns the real value (config hartId = 0x42).
      const readMhartid = (3 << 20) | (1 << 17) | 0xF14;
      await rig.dmWrite(0x17, readMhartid);
      await rig.idle(6);
      expect(
        await rig.dmRead(0x04),
        0x42,
        reason: 'mhartid read over JTAG returns the real CSR value, not 0',
      );

      // misa (0x301) still served by its dedicated constant path.
      const readMisa = (3 << 20) | (1 << 17) | 0x301;
      await rig.dmWrite(0x17, readMisa);
      await rig.idle(6);
      expect(
        await rig.dmRead(0x04),
        coreConfig.isa.misaValue & 0xFFFFFFFF,
        reason: 'misa low word still served over JTAG',
      );

      // ---- ndmreset: reset the hart over JTAG ----
      // x6 currently holds 0xDEADBEEF12345678 (written above). Setting
      // dmcontrol.ndmreset (bit 1) drives the hart into reset, clearing its
      // register file, while leaving the Debug Module alive.
      await rig.dmWrite(0x10, (1 << 1) | 1); // ndmreset | dmactive
      await rig.idle(6);
      expect(
        (await rig.dmRead(0x10) >> 1) & 1,
        1,
        reason: 'dmcontrol reads back ndmreset asserted',
      );
      expect(
        core.regs.getData(LogicValue.ofInt(6, 5))!.toBigInt(),
        BigInt.zero,
        reason: 'ndmreset reset the hart, clearing x6',
      );

      // Release ndmreset; the DM stayed alive throughout (still reads dmactive).
      await rig.dmWrite(0x10, 1); // dmactive only
      await rig.idle(4);
      expect(
        (await rig.dmRead(0x10) >> 1) & 1,
        0,
        reason: 'dmcontrol reads back ndmreset released',
      );

      await Simulator.endSimulation();
      await Simulator.simulationEnded;
    });
  }
}
