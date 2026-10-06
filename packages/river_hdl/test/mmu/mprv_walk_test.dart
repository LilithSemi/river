import 'dart:async';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final control in ['privilege', 'SUM', 'MXR']) {
    for (final tighten in [true, false]) {
      test(
        'data walk retains $control on ${tighten ? 'tightening' : 'relaxation'}',
        () async {
          final clk = SimpleClockGenerator(10).clk;
          final reset = Logic()..inject(1);
          final en = Logic()..inject(0);
          final priv = Logic(width: 3)..inject(1);
          final sum = Logic()..inject(0);
          final mxr = Logic()..inject(0);
          final ack = Logic();
          final data = Logic(width: 64);
          final mmu = RiverMmu(
            clk,
            reset,
            Const(0),
            Const(0, width: 64),
            en,
            Const(0x201000, width: 64),
            Const(0),
            Const(0, width: 64),
            Const(3, width: 3),
            ack,
            data,
            mmuConfig: HarborMmuConfig(
              mxlen: RiscVMxlen.rv64,
              pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
              tlbLevels: const [],
              pmp: HarborPmpConfig.none,
              hasSupervisorUserMemory: true,
              hasMakeExecutableReadable: true,
            ),
            busConfig: WishboneConfig(
              addressWidth: 64,
              dataWidth: 64,
              selWidth: 8,
            ),
            satpMode: Const(8, width: 4),
            satpRoot: Const(0x10, width: 64),
            privMode: Const(3, width: 3),
            dataPrivMode: priv,
            userProbe: true,
            sum: sum,
            mxr: mxr,
          );
          await mmu.build();
          final leaf = control == 'SUM'
              ? 0xdf
              : control == 'MXR'
              ? 0xc9
              : 0xcf;
          ack <= mmu.wbCyc & mmu.wbStb;
          data <=
              mux(
                mmu.wbAdr.eq(0x10000),
                Const(0x4401, width: 64),
                mux(
                  mmu.wbAdr.eq(0x11008),
                  Const(0x10000000 | leaf, width: 64),
                  mux(
                    mmu.wbAdr.eq(0x40001000),
                    Const(0x1234, width: 64),
                    Const(0, width: 64),
                  ),
                ),
              );
          void permissions(bool allow) {
            priv.inject(control == 'privilege' && !allow ? 0 : 1);
            sum.inject(control == 'SUM' && allow ? 1 : 0);
            mxr.inject(control == 'MXR' && allow ? 1 : 0);
          }

          permissions(tighten);
          Simulator.setMaxSimTime(5000);
          unawaited(Simulator.run());
          try {
            await clk.nextNegedge;
            reset.inject(0);
            await clk.nextNegedge;
            for (final first in [true, false]) {
              en.inject(1);
              var changed = false;
              var completed = false;
              final accesses = <int>[];
              for (var cycle = 0; cycle < 100; cycle++) {
                await clk.nextNegedge;
                if (mmu.wbCyc.value.toBool()) {
                  accesses.add(mmu.wbAdr.value.toInt());
                  if (first && !changed) {
                    // The root request proves acceptance already latched context.
                    expect(mmu.wbAdr.value.toInt(), 0x10000);
                    permissions(!tighten);
                    changed = true;
                  }
                }
                if (mmu.dportDone.value.toBool()) {
                  final allow = first ? tighten : !tighten;
                  expect(mmu.dportFault.value.toBool(), !allow);
                  expect(mmu.dportValid.value.toBool(), allow);
                  expect(accesses.contains(0x40001000), allow);
                  if (allow) expect(mmu.dportRdata.value.toInt(), 0x1234);
                  completed = true;
                  break;
                }
              }
              expect(completed, isTrue, reason: 'request did not complete');
              if (first) expect(changed, isTrue);
              en.inject(0);
              for (var n = 0; n < 3; n++) {
                await clk.nextNegedge;
              }
            }
            final probe = mmu.probe.value.toInt();
            expect(probe & 3, 0, reason: 'actual execution never left M');
            expect(probe & 4, control == 'privilege' && !tighten ? 4 : 0);
            // On tightening the later U request faults in the warm DTLB,
            // not in a walk; bit 3 deliberately counts only walked faults.
            expect(probe & 8, control == 'privilege' && !tighten ? 8 : 0);
          } finally {
            await Simulator.endSimulation();
            await Simulator.simulationEnded;
          }
        },
      );
    }
  }
}
