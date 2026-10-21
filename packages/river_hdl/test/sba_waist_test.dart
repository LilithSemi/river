import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/src/core/sba_waist.dart';
import 'package:test/test.dart';

/// Drives the adapter's SBA side and models a 64-bit Wishbone memory cell on
/// master side (sel-masked write, combinational read+ack), checking that
/// sub-word and full-word SBA accesses lane-shift correctly both ways.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('SBA word and sub-word accesses lane-shift through the waist', () async {
    const dw = 64, aw = 64, xlen = 64;
    final dut = SbaWaistAdapter(dataWidth: dw, addressWidth: aw, xlen: xlen);

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final sbaReq = Logic(name: 'sba_req');
    final sbaWe = Logic(name: 'sba_we');
    final sbaAddr = Logic(name: 'sba_addr', width: xlen);
    final sbaWdata = Logic(name: 'sba_wdata', width: xlen);
    final sbaSize = Logic(name: 'sba_size', width: 3);

    dut.input('sba_req').srcConnection! <= sbaReq;
    dut.input('sba_we').srcConnection! <= sbaWe;
    dut.input('sba_addr').srcConnection! <= sbaAddr;
    dut.input('sba_wdata').srcConnection! <= sbaWdata;
    dut.input('sba_size').srcConnection! <= sbaSize;

    // 64-bit memory cell. Combinational ack and read, sel-masked write on edge.
    final cell = Logic(name: 'cell', width: dw);
    final wbStb = dut.output('stb');
    final wbWe = dut.output('we');
    final wbDatMosi = dut.output('wdata');
    final wbSel = dut.output('sel');
    dut.input('ack').srcConnection! <= wbStb;
    dut.input('rdata').srcConnection! <= cell;

    // Per-byte write mask expanded from sel.
    final byteMask = <Logic>[];
    for (var i = 0; i < dw ~/ 8; i++) {
      byteMask.add(mux(wbSel[i], Const(0xff, width: 8), Const(0, width: 8)));
    }
    final mask = byteMask.rswizzle();
    Sequential(clk, reset: reset, [
      If(wbStb & wbWe, then: [cell < ((cell & ~mask) | (wbDatMosi & mask))]),
    ]);

    reset.inject(1);
    sbaReq.inject(0);
    sbaWe.inject(0);
    sbaAddr.inject(0);
    sbaWdata.inject(0);
    sbaSize.inject(0);

    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    Future<void> wr(int addr, int data, int size) async {
      sbaWe.inject(1);
      sbaAddr.inject(addr);
      sbaWdata.inject(data);
      sbaSize.inject(size);
      sbaReq.inject(1);
      await clk.nextPosedge;
      sbaReq.inject(0);
      await clk.nextPosedge;
    }

    Future<int> rd(int addr, int size) async {
      sbaWe.inject(0);
      sbaAddr.inject(addr);
      sbaSize.inject(size);
      sbaReq.inject(1);
      // Combinational read, so sample after settle.
      await clk.nextPosedge;
      final v = dut.output('sba_rdata').value.toInt();
      sbaReq.inject(0);
      await clk.nextPosedge;
      return v;
    }

    // 32-bit (size=2) into the low and high lanes of one 64-bit beat. The DM
    // takes the access-sized low bytes (sbdata0), so compare masked.
    await wr(0x00, 0x11223344, 2);
    await wr(0x04, 0xaabbccdd, 2);
    expect(
      (await rd(0x00, 2)) & 0xffffffff,
      equals(0x11223344),
      reason: 'low-lane 32-bit readback',
    );
    expect(
      (await rd(0x04, 2)) & 0xffffffff,
      equals(0xaabbccdd),
      reason: 'high-lane 32-bit readback (lane shift both ways)',
    );

    // Byte (size=0) into byte 5.
    await wr(0x05, 0x9a, 0);
    expect((await rd(0x05, 0)) & 0xff, equals(0x9a), reason: 'byte lane 5');

    // The bus address has to be beat-aligned. The lane rides `sel`, so a
    // 4-mod-8 access must present the aligned beat address, not the raw byte
    // offset, or the DDR downsizer sends it to the wrong beat. Drive a
    // high-lane access and sample addr while the request is live.
    sbaWe.inject(1);
    sbaAddr.inject(0x8000_1004);
    sbaWdata.inject(0x1234);
    sbaSize.inject(2);
    sbaReq.inject(1);
    await clk.nextPosedge;
    expect(
      dut.output('addr').value.toInt() & 0x7,
      equals(0),
      reason: 'addr beat-aligned (low 3 bits clear) for a 4-mod-8 access',
    );
    expect(
      dut.output('addr').value.toInt(),
      equals(0x8000_1000),
      reason: 'addr points at the aligned beat, sel selects the high lane',
    );
    expect(
      dut.output('sel').value.toInt(),
      equals(0xf0),
      reason: 'high 32-bit lane selected',
    );
    sbaReq.inject(0);
    await clk.nextPosedge;

    await Simulator.endSimulation();
  });
}
