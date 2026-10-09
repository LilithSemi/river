import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';
import 'fma_reference.dart';

void main() {
  tearDown(Simulator.reset);
  for (final microcoded in [false, true]) {
    group(microcoded ? 'microcoded' : 'static', () {
      final config = RiverCoreConfig(
        clock: const HarborClockConfig(
          name: 'test',
          rate: HarborFixedClockRate(10000),
        ),
        mxlen: RiscVMxlen.rv64,
        extensions: [
          rv32i,
          rv64i,
          rvZicsr,
          rvPriv,
          rvF,
          rvD,
        ],
        interrupts: [],
        microcodeMode: microcoded ? MicrocodeMode.full : MicrocodeMode.none,
        mmu: HarborMmuConfig(
          mxlen: RiscVMxlen.rv64,
          pagingModes: const [RiscVPagingMode.bare],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
        ),
        type: RiverCoreType.general,
      );
      for (final witness in [
        (
          'cancellation',
          0x3ff0000000000001,
          0x3feffffffffffffe,
          0xbff0000000000000,
        ),
        (
          'product overflow',
          0x7fefffffffffffff,
          0x4000000000000000,
          0xffefffffffffffff,
        ),
        ('product underflow', 1, 0x3fe0000000000000, 1),
      ]) {
        group(witness.$1, () {
          for (final form in [
            ('fmadd.d', 0x43, false, false),
            ('fmsub.d', 0x47, false, true),
            ('fnmsub.d', 0x4b, true, false),
            ('fnmadd.d', 0x4f, true, true),
          ]) {
            test(form.$1, () async {
              final words = [
                0x000022b7, // lui x5, 2: mstatus.FS <- Initial
                0x30029073, // csrrw x0, mstatus, x5
                0x20000093, // addi x1, x0, 0x200
                0x0000b087, // fld f1, 0(x1)
                0x0080b107, // fld f2, 8(x1)
                0x0100b187, // fld f3, 16(x1)
                (3 << 27) |
                    (1 << 25) |
                    (2 << 20) |
                    (1 << 15) |
                    (4 << 7) |
                    form.$2,
                (0x71 << 25) | (4 << 15) | (10 << 7) | 0x53, // fmv.x.d x10, f4
                0x00100593, // addi x11, x0, 1: completion sentinel
                0x0000006f,
              ];
              final image = StringBuffer('@0\n');
              void emit(int bits, int bytes) {
                for (var i = 0; i < bytes; i++) {
                  image.write(
                    '${((bits >> (8 * i)) & 0xff).toRadixString(16).padLeft(2, '0')} ',
                  );
                }
                image.writeln();
              }

              for (final word in words) {
                emit(word, 4);
              }
              image.writeln('@200');
              for (final operand in [witness.$2, witness.$3, witness.$4]) {
                emit(operand, 8);
              }
              await coreTest(
                image.toString(),
                {
                  Register.x10: fusedBits(
                    witness.$2,
                    witness.$3,
                    witness.$4,
                    exponentBits: 11,
                    fractionBits: 52,
                    negateProduct: form.$3,
                    negateAddend: form.$4,
                  ),
                  Register.x11: 1,
                },
                config,
                nextPc: (words.length - 1) * 4,
              );
            }, timeout: const Timeout(Duration(minutes: 5)));
          }
        });
      }
    });
  }
}
