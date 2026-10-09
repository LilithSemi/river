import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

int _jump(int offset) =>
    (((offset >> 20) & 1) << 31) |
    (((offset >> 1) & 0x3ff) << 21) |
    (((offset >> 11) & 1) << 20) |
    (((offset >> 12) & 0xff) << 12) |
    0x6f;

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
      test(
        'U mode aliases and invalid frm with nonrounding operations',
        () async {
          final boot = [
            0x18000313,
            0x30531073,
            0x000022b7,
            0x30029073,
            0x10000313,
            0x34131073,
            0x30200073,
          ];
          final body = [
            0x20000093, 0x0000b087, 0x0080b107,
            (3 << 20) | (31 << 15) | (5 << 12) | 0x73,
            (2 << 20) | (7 << 15) | (5 << 12) | 0x73,
            (3 << 20) | (2 << 12) | (10 << 7) | 0x73,
            (1 << 20) | (5 << 12) | 0x73,
            (3 << 20) | (2 << 12) | (11 << 7) | 0x73,
            (0x71 << 25) | (1 << 15) | (1 << 12) | (12 << 7) | 0x53, // fclass.d
            (0x51 << 25) | (1 << 20) | (1 << 15) | (2 << 12) | (13 << 7) | 0x53,
            0x2a1081d3, // fmin.d f3, f1, f1: frm=7 ignored
            (0x71 << 25) | (3 << 15) | (14 << 7) | 0x53,
            0x02208253, // fadd.d f4, f1, f2, RNE: static mode overrides frm=7
            (1 << 20) | (2 << 12) | (16 << 7) | 0x73,
            (2 << 20) | (2 << 12) | (17 << 7) | 0x73,
            (3 << 20) | (2 << 12) | (18 << 7) | 0x73,
            0x73,
          ];
          final image = StringBuffer();
          void section(int address, List<int> values, int bytes) {
            image.writeln('@${address.toRadixString(16)}');
            for (final value in values) {
              for (var i = 0; i < bytes; i++) {
                image.write(
                  '${((value >> (8 * i)) & 255).toRadixString(16).padLeft(2, "0")} ',
                );
              }
              image.writeln();
            }
          }

          section(0, boot, 4);
          section(0x100, body, 4);
          section(0x180, [0x34202a73, 0x34102af3, _jump(0x1c0 - 0x188)], 4);
          section(0x1c0, [0x6f], 4);
          section(0x200, [0x3ff0000000000000, 0x3ca0000000000000], 8);
          await coreTest(
            image.toString(),
            {
              Register.x20: 8,
              Register.x21: 0x100 + (body.length - 1) * 4,
              Register.x10: 255,
              Register.x11: 224,
              Register.x12: 64,
              Register.x13: 1,
              Register.x14: 0x3ff0000000000000,
              Register.x16: 1,
              Register.x17: 7,
              Register.x18: 225,
            },
            config,
            nextPc: 0x1c0,
          );
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );
      for (final producer in <(String, int, int, int, int, int, int, bool)>[
        (
          'fused intermediate overflow is exact',
          0x222081c3,
          0x7fefffffffffffff,
          0x4000000000000000,
          0xffefffffffffffff,
          0x7fefffffffffffff,
          0,
          false,
        ),
        (
          'fused tiny product normal sum',
          0x222081c3,
          1,
          0x3fe0000000000000,
          0x3ff0000000000000,
          0x3ff0000000000000,
          1,
          false,
        ),
        (
          'sqrt single inexact',
          0x580081d3,
          0xffffffff40000000,
          0,
          0,
          0xffffffff3fb504f3,
          1,
          false,
        ),
        (
          'integer to single inexact',
          0xd00601d3,
          0x1000001,
          0,
          0,
          0xffffffff4b800000,
          1,
          false,
        ),
        (
          'narrow precision',
          0x401081d3,
          0x4000000000000000,
          0,
          0,
          0xffffffff40000000,
          0,
          false,
        ),
        (
          'widen unboxed single',
          0x420081d3,
          0x000000003f800000,
          0,
          0,
          0x7ff8000000000000,
          0,
          false,
        ),
        (
          'raw move to single',
          0xf00601d3,
          0x7f800001,
          0,
          0,
          0xffffffff7f800001,
          0,
          false,
        ),
        (
          'raw move from single sign extends',
          0xe0008653,
          0xdeadbeefbf800000,
          0,
          0,
          0xffffffffbf800000,
          0,
          true,
        ),
        (
          'divide zero',
          0x1a2081d3,
          0x3ff0000000000000,
          0,
          0,
          0x7ff0000000000000,
          8,
          false,
        ),
        (
          'sqrt invalid',
          0x5a0081d3,
          0xbff0000000000000,
          0,
          0,
          0x7ff8000000000000,
          16,
          false,
        ),
        (
          'multiply overflow',
          0x122081d3,
          0x7fefffffffffffff,
          0x4000000000000000,
          0,
          0x7ff0000000000000,
          5,
          false,
        ),
        (
          'multiply underflow',
          0x122081d3,
          1,
          0x3fe0000000000000,
          0,
          0,
          3,
          false,
        ),
        (
          'fused exact cancellation',
          0x222081c3,
          0x3ff0000000000001,
          0x3feffffffffffffe,
          0xbff0000000000000,
          0xb970000000000000,
          0,
          false,
        ),
        (
          'FP to integer inexact',
          0xc2008653,
          0x4004000000000000,
          0,
          0,
          2,
          1,
          true,
        ),
        (
          'FP to integer invalid',
          0xc2008653,
          0x7ff8000000000000,
          0,
          0,
          0x7fffffff,
          16,
          true,
        ),
        (
          'integer to FP inexact',
          0xd22601d3,
          0x0020000000000001,
          0,
          0,
          0x4340000000000000,
          1,
          false,
        ),
        (
          'quiet equality',
          0xa220a653,
          0x7ff8000000000000,
          0x3ff0000000000000,
          0,
          0,
          0,
          true,
        ),
        (
          'signaling comparison',
          0xa2209653,
          0x7ff8000000000000,
          0x3ff0000000000000,
          0,
          0,
          16,
          true,
        ),
        (
          'minimum quiet NaN',
          0x2a2081d3,
          0x3ff0000000000000,
          0x7ff8000000000000,
          0,
          0x3ff0000000000000,
          0,
          false,
        ),
        (
          'minimum signaling NaN',
          0x2a2081d3,
          0x3ff0000000000000,
          0x7ff0000000000001,
          0,
          0x3ff0000000000000,
          16,
          false,
        ),
        (
          'minimum signed zero',
          0x2a2081d3,
          0,
          0x8000000000000000,
          0,
          0x8000000000000000,
          0,
          false,
        ),
        (
          'unboxed single is quiet NaN',
          0x002081d3,
          0x000000007f800001,
          0xffffffff3f800000,
          0,
          0xffffffff7fc00000,
          0,
          false,
        ),
        (
          'boxed signaling single',
          0x002081d3,
          0xffffffff7f800001,
          0xffffffff3f800000,
          0,
          0xffffffff7fc00000,
          16,
          false,
        ),
      ]) {
        test('producer ${producer.$1}', () async {
          final seed = producer.$7 == 8 ? 1 : 8;
          final words = <int>[
            0x18000313, 0x30531073, 0x000022b7, 0x30029073,
            0x20000093, 0x0000b087, 0x0080b107, 0x0100b207,
            0x0000b603, // integer x12 also reads the raw first operand
            (1 << 20) | (seed << 15) | (5 << 12) | 0x73, // distinct sticky flag
            0x000042b7, 0x30029073, // FS Clean before the operation
            producer.$2,
            if (!producer.$8) (0x71 << 25) | (3 << 15) | (10 << 7) | 0x53,
            (1 << 20) | (2 << 12) | (11 << 7) | 0x73,
            (0x300 << 20) | (2 << 12) | (15 << 7) | 0x73,
            (13 << 20) | (15 << 15) | (5 << 12) | (15 << 7) | 0x13,
            (3 << 20) | (15 << 15) | (7 << 12) | (15 << 7) | 0x13,
          ];
          words.add(_jump(0x1c0 - words.length * 4));
          final image = StringBuffer();
          void section(int address, List<int> values, int bytes) {
            image.writeln('@${address.toRadixString(16)}');
            for (final value in values) {
              for (var i = 0; i < bytes; i++) {
                image.write(
                  '${((value >> (8 * i)) & 255).toRadixString(16).padLeft(2, "0")} ',
                );
              }
              image.writeln();
            }
          }

          section(0, words, 4);
          section(0x180, [0x34202a73, 0x34102af3, _jump(0x1c0 - 0x188)], 4);
          section(0x1c0, [0x6f], 4);
          section(0x200, [producer.$3, producer.$4, producer.$5], 8);
          await coreTest(
            image.toString(),
            {
              Register.x20: 0,
              Register.x21: 0,
              producer.$8 ? Register.x12 : Register.x10: producer.$6,
              Register.x11: seed | producer.$7,
              Register.x15: !producer.$8 || producer.$7 != 0 ? 3 : 2,
            },
            config,
            nextPc: 0x1c0,
          );
        }, timeout: const Timeout(Duration(minutes: 5)));
      }
      for (final scenario in [
        ('reserved static 5', false, 5, -1, false, 0x022081d3),
        ('reserved static 6', false, 6, -1, false, 0x022081d3),
        ('reserved dynamic 5', true, 7, 5, false, 0x022081d3),
        ('reserved dynamic 6', true, 7, 6, false, 0x022081d3),
        ('reserved dynamic 7', true, 7, 7, false, 0x022081d3),
        ('FS Off add', false, 0, -1, true, 0x022081d3),
        ('FS Off load', false, 0, -1, true, 0x0080b187),
        ('FS Off store', false, 0, -1, true, 0x0030b827),
        ('FS Off compare', false, 0, -1, true, 0xa220a653),
      ]) {
        test(scenario.$1, () async {
          final words = <int>[
            0x18000313, 0x30531073, 0x000022b7, 0x30029073,
            0x20000093, 0x0000b087, 0x0080b107, 0x0000b187,
            0x06300613, // x12 destination sentinel
            if (scenario.$4 >= 0)
              (2 << 20) | (scenario.$4 << 15) | (5 << 12) | 0x73,
            if (scenario.$5) 0x30001073, // FS Off
          ];
          final faultPc = words.length * 4;
          words.add(
            scenario.$5 ? scenario.$6 : scenario.$6 | (scenario.$3 << 12),
          );
          words.add(
            0x00100b13,
          ); // must not execute after the illegal instruction
          words.add(_jump(0x1c0 - words.length * 4));
          final trapWords = [
            0x34202a73, 0x34102af3, // mcause/mepc
            0x000022b7, 0x30029073, // re-enable FP for destination inspection
            0x1b000313,
            0x30531073, // nested unsupported-CSR trap escapes on baseline
            (0x71 << 25) | (3 << 15) | (10 << 7) | 0x53,
            (1 << 20) | (2 << 12) | (11 << 7) | 0x73,
            _jump(0x1c0 - (0x180 + 8 * 4)),
          ];
          final image = StringBuffer();
          void section(int address, List<int> values, int bytes) {
            image.writeln('@${address.toRadixString(16)}');
            for (final value in values) {
              for (var i = 0; i < bytes; i++) {
                image.write(
                  '${((value >> (8 * i)) & 255).toRadixString(16).padLeft(2, "0")} ',
                );
              }
              image.writeln();
            }
          }

          section(0, words, 4);
          section(0x180, trapWords, 4);
          section(0x1b0, [0x00100b93, _jump(0x1c0 - 0x1b4)], 4);
          section(0x1c0, [0x6f], 4);
          section(0x200, [
            0x3ff0000000000000,
            0x3ca0000000000000,
            0x123456789abcdef,
          ], 8);
          await coreTest(
            image.toString(),
            {
              Register.x20: 2,
              Register.x21: faultPc,
              Register.x22: 0,
              Register.x23: 0,
              Register.x10: 0x3ff0000000000000,
              Register.x11: 0,
              Register.x12: 99,
            },
            config,
            nextPc: 0x1c0,
            memStates: {0x210: 0x123456789abcdef},
          );
        }, timeout: const Timeout(Duration(minutes: 5)));
      }
      for (final dynamic in [false, true]) {
        for (var mode = 0; mode < 5; mode++) {
          final rm = mode;
          test(
            '${dynamic ? "dynamic" : "static"} rm=$rm flags retire once',
            () async {
              final frm = dynamic ? rm : (rm + 1) % 5;
              final words = [
                0x18000313, 0x30531073, // mtvec=0x180; baseline traps terminate
                0x000022b7, 0x30029073, // FS Initial
                0x20000093, 0x0000b087, 0x0080b107, // f1=1, f2=half ulp
                (2 << 20) | (frm << 15) | (5 << 12) | 0x73, // csrrwi frm
                (1 << 25) |
                    (2 << 20) |
                    (1 << 15) |
                    ((dynamic ? 7 : rm) << 12) |
                    (3 << 7) |
                    0x53,
                (0x71 << 25) | (3 << 15) | (10 << 7) | 0x53,
                (1 << 20) | (2 << 12) | (11 << 7) | 0x73, // read fflags
                (1 << 20) | (5 << 12) | 0x73, // clear flags
                0x00000013,
                (1 << 20) | (2 << 12) | (12 << 7) | 0x73,
                (1 << 25) |
                    (1 << 20) |
                    (1 << 15) |
                    (4 << 7) |
                    0x53, // exact 1+1
                (0x71 << 25) | (4 << 15) | (13 << 7) | 0x53,
                (1 << 20) | (2 << 12) | (14 << 7) | 0x73,
                (0x300 << 20) | (2 << 12) | (15 << 7) | 0x73,
                (13 << 20) | (15 << 15) | (5 << 12) | (15 << 7) | 0x13,
                (3 << 20) | (15 << 15) | (7 << 12) | (15 << 7) | 0x13,
                (3 << 20) | (2 << 12) | (16 << 7) | 0x73,
                0x0000006f,
              ];
              words[words.length - 1] = _jump(0x1c0 - (words.length - 1) * 4);
              final image = StringBuffer('@0\n');
              void emit(int value, int bytes) {
                for (var i = 0; i < bytes; i++) {
                  image.write(
                    '${((value >> (8 * i)) & 255).toRadixString(16).padLeft(2, "0")} ',
                  );
                }
                image.writeln();
              }

              for (final word in words) {
                emit(word, 4);
              }
              image.writeln('@180');
              emit(0x34202a73, 4);
              emit(0x34102af3, 4);
              emit(_jump(0x1c0 - 0x188), 4);
              image.writeln('@1c0');
              emit(0x0000006f, 4);
              image.writeln('@200');
              emit(0x3ff0000000000000, 8);
              emit(0x3ca0000000000000, 8);
              await coreTest(
                image.toString(),
                {
                  Register.x20: 0,
                  Register.x21: 0,
                  Register.x10:
                      0x3ff0000000000000 + (rm == 3 || rm == 4 ? 1 : 0),
                  Register.x11: 1,
                  Register.x12: 0,
                  Register.x13: 0x4000000000000000,
                  Register.x14: 0,
                  Register.x15: 3,
                  Register.x16: frm << 5,
                },
                config,
                nextPc: 0x1c0,
              );
            },
            timeout: const Timeout(Duration(minutes: 5)),
          );
        }
      }
    });
  }
}
