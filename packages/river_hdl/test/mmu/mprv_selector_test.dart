import 'dart:async';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final xlen in [RiscVMxlen.rv32, RiscVMxlen.rv64]) {
    test('RV${xlen.size} white-box selector has no actual-mode gate', () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic()..inject(1);
      final core = RiverCore(
        RiverCoreConfig(
          clock: const HarborClockConfig(
            name: 'test',
            rate: HarborFixedClockRate(10000),
          ),
          mxlen: xlen,
          extensions: [rv32i, if (xlen == RiscVMxlen.rv64) rv64i, rvZicsr],
          interrupts: [],
          mmu: HarborMmuConfig(
            mxlen: xlen,
            pagingModes: const [RiscVPagingMode.bare],
            tlbLevels: const [],
            pmp: HarborPmpConfig.none,
          ),
          type: RiverCoreType.general,
        ),
        busConfig: WishboneConfig(
          addressWidth: xlen.size,
          dataWidth: xlen.size,
          selWidth: xlen.size ~/ 8,
        ),
      );
      core.input('clk').srcConnection! <= clk;
      core.input('reset').srcConnection! <= reset;
      // Keep the core quiescent: no instruction can complete its first fetch.
      core.input('dataBus_ACK').srcConnection! <= Const(0);
      core.input('dataBus_DAT_MISO').srcConnection! <=
          Const(0, width: xlen.size);
      await core.build();
      final csr = core.subModules.whereType<RiscVCsrFile>().single;
      final mode = core.internalSignals.firstWhere((s) => s.name == 'mode');
      final effective = core.internalSignals.firstWhere(
        (s) => s.name == 'effectiveDataPriv',
      );
      Simulator.setMaxSimTime(5000);
      unawaited(Simulator.run());
      try {
        await clk.nextNegedge;
        reset.inject(0);
        await clk.nextNegedge;
        // Deliberately injected states. Ordinary xRET clears MPRV below M;
        // this is not a claim that software can construct these lower-mode states.
        for (final actual in [0, 1, 3]) {
          for (final mprv in [0, 1]) {
            for (final mpp in [0, 1, 3]) {
              mode.inject(actual);
              csr.setData(
                LogicValue.ofInt(0x300, 12),
                LogicValue.ofInt((mprv << 17) | (mpp << 11), xlen.size),
              );
              await clk.nextNegedge;
              expect(mode.value.toInt(), actual);
              expect(effective.value.toInt(), mprv == 1 ? mpp : actual);
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
