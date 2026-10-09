import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Differential parity sweep: each program runs on the EMULATOR (golden ISS) and
/// the HDL core, and their architectural state must match. The emulator computes
/// the expected register/memory values; the HDL is checked against them. This
/// proves the HDL and emulator agree on SCENARIO paths (traps, CSR WARL, fence,
/// F/D incl. FMA/fsgnj, hypervisor CSRs, MMU walks) + a few representation edges.
/// Per-instruction parity (integer/M/OP-IMM/AMO/LR-SC/Zacas/vector/W-variants) is
/// now covered systematically by the matrix categories (#66 dedupe), so the plain
/// per-op cases were removed here and their edges folded into matrix cells.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Lean integer/M config - no F/D/V, so the core builds and simulates fast
  // enough for a long instruction battery.
  RiverCoreConfig intConfig() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv64,
    extensions: [rv64i, rv32i, rvM, rvZicsr, rvZifencei],
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

  // rv32 base config (the nano profile's width). No rv64i. Probes whether 32-bit
  // results are consistently masked (add-overflow wrap, 5-bit shift amounts).
  RiverCoreConfig rv32Config() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv32,
    extensions: [rv32i, rvM, rvZicsr, rvZifencei],
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv32,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
    vlen: 128,
  );

  // F/D config without vector - much faster to build/simulate than fdvConfig for
  // a long FP battery (the vector lane units dominate elaboration).
  RiverCoreConfig fdConfig() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv64,
    extensions: [
      rv64i,
      rv32i,
      rvM,
      rvF,
      rvD,
      rvZicsr,
      rvZifencei,
    ],
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

  // Lean config with rvPriv (ecall/mret) + Zicsr for the trap/CSR sweep.
  RiverCoreConfig trapConfig() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv64,
    extensions: [rv64i, rv32i, rvM, rvZicsr, rvZifencei, rvPriv],
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

  RiverCoreConfig hvConfig() => RiverCoreConfig(
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
    mxlen: RiscVMxlen.rv64,
    extensions: [rv64i, rv32i, rvZicsr, rvZifencei, rvPriv, rvH],
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
  );

  void ww(Sram sram, int addr, int value) {
    for (var i = 0; i < 4; i++) {
      sram.data[addr + i] = (value >> (i * 8)) & 0xFF;
    }
  }

  int rd64(Sram sram, int addr) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v |= sram.data[addr + i] << (i * 8);
    }
    return v;
  }

  void appendWord(StringBuffer sb, int w) {
    for (var b = 0; b < 4; b++) {
      sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
  }

  /// Run [program] (words at 0,4,8,...) on the emulator, collect the golden
  /// register/memory state, then check the HDL against it.
  Future<void> parityCheck(
    List<int> program,
    RiverCoreConfig config, {
    Map<Register, int> seed = const {},
    Map<int, List<int>> dataMem = const {},
    required int nextPc,
    required List<Register> checkRegs,
    List<int> checkMem = const [],
    // Privilege both engines start in. M-mode accesses are PHYSICAL in both, so
    // a test that must exercise paged translation has to run in S-mode.
    PrivilegeMode? startPriv,
    // Golden values the EMULATOR must produce before the HDL is compared to it.
    // parityCheck only asserts that the two engines agree, so a case where both
    // do nothing agrees trivially. Pin the expected result here and that silent
    // pass becomes a failure.
    Map<Register, int> expectGold = const {},
  }) async {
    // --- Emulator golden run ---
    final sram = Sram(
      RiverDevice(
        name: 'sram',
        compatible: 'river,sram',
        range: BusAddressRange(0, 0xFFFFF),
        clockFrequency: (config.clock.rate as HarborFixedClockRate).frequency,
      ),
    );
    final ecore = RiverCore(config, memDevices: Map.fromEntries([sram.mem!]));
    for (var i = 0; i < program.length; i++) {
      ww(sram, i * 4, program[i]);
    }
    dataMem.forEach((addr, words) {
      for (var j = 0; j < words.length; j++) {
        ww(sram, addr + j * 4, words[j]);
      }
    });
    seed.forEach((r, v) => ecore.xregs[r] = v);
    if (startPriv != null) ecore.mode = startPriv;
    // fetch + cycle (NOT runPipeline): cycle() routes V opcodes to executeVector;
    // runPipeline would hit the stub rv_v microcode and skip vector execution.
    var pc = config.resetVector;
    for (var s = 0; s < 5000 && pc != nextPc; s++) {
      final instr = await ecore.fetch(pc);
      pc = await ecore.cycle(pc, instr);
    }
    expect(
      pc,
      nextPc,
      reason: 'emulator did not reach nextPc=$nextPc (got $pc)',
    );
    final goldRegs = {for (final r in checkRegs) r: ecore.xregs[r] ?? 0};
    expectGold.forEach((r, want) {
      expect(
        goldRegs[r],
        want,
        reason: 'emulator golden $r is wrong, so the parity check is vacuous',
      );
    });
    final goldMem = {for (final a in checkMem) a: rd64(sram, a)};

    // --- HDL check vs golden ---
    final sb = StringBuffer('@0\n');
    for (final w in program) {
      appendWord(sb, w);
    }
    dataMem.forEach((addr, words) {
      sb.write('\n@${addr.toRadixString(16)}\n');
      for (final w in words) {
        appendWord(sb, w);
      }
    });
    await coreTest(
      '$sb\n',
      goldRegs,
      config,
      memStates: goldMem,
      initRegisters: seed,
      nextPc: nextPc,
      startPriv: startPriv,
    );
  }

  // ---- instruction encoders ----
  int iimm(int imm, int rs1, int f3, int rd) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
  int rtype(int f7, int rs2, int rs1, int f3, int rd) =>
      (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33;
  int store(int imm, int rs2, int rs1, int f3, int op) =>
      (((imm >> 5) & 0x7F) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (f3 << 12) |
      ((imm & 0x1F) << 7) |
      op;
  int fop(int f7, int rs2, int rs1, int rm, int rd) =>
      (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7) | 0x53;
  int fop4(int op, int rs3, int rs2, int rs1, int rd, {int fmt = 0}) =>
      (rs3 << 27) | (fmt << 25) | (rs2 << 20) | (rs1 << 15) | (rd << 7) | op;
  int csrw(int csr, int rs1) => (csr << 20) | (rs1 << 15) | (0x1 << 12) | 0x73;
  int csrr(int csr, int rd) => (csr << 20) | (0x2 << 12) | (rd << 7) | 0x73;
  int lui(int imm20, int rd) => (imm20 << 12) | (rd << 7) | 0x37;
  int ld(int imm, int rs1, int rd) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (0x3 << 12) | (rd << 7) | 0x03;
  const nop = 0x00000013;

  // NOTE: per-instruction integer OP/OP-IMM/M/W-variants parity (same -5/3
  // operands + div-by-zero edge cases) is now covered systematically by the
  // matrix base/ + m/ categories across ALL configs (#66 dedupe) - removed here.

  // Trap + CSR behavior: ecall traps to mtvec; the handler reads mcause (11 =
  // ecall-from-M) and mepc (the ecall PC), advances mepc past the ecall, and
  // mret resumes. Verifies trap save (mcause/mepc) + mret restore are identical.
  test('parity: trap (ecall -> mtvec -> mret) + mcause/mepc', () async {
    const ecall = 0x00000073;
    const mret = 0x30200073;
    final prog = <int>[
      // main @ 0x00
      iimm(0x40, 0, 0x0, 5), // x5 = 0x40 (handler addr)
      csrw(0x305, 5), // mtvec = 0x40
      iimm(0x55, 0, 0x0, 6), // x6 = 0x55 (pre-ecall marker)
      ecall, // @0x0C: trap -> mepc=0x0C, mcause=11
      iimm(0x99, 0, 0x0, 7), // @0x10: post-mret marker
      nop, // @0x14: halt target
    ];
    // pad 0x18..0x3C so the handler lands at 0x40 (index 16).
    while (prog.length < 16) {
      prog.add(nop);
    }
    prog.addAll([
      csrr(0x342, 10), // @0x40: x10 = mcause (11)
      csrr(0x341, 11), // @0x44: x11 = mepc (0x0C)
      iimm(4, 11, 0x0, 12), // @0x48: x12 = mepc + 4 = 0x10
      csrw(0x341, 12), // @0x4C: mepc = 0x10
      mret, // @0x50: return to mepc = 0x10
    ]);
    await parityCheck(
      prog,
      trapConfig(),
      nextPc: 0x14,
      checkRegs: [Register.x6, Register.x7, Register.x10, Register.x11],
    );
  });

  // M-mode CSR WARL: write mstatus/mie/mscratch and read back. The writable-bit
  // masking (mstatus MIE/MPIE/MPP..., mie's SIE/TIE/EIE) must match the HDL.
  test('parity: M-CSR WARL (mstatus / mie / mscratch)', () async {
    await parityCheck(
      [
        iimm(0x88, 0, 0x0, 10), // MIE(3) + MPIE(7)
        csrw(0x300, 10), csrr(0x300, 11), // mstatus
        iimm(0x888, 0, 0x0, 12), // MSIE/MTIE/MEIE
        csrw(0x304, 12), csrr(0x304, 13), // mie
        iimm(0x123, 0, 0x0, 16),
        csrw(0x340, 16), csrr(0x340, 17), // mscratch (fully writable)
        nop,
      ],
      trapConfig(),
      nextPc: 0x28,
      checkRegs: [Register.x11, Register.x13, Register.x17],
    );
  });

  // NOTE: AMO (incl signed amomax / unsigned amominu), LR/SC (incl sc-fail), and
  // Zacas amocas parity moved to the matrix a/ + zacas/ categories - the
  // signed/unsigned + sc-fail edges were folded into those cells (#66 dedupe).

  // rv32 representation: 32-bit add must wrap, shift amounts mask to 5 bits, and
  // slt/sltu use 32-bit signedness. The emulator returns raw Dart ints, so this
  // catches any rv32 result that isn't masked to 32 bits like the HDL regfile.
  test('parity: rv32 representation (add wrap / 5-bit shamt / slt)', () async {
    await parityCheck(
      [
        iimm(-1, 0, 0x0, 1), // x1 = 0xFFFFFFFF (-1 in rv32)
        iimm(1, 0, 0x0, 2), // x2 = 1
        rtype(0x00, 2, 1, 0x0, 3), // add  x3 = x1+x2 -> wraps to 0 in rv32
        iimm(33, 0, 0x0, 4), // x4 = 33
        iimm(1, 0, 0x0, 5), // x5 = 1
        rtype(0x00, 4, 5, 0x1, 6), // sll  x6 = x5 << (33 & 31) = 1<<1 = 2
        rtype(0x00, 2, 1, 0x3, 7), // sltu x7 = (0xFFFFFFFF <u 1) = 0
        rtype(0x00, 2, 1, 0x2, 8), // slt  x8 = (-1 <s 1) = 1
        nop,
      ],
      rv32Config(),
      nextPc: 0x20,
      checkRegs: [Register.x3, Register.x6, Register.x7, Register.x8],
    );
  });

  // fence / fence.i: functionally no-ops in this in-order model. Confirm both
  // engines decode them (no illegal-instruction trap) and step over identically,
  // with the surrounding arithmetic landing the same value.
  test('parity: fence / fence.i (no-op, execution continues)', () async {
    await parityCheck(
      [
        iimm(5, 0, 0x0, 1), // x1 = 5
        0x0FF0000F, // fence iorw, iorw
        iimm(3, 1, 0x0, 1), // x1 = x1 + 3 = 8
        0x0000100F, // fence.i
        iimm(2, 1, 0x0, 1), // x1 = x1 + 2 = 10
        nop,
      ],
      intConfig(),
      nextPc: 0x18,
      checkRegs: [Register.x1],
    );
  });

  // OP-IMM: addi/slti/sltiu/xori/ori/andi + shift-imm (slli/srli/srai). sltiu
  // sign-extends the 12-bit imm THEN compares unsigned (imm=-1 -> compare vs
  // 0xFFFF..FFFF); srli/srai must be logical/arith on a negative operand.
  test('parity: OP-IMM (slti/sltiu/shift-imm + sign-extended imm)', () async {
    await parityCheck(
      [
        iimm(5, 0, 0x0, 1), // x1 = 5
        iimm(-5, 0, 0x0, 13), // x13 = -5
        iimm(10, 1, 0x0, 2), // addi  x2 = 15
        iimm(3, 1, 0x2, 3), // slti  x3 = (5<3) = 0
        iimm(-1, 1, 0x2, 4), // slti  x4 = (5<-1) = 0
        iimm(-1, 1, 0x3, 5), // sltiu x5 = (5 <u 0xFFFF..F) = 1
        iimm(3, 1, 0x3, 6), // sltiu x6 = (5 <u 3) = 0
        iimm(-1, 1, 0x4, 7), // xori  x7 = 5 ^ -1 = -6
        iimm(0x10, 1, 0x6, 8), // ori  x8 = 0x15
        iimm(0x6, 1, 0x7, 9), // andi x9 = 4
        iimm(3, 1, 0x1, 10), // slli  x10 = 40
        iimm(1, 1, 0x5, 11), // srli  x11 = 2
        iimm(0x401, 13, 0x5, 14), // srai x14 = -5 >>a 1 = -3 (funct6=0x10)
        iimm(1, 13, 0x5, 15), // srli  x15 = -5 >>l 1 (huge positive)
        iimm(3, 13, 0x3, 16), // sltiu x16 = (-5 <u 3) = 0
        nop,
      ],
      intConfig(),
      nextPc: 0x3C,
      checkRegs: [
        Register.x2,
        Register.x3,
        Register.x4,
        Register.x5,
        Register.x6,
        Register.x7,
        Register.x8,
        Register.x9,
        Register.x10,
        Register.x11,
        Register.x14,
        Register.x15,
        Register.x16,
      ],
    );
  });

  // W-variants (RV64 32-bit OP-32): the 32-bit result is sign-extended to 64.
  // Exercises shift logical/arith, div/rem signed/unsigned, and the sign-extension
  // of unsigned results (a divuw/remuw whose bit31 is set must become negative).
  int rtypew(int f7, int rs2, int rs1, int f3, int rd) =>
      rtype(f7, rs2, rs1, f3, rd) | 0x08; // opcode 0x33 -> 0x3B (OP-32)
  test('parity: W-variants (addw..remuw, sign-extension)', () async {
    await parityCheck(
      [
        iimm(-1, 0, 0x0, 1), // x1 = -1 (low32 = 0xFFFFFFFF)
        iimm(3, 0, 0x0, 2), // x2 = 3
        iimm(1, 0, 0x0, 3), // x3 = 1
        rtypew(0x00, 2, 1, 0x0, 4), // addw
        rtypew(0x20, 2, 1, 0x0, 5), // subw
        rtypew(0x00, 2, 1, 0x1, 6), // sllw
        rtypew(0x00, 2, 1, 0x5, 7), // srlw (logical)
        rtypew(0x20, 2, 1, 0x5, 8), // sraw (arithmetic)
        rtypew(0x01, 2, 1, 0x0, 9), // mulw
        rtypew(0x01, 2, 1, 0x4, 10), // divw
        rtypew(0x01, 2, 1, 0x5, 11), // divuw
        rtypew(
          0x01,
          0,
          1,
          0x5,
          12,
        ), // divuw / x0 -> div by zero (all-ones -> -1)
        rtypew(0x01, 3, 1, 0x5, 16), // divuw x1/1 = 0xFFFFFFFF -> sign-ext -1
        rtypew(0x01, 2, 1, 0x6, 13), // remw
        rtypew(0x01, 2, 1, 0x7, 14), // remuw
        rtypew(0x01, 3, 1, 0x7, 15), // remuw x1%1 = 0
        nop,
      ],
      intConfig(),
      nextPc: 0x40,
      checkRegs: [for (var i = 4; i <= 16; i++) Register.values[i]],
    );
  });

  // F/D broad: arith (add/sub/mul/div/sqrt), min/max/sgnj, FMA (madd/msub/nmsub),
  // compares (feq/flt/fle), and fcvt. Arith results land in the separate HDL FP
  // regfile, so each is fsw'd to memory and compared there; compares + fcvt write
  // integer regs and are compared directly. f1=2, f2=3, f3=4 (built via fcvt.s.w).
  int fsw(int off, int fp, int base) => store(off, fp, base, 0x2, 0x27);
  test('parity: F/D broad (arith/min-max/sgnj/FMA/cmp/fcvt)', () async {
    await parityCheck(
      [
        iimm(2, 0, 0x0, 5), iimm(3, 0, 0x0, 6), iimm(4, 0, 0x0, 7),
        fop(0x68, 0, 5, 0, 1), // f1 = 2.0
        fop(0x68, 0, 6, 0, 2), // f2 = 3.0
        fop(0x68, 0, 7, 0, 3), // f3 = 4.0
        iimm(0x100, 0, 0x0, 10), // x10 = result base
        fop(0x00, 2, 1, 0, 4), fsw(0, 4, 10), // fadd  f4 = 5.0   -> 0x100
        fop(0x04, 2, 1, 0, 5), fsw(8, 5, 10), // fsub  f5 = -1.0  -> 0x108
        fop(0x08, 2, 1, 0, 8), fsw(16, 8, 10), // fmul f8 = 6.0   -> 0x110
        fop(0x0C, 1, 3, 0, 9), fsw(24, 9, 10), // fdiv f9 = 4/2=2 -> 0x118
        fop(0x2C, 0, 3, 0, 11), fsw(32, 11, 10), // fsqrt(4)=2.0  -> 0x120
        fop(0x14, 2, 1, 0, 12), fsw(40, 12, 10), // fmin = 2.0    -> 0x128
        fop(0x14, 2, 1, 1, 13), fsw(48, 13, 10), // fmax = 3.0    -> 0x130
        fop(0x10, 2, 1, 0, 14), fsw(56, 14, 10), // fsgnj = 2.0   -> 0x138
        fop4(0x43, 3, 2, 1, 15), fsw(64, 15, 10), // fmadd = 10.0 -> 0x140
        fop4(0x47, 3, 2, 1, 16), fsw(72, 16, 10), // fmsub = 2.0  -> 0x148
        fop4(0x4B, 3, 2, 1, 17), fsw(80, 17, 10), // fnmsub = -2  -> 0x150
        fop(0x50, 2, 1, 2, 18), // feq.s x18 = (f1==f2) = 0
        fop(0x50, 2, 1, 1, 19), // flt.s x19 = (f1<f2)  = 1
        fop(0x50, 1, 2, 0, 20), // fle.s x20 = (f2<=f1) = 0
        fop(0x60, 2, 3, 1, 21), // fcvt.l.s x21 = (long)4.0 = 4 (rm=RTZ)
        nop,
      ],
      fdConfig(),
      nextPc: 0x84,
      checkRegs: [Register.x18, Register.x19, Register.x20, Register.x21],
      checkMem: [
        0x100,
        0x108,
        0x110,
        0x118,
        0x120,
        0x128,
        0x130,
        0x138,
        0x140,
        0x148,
        0x150,
      ],
    );
  });

  // Hypervisor: write the H CSRs (hgatp with an Sv39x4 MODE+PPN, hstatus with a
  // spread of bits) and read them back. The WARL masking (which fields/bits are
  // writable) must be identical between the engines, else the read-back diverges.
  test('parity: H CSRs (hgatp / hstatus WARL round-trip)', () async {
    await parityCheck(
      [
        csrw(0x680, 10), // hgatp = x10
        csrr(0x680, 11), // x11 = hgatp (WARL read-back)
        csrw(0x600, 12), // hstatus = x12
        csrr(0x600, 13), // x13 = hstatus
        csrw(0x643, 14), // htval = x14
        csrr(0x643, 15), // x15 = htval
        nop,
      ],
      hvConfig(),
      seed: {
        Register.x10: 0x8000000000000123, // Sv39x4 mode + PPN
        Register.x12:
            0x00000000002021C2, // assorted hstatus bits (SPV/SPVP/...)
        Register.x14: 0x0000000000ABCDEF, // htval (full WARL)
      },
      nextPc: 0x1C,
      checkRegs: [Register.x11, Register.x13, Register.x15],
    );
  });

  // MMU: enable Sv39, load through a virtual address that the page table maps to
  // a different physical page. Both engines walk the SAME table and must read the
  // same value. The emulator translates in M-mode (gates on paging-enabled), and
  // it translates ifetch too - so the code page (VA 0x0) is identity-mapped, and
  // the HDL (which doesn't translate ifetch) fetches the same physical bytes.
  //   l2 @ 0x10000 (root, PPN 0x10) -> l1 @ 0x11000 -> l0 @ 0x12000
  //   l0[0]    identity VA 0x0     -> PA 0x0     (code)
  //   l0[0x20] maps    VA 0x20000  -> PA 0x30000 (data)
  test('parity: MMU Sv39 translated load (0x20000 -> 0x30000)', () async {
    await parityCheck(
      [
        csrw(0x180, 10), // csrw satp, a0  (MODE=8 Sv39, root PPN 0x10)
        lui(0x20, 12), // a2 = 0x20000 (virtual)
        ld(0, 12, 11), // a1 = *(a2)  -> phys 0x30000
        nop,
      ],
      hvConfig(),
      // S-mode: M-mode data accesses are physical in BOTH engines (HDL
      // mmu.dart `dataPagingOn`, emulator Core.translate), so an M-mode run
      // would read PA 0x20000, get 0 in both, and pass without ever walking the
      // table. S-mode makes the walk actually happen.
      startPriv: PrivilegeMode.supervisor,
      // The walk must actually reach PA 0x30000 and load its data.
      expectGold: {Register.x11: 0x12345678DEADBEEF},
      seed: {Register.x10: 0x8000000000000010},
      dataMem: {
        0x10000: [0x4401, 0], // l2[0] -> l1 (PPN 0x11), V
        0x11000: [0x4801, 0], // l1[0] -> l0 (PPN 0x12), V
        0x12000: [0xCF, 0], // l0[0]    PA 0x0,     V|R|W|X|A|D
        0x12100: [0xC0CF, 0], // l0[0x20] PA 0x30000, V|R|W|X|A|D
        0x30000: [0xDEADBEEF, 0x12345678], // data @ phys 0x30000
      },
      nextPc: 0x0C,
      checkRegs: [Register.x11],
    );
  });
}
