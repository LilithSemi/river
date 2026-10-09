import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// River's exec dispatches vector ops by mnemonic. It claims `vsetvli`,
/// `vle32.v` and `vse32.v`, but Harbor also defines `vsetvl`, `vsetivli` and
/// the 8/16/64-bit load and store widths. An op no handler claims leaves the
/// result undriven, so these pin which of them actually work.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig vecConfig() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv64,
    extensions: [rv64i, rv32i, rvZicsr, rvZifencei, rvV],
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
    vlen: 128,
  );

  int iimm(int imm, int rs1, int f3, int rd) =>
      (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
  // vsetvli rd, rs1, vtypei. vtypei 0x10 = e32,m1; 0x18 = e64,m1.
  int vsetvli(int vtypei, int rs1, int rd) =>
      (vtypei << 20) | (rs1 << 15) | (0x7 << 12) | (rd << 7) | 0x57;
  // vsetivli rd, uimm, vtypei: bits 31:30 = 11, AVL is the 5-bit uimm.
  int vsetivli(int vtypei, int uimm, int rd) =>
      (3 << 30) |
      (vtypei << 20) |
      (uimm << 15) |
      (0x7 << 12) |
      (rd << 7) |
      0x57;
  // vsetvl rd, rs1, rs2: bit 31 = 1, AVL from rs1 and vtype from rs2.
  int vsetvl(int rs2, int rs1, int rd) =>
      (1 << 31) | (rs2 << 20) | (rs1 << 15) | (0x7 << 12) | (rd << 7) | 0x57;
  // Unit-stride vector load/store. width: 0 = 8b, 5 = 16b, 6 = 32b, 7 = 64b.
  int vle(int width, int rs1, int vd) =>
      (1 << 25) | (rs1 << 15) | (width << 12) | (vd << 7) | 0x07;
  int vse(int width, int rs1, int vs3) =>
      (1 << 25) | (rs1 << 15) | (width << 12) | (vs3 << 7) | 0x27;

  String prog(List<int> ws) =>
      '@0\n${ws.expand((w) => [for (var b = 0; b < 4; b++) ((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0')]).join(' ')}\n';

  // VLEN=128, e32,m1 -> VLMAX = 4. AVL=8 so vl saturates at 4, the same
  // arithmetic the existing vsetvli test pins.
  test(
    'vsetivli computes vl into rd (e32,m1 -> vl=4)',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      prog([
        vsetivli(0x10, 8, 1), // vsetivli x1, 8, e32,m1
        0x00000013,
      ]),
      {Register.x1: 4},
      vecConfig(),
      nextPc: 0x08,
    ),
  );

  test(
    'vsetvl computes vl into rd from registers (e32,m1 -> vl=4)',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      prog([
        iimm(8, 0, 0x0, 2), // x2 = 8    (AVL)
        iimm(0x10, 0, 0x0, 3), // x3 = e32,m1 (vtype)
        vsetvl(3, 2, 1), // vsetvl x1, x2, x3
        0x00000013,
      ]),
      {Register.x1: 4, Register.x2: 8, Register.x3: 0x10},
      vecConfig(),
      nextPc: 0x10,
    ),
  );

  // e64,m1 with VLEN=128 -> VLMAX = 2, so a round trip moves 16 bytes.
  test(
    'vle64.v + vse64.v round-trip through a vreg',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      '${prog([
        iimm(8, 0, 0x0, 2), // AVL = 8, saturates to vl = 2
        vsetvli(0x18, 2, 1), // e64,m1
        iimm(0x100, 0, 0x0, 10), // src
        iimm(0x200, 0, 0x0, 11), // dst
        vle(7, 10, 1), // vle64.v v1, (x10)
        vse(7, 11, 1), // vse64.v v1, (x11)
        0x00000013,
      ])}@100\nbe ba fe ca ef be ad de\n',
      {Register.x10: 0x100, Register.x11: 0x200},
      vecConfig(),
      nextPc: 0x1C,
      memStates: {0x200: 0xDEADBEEFCAFEBABE},
    ),
  );

  // Byte-width unit stride. vl is still 2 elements at e64, so only the low
  // bytes matter here; the point is that the op is dispatched at all.
  test(
    'vle8.v + vse8.v round-trip through a vreg',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      '${prog([
        iimm(16, 0, 0x0, 2), // AVL = 16, e8,m1 -> VLMAX = 16
        vsetvli(0x00, 2, 1), // e8,m1
        iimm(0x100, 0, 0x0, 10),
        iimm(0x200, 0, 0x0, 11),
        vle(0, 10, 1), // vle8.v v1, (x10)
        vse(0, 11, 1), // vse8.v v1, (x11)
        0x00000013,
      ])}@100\nbe ba fe ca ef be ad de\n',
      {Register.x10: 0x100, Register.x11: 0x200},
      vecConfig(),
      nextPc: 0x1C,
      memStates: {0x200: 0xDEADBEEFCAFEBABE},
    ),
  );
}
