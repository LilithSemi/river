import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/src/core/debug.dart';
import 'package:test/test.dart';

/// Drives the RTL debug module exactly as a JTAG adapter (OpenOCD bitbang)
/// would: it injects TCK/TMS/TDI pins, steps the system clock so the module's
/// edge-detected TAP advances, and services the System Bus Access port against
/// a plain memory map (standing in for the sim's storage).
class JtagHost {
  final RiverDebugModule dut;
  final Logic clk;
  final Logic tck;
  final Logic tms;
  final Logic tdi;
  final Logic sbaRdata;
  final Logic sbaAck;
  final Map<int, int> mem;
  bool _acked = false;

  JtagHost(
    this.dut,
    this.clk,
    this.tck,
    this.tms,
    this.tdi,
    this.sbaRdata,
    this.sbaAck,
    this.mem,
  );

  Future<void> _tick() async {
    await clk.nextPosedge;
    final req = dut.sbaReq.value.isValid ? dut.sbaReq.value.toInt() : 0;
    if (req == 1 && !_acked) {
      final we = dut.sbaWe.value.toInt();
      final addr = dut.sbaAddr.value.toInt();
      if (we == 1) {
        mem[addr] = dut.sbaWdata.value.toInt();
      }
      sbaRdata.inject(mem[addr] ?? 0);
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
    await _clk(1); // -> Select-DR
    await _clk(0); // -> Capture-DR
    await _clk(0); // -> Shift-DR
    var captured = 0;
    for (var i = 0; i < bits; i++) {
      final last = i == bits - 1;
      // TDO is combinational (the bit about to shift out); sample it BEFORE the
      // clock that shifts it, matching the JTAG / OpenOCD convention.
      if (dut.tdo.value.toInt() == 1) captured |= 1 << i;
      await _clk(last ? 1 : 0, (value >> i) & 1);
    }
    await _clk(1); // Exit1-DR -> Update-DR
    await _clk(0); // -> Run-Test/Idle
    return captured;
  }

  Future<int> scanIr(int bits, int value) async {
    await _clk(1); // -> Select-DR
    await _clk(1); // -> Select-IR
    await _clk(0); // -> Capture-IR
    await _clk(0); // -> Shift-IR
    var captured = 0;
    for (var i = 0; i < bits; i++) {
      final last = i == bits - 1;
      // TDO is combinational (the bit about to shift out); sample it BEFORE the
      // clock that shifts it, matching the JTAG / OpenOCD convention.
      if (dut.tdo.value.toInt() == 1) captured |= 1 << i;
      await _clk(last ? 1 : 0, (value >> i) & 1);
    }
    await _clk(1); // -> Update-IR
    await _clk(0); // -> Run-Test/Idle
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
  group('RiverDebugModule (TAP/DTM/DM/SBA over JTAG)', () {
    late Logic clk, reset, tck, tms, tdi, trstN, sbaRdata, sbaAck;
    late RiverDebugModule dut;
    late JtagHost host;
    late Map<int, int> mem;

    Future<void> boot({Logic? hartHalted}) async {
      await Simulator.reset();
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      tck = Logic(name: 'tck');
      tms = Logic(name: 'tms');
      tdi = Logic(name: 'tdi');
      trstN = Logic(name: 'trst_n');
      sbaRdata = Logic(name: 'sba_rdata', width: 64);
      sbaAck = Logic(name: 'sba_ack');
      mem = {};
      dut = RiverDebugModule(
        clk,
        reset,
        tck,
        tms,
        tdi,
        trstN,
        hartHalted: hartHalted,
        sbaRdata: sbaRdata,
        sbaAck: sbaAck,
        xlen: 64,
        idcode: 0x10000001,
      );
      await dut.build();
      reset.inject(1);
      tck.inject(0);
      tms.inject(0);
      tdi.inject(0);
      trstN.inject(1);
      sbaRdata.inject(0);
      sbaAck.inject(0);
      Simulator.setMaxSimTime(50000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      host = JtagHost(dut, clk, tck, tms, tdi, sbaRdata, sbaAck, mem);
    }

    tearDown(() async {
      await Simulator.endSimulation();
      await Simulator.simulationEnded;
    });

    test('reads IDCODE', () async {
      await boot();
      await host.resetTap();
      expect(await host.scanDr(32, 0), 0x10000001);
    });

    test('dmstatus reports version 0.13.2 and running', () async {
      await boot();
      await host.resetTap();
      await host.scanIr(5, 0x11);
      final dmstatus = await host.dmRead(0x11);
      expect(dmstatus & 0xF, 2, reason: 'debug spec version field');
      expect((dmstatus >> 9) & 1, 0, reason: 'allhalted == 0 when running');
      expect((dmstatus >> 11) & 1, 1, reason: 'allrunning == 1');
    });

    test('dmstatus reflects a halted hart', () async {
      final halted = Logic(name: 'halted_tie');
      await boot(hartHalted: halted);
      halted.inject(1);
      await host.resetTap();
      await host.scanIr(5, 0x11);
      final dmstatus = await host.dmRead(0x11);
      expect((dmstatus >> 9) & 1, 1, reason: 'allhalted == 1');
      expect((dmstatus >> 8) & 1, 1, reason: 'anyhalted == 1');
    });

    test('system bus access: write then read back memory', () async {
      await boot();
      await host.resetTap();
      await host.scanIr(5, 0x11);

      await host.dmWrite(0x10, 1);
      expect((await host.dmRead(0x10)) & 1, 1);
      // Write phase (sbreadonaddr off): set address, then write data0.
      await host.dmWrite(0x39, 0x40); // sbaddress0 = 0x40
      await host.dmWrite(0x3c, 0xCAFEBABE); // sbdata0 -> bus write
      await host.idle(4); // let the bus access drain
      expect(mem[0x40], 0xCAFEBABE, reason: 'SBA wrote through to memory');

      // Read phase: enable sbreadonaddr, write the address to trigger a read,
      // then read sbdata0 back.
      await host.dmWrite(
        0x38,
        (2 << 17) | (1 << 20),
      ); // sbaccess=32b, readonaddr
      await host.dmWrite(0x39, 0x40);
      await host.idle(4);
      expect(await host.dmRead(0x3c), 0xCAFEBABE);
    });
  });
}
