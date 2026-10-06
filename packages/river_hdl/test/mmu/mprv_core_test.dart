import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

int _csrw(int addr, int rs) => (addr << 20) | (rs << 15) | 0x1073;
int _csrr(int addr, int rd) => (addr << 20) | (rd << 7) | 0x2073;
int _ld(int rd) => (11 << 15) | (3 << 12) | (rd << 7) | 3;
String _bytes(int value, int count) => List.generate(
  count,
  (i) => ((value >> (i * 8)) & 255).toRadixString(16).padLeft(2, '0'),
).join(' ');
String _image(List<int> program, int leaf) =>
    '''
@0
${program.map((w) => _bytes(w, 4)).join('\n')}
@100
${[_csrr(0x342, 8), _csrr(0x343, 9), 0x6f].map((w) => _bytes(w, 4)).join('\n')}
@10000
${_bytes(0x4401, 8)}
@11000
${_bytes(0x4801, 8)}
@12100
${_bytes(0xc000 | leaf, 8)}
@20000
${_bytes(0x1111, 8)}
@30000
${_bytes(0x2222, 8)}
''';

void main() => runMprvCoreTests();

void runMprvCoreTests({bool microcoded = false}) {
  tearDown(Simulator.reset);
  const mprv = 1 << 17, sum = 1 << 18, mxr = 1 << 19;
  for (final cached in [false, true]) {
    final config = RiverCoreConfig(
      mxlen: RiscVMxlen.rv64,
      extensions: kRva22S64Extensions,
      type: RiverCoreType.general,
      microcodeMode: microcoded ? MicrocodeMode.full : MicrocodeMode.none,
      l1cache: cached
          ? HarborL1CacheConfig.split(
              iSize: 64,
              dSize: 256,
              ways: 1,
              lineSize: 8,
            )
          : null,
      mmu: HarborMmuConfig(
        mxlen: RiscVMxlen.rv64,
        pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
        tlbLevels: const [],
        pmp: HarborPmpConfig.none,
        hasSupervisorUserMemory: true,
        hasMakeExecutableReadable: true,
      ),
      interrupts: [],
      clock: const HarborClockConfig(
        name: 'test',
        rate: HarborFixedClockRate(10000),
      ),
    );
    final seeds = <Register, int>{
      Register.x10: 0x8000000000000010,
      Register.x11: 0x20000,
      Register.x14: 0x100,
    };
    test('MPRV physical/translated warm loads cached=$cached', () async {
      final program = [
        _csrw(0x180, 10),
        _csrw(0x305, 14),
        _ld(5),
        _ld(6),
        _csrw(0x300, 12),
        _ld(7),
        _ld(8),
        _csrw(0x300, 13),
        _ld(9),
        _csrw(0x300, 0),
        _ld(15),
        0x6f,
      ];
      await coreTest(
        _image(program, 0xcf),
        {
          Register.x5: 0x1111,
          Register.x6: 0x1111,
          Register.x7: 0x2222,
          Register.x8: 0x2222,
          Register.x9: 0x1111,
          Register.x15: 0x1111,
        },
        config,
        initRegisters: {
          ...seeds,
          Register.x12: mprv | (1 << 11),
          Register.x13: mprv | (3 << 11),
        },
        nextPc: (program.length - 1) * 4,
        maxCycles: 3000,
      );
    });
    for (final c in [
      (name: 'MPP S to U', leaf: 0xcf, warm: mprv | (1 << 11), cold: mprv),
      (
        name: 'SUM cleared',
        leaf: 0xdf,
        warm: mprv | (1 << 11) | sum,
        cold: mprv | (1 << 11),
      ),
      (
        name: 'MXR cleared',
        leaf: 0xc9,
        warm: mprv | (1 << 11) | mxr,
        cold: mprv | (1 << 11),
      ),
    ]) {
      test('MPRV ${c.name} denies warm hit cached=$cached', () async {
        final program = [
          _csrw(0x180, 10),
          _csrw(0x305, 14),
          _csrw(0x300, 12),
          _ld(5),
          _ld(6),
          _csrw(0x300, 13),
          _ld(7),
          // If incorrectly allowed, still reach the checker instead of spinning.
          // x7/cause/tval then expose the failure. jal x0, 0x100 from PC=0x1c.
          0x0e40006f,
        ];
        await coreTest(
          _image(program, c.leaf),
          {
            Register.x5: 0x2222,
            Register.x6: 0x2222,
            Register.x7: 0,
            Register.x8: 13,
            Register.x9: 0x20000,
          },
          config,
          initRegisters: {...seeds, Register.x12: c.warm, Register.x13: c.cold},
          nextPc: 0x108,
          maxCycles: 3000,
        );
      });
    }
    test('MPRV store uses translated address cached=$cached', () async {
      final program = [
        _csrw(0x180, 10), _csrw(0x305, 14),
        _csrw(0x300, 12), _ld(5),
        (15 << 20) | (11 << 15) | (3 << 12) | 0x23, // sd x15, 0(x11)
        _ld(6), _csrw(0x300, 0), _ld(7), 0x6f,
      ];
      await coreTest(
        _image(program, 0xcf),
        {Register.x5: 0x2222, Register.x6: 0x3333, Register.x7: 0x1111},
        config,
        initRegisters: {
          ...seeds,
          Register.x12: mprv | (1 << 11),
          Register.x15: 0x3333,
        },
        memStates: {0x20000: 0x1111, 0x30000: 0x3333},
        nextPc: 32,
        maxCycles: 3000,
      );
    });
    test('MRET to M changes effective data privilege cached=$cached', () async {
      final program = [
        _csrw(0x180, 10),
        _csrw(0x305, 14),
        _csrw(0x300, 12),
        _ld(5),
        _ld(6),
        _csrw(0x341, 13),
        0x30200073,
        _ld(7),
        _ld(8),
        0x6f,
      ];
      await coreTest(
        _image(program, 0xdf),
        {
          Register.x5: 0x1111,
          Register.x6: 0x1111,
          Register.x7: 0x2222,
          Register.x8: 0x2222,
        },
        config,
        initRegisters: {
          ...seeds,
          Register.x12: mprv | (3 << 11),
          Register.x13: 28,
        },
        nextPc: 36,
        maxCycles: 3000,
      );
    });
  }
}
