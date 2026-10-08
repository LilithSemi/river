import 'package:river_hdl/src/core/debug.dart';
import 'package:rohd/rohd.dart';
import 'dm_reset_cases.dart';

void main() {
  resetCases('direct', (width) async {
    final h = ResetHarness(width);
    final request = Logic()..inject(0), write = Logic()..inject(0);
    final address = Logic(width: 7)..inject(0),
        data = Logic(width: 32)..inject(0);
    h.dm = RiverDebugModule(
      h.clk,
      h.reset,
      Const(0),
      Const(0),
      Const(0),
      Const(1),
      directDmi: true,
      dmiRequest: request,
      dmiWrite: write,
      dmiAddress: address,
      dmiWriteData: data,
      xlen: width,
      hartHalted: h.halted,
      regReady: h.ready,
      regRdata: h.regData,
      sbaAck: h.ack,
      sbaRdata: h.busData,
    );
    final response = Logic(width: 32);
    Sequential(h.clk, [
      If(request & ~write, then: [response < h.dm.dmiRdata]),
    ]);
    h.access = (addr, value) async {
      address.inject(addr);
      data.inject(value ?? 0);
      write.inject(value == null ? 0 : 1);
      request.inject(1);
      await h.tick();
      request.inject(0);
      return value == null ? response.value.toInt() : 0;
    };
    await h.start();
    return h;
  });
}
