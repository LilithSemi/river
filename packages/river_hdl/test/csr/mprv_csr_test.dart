import 'dart:async';

import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final xlen in [RiscVMxlen.rv32, RiscVMxlen.rv64]) {
    for (final modes in [
      'M',
      'MU',
      'MSU',
      if (xlen == RiscVMxlen.rv64) 'MSUH',
    ]) {
      final user = modes.contains('U');
      final sup = modes.contains('S');
      final hyp = modes.contains('H');
      for (final scenario in [
        'availability',
        if (!hyp) ...['MPP WARL', 'MRET', if (sup) 'SRET'],
      ]) {
        test('RV${xlen.size} $modes $scenario', () async {
          final clk = SimpleClockGenerator(10).clk;
          final reset = Logic()..inject(1);
          final mode = Logic(width: 3)..inject(3);
          final ret = Logic()..inject(0);
          final retM = Logic()..inject(1);
          final rd = DataPortInterface(xlen.size, 12);
          final wr = DataPortInterface(xlen.size, 12);
          rd.en.inject(0);
          rd.addr.inject(0x300);
          wr.en.inject(0);
          wr.addr.inject(0x300);
          wr.data.inject(0);
          final csr = RiscVCsrFile(
            clk,
            reset,
            mode,
            mxlen: xlen,
            misa: xlen.misa,
            hasUser: user,
            hasSupervisor: sup,
            hasHypervisor: hyp,
            csrRead: rd,
            csrWrite: wr,
            trapActive: Const(0),
            trapTargetIsM: Const(1),
            trapPc: Const(0, width: xlen.size),
            trapCauseVal: Const(0, width: xlen.size),
            trapTval: Const(0, width: xlen.size),
            returnActive: ret,
            returnFromM: retM,
          );
          await csr.build();
          Simulator.setMaxSimTime(2000);
          unawaited(Simulator.run());
          const mprv = 1 << 17;
          int status() => csr.mstatus.value.toInt();
          Future<void> write(int value, {int address = 0x300}) async {
            wr.addr.inject(address);
            wr.data.inject(value);
            wr.en.inject(1);
            await clk.nextNegedge;
            expect(wr.valid.value.toBool(), isTrue);
            wr.en.inject(0);
            await clk.nextNegedge;
          }

          try {
            await clk.nextNegedge;
            reset.inject(0);
            await clk.nextNegedge;
            switch (scenario) {
              case 'availability':
                await write(mprv | (3 << 11));
                expect(status() & mprv, user && !hyp ? mprv : 0);
                if (sup) {
                  await write(0, address: 0x100);
                  expect(
                    status() & mprv,
                    hyp ? 0 : mprv,
                    reason: 'sstatus cannot clear MPRV',
                  );
                }
                await write(3 << 11);
                expect(status() & mprv, 0);
              case 'MPP WARL':
                expect((status() >> 11) & 3, user ? 0 : 3);
                for (final requested in [0, 1, 2, 3]) {
                  await write(requested << 11);
                  final legal =
                      requested == 3 ||
                      (requested == 0 && user) ||
                      (requested == 1 && sup);
                  expect((status() >> 11) & 3, legal ? requested : 3);
                }
              case 'MRET':
                for (final target in [if (user) 0, if (sup) 1, 3]) {
                  await write(mprv | (target << 11) | (1 << 7));
                  ret.inject(1);
                  await clk.nextNegedge;
                  ret.inject(0);
                  await clk.nextNegedge;
                  expect(status() & mprv, user && target == 3 ? mprv : 0);
                  expect((status() >> 11) & 3, user ? 0 : 3);
                  expect(status() & 0x88, 0x88);
                }
              case 'SRET':
                retM.inject(0);
                for (final source in [1, 3]) {
                  for (final spp in [0, 1]) {
                    mode.inject(3);
                    await write(mprv | (3 << 11) | (spp << 8) | (1 << 5));
                    mode.inject(source);
                    ret.inject(1);
                    await clk.nextNegedge;
                    ret.inject(0);
                    await clk.nextNegedge;
                    expect(status() & mprv, 0);
                    expect((status() >> 11) & 3, 3);
                    expect(status() & 0x122, 0x22);
                  }
                }
            }
          } finally {
            await Simulator.endSimulation();
            await Simulator.simulationEnded;
          }
        });
      }
    }
  }
}
