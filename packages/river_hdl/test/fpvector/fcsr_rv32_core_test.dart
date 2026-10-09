import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

void main() {
  tearDown(Simulator.reset);
  for (final microcoded in [false, true]) {
    group('RV32 ${microcoded ? "microcoded" : "static"}', () {
      final config = RiverCoreConfig(
        clock: const HarborClockConfig(
          name: 'test',
          rate: HarborFixedClockRate(10000),
        ),
        mxlen: RiscVMxlen.rv32,
        extensions: [rv32i, rvZicsr, rvPriv, rvF],
        interrupts: [],
        microcodeMode: microcoded ? MicrocodeMode.full : MicrocodeMode.none,
        mmu: HarborMmuConfig(
          mxlen: RiscVMxlen.rv32,
          pagingModes: const [RiscVPagingMode.bare],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
        ),
        type: RiverCoreType.general,
      );
      for (final dynamic in [false, true]) {
        for (var mode = 0; mode < 5; mode++) {
          final rm = mode;
          test('${dynamic ? "dynamic" : "static"} rm=$rm', () async {
            final frm = dynamic ? rm : (rm + 1) % 5;
            final words = [
              0x18000313, 0x30531073, 0x000022b7, 0x30029073,
              0x20000093, 0x0000a087, 0x0040a107,
              (2 << 20) | (frm << 15) | (5 << 12) | 0x73,
              (2 << 20) |
                  (1 << 15) |
                  ((dynamic ? 7 : rm) << 12) |
                  (3 << 7) |
                  0x53,
              0xe0018553, // fmv.x.w x10, f3
              (1 << 20) | (2 << 12) | (11 << 7) | 0x73,
              (1 << 20) | (5 << 12) | 0x73,
              (3 << 20) | (2 << 12) | (12 << 7) | 0x73,
              0x00000073, // ecall -> handler and a bounded end on both trees
            ];
            final image = StringBuffer();
            void section(int address, List<int> values) {
              image.writeln('@${address.toRadixString(16)}');
              for (final value in values) {
                for (var i = 0; i < 4; i++) {
                  image.write(
                    '${((value >> (8 * i)) & 255).toRadixString(16).padLeft(2, "0")} ',
                  );
                }
                image.writeln();
              }
            }

            section(0, words);
            section(0x180, [0x34202a73, 0x34102af3, 0x0000006f]);
            section(0x200, [0x3f800000, 0x33800000]);
            await coreTest(
              image.toString(),
              {
                Register.x20: 11,
                Register.x21: (words.length - 1) * 4,
                Register.x10: 0x3f800000 + (rm == 3 || rm == 4 ? 1 : 0),
                Register.x11: 1,
                Register.x12: frm << 5,
              },
              config,
              nextPc: 0x188,
            );
          }, timeout: const Timeout(Duration(minutes: 5)));
        }
      }
    });
  }
}
