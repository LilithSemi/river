import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

int csr(int addr, int rs1, int funct3, int rd) =>
    (addr << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x73;

String program(Map<int, int> words) {
  final end = words.keys.reduce((a, b) => a > b ? a : b);
  final out = StringBuffer('@0\n');
  for (var addr = 0; addr <= end + 4; addr += 4) {
    final word = words[addr] ?? 0x13;
    for (var byte = 0; byte < 4; byte++) {
      out.write(
        '${((word >> (byte * 8)) & 255).toRadixString(16).padLeft(2, '0')} ',
      );
    }
  }
  return out.toString();
}

RiverCoreConfig config(bool microcoded, RiscVMxlen xlen) => RiverCoreConfig(
  resetVector: 0,
  clock: const HarborClockConfig(
    name: 'test',
    rate: HarborFixedClockRate(12000000),
  ),
  mxlen: xlen,
  extensions: [if (xlen == RiscVMxlen.rv64) rv64i, rv32i, rvPriv, rvZicsr],
  microcodeMode: microcoded ? MicrocodeMode.full : MicrocodeMode.none,
  interrupts: [],
  mmu: HarborMmuConfig(
    mxlen: xlen,
    pagingModes: const [RiscVPagingMode.bare],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
  ),
  type: RiverCoreType.general,
);

Future<void> runCase(
  bool microcoded,
  RiscVMxlen xlen,
  List<int> body,
  Map<Register, int> expected, {
  int mode = 0,
  int mc = 2,
  int sc = 2,
  int? illegalIndex,
}) async {
  final code = <int, int>{
    0x00: csr(0x305, 10, 1, 0), // mtvec
    0x04: csr(0x341, 11, 1, 0), // mepc
    0x08: csr(0x300, 12, 1, 0), // mstatus.MPP
    0x0c: csr(0x306, 13, 1, 0), // mcounteren
    0x10: csr(0x106, 14, 1, 0), // scounteren
    0x14: 0x30200073, // mret
    for (var i = 0; i < body.length; i++) 0x80 + 4 * i: body[i],
    0x80 + body.length * 4: 0x73, // ecall proves selected privilege was reached
    0x400: csr(0x342, 0, 2, 21), // mcause
    0x404: csr(0x341, 0, 2, 22), // mepc
    0x408: 0x13,
  };
  await coreTest(
    program(code),
    {
      ...expected,
      Register.x21: illegalIndex == null ? 8 + mode : 2,
      Register.x22: 0x80 + 4 * (illegalIndex ?? body.length),
    },
    config(microcoded, xlen),
    initRegisters: {
      Register.x10: 0x400,
      Register.x11: 0x80,
      Register.x12: mode << 11,
      Register.x13: mc,
      Register.x14: sc,
      Register.x15: 0x55,
      Register.x20: 0x77,
    },
    timeIn: Const(0x12345678, width: xlen.size),
    nextPc: 0x408,
    maxCycles: 2500,
  );
}

// Separate entrypoints keep each width/executor combination in its own test
// isolate, avoiding accumulated simulator overhead across repeated core builds.
void runUserAccessTests(bool microcoded, RiscVMxlen xlen) {
  tearDown(Simulator.reset);
  final label = '${microcoded ? "microcoded" : "static"} RV${xlen.size}';
  test('$label user reads time and accesses implemented user CSR', () async {
    await runCase(
      microcoded,
      xlen,
      [
        csr(0xc01, 0, 2, 20), // CSRRS x0: read-only access must not write
        csr(0x040, 15, 1, 0), // CSRRW rd=x0: write without read
        csr(0x040, 0, 2, 23),
        csr(0x040, 3, 5, 24), // CSRRWI
        csr(0x040, 4, 6, 25), // CSRRSI
        csr(0x040, 1, 7, 26), // CSRRCI
        csr(0x040, 15, 2, 27), // CSRRS
        csr(0x040, 15, 3, 28), // CSRRC
        csr(0x040, 0, 2, 29),
      ],
      {
        Register.x20: 0x12345678,
        Register.x23: 0x55,
        Register.x24: 0x55,
        Register.x25: 3,
        Register.x26: 7,
        Register.x27: 6,
        Register.x28: 0x57,
        Register.x29: 2,
      },
    );
  });
  for (final (mode, mc, sc, allowed) in [
    (0, 0, 2, false),
    (0, 2, 0, false),
    (1, 0, 2, false),
    (1, 2, 0, true),
    (3, 0, 0, true),
  ]) {
    test('$label time mode=$mode mcounteren=$mc scounteren=$sc', () async {
      await runCase(
        microcoded,
        xlen,
        [csr(0xc01, 0, 2, 20)],
        {Register.x20: allowed ? 0x12345678 : 0x77},
        mode: mode,
        mc: mc,
        sc: sc,
        illegalIndex: allowed ? null : 0,
      );
    });
  }
  for (final (name, instruction) in [
    ('supervisor read', csr(0x100, 0, 2, 20)),
    ('machine write', csr(0x300, 15, 1, 20)),
    ('absent CSR', csr(0x006, 0, 2, 20)),
    ('read-only write', csr(0xc01, 15, 1, 20)),
  ]) {
    test('$label user rejects $name', () async {
      await runCase(
        microcoded,
        xlen,
        [instruction],
        {Register.x20: 0x77},
        illegalIndex: 0,
      );
    });
  }
}
