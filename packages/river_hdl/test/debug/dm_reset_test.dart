import 'package:river_hdl/src/core/debug.dart';
import 'package:rohd/rohd.dart';
import 'debug_module_test.dart' show JtagHost;
import 'dm_reset_cases.dart';

void main() {
  resetCases('JTAG', (width) async {
    final h = ResetHarness(width);
    final tck = Logic()..inject(0),
        tms = Logic()..inject(1),
        tdi = Logic()..inject(0);
    h.dm = RiverDebugModule(
      h.clk,
      h.reset,
      tck,
      tms,
      tdi,
      Const(1),
      xlen: width,
      hartHalted: h.halted,
      regReady: h.ready,
      regRdata: h.regData,
      sbaAck: h.ack,
      sbaRdata: h.busData,
    );
    // The host's optional memory emulator drives dummy signals: this suite
    // controls the real backend response timing, independently of TAP clocks.
    final host = JtagHost(
      h.dm,
      h.clk,
      tck,
      tms,
      tdi,
      Logic(width: width)..inject(0),
      Logic()..inject(0),
      {},
    );
    h.access = (address, data) async {
      if (data == null) return host.dmRead(address);
      await host.dmWrite(address, data);
      return 0;
    };
    h.resetTransport = () async {
      // These reset the transport, not the DM's accepted abstract/SBA work.
      for (final bit in [16, 17]) {
        await host.scanIr(5, 0x10);
        await host.scanDr(32, 1 << bit);
        await host.scanIr(5, 0x11);
      }
      await host.resetTap();
      await host.scanIr(5, 0x11);
    };
    await h.start();
    await host.resetTap();
    await host.scanIr(5, 0x11);
    return h;
  });
}
