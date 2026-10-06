import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// An FP load must not touch the INTEGER register file.
///
/// rc1-f advertises RV64GC and runs MicrocodeMode.full, so every instruction,
/// F and D included, comes out of the micro-op ROM and executes in the
/// DynamicExecutionUnit. The ROM's ReadRegister/WriteRegister micro-ops carry a
/// field code (rd/rs1/rs2/imm/pc) and NO register-file selector, and the dynamic
/// unit's ReadRegister/WriteRegister arms drive rs1Read/rs2Read/rdWrite, which
/// are the integer ports. The FP register file the unit builds is only wired up
/// by the StaticExecutionUnit.
///
/// So `fld f19, 0(a0)` is expected to be decoded, executed, and committed
/// against integer x19. This test pins that down: x19 holds a sentinel across
/// the FP load, and the load's data must not appear there.
///
/// [core_fp_test] does not cover this: it builds a core with the default
/// MicrocodeMode.none, so its F/D coverage is entirely on the STATIC unit,
/// which wires the FP ports correctly and passes. The divergence is therefore
/// specific to the microcoded execution path, which is the one rc1-f (and only
/// rc1-f, since no other microcoded tier carries F/D) runs on the board.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  final config = RiverCoreConfigV1.full(
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
  // fld rd, imm(rs1): opcode 0x07, funct3 = 3.
  int fld(int rd, int rs1, int imm) =>
      ((imm & 0xfff) << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x07;
  // fsd rs2, imm(rs1): opcode 0x27, funct3 = 3.
  int fsd(int rs2, int rs1, int imm) =>
      (((imm >> 5) & 0x7f) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (3 << 12) |
      ((imm & 0x1f) << 7) |
      0x27;

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

  final body = <int>[
    lui(10, 2), // x10 = 0x2000
    addi(19, 0, 0x123), // x19 = sentinel
    fld(19, 10, 0), // f19 = mem[0x2000]
    addi(20, 19, 0), // x20 = x19 (prove the sentinel survived the FP load)
    0x0000006f, // park
  ];
  final parkPc = (body.length - 1) * 4;

  // The store side of the same hole: `fsd f19` must store f19, which is 0 out
  // of reset, and not integer x19.
  final storeBody = <int>[
    lui(10, 2), // x10 = 0x2000
    addi(19, 0, 0x123), // integer x19 = sentinel
    fsd(19, 10, 8), // mem[0x2008] = f19
    0x0000006f, // park
  ];
  final storeParkPc = (storeBody.length - 1) * 4;

  test(
    'fld does not write the integer register file (rc1-f)',
    timeout: Timeout(Duration(minutes: 20)),
    () => coreTest(
      memImage({
        0x0: body,
        0x2000: [0x1234ABCD, 0],
      }),
      {Register.x19: 0x123, Register.x20: 0x123},
      config,
      nextPc: parkPc,
      maxCycles: 40000,
    ),
  );

  test(
    'fsd does not read the integer register file (rc1-f)',
    timeout: Timeout(Duration(minutes: 20)),
    () => coreTest(
      memImage({0x0: storeBody}),
      const <Register, int>{},
      config,
      nextPc: storeParkPc,
      maxCycles: 40000,
      // f19 is zero out of reset. The integer x19 sentinel must not appear.
      memStates: {0x2008: 0},
    ),
  );
}
