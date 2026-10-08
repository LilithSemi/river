import 'dart:async';

import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final xlen in [RiscVMxlen.rv32, RiscVMxlen.rv64]) {
    for (final machine in [false, true]) {
      test(
        'RV${xlen.size} ${machine ? "M" : "S"} trap/return status stack',
        () async {
          final clk = SimpleClockGenerator(10).clk;
          final reset = Logic()..inject(1);
          final mode = Logic(width: 3)..inject(3);
          final trap = Logic()..inject(0);
          final returning = Logic()..inject(0);
          final rd = DataPortInterface(xlen.size, 12);
          final wr = DataPortInterface(xlen.size, 12);
          final csr = RiscVCsrFile(
            clk,
            reset,
            mode,
            mxlen: xlen,
            misa: xlen.misa,
            hasSupervisor: true,
            hasUser: true,
            hasPaging: true,
            hasSum: true,
            hasMxr: true,
            trapActive: trap,
            trapTargetIsM: Const(machine ? 1 : 0),
            trapPc: Const(0x40000100, width: xlen.size),
            trapCauseVal: Const(13, width: xlen.size),
            trapTval: Const(0x40204000, width: xlen.size),
            returnActive: returning,
            returnFromM: Const(machine ? 1 : 0),
            csrRead: rd,
            csrWrite: wr,
          );
          await csr.build();
          rd.en.inject(0);
          rd.addr.inject(0);
          wr.en.inject(0);
          wr.addr.inject(CsrAddress.mstatus.address);
          wr.data.inject(0);
          Simulator.setMaxSimTime(10000);
          unawaited(Simulator.run());
          try {
            await clk.nextNegedge;
            reset.inject(0);
            await clk.nextNegedge;
            const sumMxr = (1 << 18) | (1 << 19);
            const mprv = 1 << 17;
            const mStack = (3 << 11) | (1 << 7) | (1 << 3);
            const sStack = (1 << 8) | (1 << 5) | (1 << 1);
            const mask = sumMxr | mprv | mStack | sStack;
            final ieBit = machine ? 3 : 1;
            final pieBit = machine ? 7 : 5;
            final ppBit = machine ? 11 : 8;
            final preserved = sumMxr | (machine ? sStack : mStack);
            for (final origin in [0, 1, if (machine) 3]) {
              for (final ie in [0, 1]) {
                mode.inject(3);
                // Opposite initial PIE/PP values catch dropped single-field updates.
                wr.data.inject(
                  preserved |
                      mprv |
                      ((origin == 0 ? 1 : 0) << ppBit) |
                      ((1 - ie) << pieBit) |
                      (ie << ieBit),
                );
                wr.en.inject(1);
                await clk.nextNegedge;
                wr.en.inject(0);
                mode.inject(origin);
                trap.inject(1);
                await clk.nextNegedge;
                trap.inject(0);
                expect(
                  csr.mstatus.value.toInt() & mask,
                  preserved | mprv | (origin << ppBit) | (ie << pieBit),
                  reason: 'origin=$origin IE=$ie: push receiving stack only',
                );
                final epc = machine ? CsrAddress.mepc : CsrAddress.sepc;
                final cause = machine ? CsrAddress.mcause : CsrAddress.scause;
                final tval = machine ? CsrAddress.mtval : CsrAddress.stval;
                int read(CsrAddress address) =>
                    csr.getData(LogicValue.ofInt(address.address, 12))!.toInt();
                expect(read(epc), 0x40000100);
                expect(read(cause), 13);
                expect(read(tval), 0x40204000);
                mode.inject(machine ? 3 : 1);
                returning.inject(1);
                await clk.nextNegedge;
                returning.inject(0);
                expect(
                  csr.mstatus.value.toInt() & mask,
                  preserved |
                      (1 << pieBit) |
                      (ie << ieBit) |
                      (machine && origin == 3 ? mprv : 0),
                  reason: 'pop stack; clear MPRV only on return below M',
                );
                await clk.nextNegedge;
              }
            }
          } finally {
            await Simulator.endSimulation();
            await Simulator.simulationEnded;
          }
        },
      );
    }
  }
}
