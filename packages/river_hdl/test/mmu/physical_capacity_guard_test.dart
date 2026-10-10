import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final size in [8192, 16384]) {
    for (final profile in ['bare', 'out-of-order']) {
      test('$profile keeps virtual D-cache capacity guard at $size bytes', () {
        final config = RiverCoreConfig(
          mxlen: RiscVMxlen.rv64,
          type: RiverCoreType.general,
          extensions: [rv32i, rv64i, rvZicsr, rvPriv],
          interrupts: [],
          resetVector: 0,
          executionMode: profile == 'out-of-order'
              ? ExecutionMode.outOfOrder
              : ExecutionMode.inOrder,
          l1cache: HarborL1CacheConfig.unified(
            HarborL1dCacheConfig(size: size, ways: 1, lineSize: 16),
          ),
          mmu: HarborMmuConfig(
            mxlen: RiscVMxlen.rv64,
            pagingModes: profile == 'bare'
                ? const [RiscVPagingMode.bare]
                : const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
            tlbLevels: const [],
            pmp: HarborPmpConfig.none,
          ),
          clock: const HarborClockConfig(
            name: 'test',
            rate: HarborFixedClockRate(100000000),
          ),
        );
        expect(
          () => RiverCore(
            config,
            busConfig: WishboneConfig(
              addressWidth: 64,
              dataWidth: 64,
              selWidth: 8,
            ),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message.toString(),
              'message',
              contains('must not exceed'),
            ),
          ),
        );
      });
    }
  }
}
