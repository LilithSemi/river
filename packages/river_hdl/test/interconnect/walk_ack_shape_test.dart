import 'dart:async';

import 'package:harbor/harbor.dart';
// ignore: implementation_imports
import 'package:harbor/src/bus/wishbone/wishbone_register_stage.dart';
// ignore: implementation_imports
import 'package:harbor/src/clock/wishbone_cdc_fifo.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// The SHAPE of the acknowledge a page-table walk sees coming back from DRAM.
///
/// The MMU walk FSM used to accept an acknowledge on `busActive & wbAck` with
/// no check that it still owned a live transaction. A slave that held ACK for
/// two cycles therefore had its second cycle consumed as the NEXT page-table
/// entry: the walk descended a level on data it had already used, read a table
/// entry belonging to no part of the translation, found it empty, and raised an
/// instruction page fault on a valid executable superpage. That is the Arty S7
/// signature, so it matters whether anything on the real DRAM path can stretch
/// ACK.
///
/// A walk read reaches DRAM as:
///   MMU -> channel arbiter -> WishboneRegisterStage -> decoder
///       -> converge arbiter -> HarborDdr3.bus
///       -> HarborWishboneCdcFifoBridge -> burst adapter -> DDR3 controller
///
/// The two stages that could plausibly stretch are the clock-domain crossing
/// (the DDR side runs far faster than the 20 MHz core, so an acknowledge
/// carried across as a LEVEL would widen) and the register slice. These tests
/// drive both with a downstream slave that holds its acknowledge asserted
/// forever, which is the worst case, and measure the pulse each one presents
/// upstream.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  /// Widths of every acknowledge pulse seen on [ack], sampled on [clk].
  Future<List<int>> ackPulseWidths(
    Logic clk,
    Logic ack,
    int cycles, {
    void Function(int cycle)? drive,
  }) async {
    final widths = <int>[];
    var run = 0;
    for (var i = 0; i < cycles; i++) {
      drive?.call(i);
      await clk.nextPosedge;
      if (ack.value.isValid && ack.value.toBool()) {
        run++;
      } else if (run > 0) {
        widths.add(run);
        run = 0;
      }
    }
    if (run > 0) widths.add(run);
    return widths;
  }

  test(
    'the DDR clock-domain bridge answers the core with a one-cycle ACK',
    () async {
      // s_clk is the 20 MHz core domain, m_clk the much faster DDR domain, the
      // delta ratio. The DDR side is modelled as permanently acknowledging,
      // which is the most stretched acknowledge a slave could present.
      final sClk = SimpleClockGenerator(100).clk;
      final mClk = SimpleClockGenerator(14).clk;
      final sReset = Logic(name: 'sReset');
      final mReset = Logic(name: 'mReset');
      final sCyc = Logic(name: 'sCyc');
      final sWe = Logic(name: 'sWe');
      final sAdr = Logic(name: 'sAdr', width: 32);

      final cdc = HarborWishboneCdcFifoBridge(
        addressWidth: 32,
        dataWidth: 64,
        selWidth: 8,
        depth: 16,
      );
      cdc.input('s_clk').srcConnection! <= sClk;
      cdc.input('s_reset').srcConnection! <= sReset;
      // HarborDdr3 wires the bridge exactly this way: s_cyc from the bus strobe
      // and s_stb tied high.
      cdc.input('s_cyc').srcConnection! <= sCyc;
      cdc.input('s_stb').srcConnection! <= Const(1);
      cdc.input('s_we').srcConnection! <= sWe;
      cdc.input('s_adr').srcConnection! <= sAdr;
      cdc.input('s_dat_w').srcConnection! <= Const(0, width: 64);
      cdc.input('s_sel').srcConnection! <= Const(0xFF, width: 8);
      cdc.input('m_clk').srcConnection! <= mClk;
      cdc.input('m_reset').srcConnection! <= mReset;
      // The pathological DDR side: acknowledge asserted permanently.
      cdc.input('m_ack').srcConnection! <= Const(1);
      cdc.input('m_dat_r').srcConnection! <= Const(0xA5A5A5A5, width: 64);
      await cdc.build();

      sReset.inject(1);
      mReset.inject(1);
      sCyc.inject(0);
      sWe.inject(0);
      sAdr.inject(0x80000000);

      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await sClk.nextPosedge;
      await sClk.nextPosedge;
      sReset.inject(0);
      mReset.inject(0);
      await sClk.nextPosedge;

      // A master that holds its request until it is acknowledged, which is what
      // the MMU does (its CYC is a register, so it stays up through the ACK).
      final widths = await ackPulseWidths(
        sClk,
        cdc.output('s_ack'),
        400,
        drive: (i) => sCyc.inject(1),
      );

      await Simulator.endSimulation();
      await Simulator.simulationEnded;

      expect(
        widths,
        isNotEmpty,
        reason: 'VACUOUS TEST: the bridge never acknowledged anything',
      );
      expect(
        widths.length,
        greaterThan(4),
        reason: 'too few transfers to say anything about the pulse shape',
      );
      expect(
        widths.toSet(),
        {1},
        reason:
            'the clock-domain bridge STRETCHED an acknowledge. It answers the '
            'core domain with a level carried over from the DDR domain rather '
            'than a pulse it generates itself, so a walk can consume the second '
            'cycle as the next page-table entry. Observed pulse widths: '
            '${widths.toSet().toList()..sort()}',
      );
    },
  );

  test(
    'the fabric register slice re-pulses a stretched ACK to one cycle',
    () async {
      // Even if a slave held its acknowledge, the register slice between the
      // arbiter and the decoder latches a completion and pulses upstream once.
      // This pins that second, independent guarantee.
      final clk = SimpleClockGenerator(20).clk;
      final reset = Logic(name: 'reset');
      final upCyc = Logic(name: 'upCyc');

      final wbConfig = WishboneConfig(
        addressWidth: 32,
        dataWidth: 64,
        selWidth: 8,
      );
      final reg = WishboneRegisterStage(config: wbConfig);
      reg.input('clk').srcConnection! <= clk;
      reg.input('reset').srcConnection! <= reset;

      reg.input('up_CYC').srcConnection! <= upCyc;
      reg.input('up_STB').srcConnection! <= upCyc;
      reg.input('up_WE').srcConnection! <= Const(0);
      reg.input('up_ADR').srcConnection! <= Const(0x80000000, width: 32);
      reg.input('up_DAT_MOSI').srcConnection! <= Const(0, width: 64);
      reg.input('up_SEL').srcConnection! <= Const(0xFF, width: 8);
      // The pathological slave again: acknowledge asserted permanently.
      reg.input('down_ACK').srcConnection! <= Const(1);
      reg.input('down_DAT_MISO').srcConnection! <= Const(0x5A5A5A5A, width: 64);

      await reg.build();

      reset.inject(1);
      upCyc.inject(0);
      Simulator.setMaxSimTime(400000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      final widths = await ackPulseWidths(
        clk,
        reg.output('up_ACK'),
        200,
        drive: (i) => upCyc.inject(1),
      );

      await Simulator.endSimulation();
      await Simulator.simulationEnded;

      expect(widths, isNotEmpty, reason: 'VACUOUS TEST: no acknowledge at all');
      expect(
        widths.toSet(),
        {1},
        reason:
            'the register slice passed a stretched acknowledge through. Observed '
            'pulse widths: ${widths.toSet().toList()..sort()}',
      );
    },
  );
}
