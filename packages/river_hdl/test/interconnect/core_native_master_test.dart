import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig cfg() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv32,
    extensions: [rv32i, rvZicsr, rvZifencei],
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv32,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
    executionMode: ExecutionMode.inOrder,
  );

  const portsByKind = {
    HarborFabricKind.wishbone: ['dataBus_STB', 'dataBus_CYC'],
    HarborFabricKind.axi4: ['dataBus_ARVALID', 'dataBus_AWVALID'],
    HarborFabricKind.tilelink: ['dataBus_A_VALID', 'dataBus_D_READY'],
  };

  for (final kind in HarborFabricKind.values) {
    test('core builds a native ${kind.name} master', () async {
      final core = RiverCore(
        cfg(),
        busConfig: WishboneConfig(
          addressWidth: 32,
          dataWidth: 32,
          selWidth: 4,
          useErr: true,
        ),
        fabricKind: kind,
      );
      core.input('clk').srcConnection! <= Logic();
      core.input('reset').srcConnection! <= Logic();
      await core.build();

      final names = [...core.inputs.keys, ...core.outputs.keys];
      for (final port in portsByKind[kind]!) {
        expect(names, contains(port));
      }
      if (kind != HarborFabricKind.wishbone) {
        expect(names, isNot(contains('dataBus_CYC')));
      }
    });
  }
}
