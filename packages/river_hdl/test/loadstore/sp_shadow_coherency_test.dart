import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// x2 (sp) has a SHADOW copy outside the register file.
///
/// exec.dart keeps `currentSp`/`nextSp`, and a `ReadRegister` micro-op whose
/// register index resolves to x2 takes that shadow instead of the register file
/// (exec.dart, the `Iff(rs == x2)` arm of the ReadRegister dispatch). The shadow
/// is therefore the ARCHITECTURAL value of sp for every later instruction, and
/// the register-file copy is only what a debugger or a test reads back.
///
/// The `WriteRegister` micro-op mirrors an x2 write into `nextSp`, so the two
/// stay together on the ordinary path. The arms that drive the register write
/// port DIRECTLY did not: the AMO write-completion, the load-reserved commit,
/// both store-conditional commits and the link-register write set
/// rdWrite.en/addr/data with no mirror. An `amo*.d sp, ...`, `lr.d sp, ...`,
/// `sc.d sp, ...`, `jal sp, ...` or `jalr sp, ...` therefore updated the
/// register file and left the shadow holding the OLD sp, permanently, for every
/// instruction that follows.
///
/// Each case here writes sp through one of those arms and then reads sp back
/// through an ordinary instruction. A coherent core sees the new value in both
/// the register file and the shadow.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig cfg() => RiverCoreConfigV1.small(
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    clock: const HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
  );

  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  int lui(int rd, int imm20) => ((imm20 & 0xfffff) << 12) | (rd << 7) | 0x37;
  // amoadd.d rd, rs2, (rs1)
  int amoaddD(int rd, int rs2, int rs1) =>
      (rs2 << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x2F;
  // lr.d rd, (rs1): funct5 = 0b00010
  int lrD(int rd, int rs1) =>
      (2 << 27) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x2F;
  // sc.d rd, rs2, (rs1): funct5 = 0b00011
  int scD(int rd, int rs2, int rs1) =>
      (3 << 27) | (rs2 << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x2F;
  int jal(int rd, int imm) =>
      (((imm >> 20) & 1) << 31) |
      (((imm >> 1) & 0x3ff) << 21) |
      (((imm >> 11) & 1) << 20) |
      (((imm >> 12) & 0xff) << 12) |
      (rd << 7) |
      0x6f;

  String memImage(Map<int, List<int>> words) {
    final sb = StringBuffer();
    final addrs = words.keys.toList()..sort();
    for (final a in addrs) {
      sb.writeln('@${a.toRadixString(16)}');
      for (final w in words[a]!) {
        for (var i = 0; i < 4; i++) {
          sb.write(((w >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }
      sb.writeln();
    }
    return sb.toString();
  }

  //   lui  x2, 1          ; sp = 0x1000 (shadow and regfile agree)
  //   lui  x10, 2         ; x10 = 0x2000
  //   addi x11, x0, 0x40
  //   amoadd.d x2, x11, (x10)  ; sp = old mem[0x2000] = 0x800
  //   addi x3, x2, 0      ; x3 = sp, read through the ReadRegister x2 path
  //   jal  x0, 0
  final body = <int>[
    lui(2, 1),
    lui(10, 2),
    addi(11, 0, 0x40),
    amoaddD(2, 11, 10),
    addi(3, 2, 0),
    0x0000006f,
  ];
  final parkPc = (body.length - 1) * 4;

  //   lui  x2, 1          ; sp = 0x1000
  //   lui  x10, 2
  //   lr.d x2, (x10)      ; sp = mem[0x2000] = 0x800
  //   addi x3, x2, 0
  //   jal  x0, 0
  final lrBody = <int>[
    lui(2, 1),
    lui(10, 2),
    lrD(2, 10),
    addi(3, 2, 0),
    0x0000006f,
  ];
  final lrParkPc = (lrBody.length - 1) * 4;

  //   lui  x2, 1          ; sp = 0x1000
  //   lui  x10, 2
  //   lr.d x11, (x10)     ; arm the reservation on 0x2000
  //   addi x12, x0, 0x55
  //   sc.d x2, x12, (x10) ; the store SUCCEEDS, so sp = 0
  //   addi x3, x2, 0
  //   jal  x0, 0
  final scBody = <int>[
    lui(2, 1),
    lui(10, 2),
    lrD(11, 10),
    addi(12, 0, 0x55),
    scD(2, 12, 10),
    addi(3, 2, 0),
    0x0000006f,
  ];
  final scParkPc = (scBody.length - 1) * 4;

  //   lui  x2, 1          ; sp = 0x1000
  //   jal  x2, +8         ; sp = the link address, which is 8
  //   jal  x0, 0          ; (skipped)
  //   addi x3, x2, 0
  //   jal  x0, 0
  final jalBody = <int>[
    lui(2, 1),
    jal(2, 8),
    0x0000006f,
    addi(3, 2, 0),
    0x0000006f,
  ];
  final jalParkPc = (jalBody.length - 1) * 4;

  test('an AMO into sp updates the value later instructions read', () {
    return coreTest(
      memImage({
        0x0: body,
        // mem[0x2000] = 0x800
        0x2000: [0x800, 0],
      }),
      {
        // The register file gets the AMO result either way.
        Register.x2: 0x800,
        // x3 is sp as the DATAPATH sees it. A stale shadow leaves 0x1000 here.
        Register.x3: 0x800,
      },
      cfg(),
      nextPc: parkPc,
      maxCycles: 20000,
    );
  });

  test('a load-reserved into sp updates the value later instructions read', () {
    return coreTest(
      memImage({
        0x0: lrBody,
        0x2000: [0x800, 0],
      }),
      {Register.x2: 0x800, Register.x3: 0x800},
      cfg(),
      nextPc: lrParkPc,
      maxCycles: 20000,
    );
  });

  test(
    'a store-conditional into sp updates the value later instructions read',
    () {
      return coreTest(
        memImage({
          0x0: scBody,
          0x2000: [0x800, 0],
        }),
        // The SC hits its own reservation, so rd = 0 (success).
        {Register.x2: 0, Register.x3: 0},
        cfg(),
        nextPc: scParkPc,
        maxCycles: 20000,
      );
    },
  );

  test('a jal link into sp updates the value later instructions read', () {
    return coreTest(
      memImage({0x0: jalBody}),
      // The link address is the instruction after the jal, which is 8.
      {Register.x2: 8, Register.x3: 8},
      cfg(),
      nextPc: jalParkPc,
      maxCycles: 20000,
    );
  });
}
