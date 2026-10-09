import 'package:river/river.dart';
import 'package:test/test.dart';

/// RV32C/RV64C decode regression: overlap-prone ops resolve distinctly, the full
/// op set is present, and the per-instruction scrambled immediates decode per the
/// RISC-V C-extension spec. Guards the fixes that closed project_rvc_audit (the
/// c.mv/c.add and c.jr/c.jalr/c.ebreak overlaps, the ~12 once-missing ops, and the
/// per-instruction sign-extended/scrambled immediates).
void main() {
  final config = RiverCoreConfigV1.macro(
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    interrupts: [],
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
  );

  RiscVOperation? decode(int instr) {
    for (final ext in config.extensions) {
      final op = ext.findOperation(instr, mxlen: config.mxlen);
      if (op != null) return op;
    }
    return null;
  }

  test('RVC overlap + once-missing ops resolve distinctly', () {
    final cases = {
      0x8082: 'c.jr', // inst12=0, rs2=0  (NOT shadowed by c.mv)
      0x852E: 'c.mv', // inst12=0, rs2!=0
      0x9082: 'c.jalr', // inst12=1, rs1!=0, rs2=0  (NOT shadowed by c.add)
      0x9002: 'c.ebreak', // inst12=1, rs1=0, rs2=0
      0x952E: 'c.add', // inst12=1, rs2!=0
      0x8091: 'c.srli',
      0x8511: 'c.srai',
      0x8911: 'c.andi',
      0x8D0D: 'c.sub',
      0x8D2D: 'c.xor',
      0x8D4D: 'c.or',
      0x8D6D: 'c.and',
    };
    for (final e in cases.entries) {
      expect(
        decode(e.key)?.mnemonic,
        e.value,
        reason: '0x${e.key.toRadixString(16)} should decode to ${e.value}',
      );
    }
  });

  test('RVC per-instruction scrambled immediates (known answers)', () {
    // [kind, instrWord, expectedImm]
    final cases = <(RvcImm, int, int)>[
      (RvcImm.ciAddi, 0x0014, 5), // +5
      (RvcImm.ciAddi, 0x107C, -1), // sign-extended -1
      (RvcImm.ciLui, 0x0004, 4096), // imm<<12
      (RvcImm.ciLui, 0x1000, -131072), // sign-extended from bit17
      (RvcImm.ciAddi16sp, 0x0040, 16),
      (RvcImm.ciLwsp, 0x0004, 64),
      (RvcImm.cssSwsp, 0x0200, 4),
      (RvcImm.ciwAddi4spn, 0x0080, 64),
    ];
    for (final (kind, word, want) in cases) {
      expect(
        decodeRvcImm(kind, word),
        want,
        reason: '$kind of 0x${word.toRadixString(16)} should be $want',
      );
    }
  });

  test(
    'RV64C floating-point loads and stores decode on the D-bearing tiers',
    () {
      // Reference words from GNU as (riscv64-none-elf-as -march=rv64gc).
      final cases = {
        0x2D18: 'c.fld', // c.fld f14, 24(x10)
        0x25E4: 'c.fld', // c.fld f9, 200(x11)
        0xAD10: 'c.fsd', // c.fsd f12, 24(x10)
        0xA6FC: 'c.fsd', // c.fsd f15, 200(x13)
        0x2122: 'c.fldsp', // c.fldsp f2, 8(sp)
        0x2FB2: 'c.fldsp', // c.fldsp f31, 264(sp)
        0xA822: 'c.fsdsp', // c.fsdsp f8, 16(sp)
        0xA282: 'c.fsdsp', // c.fsdsp f0, 320(sp)
      };
      for (final e in cases.entries) {
        expect(
          decode(e.key)?.mnemonic,
          e.value,
          reason: '0x${e.key.toRadixString(16)} should decode to ${e.value}',
        );
      }
      // The integer forms keep funct3 011 and 111. There is no c.flw on RV64.
      expect(decode(0x6118)?.mnemonic, 'c.ld');
      expect(decode(0xE118)?.mnemonic, 'c.sd');
    },
  );

  test('a tier with C but no D traps the floating-point compressed ops', () {
    final small = RiverCoreConfigV1.small(
      mmu: HarborMmuConfig(
        mxlen: RiscVMxlen.rv64,
        pagingModes: const [RiscVPagingMode.bare],
        tlbLevels: const [],
        pmp: HarborPmpConfig.none,
      ),
      interrupts: [],
      clock: const HarborClockConfig(
        name: 'test',
        rate: HarborFixedClockRate(10000),
      ),
    );
    RiscVOperation? decodeSmall(int instr) {
      for (final ext in small.extensions) {
        final op = ext.findOperation(instr, mxlen: small.mxlen);
        if (op != null) return op;
      }
      return null;
    }

    for (final word in [0x2D18, 0xAD10, 0x2122, 0xA822]) {
      expect(
        decodeSmall(word),
        isNull,
        reason: '0x${word.toRadixString(16)} must be illegal without D',
      );
    }
    // The integer compressed ops still decode there.
    expect(decodeSmall(0x6118)?.mnemonic, 'c.ld');
  });
}
