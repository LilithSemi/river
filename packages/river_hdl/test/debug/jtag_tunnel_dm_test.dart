import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:harbor/harbor.dart' show JtagBscanTunnel;
import 'package:river_hdl/src/core/debug.dart';
import 'package:test/test.dart';

/// Drives the [JtagBscanTunnel] + a real [RiverDebugModule] exactly as
/// riscv-openocd would over the ECP5 `JTAGG` ER1 user register: it builds the
/// SiFive NESTED_TAP tunnel frame (sel + width + payload + idle), strobes the
/// ER1 Capture/Shift/Update signals the JTAGG primitive would emit, and recovers
/// the inner TAP's TDO from `jtdo1`. The frame layout is taken verbatim from
/// OpenOCD's `riscv_add_bscan_tunneled_scan` so this validates the tunnel
/// framing against the authoritative protocol, not against our own assumptions.
class Er1Host {
  final Logic clk, jtck, jtdi, jshift, jupdate, jce1, jrstn, jtdo1;
  final RiverDebugModule dut;
  final Logic sbaRdata, sbaAck;
  final Map<int, int> mem;
  bool _acked = false;

  Er1Host(
    this.clk,
    this.jtck,
    this.jtdi,
    this.jshift,
    this.jupdate,
    this.jce1,
    this.jrstn,
    this.jtdo1,
    this.dut,
    this.sbaRdata,
    this.sbaAck,
    this.mem,
  );

  /// Service the DM's single-outstanding System Bus Access port against [mem].
  void _serviceSba() {
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

  Future<void> _settle() async {
    // Let the system clock sample the JTAG-domain levels (2-FF synchronizer +
    // edge detect) and service SBA so DM bus accesses can drain. Enough cycles
    // to cover the synchronizer latency before the next JTAG level is applied.
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
      _serviceSba();
    }
  }

  /// One ER1 TCK pulse with the given shift/update strobes and TDI; returns the
  /// jtdo1 value sampled just before the shifting edge (JTAG TDO convention).
  Future<int> _pulse({
    required int shift,
    required int update,
    required int tdi,
    int ce1 = 1,
  }) async {
    jce1.inject(ce1);
    jshift.inject(shift);
    jupdate.inject(update);
    jtdi.inject(tdi);
    await _settle();
    final tdo = jtdo1.value.isValid ? jtdo1.value.toInt() : 0;
    jtck.inject(1);
    await _settle();
    jtck.inject(0);
    await _settle();
    return tdo;
  }

  /// Scan a NESTED_TAP tunnel frame: sel (1=DR,0=IR), width N, payload of N+1
  /// bits. Returns the N+1 jtdo1 samples taken over the payload window.
  Future<int> tunnelScan(int sel, int n, int payload) async {
    final frame = <int>[];
    frame.add(sel & 1);
    for (var i = 0; i < 7; i++) {
      frame.add((n >> i) & 1); // width, LSB first
    }
    for (var i = 0; i < n + 1; i++) {
      frame.add((payload >> i) & 1); // payload (N+1, LSB first)
    }
    frame.addAll([0, 0, 0]); // idle

    // Outer Capture-DR (jce1=1, jshift=0): inner TAP is NOT clocked.
    await _pulse(shift: 0, update: 0, tdi: 0);

    // Outer Shift-DR: shift the whole frame, sample jtdo1 each bit.
    final payloadStart = 8;
    var captured = 0;
    for (var i = 0; i < frame.length; i++) {
      final tdo = await _pulse(shift: 1, update: 0, tdi: frame[i]);
      if (i >= payloadStart && i <= payloadStart + n) {
        if (tdo == 1) captured |= 1 << (i - payloadStart);
      }
    }

    // Outer Update-DR.
    await _pulse(shift: 0, update: 1, tdi: 0);
    await _pulse(shift: 0, update: 0, tdi: 0);
    return captured;
  }

  Future<void> tapReset() async {
    jrstn.inject(0);
    await _settle();
    jrstn.inject(1);
    await _settle();
  }

  /// Inner IR scan (sel=0): set the inner DM TAP instruction (irWidth=5).
  Future<void> innerIr(int ir) => tunnelScan(0, 5, ir);

  /// Inner DR scan (sel=1) of [n] bits; returns the inner TAP's TDO with the
  /// 1-TCK skew removed (OpenOCD right-shifts the captured field by 1).
  Future<int> innerDr(int n, int value) async {
    final raw = await tunnelScan(1, n, value);
    return (raw >> 1) & ((1 << n) - 1);
  }

  Future<void> idleFrames(int n) async {
    for (var i = 0; i < n; i++) {
      await _pulse(shift: 0, update: 0, tdi: 0, ce1: 0);
    }
  }

  Future<void> dmiWrite(int addr, int data) =>
      innerDr(41, (addr << 34) | ((data & 0xFFFFFFFF) << 2) | 2);

  Future<int> dmiRead(int addr) async {
    await innerDr(41, (addr << 34) | 1);
    final captured = await innerDr(41, 0);
    return (captured >> 2) & 0xFFFFFFFF;
  }
}

void main() {
  group('JtagBscanTunnel + RiverDebugModule (NESTED_TAP over ER1)', () {
    late Logic clk, reset, sbaRdata, sbaAck;
    late JtagBscanTunnel tunnel;
    late RiverDebugModule dm;
    late Er1Host host;
    late Map<int, int> mem;
    late Logic jtck, jtdi, jshift, jupdate, jce1, jrstn;

    Future<void> boot() async {
      await Simulator.reset();
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      jtck = Logic(name: 'jtck');
      jtdi = Logic(name: 'jtdi');
      jshift = Logic(name: 'jshift');
      jupdate = Logic(name: 'jupdate');
      jce1 = Logic(name: 'jce1');
      jrstn = Logic(name: 'jrstn');
      sbaRdata = Logic(name: 'sba_rdata', width: 64);
      sbaAck = Logic(name: 'sba_ack');
      mem = {};

      tunnel = JtagBscanTunnel();
      tunnel.input('clk').srcConnection! <= clk;
      tunnel.input('reset').srcConnection! <= reset;
      tunnel.input('jtck').srcConnection! <= jtck;
      tunnel.input('jtdi').srcConnection! <= jtdi;
      tunnel.input('jshift').srcConnection! <= jshift;
      tunnel.input('jupdate').srcConnection! <= jupdate;
      tunnel.input('jce1').srcConnection! <= jce1;
      tunnel.input('jrstn').srcConnection! <= jrstn;

      dm = RiverDebugModule(
        clk,
        reset,
        tunnel.output('inner_tck'),
        tunnel.output('inner_tms'),
        tunnel.output('inner_tdi'),
        tunnel.output('inner_trst_n'),
        sbaRdata: sbaRdata,
        sbaAck: sbaAck,
        xlen: 64,
        idcode: 0x10000001,
      );
      tunnel.input('inner_tdo').srcConnection! <= dm.tdo;

      await tunnel.build();
      await dm.build();
      reset.inject(1);
      jtck.inject(0);
      jtdi.inject(0);
      jshift.inject(0);
      jupdate.inject(0);
      jce1.inject(0);
      jrstn.inject(1);
      sbaRdata.inject(0);
      sbaAck.inject(0);
      Simulator.setMaxSimTime(200000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      host = Er1Host(
        clk,
        jtck,
        jtdi,
        jshift,
        jupdate,
        jce1,
        jrstn,
        tunnel.output('jtdo1'),
        dm,
        sbaRdata,
        sbaAck,
        mem,
      );
    }

    tearDown(() async {
      await Simulator.endSimulation();
      await Simulator.simulationEnded;
    });

    test('tunneled IDCODE read returns 0x10000001', () async {
      await boot();
      await host.tapReset();
      // Inner IR defaults to IDCODE after TAP reset. Inner DR scan, N=32.
      final raw = await host.tunnelScan(1, 32, 0);
      // OpenOCD compensates the 1-TCK skew by right-shifting the captured field.
      final idcode = (raw >> 1) & 0xFFFFFFFF;
      expect(idcode, 0x10000001);
    });

    test(
      'tunneled inner-IR scan + dmstatus reads version 0.13.2 / running',
      () async {
        await boot();
        await host.tapReset();
        await host.innerIr(0x11); // inner IR <- DMI
        final dmstatus = await host.dmiRead(0x11);
        expect(dmstatus & 0xF, 2, reason: 'debug spec version field');
        expect((dmstatus >> 11) & 1, 1, reason: 'allrunning == 1');
      },
    );

    test('tunneled SBA: write then read back memory', () async {
      await boot();
      await host.tapReset();
      await host.innerIr(0x11); // inner IR <- DMI

      await host.dmiWrite(0x39, 0x40); // sbaddress0 = 0x40
      await host.dmiWrite(0x3c, 0xCAFEBABE); // sbdata0 -> bus write
      await host.idleFrames(4); // let the bus access drain
      expect(mem[0x40], 0xCAFEBABE, reason: 'SBA wrote through to memory');

      await host.dmiWrite(0x38, (2 << 17) | (1 << 20)); // 32b, readonaddr
      await host.dmiWrite(0x39, 0x40); // triggers a read
      await host.idleFrames(4);
      expect(await host.dmiRead(0x3c), 0xCAFEBABE);
    });
  });
}
