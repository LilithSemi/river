import 'dart:async';

import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'core_icache_test.dart' as legacy;

void main() {
  group('instruction-only legacy frontend', () {
    legacy.instructionCacheTests(
      cacheConfig: const HarborL1CacheConfig.instructionOnly(
        HarborL1iCacheConfig(size: 32, ways: 1, lineSize: 4),
      ),
    );
  });
  test(
    'bare instruction-only core observes every data read and caches its loop',
    () async {
      final core = RiverCore(
        RiverCoreConfig(
          mxlen: RiscVMxlen.rv32,
          type: RiverCoreType.general,
          extensions: [rv32i, rvZicsr, rvZifencei],
          interrupts: [],
          resetVector: 0,
          clock: const HarborClockConfig(
            name: 'test',
            rate: HarborFixedClockRate(100000000),
          ),
          l1cache: const HarborL1CacheConfig.instructionOnly(
            HarborL1iCacheConfig(size: 128, ways: 1, lineSize: 16),
          ),
          mmu: HarborMmuConfig(
            mxlen: RiscVMxlen.rv32,
            pagingModes: const [RiscVPagingMode.bare],
            tlbLevels: const [],
            pmp: HarborPmpConfig.none,
          ),
        ),
        busConfig: WishboneConfig(addressWidth: 32, dataWidth: 32, selWidth: 4),
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic()..inject(1), ack = Logic()..inject(0);
      final rdata = Logic(width: 32)..inject(0);
      core.input('clk').srcConnection! <= clk;
      core.input('reset').srcConnection! <= reset;
      core.input('dataBus_ACK').srcConnection! <= ack;
      core.input('dataBus_DAT_MISO').srcConnection! <= rdata;
      await core.build();
      final program = [
        0x800002b7, // lui t0,0x80000
        0x0002a503, // lw a0,0(t0)
        0x0002a583, // lw a1,0(t0)
        0x00b2a223, // sw a1,4(t0)
        0x06600913, // completion marker
        0x0000006f,
      ];
      var dataReads = 0, instructionReads = 0, stores = 0;
      Future<void> tick() async {
        await clk.nextNegedge;
        if (ack.value.toBool()) {
          ack.inject(0);
          return;
        }
        if (!core.output('dataBus_CYC').value.toBool() ||
            !core.output('dataBus_STB').value.toBool()) {
          return;
        }
        final a = core.output('dataBus_ADR').value.toInt();
        if (core.output('dataBus_WE').value.toBool()) {
          expect(a, 0x80000004);
          expect(core.output('dataBus_DAT_MOSI').value.toInt(), 0x2222);
          stores++;
        } else if (a == 0x80000000) {
          dataReads++;
          rdata.inject(dataReads * 0x1111);
        } else {
          instructionReads++;
          rdata.inject(a ~/ 4 < program.length ? program[a ~/ 4] : 0x13);
        }
        ack.inject(1);
      }

      int reg(int n) => core.regs.getData(LogicValue.ofInt(n, 5))!.toInt();
      Simulator.setMaxSimTime(50000);
      unawaited(Simulator.run());
      try {
        await tick();
        await tick();
        reset.inject(0);
        for (var i = 0; i < 2000 && reg(18) != 0x66; i++) {
          await tick();
        }
        expect(reg(18), 0x66, reason: 'program completion, not timeout');
        expect(reg(10), 0x1111);
        expect(reg(11), 0x2222);
        expect(dataReads, 2);
        expect(stores, 1);
        expect(instructionReads, 8, reason: 'two 16-byte instruction refills');
        for (var i = 0; i < 40; i++) {
          await tick();
        }
        expect(
          instructionReads,
          8,
          reason: 'the loop stays in the instruction cache',
        );
        expect(dataReads, 2);
        expect(stores, 1);
        expect(core.generateSynth(), isNot(contains('module HarborL1DCache')));
      } finally {
        await Simulator.endSimulation();
        await Simulator.simulationEnded;
        await Simulator.reset();
      }
    },
  );
}
