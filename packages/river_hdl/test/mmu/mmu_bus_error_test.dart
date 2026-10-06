import 'dart:async';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final phase in [
    'bare32',
    'bare64',
    'root',
    'leaf',
    'ad',
    'data',
    'groot',
  ]) {
    for (final kind in ['fetch', 'load', 'store']) {
      if (phase == 'groot' && kind == 'fetch') continue;
      for (final ackWithError in [false, true]) {
        test(
          '$phase $kind ERR with ACK=$ackWithError terminates and recovers',
          () async {
            final xlen = phase == 'bare32' ? 32 : 64;
            final paged = !phase.startsWith('bare');
            final guest = phase == 'groot';
            final fetch = kind == 'fetch';
            final clk = SimpleClockGenerator(10).clk;
            final reset = Logic()..inject(1);
            final en = Logic()..inject(0);
            final injectError = Logic()..inject(1);
            final respond = Logic()..inject(0);
            final idleError = Logic()..inject(0);
            final ack = Logic();
            final err = Logic();
            final data = Logic(width: xlen);
            final mmu = RiverMmu(
              clk,
              reset,
              fetch ? en : Const(0),
              Const(0x201000, width: xlen),
              fetch ? Const(0) : en,
              Const(0x201000, width: xlen),
              Const(kind == 'store' ? 1 : 0),
              Const(0x5678, width: xlen),
              Const(xlen == 64 ? 3 : 2, width: 3),
              ack,
              data,
              wbErr: err,
              mmuConfig: HarborMmuConfig(
                mxlen: xlen == 32 ? RiscVMxlen.rv32 : RiscVMxlen.rv64,
                pagingModes: [
                  RiscVPagingMode.bare,
                  if (paged) RiscVPagingMode.sv39,
                ],
                tlbLevels: const [],
                pmp: HarborPmpConfig.none,
              ),
              busConfig: WishboneConfig(
                addressWidth: xlen,
                dataWidth: xlen,
                useErr: true,
              ),
              satpMode: paged ? Const(8, width: 4) : null,
              satpRoot: paged ? Const(0x10, width: xlen) : null,
              privMode: Const(1, width: 3),
              translateFetch: true,
              virtIn: guest ? Const(1) : null,
              gMode: guest ? Const(8, width: 4) : null,
              gRoot: guest ? Const(0x20, width: xlen) : null,
            );
            await mmu.build();
            final bad = switch (phase) {
              'root' => mmu.wbAdr.eq(0x10000),
              'leaf' => mmu.wbAdr.eq(0x11008),
              'ad' => mmu.wbAdr.eq(0x11008) & mmu.wbWe,
              'data' => mmu.wbAdr.eq(0x40001000),
              'groot' => mmu.wbAdr.eq(0x20000),
              _ => mmu.wbAdr.eq(0x201000),
            };
            final active = mmu.wbCyc & mmu.wbStb;
            final failed = bad & injectError;
            ack <= active & respond & (~failed | Const(ackWithError ? 1 : 0));
            err <= (active & respond & failed) | idleError;
            final words = <int, int>{
              0x10000: 0x4401,
              0x11008: 0x10000000 | (phase == 'ad' ? 0x0f : 0xcf),
              0x20000: 0xdf,
              0x20008: 0x100000df,
              0x201000: 0x1234,
              0x40001000: 0x1234,
            };
            Logic contents = Const(0, width: xlen);
            for (final e in words.entries) {
              contents = mux(
                mmu.wbAdr.eq(e.key),
                Const(e.value, width: xlen),
                contents,
              );
            }
            data <= contents;
            final done = fetch ? mmu.ifetchDone : mmu.dportDone;
            final valid = fetch ? mmu.ifetchValid : mmu.dportValid;
            final otherDone = fetch ? mmu.dportDone : mmu.ifetchDone;
            Simulator.setMaxSimTime(10000);
            unawaited(Simulator.run());
            try {
              await clk.nextNegedge;
              reset.inject(0);
              en.inject(1);
              for (var n = 0; n < 3; n++) {
                await clk.nextNegedge;
                expect(done.value.toBool(), isFalse, reason: 'no response yet');
              }
              respond.inject(1);
              for (final recovery in [false, true]) {
                var completed = false;
                var sawErrorTarget = false;
                for (var n = 0; n < 150; n++) {
                  if (active.value.toBool() && bad.value.toBool()) {
                    sawErrorTarget = true;
                  }
                  await clk.nextNegedge;
                  expect(otherDone.value.toBool(), isFalse);
                  if (done.value.toBool()) {
                    completed = true;
                    expect(valid.value.toBool(), recovery);
                    expect(mmu.dportFault.value.toBool(), isFalse);
                    expect(mmu.dportFaultGuest.value.toBool(), isFalse);
                    expect(mmu.ifetchFault.value.toBool(), isFalse);
                    expect(mmu.wbCyc.value.toBool(), isFalse);
                    expect(mmu.wbStb.value.toBool(), isFalse);
                    if (recovery && kind != 'store') {
                      expect(
                        (fetch ? mmu.ifetchRdata : mmu.dportRdata).value
                            .toInt(),
                        0x1234,
                      );
                    }
                    break;
                  }
                }
                expect(completed, isTrue, reason: 'request must terminate');
                expect(
                  sawErrorTarget,
                  isTrue,
                  reason: 'must exercise the selected bus phase',
                );
                en.inject(0);
                idleError.inject(1);
                for (var n = 0; n < 3; n++) {
                  await clk.nextNegedge;
                  expect(
                    done.value.toBool(),
                    isFalse,
                    reason: 'idle ERR must not complete again',
                  );
                  expect(otherDone.value.toBool(), isFalse);
                }
                idleError.inject(0);
                injectError.inject(0);
                if (!recovery) en.inject(1);
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
}
