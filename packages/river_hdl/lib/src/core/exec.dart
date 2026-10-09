import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import '../data_port.dart';
import '../compat.dart';
import '../microcode_rom.dart';
import 'alu_ops.dart';
import 'iterative_divider.dart';
import 'iterative_multiplier.dart';
import 'iterative_fp_arith.dart';
import 'iterative_fp_int.dart';
import 'iterative_sqrt.dart';
import 'fp_status.dart';
import 'microcode_alu.dart';

/// Supervisor address translation and protection register. A write to it
/// switches the address space, which both virtually tagged L1 caches must see.
const _satpCsrAddress = 0x180;

/// Div/rem functs routed to the shared [IterativeDivider] instead of a
/// combinational `/`/`%`. Whole RV32M/RV64M div+rem set (signed/unsigned, full+word).
const _kIterativeDivRem = {
  RiscVAluFunct.div,
  RiscVAluFunct.divu,
  RiscVAluFunct.divw,
  RiscVAluFunct.divuw,
  RiscVAluFunct.rem,
  RiscVAluFunct.remu,
  RiscVAluFunct.remw,
  RiscVAluFunct.remuw,
};

/// Manual IEEE-754 compare of two same-width float bit patterns [a],[b]
/// (ROHD-HCL has no FP comparator). Returns less-than / equal / ordered
/// (neither operand is NaN) as 1-bit Logics; handles +0==-0 and NaN-unordered.
/// [width] is the total bit width, [expBits] the exponent field width.
({Logic lt, Logic eq, Logic ordered}) fpCompare(
  Logic a,
  Logic b,
  int width,
  int expBits,
) {
  final manBits = width - 1 - expBits;
  final sa = a[width - 1];
  final sb = b[width - 1];
  final expA = a.slice(width - 2, manBits);
  final expB = b.slice(width - 2, manBits);
  final manA = a.slice(manBits - 1, 0);
  final manB = b.slice(manBits - 1, 0);
  final magA = a.slice(width - 2, 0); // exp:mantissa magnitude
  final magB = b.slice(width - 2, 0);
  final allOnes = Const((1 << expBits) - 1, width: expBits);
  final aNaN = expA.eq(allOnes) & manA.neq(0);
  final bNaN = expB.eq(allOnes) & manB.neq(0);
  final bothZero = magA.eq(0) & magB.eq(0);
  final sameSign = sa.eq(sb);
  final ltMag = mux(sa, magA.gt(magB), magA.lt(magB)); // negative => reversed
  final lt = mux(sameSign, ltMag, sa & ~bothZero); // diff sign: a<b iff a<0
  final eq = bothZero | (sameSign & magA.eq(magB));
  final ordered = ~(aNaN | bNaN);
  return (lt: lt, eq: eq, ordered: ordered);
}

/// Bit-level floating-point results for ONE precision: the three compares, the
/// three sign-injections, min/max, the 10-bit classify, and the properties of
/// operand [a] that the fp->int convert needs. [a] and [b] are the raw bit
/// patterns at width [w] (32 or 64). Pure, so the static and the microcoded
/// execution unit share one definition and cannot drift apart.
({
  Logic eq,
  Logic lt,
  Logic le,
  Logic fsgnj,
  Logic fsgnjn,
  Logic fsgnjx,
  Logic fmin,
  Logic fmax,
  Logic fclass,
  Logic eqFlags,
  Logic orderedCompareFlags,
  Logic minMaxFlags,
  Logic signBit,
  Logic isNaN,
  Logic isInf,
})
fpBitOps(Logic a, Logic b, int w) {
  final manBits = w == 64 ? 52 : 23;
  final expBits = w - 1 - manBits;
  final cmp = fpCompare(a, b, w, expBits);
  final signF = Const(1, width: w) << (w - 1);
  final magMask = ~signF;
  // Comparisons suppress their Boolean result for either NaN. FEQ is quiet;
  // FLT/FLE signal invalid even for a quiet NaN.
  final ltOrdered = cmp.ordered & cmp.lt;
  final gtOrdered = cmp.ordered & ~(cmp.lt | cmp.eq);
  final expF = a.slice(w - 2, manBits);
  final manF = a.slice(manBits - 1, 0);
  final signBit = a[w - 1];
  final expAll1 = expF.eq(Const((1 << expBits) - 1, width: expBits));
  final exp0 = ~expF.or();
  final man0 = ~manF.or();
  final isInf = expAll1 & man0;
  final isNaN = expAll1 & ~man0;
  final isQNaN = isNaN & manF[manBits - 1];
  final isSNaN = isNaN & ~manF[manBits - 1];
  final isZero = exp0 & man0;
  final isSub = exp0 & ~man0;
  final isNorm = ~expAll1 & ~exp0;
  final bMan = b.slice(manBits - 1, 0);
  final bNaN =
      b.slice(w - 2, manBits).eq(Const((1 << expBits) - 1, width: expBits)) &
      bMan.or();
  final signaling = isSNaN | (bNaN & ~bMan[manBits - 1]);
  final quietNaN = Const(
    (((BigInt.one << expBits) - BigInt.one) << manBits) |
        (BigInt.one << (manBits - 1)),
    width: w,
  );
  Logic minMax(Logic pickA) =>
      mux(isNaN, mux(bNaN, quietNaN, b), mux(bNaN, a, mux(pickA, a, b)));
  return (
    eq: cmp.ordered & cmp.eq,
    lt: ltOrdered,
    le: cmp.ordered & (cmp.lt | cmp.eq),
    fsgnj: (a & magMask) | (b & signF),
    fsgnjn: (a & magMask) | ((~b) & signF),
    fsgnjx: (a & magMask) | ((a ^ b) & signF),
    fmin: minMax(ltOrdered | (cmp.eq & signBit)),
    fmax: minMax(gtOrdered | (cmp.eq & ~signBit)),
    eqFlags: fpExceptionFlags(invalid: signaling),
    orderedCompareFlags: fpExceptionFlags(invalid: ~cmp.ordered),
    minMaxFlags: fpExceptionFlags(invalid: signaling),
    fclass: [
      isQNaN,
      isSNaN,
      ~signBit & isInf,
      ~signBit & isNorm,
      ~signBit & isSub,
      ~signBit & isZero,
      signBit & isZero,
      signBit & isSub,
      signBit & isNorm,
      signBit & isInf,
    ].swizzle(),
    signBit: signBit,
    isNaN: isNaN,
    isInf: isInf,
  );
}

/// Converts a floating-point magnitude to an integer with per-rm rounding and
/// RISC-V saturation. [intMag]/[roundBit]/[sticky] come from
/// [IterativeFpIntConvert]; [ovf] flags |operand| >= 2^64. [rm] is the instruction's
/// funct3 (DYN=7 falls back to RNE, which matches the emulator), [isL] is
/// rs2 bit 1 (64-bit L form) and [uns] is rs2 bit 0 (unsigned form).
Logic roundSatFpToInt({
  required Logic intMag,
  required Logic roundBit,
  required Logic sticky,
  required Logic ovf,
  required Logic signBit,
  required Logic isNaN,
  required Logic isInf,
  required Logic rm,
  required Logic isL,
  required Logic uns,
  required RiscVMxlen mxlen,
  Logic? flagsOut,
}) {
  final ones64 = Const(BigInt.parse('FFFFFFFFFFFFFFFF', radix: 16), width: 64);
  final rne = roundBit & (sticky | intMag[0]);
  final rdn = signBit & (roundBit | sticky);
  final rup = ~signBit & (roundBit | sticky);
  final roundUp = mux(
    rm.eq(Const(1, width: 3)), // RTZ
    Const(0),
    mux(
      rm.eq(Const(2, width: 3)), // RDN
      rdn,
      mux(
        rm.eq(Const(3, width: 3)), // RUP
        rup,
        mux(rm.eq(Const(4, width: 3)), roundBit, rne),
      ),
    ),
  );
  final rounded = (intMag.zeroExtend(65) + roundUp.zeroExtend(65)).slice(64, 0);
  final magOvf = ovf | rounded[64];
  final rMag = rounded.slice(63, 0);
  final neg = (~rMag + Const(1, width: 64)).slice(63, 0);
  final special = isNaN | isInf;
  // W signed (sign-extended to xlen)
  final wsPos = mux(
    magOvf | rMag.gt(Const(0x7FFFFFFF, width: 64)),
    Const(0x7FFFFFFF, width: 32),
    rMag.slice(31, 0),
  );
  final wsNeg = mux(
    magOvf | rMag.gt(Const(0x80000000, width: 64)),
    Const(0x80000000, width: 32),
    neg.slice(31, 0),
  );
  final ws = mux(
    special,
    mux(
      isNaN,
      Const(0x7FFFFFFF, width: 32),
      mux(signBit, Const(0x80000000, width: 32), Const(0x7FFFFFFF, width: 32)),
    ),
    mux(signBit, wsNeg, wsPos),
  ).signExtend(mxlen.size);
  // W unsigned (sign-extended to xlen)
  final wuPos = mux(
    magOvf | rMag.gt(Const(0xFFFFFFFF, width: 64)),
    Const(0xFFFFFFFF, width: 32),
    rMag.slice(31, 0),
  );
  final wu = mux(
    special,
    mux(
      isNaN | (isInf & ~signBit),
      Const(0xFFFFFFFF, width: 32),
      Const(0, width: 32),
    ),
    mux(signBit, Const(0, width: 32), wuPos),
  ).signExtend(mxlen.size);
  // L signed
  final c63 = Const(BigInt.parse('7FFFFFFFFFFFFFFF', radix: 16), width: 64);
  final c63n = Const(BigInt.parse('8000000000000000', radix: 16), width: 64);
  final lsPos = mux(magOvf | rMag.gt(c63), c63, rMag);
  final lsNeg = mux(magOvf | rMag.gt(c63n), c63n, neg);
  final ls = mux(
    special,
    mux(isNaN, c63, mux(signBit, c63n, c63)),
    mux(signBit, lsNeg, lsPos),
  );
  // L unsigned
  final lu = mux(
    special,
    mux(isNaN | (isInf & ~signBit), ones64, Const(0, width: 64)),
    mux(signBit, Const(0, width: 64), mux(magOvf, ones64, rMag)),
  );
  if (flagsOut != null) {
    // Test the rounded magnitude, not merely the source sign: a negative
    // fraction rounding to unsigned zero is valid. Invalid suppresses NX.
    final signedLimit = mux(
      isL,
      mux(signBit, c63n, c63),
      mux(signBit, Const(0x80000000, width: 64), Const(0x7fffffff, width: 64)),
    );
    final unsignedRange =
        (signBit & rMag.or()) | (~isL & rMag.gt(Const(0xffffffff, width: 64)));
    final invalid =
        special | magOvf | mux(uns, unsignedRange, rMag.gt(signedLimit));
    flagsOut <=
        [invalid, Const(0, width: 3), ~invalid & (roundBit | sticky)].swizzle();
  }
  // ws/wu are mxlen-wide; ls/lu are 64 (the L=fcvt.l.* form is rv64-only, dead
  // on rv32). Coerce the L side to mxlen so the W/L mux is uniform width (a
  // no-op on rv64). #71.
  return mux(isL, mux(uns, lu, ls).getRange(0, mxlen.size), mux(uns, wu, ws));
}

/// Selects the privilege mode a trap is delivered to: supervisor when the core
/// is below M-mode, supervisor is configured, and the cause is delegated
/// (medeleg/mideleg); otherwise machine. Pure (no module state) so both the
/// in-order [ExecutionUnit] and the OoO commit path can call it.
Logic selectTrapTargetModeTop(
  Logic trapInterrupt,
  Logic causeCode,
  Logic mode,
  Logic? mideleg,
  Logic? medeleg, {
  required bool hasCsr,
  required bool hasSupervisor,
}) {
  final machine = Const(PrivilegeMode.machine.id, width: 3);
  if (!hasCsr) return machine;
  final supervisor = Const(PrivilegeMode.supervisor.id, width: 3);
  final isMachine = mode.eq(machine);
  final delegatedInterrupt = mideleg == null ? Const(0) : mideleg[causeCode];
  final delegatedException = medeleg == null ? Const(0) : medeleg[causeCode];
  final goesToSupervisor = mux(
    trapInterrupt,
    delegatedInterrupt,
    delegatedException,
  );
  final notMachineAndHasSup = ~isMachine & Const(hasSupervisor ? 1 : 0);
  return mux(
    notMachineAndHasSup,
    mux(goesToSupervisor, supervisor, machine),
    machine,
  );
}

/// Computes the trap-handler PC from a tvec CSR: base = tvec & ~3; vectored
/// mode (tvec[1:0]==1) adds 4*cause but only for interrupts. Pure helper shared
/// by the in-order and OoO trap paths.
Logic computeTrapVectorPcTop(
  Logic tvec,
  Logic causeCode,
  Logic trapInterrupt,
  RiscVMxlen mxlen, {
  String? suffix,
}) {
  suffix ??= '';
  final base = (tvec & Const(~0x3, width: mxlen.size)).named('trapBase$suffix');
  final mode = tvec.slice(1, 0).named('trapMode$suffix');
  final isVectored = mode.eq(Const(1, width: 2)).named('isVectored$suffix');
  final vecOffset = (causeCode << 2)
      .zeroExtend(mxlen.size)
      .named('tvecOffset$suffix');
  return mux(
    isVectored & trapInterrupt,
    base + vecOffset,
    base,
  ).named('tvecPc$suffix');
}

abstract class ExecutionUnit extends Module {
  final MicrocodeRom microcode;
  final RiscVMxlen mxlen;
  final int vlen;
  final bool hasSupervisor;
  final bool hasUser;
  final bool enableMisalignedLoads;
  // Byte-addressed, sized reads with lane-zero responses from the MMU.
  // Legacy front-of-MMU caches retain their existing read convention.
  final bool exactMemoryReads;
  Logic get misalignedLoad => output('misalignedLoad');
  Logic get loadSize => output('loadSize');
  late final Logic _misalignedLoadAllowed;
  late final Logic? _loadFaultTval;
  // When true the mul family uses the shared multi-cycle IterativeMultiplier
  // (chunk multiply reused per cycle) instead of a single-cycle partial-product
  // tree. The area sign is config-dependent (measured both ways: iterative loses
  // on creek+DFU 25F, wins on creek_weir DDR rv64 25F). Re-measure post-pack per
  // config before flipping.
  final bool useIterativeMul;
  // Zvfh = half-precision (SEW=16) vector FP. Derived from the ISA config so a
  // core without it never elaborates the FP16 lane units (8 adders + 8 mults at
  // VLEN=128).
  bool get hasZvfh => microcode.isa.extensions.any((e) => e.name == 'Zvfh');
  final List<String> staticInstructions;

  late final Logic clk;
  late final Logic currentSp;
  late final Logic currentPc;
  late final Logic currentMode;
  late final DataPortInterface? csrRead;
  late final DataPortInterface? csrWrite;
  late final Logic? mideleg;
  late final Logic? medeleg;
  late final Logic? mtvec;
  late final Logic? stvec;
  // Async interrupt take (computed in core.dart from mip&mie + mode/delegation).
  // When [interruptTake] is high at an instruction boundary (mopStep==0), an
  // interrupt trap with cause [interruptCause] is taken instead of the fetched
  // instruction, vectoring through the shared trap helpers.
  late final Logic? interruptTake;
  late final Logic? interruptCause;
  late final Logic?
  virtIn; // V-bit: VS-mode access to an HS-only CSR -> cause 22
  // Smstateen SE0 bits, for the VS-mode state-enable virtual-instruction nuance.
  late final Logic? mstateen0Se0;
  late final Logic? hstateen0Se0;
  late final Logic? memFaultGuest; // dport fault was in the G-stage -> guest PF

  // LR/SC reservation (A extension): a single address reservation set by
  // load-reserved and consumed/cleared by store-conditional.
  //
  // It is ALSO cleared by ANY STORE from this hart. Without that, a reservation
  // survives anything that runs between the LR and the SC. An interrupt then
  // lands inside a Linux `cmpxchg` loop, the handler writes the same address
  // with a plain store, and the SC still succeeds: it writes a value computed
  // from the stale old value and it destroys the handler's write. The result is
  // a silent lost update in kernel data. The handler's own store is what closes
  // that hole, so the store clear is sufficient.
  //
  // DELIBERATELY NOT cleared on trap/interrupt or on MRET/SRET, even though QEMU
  // clears its equivalent (`env->load_res`) on every privilege change. Clearing
  // on every trap WEDGED the delta NixOS boot at kernel init_IRQ. Proven by RTL
  // diff: the working reference bitstream and the wedging build differ in
  // NOTHING except those trap clears. Spurious SC failure is always permitted by
  // the spec, but starving every SC is not, and a trap clear does exactly that
  // once traps become frequent.
  //
  // A constrained LR/SC sequence holds no stores, so clearing on every store
  // costs correct software nothing.
  // See test/a/lrsc_reservation_store_test.dart.
  late final Logic reservationValid;
  late final Logic reservationAddr;
  // AMO scratch: holds the loaded ("old") value across the dynamic-microcode
  // read -> modify -> write phases of a single RiscVAtomicMemory micro-op, so
  // the destination register gets the pre-modification value on completion.
  late final Logic amoOld;

  // Floating-point (F/D) register file, internal to the in-order unit. Present
  // only when the configured ISA uses FP regs (detected from op resources).
  // FP reads/writes are routed here when an op's RfResource marks the field FP.
  DataPortInterface? fprs1Read;
  DataPortInterface? fprs2Read;
  DataPortInterface? fprdWrite;
  HarborRegisterFile? fpRegfile;

  // Vector register file (32 x VLEN), present when the ISA has the V extension.
  DataPortInterface? vrs1Read;
  DataPortInterface? vrs2Read;
  DataPortInterface? vrdWrite;
  HarborRegisterFile? vRegfile;
  // Vector config state, written by vsetvli, read by vector ops: _vtype holds
  // vtypei (vsew[5:3]/vlmul[2:0]); _vl holds the active element count. _vtmp
  // holds an arith result across the read-modify-write for vl/tail masking.
  Logic? _vtype;
  Logic? _vl;
  Logic? _vtmp;
  // LMUL grouping: the register index (0..LMUL-1) within the destination group
  // currently being processed by a vector arith op.
  Logic? _vregIdx;

  // FP arithmetic results, combinationally computed from the rs1/rs2/rs3
  // operand latches by ROHD-HCL units (present when hasFloat).
  //
  // ONE adder and ONE multiplier per precision serve the whole arithmetic
  // family. The selection is on the OPERAND side, not on the result side:
  // fsub is fadd with the sign of b flipped, the four fused multiply-add forms
  // are the same sum of (+-product, +-rs3), and the divide iteration reuses
  // both units. Sign flips are one XOR gate, so the alternative (one adder per
  // form, then a result mux) costs 6 adders per precision for no extra
  // function. See [_fpSelFma], [_fpSelNegA], [_fpSelNegB] and [_fpSelDiv].
  //
  // A core with D holds ONE precision of arithmetic hardware. The single
  // family runs on the double units, which read binary32 operand fields and
  // round the answer back to binary32 themselves, so the _S nets below are
  // null there. Only an F-without-D core builds the _S units.
  // The one arithmetic answer: fadd, fsub, fmul, fdiv and the four fused
  // multiply-add forms all come back here, because one multi-cycle unit
  // computes them all. See [_fpArith].
  Logic? _fpArithS;
  Logic? _fpSqrtS;
  Logic? _fpArithD;
  Logic? _fpSqrtD;
  // Operand-side select for the shared adder and multiplier. The subclass
  // drives these from ITS OWN decode: the microcoded unit from the ROM
  // fpuFunct field, the static unit from the resident instruction index. That
  // keeps one decode of the operation, so the two units cannot disagree.
  //   _fpSelFma    left operand = product, right operand = rs3
  //   _fpSelNegA   flip the sign of the left operand
  //   _fpSelNegB   flip the sign of the right operand
  //   _fpSelDiv    the operation is a divide
  //   _fpSelMul    the operation is a multiply
  //   _fpSelCvt    the operation converts between the two precisions, so the
  //                answer takes the OTHER format from the operand
  //   _fpSelToInt  the operation converts a float to an integer
  //   _fpSelFpNarrow   the float side of an integer convert is the NARROW
  //                format, whichever way that conversion runs
  //   _fpSelSingle the operation is single-precision, so the shared units read
  //                the operand fields at binary32 and round back to binary32
  Logic? _fpSelFma;
  Logic? _fpSelNegA;
  Logic? _fpSelNegB;
  Logic? _fpSelDiv;
  Logic? _fpSelMul;
  Logic? _fpSelCvt;
  Logic? _fpSelToInt;
  Logic? _fpSelFpNarrow;
  Logic? _fpSelSingle;
  // True after a subclass calls [driveFpSelect]. A configuration with FP
  // registers but no FP arithmetic never calls it, so the base constructor
  // ties the selects low itself.
  bool _fpSelDriven = false;
  // The rs3 operand latch (instance field so cycle()'s readField/writeField can
  // reach it without threading a new param through every cycle variant).
  Logic? _rs3Latch;
  // Shared multi-cycle integer <-> floating-point convert. ONE unit serves
  // both directions and both destination formats: it shifts one bit per cycle
  // on a single register, which replaces a leading-zero count plus barrel
  // shifter per destination format (int -> fp) and a 117-bit barrel shifter
  // (fp -> int). Both are shift and compare logic with nothing for a DSP tile
  // to do, so iterating them buys LUTs at no other cost.
  //
  // An fcvt mop holds [_fpIntCvtStart] while resident. The fp -> int direction
  // reports a truncated magnitude with a round and a sticky bit, which the
  // shared [roundSatFpToInt] turns into the per-rm rounding and the RISC-V
  // saturation. See iterative_fp_int.dart.
  IterativeFpIntConvert? _fpIntCvt;
  Logic? _fpIntCvtStart;
  // Shared multi-cycle add/multiply/divide. ONE unit serves the whole
  // arithmetic family: it adds, multiplies and divides one bit per cycle, and
  // it retains the full FMA product until the single final rounding. This replaces the
  // combinational adder (align shifter, normaliser, rounder) and the 53x53
  // partial-product array, which together were the largest block in the FP
  // datapath. An arithmetic mop holds [_fpArithStart] while resident and reads
  // back IterativeFpArith.result; see iterative_fp_arith.dart. Only one
  // precision is built, because a single-precision operation widens into the
  // double unit first.
  IterativeFpArith? _fpArith;
  Logic? _fpArithStart;
  // Shared multi-cycle square root. One radix-2 restoring core replaces the
  // unrolled subtract array, which at binary64 is the single largest block in
  // the FP datapath. An fsqrt mop holds [_fsqrtStart] while resident and reads
  // back IterativeFpSqrt.result; see iterative_sqrt.dart. Only one precision is
  // built, because a single-precision root widens into the double units first.
  IterativeFpSqrt? _fsqrt;
  Logic? _fsqrtStart;
  // Shared multi-cycle integer divider (M-extension div/rem), present when the
  // ISA has M. One instance replaces the eight combinational div/rem trees that
  // otherwise dominate the static execution unit's LUTs. The div/rem mop holds
  // [_idivStart] high while resident and reads back the divider outputs; see
  // StaticExecutionUnit.cycle and iterative_divider.dart.
  IterativeDivider? _idiv;
  Logic? _idivStart;
  Logic? _idivDividend;
  Logic? _idivDivisor;

  // Shared multi-cycle iterative multiplier (M mul family), present when the ISA
  // has M. Replaces the single-cycle 64x64 partial-product tree (a large LUT4
  // cost on ECP5 25F): one chunk-multiply reused per cycle accumulates the 2*XLEN
  // unsigned product. A mul/mulh* mop holds [_imulStart] while resident and reads
  // back IterativeMultiplier.product; signed-high flavors apply the same two
  // sign-correction subtracts as the single-cycle path. See iterative_multiplier.dart.
  IterativeMultiplier? _imul;
  Logic? _imulStart;
  Logic? _imulA;
  Logic? _imulB;

  late final Logic _fpRm;
  late final bool _fpControlEnabled;
  bool _fpHasDouble = false;

  // Computational F32 reads on FLEN=64 treat invalid boxes as quiet NaNs.
  // Raw moves and stores deliberately bypass this helper.
  Logic _fpOperand(Logic value, int width) {
    final bits = value.getRange(0, width);
    if (!_fpControlEnabled ||
        !_fpHasDouble ||
        width != 32 ||
        value.width <= 32) {
      return bits;
    }
    return mux(
      value.getRange(32, value.width).and(),
      bits,
      Const(0x7fc00000, width: 32),
    );
  }

  Logic _fpBoxResult(Logic value, Logic single) {
    if (!_fpControlEnabled || !_fpHasDouble || value.width != 64) return value;
    return mux(
      single,
      [Const(0xffffffff, width: 32), value.slice(31, 0)].swizzle(),
      value,
    );
  }

  bool _fpSingleResult(RiscVFpuOp mop) => switch (mop.funct) {
    RiscVFpuFunct.fcvtSD || RiscVFpuFunct.fcvtSW => true,
    RiscVFpuFunct.fcvtDS || RiscVFpuFunct.fcvtDW => false,
    _ => !mop.doublePrecision,
  };

  Logic _fpMoveToIntWord = Const(0), _fpMoveFromIntWord = Const(0);
  Logic _fpMoveResult(Logic value) {
    if (!_fpControlEnabled) return value;
    return mux(
      _fpMoveToIntWord,
      value.slice(31, 0).signExtend(value.width),
      mux(_fpMoveFromIntWord, _fpBoxResult(value, Const(1)), value),
    );
  }

  late final Logic _csrNoWrite;
  Logic get fpFlags => output('fpFlags');
  Logic get done => output('done');
  Logic get valid => output('valid');
  Logic get nextSp => output('nextSp');
  Logic get nextPc => output('nextPc');
  Logic get nextMode => output('nextMode');
  Logic get trap => output('trap');
  Logic get trapCause => output('trapCause');
  Logic get trapInterrupt => output('trapInterrupt');
  Logic get trapTval => output('trapTval');
  Logic get trapEpc => output('trapEpc');
  Logic get isReturn => output('isReturn');
  Logic get returnLevel => output('returnLevel');
  Logic get memGuest => output('memGuest');
  Logic get fence => output('fence');
  Logic get interruptHold => output('interruptHold');
  Logic get counter => output('counter');

  ExecutionUnit(
    Logic clk,
    Logic reset,
    Logic enable,
    Logic currentSp,
    Logic currentPc,
    Logic currentMode,
    Logic instrIndex,
    Map<String, Logic> instrTypeMap,
    Map<String, Logic> fields,
    DataPortInterface? csrRead,
    DataPortInterface? csrWrite,
    DataPortInterface memRead,
    DataPortInterface memWrite,
    DataPortInterface rs1Read,
    DataPortInterface rs2Read,
    DataPortInterface rdWrite, {
    DataPortInterface? microcodeRead,
    this.hasSupervisor = false,
    this.hasUser = false,
    this.enableMisalignedLoads = false,
    this.exactMemoryReads = false,
    Logic? loadFaultTval,
    this.useIterativeMul = true,
    required this.microcode,
    required this.mxlen,
    this.vlen = 128,
    Logic? mideleg,
    Logic? medeleg,
    Logic? mtvec,
    Logic? stvec,
    Logic? interruptTake,
    Logic? interruptCause,
    Logic? virtIn,
    Logic? mstateen0Se0,
    Logic? hstateen0Se0,
    Logic? memFaultGuest,
    // Asserted when the instruction at currentPc could not be fetched because
    // an instruction access or translation fault occurred. The cycle traps
    // instead of executing (there is no instruction).
    Logic? fetchFault,
    // Access/page classification paired with the faulting fetch or data response.
    Logic? fetchAccessFault,
    // Faulting instruction portion's VA; the instruction start remains EPC.
    Logic? fetchFaultTval,
    Logic? memAccessFault,
    Logic? frm,
    // mstatus trap-enable bits. These make an operation illegal in a mode its
    // privilege level already allows, so they are separate from requiredPriv.
    Logic? tsr,
    Logic? tvm,
    Logic? tw,
    Logic? fpEnabled,
    // Floating-point register ports. The FP register file belongs in the core
    // module next to the integer file, which is where the device target is
    // known and where a BRAM backend can be selected. When these are supplied
    // the exec unit uses them. When they are not, it falls back to a local
    // flop-based file so a directly-constructed exec unit still works.
    DataPortInterface? fpRs1Port,
    DataPortInterface? fpRs2Port,
    DataPortInterface? fpRdPort,
    int counterWidth = 32,
    this.staticInstructions = const [],
    super.name = 'river_execution_unit',
  }) {
    this.clk = clk = addInput('clk', clk);

    reset = addInput('reset', reset);
    enable = addInput('enable', enable);

    this.currentSp = addInput('currentSp', currentSp, width: mxlen.size);
    currentSp = this.currentSp;

    this.currentPc = addInput('currentPc', currentPc, width: mxlen.size);
    currentPc = this.currentPc;

    this.currentMode = addInput('currentMode', currentMode, width: 3);
    currentMode = this.currentMode;

    _fetchAccessFault = addInput(
      'fetchAccessFault',
      fetchAccessFault ?? Const(0),
    );
    _memAccessFault = addInput('memAccessFault', memAccessFault ?? Const(0));
    _loadFaultTval = loadFaultTval == null
        ? null
        : addInput('loadFaultTval', loadFaultTval, width: mxlen.size);
    addOutput('misalignedLoad');
    addOutput('loadSize', width: 3);
    if (!enableMisalignedLoads) {
      misalignedLoad <= Const(0);
    }
    if (!enableMisalignedLoads && !exactMemoryReads) {
      loadSize <= Const(2, width: 3);
    }
    _fetchFaultTval = fetchFaultTval == null
        ? null
        : addInput('fetchFaultTval', fetchFaultTval, width: mxlen.size);
    final fetchFaultIn = fetchFault == null
        ? Const(0)
        : addInput('fetchFault', fetchFault);

    instrIndex = addInput(
      'instrIndex',
      instrIndex,
      width: microcode.opIndexWidth,
    );

    const integerLoads = {
      'lb',
      'lbu',
      'lh',
      'lhu',
      'lw',
      'lwu',
      'ld',
      'c.lw',
      'c.ld',
      'c.lwsp',
      'c.ldsp',
      'c.lh',
      'c.lhu',
      'c.lbu',
    };
    Logic allowed = Const(0);
    if (enableMisalignedLoads) {
      for (final entry in microcode.execLookup.entries) {
        if (integerLoads.contains(entry.value.mnemonic)) {
          allowed |= instrIndex.eq(entry.key);
        }
      }
    }
    _misalignedLoadAllowed = allowed;

    instrTypeMap = Map.fromEntries(
      instrTypeMap.entries.map(
        (entry) => MapEntry(entry.key, addInput(entry.value.name, entry.value)),
      ),
    );

    fields = Map.fromEntries(
      fields.entries.map(
        (entry) => MapEntry(
          entry.key,
          addInput(entry.value.name, entry.value, width: entry.value.width),
        ),
      ),
    );

    if (csrRead != null) {
      this.csrRead = csrRead.clone()
        ..connectIO(
          this,
          csrRead,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'csrRead_$og',
        );
      csrRead = this.csrRead;
    } else {
      this.csrRead = null;
    }

    if (csrWrite != null) {
      this.csrWrite = csrWrite.clone()
        ..connectIO(
          this,
          csrWrite,
          outputTags: {DataPortGroup.control, DataPortGroup.data},
          inputTags: {DataPortGroup.integrity},
          uniquify: (og) => 'csrWrite_$og',
        );
      csrWrite = this.csrWrite;
    } else {
      this.csrWrite = null;
    }

    memRead = memRead.clone()
      ..connectIO(
        this,
        memRead,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'memRead_$og',
      );
    memWrite = memWrite.clone()
      ..connectIO(
        this,
        memWrite,
        outputTags: {DataPortGroup.control, DataPortGroup.data},
        inputTags: {DataPortGroup.integrity},
        uniquify: (og) => 'memWrite_$og',
      );

    rs1Read = rs1Read.clone()
      ..connectIO(
        this,
        rs1Read,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'rs1Read_$og',
      );
    rs2Read = rs2Read.clone()
      ..connectIO(
        this,
        rs2Read,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'rs2Read_$og',
      );
    rdWrite = rdWrite.clone()
      ..connectIO(
        this,
        rdWrite,
        outputTags: {DataPortGroup.control, DataPortGroup.data},
        inputTags: {DataPortGroup.integrity},
        uniquify: (og) => 'rdWrite_$og',
      );

    if (microcodeRead != null) {
      microcodeRead = microcodeRead.clone()
        ..connectIO(
          this,
          microcodeRead,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'microcodeRead_$og',
        );
    }

    if (mideleg != null) {
      this.mideleg = addInput('mideleg', mideleg, width: mxlen.size);
    } else {
      this.mideleg = null;
    }
    if (medeleg != null) {
      this.medeleg = addInput('medeleg', medeleg, width: mxlen.size);
    } else {
      this.medeleg = null;
    }
    if (mtvec != null) {
      this.mtvec = addInput('mtvec', mtvec, width: mxlen.size);
    } else {
      this.mtvec = null;
    }
    if (stvec != null) {
      this.stvec = addInput('stvec', stvec, width: mxlen.size);
    } else {
      this.stvec = null;
    }
    if (interruptTake != null) {
      this.interruptTake = addInput('interruptTake', interruptTake);
      this.interruptCause = addInput(
        'interruptCause',
        interruptCause!,
        width: 6,
      );
    } else {
      this.interruptTake = null;
      this.interruptCause = null;
    }
    if (virtIn != null) {
      this.virtIn = addInput('virtIn', virtIn);
    } else {
      this.virtIn = null;
    }
    this.mstateen0Se0 = mstateen0Se0 == null
        ? null
        : addInput('mstateen0Se0', mstateen0Se0);
    this.hstateen0Se0 = hstateen0Se0 == null
        ? null
        : addInput('hstateen0Se0', hstateen0Se0);
    if (memFaultGuest != null) {
      this.memFaultGuest = addInput('memFaultGuest', memFaultGuest);
    } else {
      this.memFaultGuest = null;
    }

    addOutput('fpFlags', width: 5);
    _fpControlEnabled = frm != null;
    final frmIn = addInput('frm', frm ?? Const(0, width: 3), width: 3);
    final tsrIn = addInput('tsr', tsr ?? Const(0));
    final tvmIn = addInput('tvm', tvm ?? Const(0));
    final twIn = addInput('tw', tw ?? Const(0));
    final fpEnabledIn = addInput('fpEnabled', fpEnabled ?? Const(1));
    final instructionRm = fields['funct3'] ?? Const(0, width: 3);
    _csrNoWrite =
        instructionRm[1] & (fields['rs1'] ?? Const(0, width: 5)).eq(0);
    _fpRm = mux(instructionRm.eq(Const(7, width: 3)), frmIn, instructionRm);
    final fpUnitRm = _fpControlEnabled ? _fpRm : Const(0, width: 3);
    Logic fpInstruction = Const(0), roundedInstruction = Const(0);
    // Lowest mode each operation needs. Harbor marks mret 3 and the supervisor
    // ops 1, the same encoding currentMode uses.
    Logic needsSupervisor = Const(0), needsMachine = Const(0);
    // Operations the mstatus trap bits single out by name.
    const vmFences = {
      'sfence.vma',
      'sinval.vma',
      'sfence.w.inval',
      'sfence.inval.ir',
    };
    Logic isSret = Const(0), isVmFence = Const(0), isWfi = Const(0);
    const roundedFunctions = {
      RiscVFpuFunct.fadd,
      RiscVFpuFunct.fsub,
      RiscVFpuFunct.fmul,
      RiscVFpuFunct.fdiv,
      RiscVFpuFunct.fsqrt,
      RiscVFpuFunct.fmadd,
      RiscVFpuFunct.fmsub,
      RiscVFpuFunct.fnmsub,
      RiscVFpuFunct.fnmadd,
      RiscVFpuFunct.fcvtSD,
      RiscVFpuFunct.fcvtDS,
      RiscVFpuFunct.fcvtWS,
      RiscVFpuFunct.fcvtWD,
      RiscVFpuFunct.fcvtSW,
      RiscVFpuFunct.fcvtDW,
    };
    for (final entry in microcode.execLookup.entries) {
      final hit = instrIndex.eq(Const(entry.key, width: instrIndex.width));
      if (entry.value.mnemonic == 'fmv.x.w') {
        _fpMoveToIntWord = _fpMoveToIntWord | hit;
      }
      if (entry.value.mnemonic == 'fmv.w.x') {
        _fpMoveFromIntWord = _fpMoveFromIntWord | hit;
      }
      if (entry.value.resources.any(
        (r) => r is RfResource && r.regfile is RiscVFloatRegFile,
      )) {
        fpInstruction = fpInstruction | hit;
      }
      if (entry.value.indexedMicrocode.values.any(
        (mop) => mop is RiscVFpuOp && roundedFunctions.contains(mop.funct),
      )) {
        roundedInstruction = roundedInstruction | hit;
      }
      final level = entry.value.privilegeLevel;
      if (level == PrivilegeMode.supervisor.id) {
        needsSupervisor = needsSupervisor | hit;
      } else if (level == PrivilegeMode.machine.id) {
        needsMachine = needsMachine | hit;
      }
      final mnemonic = entry.value.mnemonic;
      if (mnemonic == 'sret') isSret = isSret | hit;
      if (mnemonic == 'wfi') isWfi = isWfi | hit;
      if (vmFences.contains(mnemonic)) isVmFence = isVmFence | hit;
    }
    addOutput('done');
    addOutput('valid');
    addOutput('nextSp', width: mxlen.size);
    addOutput('nextPc', width: mxlen.size);
    addOutput('nextMode', width: 3);
    addOutput('trap');
    addOutput('trapCause', width: 6);
    // 1 when the committed trap is an interrupt (async), 0 for a synchronous
    // exception. The core sets mcause bit XLEN-1 from this; trapCause carries
    // only the low cause code (also used for delegation indexing).
    addOutput('trapInterrupt');
    addOutput('trapTval', width: mxlen.size);
    // PC of the trapping instruction → {m,s}epc. Captured here (not from the
    // core's live pc register, which has already advanced to tvec by the time
    // the registered trap pulse reaches core).
    addOutput('trapEpc', width: mxlen.size);
    // xRET (MRET/SRET): isReturn pulses on the retire cycle; returnLevel is the
    // privilege level being returned FROM (3=MRET, 1=SRET). core.dart restores
    // PC/mode from {m,s}epc/{m,s}status on this pulse.
    addOutput('isReturn');
    addOutput('returnLevel', width: 3);
    // Asserted for the duration of an HLV/HSV (hypervisor virtual) memory access
    // so the MMU translates it through the guest two-stage tables even from
    // HS-mode (virt=0). Held while memRead/memWrite.en is held (same registered
    // timing), so the multi-cycle walk sees it throughout.
    addOutput('memGuest');
    addOutput('fence');
    addOutput('interruptHold');
    addOutput('counter', width: counterWidth);

    final maxLen = microcode.microOpSequences.values
        .map((s) => s.ops.length * 2)
        .fold(0, (a, b) => a > b ? a : b);

    final mopStep = Logic(name: 'mopStep', width: maxLen.bitLength);
    final fpIllegal =
        Const(_fpControlEnabled ? 1 : 0) &
        mopStep.eq(0) &
        ((fpInstruction & ~fpEnabledIn) |
            (roundedInstruction & _fpRm.gt(Const(4, width: 3))));

    // Trap an operation that needs more privilege than the current mode, so
    // mret, sret and the supervisor fences do not run from U-mode.
    final requiredPriv = mux(
      needsMachine,
      Const(PrivilegeMode.machine.id, width: 3),
      mux(
        needsSupervisor,
        Const(PrivilegeMode.supervisor.id, width: 3),
        Const(PrivilegeMode.user.id, width: 3),
      ),
    );
    final privIllegal = mopStep.eq(0) & currentMode.lt(requiredPriv);

    // TSR traps sret in S-mode, TVM the translation fences in S-mode, and TW
    // wfi anywhere below machine mode.
    final statusIllegal =
        mopStep.eq(0) &
        ((compareCurrentMode(PrivilegeMode.supervisor) &
                ((isSret & tsrIn) | (isVmFence & tvmIn))) |
            (isWfi &
                twIn &
                currentMode.lt(Const(PrivilegeMode.machine.id, width: 3))));

    final alu = Logic(name: 'aluState', width: mxlen.size);
    final rs1 = Logic(name: 'rs1State', width: mxlen.size);
    final rs2 = Logic(name: 'rs2State', width: mxlen.size);
    // Third source latch, used by the fused multiply-add ops (rs3). Its FP read
    // reuses fprs1Read (reads are sequential), so no extra regfile port is needed.
    final rs3 = Logic(name: 'rs3State', width: mxlen.size);
    _rs3Latch = rs3;
    final rd = Logic(name: 'rdState', width: mxlen.size);
    final imm = Logic(name: 'immState', width: mxlen.size);

    reservationValid = Logic(name: 'reservationValid');
    reservationAddr = Logic(name: 'reservationAddr', width: mxlen.size);
    amoOld = Logic(name: 'amoOld', width: mxlen.size);

    // Floating-point register file (F/D). Instantiated only when some handled
    // op reads/writes an FP register (RfResource with RiscVFloatRegFile). The
    // FP regfile is 64 bits wide (holds D; F values are NaN-boxed/low-32).
    final hasFloat = microcode.execLookup.values.any(
      (op) => op.resources.any(
        (r) => r is RfResource && r.regfile is RiscVFloatRegFile,
      ),
    );
    if (hasFloat) {
      if (fpRs1Port != null && fpRs2Port != null && fpRdPort != null) {
        // The core module owns the file. Bring the ports across the module
        // boundary the same way the integer and memory ports come across.
        fprs1Read = fpRs1Port.clone()
          ..connectIO(
            this,
            fpRs1Port,
            outputTags: {DataPortGroup.control},
            inputTags: {DataPortGroup.data, DataPortGroup.integrity},
            uniquify: (og) => 'fprs1Read_$og',
          );
        fprs2Read = fpRs2Port.clone()
          ..connectIO(
            this,
            fpRs2Port,
            outputTags: {DataPortGroup.control},
            inputTags: {DataPortGroup.data, DataPortGroup.integrity},
            uniquify: (og) => 'fprs2Read_$og',
          );
        fprdWrite = fpRdPort.clone()
          ..connectIO(
            this,
            fpRdPort,
            outputTags: {DataPortGroup.control, DataPortGroup.data},
            inputTags: {DataPortGroup.integrity},
            uniquify: (og) => 'fprdWrite_$og',
          );
      } else {
        final fp1 = DataPortInterface(64, 5);
        final fp2 = DataPortInterface(64, 5);
        final fpw = DataPortInterface(64, 5);
        final fpRegs = HarborRegisterFile(
          numEntries: 32,
          dataWidth: 64,
          name: 'fp_regfile',
          // RISC-V has no hardwired-zero float register: f0/ft0 is a normal
          // storage entry (unlike integer x0). Without this the default
          // reservedZero=true forces f0 to read as zero regardless of writes.
          reservedZero: false,
        );
        fpRegs.input('clk').srcConnection! <= clk;
        fpRegs.input('reset').srcConnection! <= reset;
        fpRegs.input('rd0_addr').srcConnection! <= fp1.addr;
        fpRegs.input('rd1_addr').srcConnection! <= fp2.addr;
        fpRegs.input('wr_en').srcConnection! <= fpw.en;
        fpRegs.input('wr_addr').srcConnection! <= fpw.addr;
        fpRegs.input('wr_data').srcConnection! <= fpw.data;
        fp1.data <= fpRegs.rd0Data;
        fp2.data <= fpRegs.rd1Data;
        fp1.done <= fp1.en;
        fp1.valid <= fp1.en;
        fp2.done <= fp2.en;
        fp2.valid <= fp2.en;
        fpw.done <= fpw.en;
        fpw.valid <= fpw.en;
        fprs1Read = fp1;
        fprs2Read = fp2;
        fprdWrite = fpw;
        fpRegfile = fpRegs;
      }

      // FP arithmetic (ROHD-HCL units wired to the operand latches; the
      // square root and the divide are multi-cycle). ONE adder, ONE multiplier
      // and ONE square root serve the whole arithmetic family, because the
      // selection is on the OPERAND side:
      //   fadd   a + b
      //   fsub   a + (-b)                      sign XOR on b
      //   fmadd  (a*b) + c                     left operand = product
      //   fmsub  (a*b) + (-c)
      //   fnmsub (-(a*b)) + c
      //   fnmadd (-(a*b)) + (-c)
      //   fdiv   2.0 + (-(a*b))                the Newton-Raphson correction
      // The subclass drives [_fpSelFma], [_fpSelNegA], [_fpSelNegB],
      // [_fpSelDiv] and [_fpSelSingle] from its own decode. Result-side
      // selection instead needs six adders per precision, and an adder (align
      // shifter, normaliser, rounder) is one of the largest blocks in the core.
      //
      // A core with D holds only the DOUBLE units. The single-precision family
      // widens its operands to binary64, runs the same units, and rounds the
      // answer back to binary32 once. That is exact: f32 -> f64 loses nothing,
      // and binary64 keeps 53 bits where the bound for innocuous double
      // rounding into binary32 is 2*24 + 2 = 50. So +, -, *, / and sqrt give
      // the correctly rounded binary32 answer, and the f32 adder, multiplier
      // and square root all go away. An F-without-D core keeps its own f32
      // units, because it has no double units to borrow.
      //
      // Compares, sign injection, min/max, classify and fmv stay at the native
      // width. They are bit operations: a widen/narrow round trip does not keep
      // a NaN payload or the sign of a zero. See [fpBitOps]. int -> fp also
      // stays per precision, because an integer is not a binary32 value and the
      // 2p+2 bound does not apply to it.
      final selFma = Logic(name: 'fpSelFma');
      final selNegA = Logic(name: 'fpSelNegA');
      final selNegB = Logic(name: 'fpSelNegB');
      final selDiv = Logic(name: 'fpSelDiv');
      final selMul = Logic(name: 'fpSelMul');
      final selCvt = Logic(name: 'fpSelCvt');
      final selToInt = Logic(name: 'fpSelToInt');
      final selFpNarrow = Logic(name: 'fpSelFpNarrow');
      final selSingle = Logic(name: 'fpSelSingle');
      _fpSelFma = selFma;
      _fpSelNegA = selNegA;
      _fpSelNegB = selNegB;
      _fpSelDiv = selDiv;
      _fpSelMul = selMul;
      _fpSelCvt = selCvt;
      _fpSelToInt = selToInt;
      _fpSelFpNarrow = selFpNarrow;
      _fpSelSingle = selSingle;
      _fpArithStart = Logic(name: 'fpArithStart');
      _fpIntCvtStart = Logic(name: 'fpIntCvtStart');

      // int -> fp. The four source forms differ only in how the integer latch
      // reaches the shared converter, so the extension is selected on the
      // operand side and ONE unit serves both destination formats. rs2 bit1
      // picks the 64-bit source and rs2 bit0 the unsigned one, which is how
      // the decoder leaves them.
      final cvtIsL = fields['rs2']![1];
      final cvtUns = fields['rs2']![0];
      final intSrc = mux(
        cvtIsL,
        mux(cvtUns, rs1.zeroExtend(64), rs1.signExtend(64)),
        mux(
          cvtUns,
          rs1.slice(31, 0).zeroExtend(64),
          rs1.slice(31, 0).signExtend(64),
        ),
      ).named('fpIntSrc');

      // Double-precision arithmetic (only when the ISA uses 64-bit FP regs).
      final hasDouble = microcode.execLookup.values.any(
        (op) => op.resources.any(
          (r) =>
              r is RfResource &&
              r.regfile is RiscVFloatRegFile &&
              (r.regfile as RiscVFloatRegFile).width == 64,
        ),
      );
      _fpHasDouble = hasDouble;
      if (hasDouble) {
        final fpA = mux(selSingle, _fpOperand(rs1, 32).zeroExtend(64), rs1);
        final fpB = mux(selSingle, _fpOperand(rs2, 32).zeroExtend(64), rs2);
        final fpC = mux(selSingle, _fpOperand(rs3, 32).zeroExtend(64), rs3);
        // Shared arithmetic. ONE multi-cycle unit adds, multiplies, divides
        // and converts between the two precisions. FMA retains the full product
        // through addition and rounds once, so the whole family shares one
        // align/normalise/round datapath and one adder instead of an unrolled
        // adder plus a 53x53 product array. It reads its operands at the
        // source width and rounds the answer at the destination width, which
        // is why there is no widen on b or c and no narrowing converter after
        // it. An arithmetic mop parks at its mopStep and waits for done.
        _fpArith = IterativeFpArith(
          clk,
          reset,
          _fpArithStart!,
          fpA,
          fpB,
          fpC,
          selFma,
          selNegA,
          selNegB,
          selDiv,
          selMul,
          selCvt,
          selSingle,
          exponentWidth: 11,
          mantissaWidth: 52,
          rm: fpUnitRm,
        );
        _fpArithD = _fpArith!.result;

        // Square root. Multi-cycle and exact: the digit recurrence gives the
        // truncated root and the exact remainder, so the rounding is the same
        // one the golden model does. Both precisions read it: a single root
        // reads the binary32 operand fields itself and rounds once at the
        // binary32 position, so no widening converter stands in front of it.
        _fsqrtStart = Logic(name: 'fsqrtStart');
        _fsqrt = IterativeFpSqrt(
          clk,
          reset,
          _fsqrtStart!,
          fpA,
          selSingle,
          exponentWidth: 11,
          mantissaWidth: 52,
          rm: fpUnitRm,
        );
        _fpSqrtD = _fsqrt!.result;

        // Shared integer <-> float convert. ONE magnitude path serves
        // fcvt.w.s and fcvt.w.d, and one normalise and rounding serves
        // fcvt.s.w and fcvt.d.w, because the unit reads and writes the float
        // side at whichever width the operation names.
        _fpIntCvt = IterativeFpIntConvert(
          clk,
          reset,
          _fpIntCvtStart!,
          mux(selFpNarrow, _fpOperand(rs1, 32).zeroExtend(64), rs1),
          intSrc,
          ~cvtUns,
          selToInt,
          selFpNarrow,
          exponentWidth: 11,
          mantissaWidth: 52,
          rm: fpUnitRm,
        );
      } else {
        // F without D: no double unit to borrow, so the single family builds
        // its own arithmetic unit at binary32. Same operand-side select.
        _fpArith = IterativeFpArith(
          clk,
          reset,
          _fpArithStart!,
          rs1.slice(31, 0),
          rs2.slice(31, 0),
          rs3.slice(31, 0),
          selFma,
          selNegA,
          selNegB,
          selDiv,
          selMul,
          selCvt,
          selSingle,
          exponentWidth: 8,
          mantissaWidth: 23,
          rm: fpUnitRm,
        );
        _fpArithS = _fpArith!.result;

        _fsqrtStart = Logic(name: 'fsqrtStart');
        _fsqrt = IterativeFpSqrt(
          clk,
          reset,
          _fsqrtStart!,
          rs1.slice(31, 0),
          // A core built at binary32 has no narrower format to round to.
          Const(0),
          exponentWidth: 8,
          mantissaWidth: 23,
          rm: fpUnitRm,
        );
        _fpSqrtS = _fsqrt!.result;

        // Shared integer <-> float convert at binary32. A core built at that
        // format has no narrower one, so the destination select is tied low.
        _fpIntCvt = IterativeFpIntConvert(
          clk,
          reset,
          _fpIntCvtStart!,
          rs1.slice(31, 0),
          intSrc,
          ~cvtUns,
          selToInt,
          Const(0),
          exponentWidth: 8,
          mantissaWidth: 23,
          rm: fpUnitRm,
        );
      }
    }

    // Vector register file (32 x VLEN). Present when any handled op has a
    // VectorResource. Zero-latency, ROHD auto-detects the submodule.
    final hasVector = microcode.execLookup.values.any(
      (op) => op.resources.any((r) => r is VectorResource),
    );
    if (hasVector) {
      final v1 = DataPortInterface(vlen, 5);
      final v2 = DataPortInterface(vlen, 5);
      final vw = DataPortInterface(vlen, 5);
      final vregs = HarborRegisterFile(
        numEntries: 32,
        dataWidth: vlen,
        name: 'v_regfile',
      );
      vregs.input('clk').srcConnection! <= clk;
      vregs.input('reset').srcConnection! <= reset;
      vregs.input('rd0_addr').srcConnection! <= v1.addr;
      vregs.input('rd1_addr').srcConnection! <= v2.addr;
      vregs.input('wr_en').srcConnection! <= vw.en;
      vregs.input('wr_addr').srcConnection! <= vw.addr;
      vregs.input('wr_data').srcConnection! <= vw.data;
      v1.data <= vregs.rd0Data;
      v2.data <= vregs.rd1Data;
      v1.done <= v1.en;
      v1.valid <= v1.en;
      v2.done <= v2.en;
      v2.valid <= v2.en;
      vw.done <= vw.en;
      vw.valid <= vw.en;
      vrs1Read = v1;
      vrs2Read = v2;
      vrdWrite = vw;
      vRegfile = vregs;
      _vtype = Logic(name: 'vtypeState', width: 11);
      _vl = Logic(name: 'vlState', width: mxlen.size);
      _vtmp = Logic(name: 'vtmpState', width: vlen);
      _vregIdx = Logic(name: 'vregIdxState', width: 4);
    }

    // One shared multi-cycle integer divider for the whole div/rem family
    // (built when the ISA has M). Its control register [_idivStart] is driven
    // and reset alongside the other multi-cycle state in the Sequential below;
    // the operand nets carry unsigned magnitudes selected by the resident
    // div/rem mop (StaticExecutionUnit.cycle). Unused (start tied low) on the
    // microcode/OoO paths, where synthesis prunes it.
    if (microcode.isa.extensions.any((e) => e.name == 'M')) {
      _idivStart = Logic(name: 'idivStart');
      _idivDividend = Logic(name: 'idivDividend', width: mxlen.size);
      _idivDivisor = Logic(name: 'idivDivisor', width: mxlen.size);
      _idiv = IterativeDivider(
        clk,
        reset,
        _idivStart!,
        _idivDividend!,
        _idivDivisor!,
        width: mxlen.size,
      );
      if (useIterativeMul) {
        _imulStart = Logic(name: 'imulStart');
        _imulA = Logic(name: 'imulA', width: mxlen.size);
        _imulB = Logic(name: 'imulB', width: mxlen.size);
        _imul = IterativeMultiplier(
          clk,
          reset,
          _imulStart!,
          _imulA!,
          _imulB!,
          width: mxlen.size,
        );
      }
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          alu < 0,
          mopStep < 0,
          done < 0,
          fpFlags < 0,
          if (enableMisalignedLoads) misalignedLoad < 0,
          if (enableMisalignedLoads || exactMemoryReads) loadSize < 2,
          output('trap') < 0,
          output('trapInterrupt') < 0,
          output('trapEpc') < currentPc,
          output('isReturn') < 0,
          output('returnLevel') < 0,
          output('memGuest') < 0,
          reservationValid < 0,
          amoOld < 0,
          if (_fpArithStart != null) _fpArithStart! < 0,
          if (_fpIntCvtStart != null) _fpIntCvtStart! < 0,
          if (_fsqrtStart != null) _fsqrtStart! < 0,
          if (_idivStart != null) ...[
            _idivStart! < 0,
            _idivDividend! < 0,
            _idivDivisor! < 0,
          ],
          if (_imulStart != null) ...[
            _imulStart! < 0,
            _imulA! < 0,
            _imulB! < 0,
          ],
          // Pragmatic power-on vector config (e32, vl=VLMAX) so ops work before
          // an explicit vsetvli; real code sets vtype/vl first. (RVV proper
          // would reset vill; this convenience keeps non-vsetvli tests valid.)
          if (_vtype != null) _vtype! < Const(0x10, width: 11),
          if (_vl != null) _vl! < Const(vlen ~/ 32, width: mxlen.size),
          if (_vtmp != null) _vtmp! < 0,
          if (_vregIdx != null) _vregIdx! < 0,
          rs1Read.en < 0,
          rs1Read.addr < 0,
          rs2Read.en < 0,
          rs2Read.addr < 0,
          rdWrite.en < 0,
          rdWrite.addr < 0,
          rdWrite.data < 0,
          // The floating-point ports need the same idle default as the integer
          // ports. Without it their enables are undriven out of reset and the
          // FP handshake never completes.
          if (fprs1Read != null) ...[fprs1Read!.en < 0, fprs1Read!.addr < 0],
          if (fprs2Read != null) ...[fprs2Read!.en < 0, fprs2Read!.addr < 0],
          if (fprdWrite != null) ...[
            fprdWrite!.en < 0,
            fprdWrite!.addr < 0,
            fprdWrite!.data < 0,
          ],
          memRead.en < 0,
          memRead.addr < 0,
          memWrite.en < 0,
          memWrite.addr < 0,
          memWrite.data < 0,
          if (microcodeRead != null) ...[
            microcodeRead.en < 0,
            microcodeRead.addr < 0,
          ],
          if (this.csrRead != null) ...[
            this.csrRead!.en < 0,
            this.csrRead!.addr < 0,
          ],
          if (this.csrWrite != null) ...[
            this.csrWrite!.en < 0,
            this.csrWrite!.addr < 0,
            this.csrWrite!.data < 0,
          ],
          fence < 0,
          interruptHold < 0,
          nextPc < currentPc,
          nextSp < currentSp,
          nextMode < Const(PrivilegeMode.machine.id, width: 3),
          counter < 0,
        ],
        orElse: [
          If(
            enable,
            then: [
              counter < (counter + 1),
              // Default: privilege is unchanged and no trap. doTrap/MRET/SRET
              // override these later in the same Sequential, taking precedence.
              nextMode < currentMode,
              output('trap') < 0,
              output('trapEpc') < currentPc,
              output('isReturn') < 0,
              output('returnLevel') < 0,
              output('memGuest') < 0,
              // A fetch fault means there is no instruction to run: raise an
              // instruction fault at currentPc (the faulting PC) instead.
              // An async interrupt is taken only at a CLEAN instruction boundary:
              // mopStep==0 AND no memory or register-write side effect is in
              // flight. mopStep==0 alone is NOT a clean boundary. An atomic runs
              // its whole read-modify-write at mopStep==0 (the read-completion
              // wrapper issues the write and the write-completion wrapper writes
              // rd, neither advances mopStep), so mopStep stays 0 across the
              // memRead wait, the memWrite wait and the rd commit. Taking the
              // interrupt during that window lets the posted write commit on
              // silicon while rd and the PC do not retire, so the atomic re-runs
              // and applies the operation twice (a skipped ticket that deadlocks
              // a ticket spinlock). It also leaves memRead/memWrite.en asserted
              // into the handler, because rawTrap does not clear them. Gating on
              // the held (registered) memRead.en, memWrite.en and rdWrite.en
              // holds the interrupt off until the access retires, so the atomic
              // is indivisible with respect to the interrupt. At a true boundary
              // all three are 0 and epc is the not-yet-run instruction. It
              // vectors through the same rawTrap path as a synchronous trap.
              If(
                (this.interruptTake ?? Const(0)) &
                    mopStep.eq(0) &
                    ~memRead.en &
                    ~memWrite.en &
                    ~rdWrite.en,
                then: rawTrap(
                  Const(1),
                  this.interruptCause ?? Const(0, width: 6),
                  Const(0, width: mxlen.size),
                ),
                orElse: [
                  If(
                    fetchFaultIn | fpIllegal | privIllegal | statusIllegal,
                    then: [
                      If(
                        fetchFaultIn,
                        then: doTrap(Trap.instructionPageFault, currentPc),
                        orElse: doTrap(
                          Trap.illegal,
                          Const(0, width: mxlen.size),
                        ),
                      ),
                    ],
                    orElse: microcodeRead != null
                        ? cycleMicrocode(
                            instrIndex,
                            mopStep,
                            microcodeRead,
                            alu: alu,
                            rs1: rs1,
                            rs2: rs2,
                            rd: rd,
                            imm: imm,
                            fields: fields,
                            memRead: memRead,
                            memWrite: memWrite,
                            rs1Read: rs1Read,
                            rs2Read: rs2Read,
                            rdWrite: rdWrite,
                          )
                        : cycle(
                            instrIndex,
                            mopStep,
                            alu: alu,
                            rs1: rs1,
                            rs2: rs2,
                            rd: rd,
                            imm: imm,
                            fields: fields,
                            memRead: memRead,
                            memWrite: memWrite,
                            rs1Read: rs1Read,
                            rs2Read: rs2Read,
                            rdWrite: rdWrite,
                          ),
                  ),
                ],
              ),
            ],
            orElse: [
              alu < 0,
              mopStep < 0,
              done < 0,
              fpFlags < 0,
              rs1Read.en < 0,
              rs1Read.addr < 0,
              rs2Read.en < 0,
              rs2Read.addr < 0,
              rdWrite.en < 0,
              rdWrite.addr < 0,
              rdWrite.data < 0,
              // The floating-point ports need the same idle default as the integer
              // ports. Without it their enables are undriven out of reset and the
              // FP handshake never completes.
              if (fprs1Read != null) ...[
                fprs1Read!.en < 0,
                fprs1Read!.addr < 0,
              ],
              if (fprs2Read != null) ...[
                fprs2Read!.en < 0,
                fprs2Read!.addr < 0,
              ],
              if (fprdWrite != null) ...[
                fprdWrite!.en < 0,
                fprdWrite!.addr < 0,
                fprdWrite!.data < 0,
              ],
              memRead.en < 0,
              memRead.addr < 0,
              memWrite.en < 0,
              memWrite.addr < 0,
              memWrite.data < 0,
              if (microcodeRead != null) ...[
                microcodeRead.en < 0,
                microcodeRead.addr < 0,
              ],
              if (this.csrRead != null) ...[
                this.csrRead!.en < 0,
                this.csrRead!.addr < 0,
              ],
              if (this.csrWrite != null) ...[
                this.csrWrite!.en < 0,
                this.csrWrite!.addr < 0,
                this.csrWrite!.data < 0,
              ],
              fence < 0,
              if (enableMisalignedLoads) misalignedLoad < 0,
              if (enableMisalignedLoads || exactMemoryReads) loadSize < 2,
              interruptHold < 0,
              nextPc < currentPc,
              nextSp < currentSp,
              nextMode < currentMode,
              output('trap') < 0,
              output('trapEpc') < currentPc,
              output('isReturn') < 0,
              output('returnLevel') < 0,
              output('memGuest') < 0,
            ],
          ),
        ],
      ),
    ]);

    // A configuration with FP registers but no FP arithmetic (loads, stores and
    // moves alone) never drives the operand select, so tie it low here. The
    // shared units then hold their plain fadd form and synthesis prunes them.
    if (_fpSelFma != null && !_fpSelDriven) {
      _fpSelFma! <= Const(0);
      _fpSelNegA! <= Const(0);
      _fpSelNegB! <= Const(0);
      _fpSelDiv! <= Const(0);
      _fpSelMul! <= Const(0);
      _fpSelCvt! <= Const(0);
      _fpSelToInt! <= Const(0);
      _fpSelFpNarrow! <= Const(0);
      _fpSelSingle! <= Const(0);
    }
  }

  /// Drives the operand select of the shared FP adder and multiplier.
  ///
  /// A subclass calls this ONCE from its cycle builder with the values its own
  /// decode gives. The base class holds the datapath, the subclass holds the
  /// decode, so the microcoded unit and the static unit share one adder and
  /// one multiplier per precision without a second decoder that could disagree
  /// with either of them.
  ///
  /// [fma] runs the operation as a multiply pass followed by an add pass, the
  /// product being the left operand of the add and rs3 the right one. [negA]
  /// and [negB] flip the sign of the left and the right operand of the add.
  /// [div] and [mul] name a divide and a multiply, and [cvt] a convert between
  /// the two precisions. [single] says the operand is single-precision, so the
  /// shared unit reads binary32 fields and rounds its answer back to binary32;
  /// with [cvt] the answer takes the OTHER format instead.
  void driveFpSelect({
    required Logic fma,
    required Logic negA,
    required Logic negB,
    required Logic div,
    required Logic mul,
    required Logic cvt,
    required Logic toInt,
    required Logic fpNarrow,
    required Logic single,
  }) {
    if (_fpSelFma == null || _fpSelDriven) {
      return;
    }
    _fpSelDriven = true;
    _fpSelFma! <= fma;
    _fpSelNegA! <= negA;
    _fpSelNegB! <= negB;
    _fpSelDiv! <= div;
    _fpSelMul! <= mul;
    _fpSelCvt! <= cvt;
    _fpSelToInt! <= toInt;
    _fpSelFpNarrow! <= fpNarrow;
    _fpSelSingle! <= single;
  }

  List<Conditional> cycle(
    Logic instrIndex,
    Logic mopStep, {
    required Logic alu,
    required Logic rs1,
    required Logic rs2,
    required Logic rd,
    required Logic imm,
    required Map<String, Logic> fields,
    required DataPortInterface memRead,
    required DataPortInterface memWrite,
    required DataPortInterface rs1Read,
    required DataPortInterface rs2Read,
    required DataPortInterface rdWrite,
  }) => [];

  List<Conditional> cycleMicrocode(
    Logic instrIndex,
    Logic mopStep,
    DataPortInterface microcodeRead, {
    required Logic alu,
    required Logic rs1,
    required Logic rs2,
    required Logic rd,
    required Logic imm,
    required Map<String, Logic> fields,
    required DataPortInterface memRead,
    required DataPortInterface memWrite,
    required DataPortInterface rs1Read,
    required DataPortInterface rs2Read,
    required DataPortInterface rdWrite,
  }) => [];

  Logic compareCurrentMode(PrivilegeMode target) =>
      currentMode.eq(Const(target.id, width: 3));

  // Enable implemented CSRs for ordinary U-mode, but retain the existing VU
  // rejection until virtual counter permissions and exception selection are
  // implemented together. Merely removing this guard would bypass hcounteren.
  Logic get _virtualUserCsrBlocked =>
      compareCurrentMode(PrivilegeMode.user) & (virtIn ?? Const(0));

  Logic selectTrapTargetMode(
    Logic trapInterrupt,
    Logic causeCode,
    Logic mode,
    Logic? mideleg,
    Logic? medeleg, {
    String? suffix,
  }) => selectTrapTargetModeTop(
    trapInterrupt,
    causeCode,
    mode,
    mideleg,
    medeleg,
    hasCsr: csrRead != null && csrWrite != null,
    hasSupervisor: hasSupervisor,
  );

  Logic encodeCause(Logic trapInterrupt, Logic causeCode) =>
      (trapInterrupt.zeroExtend(mxlen.size) << (mxlen.size - 1)) |
      causeCode.zeroExtend(mxlen.size);

  Logic computeTrapVectorPc(
    Logic tvec,
    Logic causeCode,
    Logic trapInterrupt, {
    String? suffix,
  }) => computeTrapVectorPcTop(
    tvec,
    causeCode,
    trapInterrupt,
    mxlen,
    suffix: suffix,
  );

  List<Conditional> rawTrap(
    Logic trapInterrupt,
    Logic causeCode, [
    Logic? tval,
    String? suffix,
    Logic? modeCause,
  ]) {
    suffix ??= '';

    // A trap op with modeCause set re-encodes its cause from the originating
    // privilege/virt: ECALL becomes U/VU=8, HS=9, VS=10, M=11. Every other trap
    // keeps its fixed causeCode. Centralized here so the static path, the
    // microcode path, and any future privilege-dependent trap share one cause
    // encoding (the switched cause also feeds delegation via
    // selectTrapTargetMode below).
    final effCause = (modeCause == null)
        ? causeCode
        : mux(
            modeCause,
            mux(
              currentMode.eq(Const(PrivilegeMode.machine.id, width: 3)),
              Const(11, width: 6),
              mux(
                currentMode.eq(Const(PrivilegeMode.supervisor.id, width: 3)),
                mux(
                  virtIn ?? Const(0),
                  Const(10, width: 6),
                  Const(9, width: 6),
                ),
                Const(8, width: 6),
              ),
            ),
            causeCode,
          );

    if (csrRead == null || csrWrite == null) {
      return [
        trapCause < encodeCause(trapInterrupt, effCause).slice(5, 0),
        output('trapInterrupt') < trapInterrupt,
        trapTval < (tval ?? Const(0, width: mxlen.size)),
        output('trapEpc') < currentPc,
        output('trap') < 1,
        done < 1,
        valid < 1,
      ];
    }

    final tvec = Logic(name: 'tvec$suffix', width: mxlen.size);

    final newMode = selectTrapTargetMode(
      trapInterrupt,
      effCause,
      currentMode,
      mideleg,
      medeleg,
      suffix: suffix,
    );

    return [
      nextMode < newMode,
      trapCause <
          encodeCause(
            trapInterrupt,
            effCause,
          ).slice(5, 0).named('cause$suffix'),
      output('trapInterrupt') < trapInterrupt,
      trapTval < (tval ?? Const(0, width: mxlen.size)),
      output('trapEpc') < currentPc,

      tvec <
          ((stvec != null)
              ? mux(
                  newMode.eq(Const(PrivilegeMode.machine.id, width: 3)),
                  mtvec ?? Const(0, width: mxlen.size),
                  stvec ?? Const(0, width: mxlen.size),
                )
              : (mtvec ?? Const(0, width: mxlen.size))),

      nextPc <
          computeTrapVectorPc(
            ((stvec != null)
                ? mux(
                    newMode.eq(Const(PrivilegeMode.machine.id, width: 3)),
                    mtvec ?? Const(0, width: mxlen.size),
                    stvec ?? Const(0, width: mxlen.size),
                  )
                : (mtvec ?? Const(0, width: mxlen.size))),
            effCause,
            trapInterrupt,
            suffix: suffix,
          ),

      output('trap') < 1,
      done < 1,
      valid < 1,
    ];
  }

  late final Logic _fetchAccessFault;
  late final Logic _memAccessFault;
  late final Logic? _fetchFaultTval;

  List<Conditional> doTrap(Trap t, [Logic? tval, String? suffix]) {
    final trapInterrupt = Const(t.interrupt ? 1 : 0);
    final accessCause = switch (t) {
      Trap.instructionPageFault => Trap.instructionAccessFault,
      Trap.loadPageFault => Trap.loadAccess,
      Trap.storePageFault => Trap.storeAccess,
      _ => null,
    };
    final causeCode = accessCause == null
        ? Const(t.causeCode, width: 6)
        : mux(
            t == Trap.instructionPageFault
                ? _fetchAccessFault
                : _memAccessFault,
            Const(accessCause.causeCode, width: 6),
            Const(t.causeCode, width: 6),
          );
    if (t == Trap.instructionPageFault && _fetchFaultTval != null) {
      tval = _fetchFaultTval;
    }
    if (t == Trap.loadPageFault && _loadFaultTval != null) {
      tval = mux(
        misalignedLoad,
        _loadFaultTval,
        tval ?? Const(0, width: mxlen.size),
      );
    }
    return rawTrap(trapInterrupt, causeCode, tval, suffix);
  }

  /// VS-mode state-enable virtual-instruction: a guest sstateen (0x10C-0x10F)
  /// access that mstateen0.SE0 permits but hstateen0.SE0 blocks. (An
  /// mstateen-blocked access is illegal, raised by the CSR legality path.)
  /// Const(0) for a core without stateen + hypervisor support.
  Logic _stateenVsViol(Logic addr12) {
    final mse0 = mstateen0Se0;
    final hse0 = hstateen0Se0;
    if (mse0 == null || hse0 == null) return Const(0);
    return (virtIn ?? Const(0)) &
        addr12.gte(Const(0x10C, width: 12)) &
        addr12.lte(Const(0x10F, width: 12)) &
        mse0 &
        ~hse0;
  }
}

class DynamicExecutionUnit extends ExecutionUnit {
  DynamicExecutionUnit(
    super.clk,
    super.reset,
    super.enable,
    super.currentSp,
    super.currentPc,
    super.currentMode,
    super.instrIndex,
    super.instrTypeMap,
    super.fields,
    super.csrRead,
    super.csrWrite,
    super.memRead,
    super.memWrite,
    super.rs1Read,
    super.rs2Read,
    super.rdWrite,
    DataPortInterface microcodeRead, {
    super.hasSupervisor,
    super.hasUser,
    super.enableMisalignedLoads,
    super.exactMemoryReads,
    super.loadFaultTval,
    required super.microcode,
    required super.mxlen,
    super.vlen = 128,
    super.mideleg,
    super.medeleg,
    super.mtvec,
    super.stvec,
    super.interruptTake,
    super.interruptCause,
    super.virtIn,
    super.mstateen0Se0,
    super.hstateen0Se0,
    super.memFaultGuest,
    super.fetchFault,
    super.fetchAccessFault,
    super.fetchFaultTval,
    super.memAccessFault,
    super.frm,
    super.tsr,
    super.tvm,
    super.tw,
    super.fpEnabled,
    super.fpRs1Port,
    super.fpRs2Port,
    super.fpRdPort,
    super.counterWidth,
    super.staticInstructions,
    super.name = 'river_dynamic_execution_unit',
  }) : super(microcodeRead: microcodeRead);

  @override
  List<Conditional> cycleMicrocode(
    Logic instrIndex,
    Logic mopStep,
    DataPortInterface microcodeRead, {
    required Logic alu,
    required Logic rs1,
    required Logic rs2,
    required Logic rd,
    required Logic imm,
    required Map<String, Logic> fields,
    required DataPortInterface memRead,
    required DataPortInterface memWrite,
    required DataPortInterface rs1Read,
    required DataPortInterface rs2Read,
    required DataPortInterface rdWrite,
  }) {
    final csrRead = this.csrRead;
    final csrWrite = this.csrWrite;

    final mopCount = Logic(name: 'mopCount', width: mopStep.width);

    // Micro-op funct codes this config's ROM actually emits. A funct-Case arm
    // whose funct is never emitted is dead logic (the ROM can never produce it),
    // so drop it and its operand datapath. Derived from the ROM alone, so each
    // config keeps exactly its arms. rc1-s (RV64IMAC) e.g. never emits
    // TlbFence/TlbInvalidate/InterruptHold/FpuOp.
    final emittedFuncts = microcode.emittedFuncts;
    bool functEmitted(int f) => emittedFuncts.contains(f);

    final mopTable = Map.fromEntries(
      kMicroOpTable
          .where((mop) {
            if (mop.funct == ReadCsrMicroOp.funct && csrRead == null) {
              return false;
            }
            if (mop.funct == WriteCsrMicroOp.funct && csrWrite == null) {
              return false;
            }
            return true;
          })
          .map((mop) => MapEntry(MicrocodeRom.mopType(mop), mop)),
    );

    final mop = mopTable.map(
      (k, mop) => MapEntry(
        k,
        Map.fromEntries(
          mop.struct(mxlen).mapping.entries.map((entry) {
            final fieldName = entry.key;
            final range = entry.value;
            final value = microcodeRead.data
                .getRange(range.start, range.end + 1)
                .named('mop${k}_$fieldName');
            return MapEntry(fieldName, value);
          }),
        ),
      ),
    );

    final funct = microcodeRead.data
        .slice(MicroOp.functRange.end, MicroOp.functRange.start)
        .named('mopFunct');

    Logic readSource(Logic source) => mux(
      source.eq(Const(MicroOpSource.imm, width: MicroOpSource.width)),
      imm,
      mux(
        source.eq(Const(MicroOpSource.alu, width: MicroOpSource.width)),
        alu,
        mux(
          source.eq(Const(MicroOpSource.rs1, width: MicroOpSource.width)),
          rs1,
          mux(
            source.eq(Const(MicroOpSource.rs2, width: MicroOpSource.width)),
            rs2,
            mux(
              source.eq(Const(MicroOpSource.rd, width: MicroOpSource.width)),
              rd,
              nextPc,
            ),
          ),
        ),
      ),
    );

    // rs3, the third source of an r4-type fused multiply-add, exists only when
    // the ISA carries such an op. Its decode field then appears in [fields].
    final hasRs3 = fields.containsKey('rs3');

    Logic readField(Logic field, {bool register = true}) => mux(
      field.eq(Const(MicroOpField.rd, width: MicroOpField.width)),
      (register ? rd : fields['rd']!).zeroExtend(mxlen.size),
      mux(
        field.eq(Const(MicroOpField.rs1, width: MicroOpField.width)),
        (register ? rs1 : fields['rs1']!).zeroExtend(mxlen.size),
        mux(
          field.eq(Const(MicroOpField.rs2, width: MicroOpField.width)),
          (register ? rs2 : fields['rs2']!).zeroExtend(mxlen.size),
          mux(
            field.eq(Const(MicroOpField.imm, width: MicroOpField.width)),
            register ? imm : fields['imm']!,
            mux(
              field.eq(Const(MicroOpField.pc, width: MicroOpField.width)),
              nextPc,
              // rs3 is named ONLY as a register INDEX, by the extra ReadRegister
              // that a fused multiply-add carries. The FPU takes its third
              // operand straight from the rs3 latch, so no XLEN-wide data path
              // ever selects rs3. Folding rs3 into the decode-field variant only
              // keeps the register variant, which is the wide one and has many
              // more users, at its existing five-way mux.
              (hasRs3 && !register)
                  ? mux(
                      field.eq(
                        Const(MicroOpField.rs3, width: MicroOpField.width),
                      ),
                      fields['rs3']!.zeroExtend(mxlen.size),
                      nextSp,
                    )
                  : nextSp,
            ),
          ),
        ),
      ),
    );

    // Shared microcode-ALU operands: hoisted out of the ~19-arm funct Case so
    // synth infers ONE operand mux per side instead of one per arm (mux-bound).
    final aluA = readField(mop['Alu']!['a']!);
    final aluB = readField(mop['Alu']!['b']!);

    // Shared single-cycle integer ALU: ONE control-driven unit for all 18
    // single-cycle funct arms (add/sub/logic/shift/compare/word/zicond). mul
    // (iterative _imul) and div/rem (IterativeDivider) stay multi-cycle and
    // explicit; everything else falls through to this result.
    final microcodeAlu = MicrocodeAlu(
      aluA,
      aluB,
      mop['Alu']!['alu']!,
      mxlen: mxlen,
    ).result;

    // Atomics (AMO/LR/SC) exist ONLY at word and doubleword width (RISC-V has no
    // sub-word atomic; the ROM never emits a byte/half atomic size, see harbor
    // rv_a.dart). Restricting the atomic size Cases to these widths drops the
    // unreachable byte/half arms (each a full operand-read + combine). The AMO
    // combine (amoNewVal, a 9-way afunct mux) per size is the biggest mux source
    // in the unit (~22% of all muxes at byte+word widths).
    bool atomicSize(RiscVMemSize s) =>
        (s.bytes == 4 || s.bytes == 8) && s.bytes <= mxlen.width;

    // Floating-point compute is present when the ROM emits an FpuOp AND the
    // unit built an FP register file. A core without F/D gets neither, so all
    // the FP logic below disappears.
    final hasFpu = fprdWrite != null && functEmitted(FpuMicroOp.funct);

    // Shared wide operand read: the base read is the SAME 6:1 operand mux in
    // all five memory handlers (MemLoad/MemStore/LoadReserved/
    // StoreConditional/AtomicMemory), differing only in which 3-bit ROM field
    // selects it. The FpuOp `a` operand is the same read again, on a
    // mutually-exclusive funct. Mux the cheap selector by the active micro-op
    // so ONE wide readField serves them all instead of six (mux-bound).
    Logic functIs(int f) => funct.eq(Const(f, width: funct.width));
    var opBaseSel = mux(
      functIs(MemLoadMicroOp.funct),
      mop['MemLoad']!['base']!,
      mux(
        functIs(MemStoreMicroOp.funct),
        mop['MemStore']!['base']!,
        mux(
          functIs(LoadReservedMicroOp.funct),
          mop['LoadReserved']!['base']!,
          mux(
            functIs(StoreConditionalMicroOp.funct),
            mop['StoreConditional']!['base']!,
            mop['AtomicMemory']!['base']!,
          ),
        ),
      ),
    );
    if (hasFpu) {
      opBaseSel = mux(
        functIs(FpuMicroOp.funct),
        mop['FpuOp']!['a']!,
        opBaseSel,
      );
    }
    final opBase = readField(opBaseSel);

    // Shared store-data operand: MemStore and StoreConditional both read a `src`
    // field (mutually-exclusive funct arms, both drive memWrite.data). Mux the
    // 3-bit selector by funct so ONE readField serves both (mux-bound).
    final opStoreSrc = readField(
      mux(
        functIs(MemStoreMicroOp.funct),
        mop['MemStore']!['src']!,
        mop['StoreConditional']!['src']!,
      ),
    );

    // Shared operand-source read. WriteRegister, ModifyLatch, MoveToField and
    // WriteCsr each read a MicroOpSource operand in mutually-exclusive funct
    // arms; muxing the 3-bit source selector by funct lets ONE readSource serve
    // them all (mux-bound). Only folds in micro-ops present in this ROM.
    Logic srcSel = mop['WriteRegister']!['source']!;
    if (mop.containsKey('ModifyLatch')) {
      srcSel = mux(
        functIs(ModifyLatchMicroOp.funct),
        mop['ModifyLatch']!['source']!,
        srcSel,
      );
    }
    if (mop.containsKey('MoveToField')) {
      srcSel = mux(
        functIs(SetFieldMicroOpFunct.funct),
        mop['MoveToField']!['src']!,
        srcSel,
      );
    }
    if (csrWrite != null && mop.containsKey('WriteCsr')) {
      srcSel = mux(
        functIs(WriteCsrMicroOp.funct),
        mop['WriteCsr']!['source']!,
        srcSel,
      );
    }
    if (mop.containsKey('UpdatePC')) {
      srcSel = mux(
        functIs(UpdatePCMicroOp.funct),
        mop['UpdatePC']!['offsetSource']!,
        srcSel,
      );
    }
    final sharedSourceVal = readSource(srcSel);

    // Data for an FP register write. The FP register file is FLEN(64) wide and
    // the value comes through the mxlen-wide intermediate, so it is resized at
    // the boundary. A single-precision datum is also NaN-boxed: the upper 32
    // bits go to all ones. The value alone does not say how wide it is, so the
    // micro-op carries the 'nanBox' flag. ONE 64-bit mux serves every FP write.
    Logic? fpWriteData;
    if (fprdWrite != null) {
      final raw = sharedSourceVal + mop['WriteRegister']!['valueOffset']!;
      fpWriteData = mux(
        mop['WriteRegister']!['nanBox']!,
        [
          Const(BigInt.parse('FFFFFFFF', radix: 16), width: 32),
          raw.getRange(0, 32),
        ].swizzle(),
        raw.zeroExtend(64),
      ).named('fpWriteData');
    }

    // Shared operand-field read for the mutually-exclusive UpdatePC and
    // CopyField arms (both readField(...) a micro-op field with the default
    // register variant); one shared 6:1 operand mux instead of two.
    Logic? sharedFieldVal;
    if (mop.containsKey('UpdatePC') && mop.containsKey('CopyField')) {
      sharedFieldVal = readField(
        mux(
          functIs(UpdatePCMicroOp.funct),
          mop['UpdatePC']!['offsetField']!,
          mop['CopyField']!['src']!,
        ),
      );
    }

    // Shared CSR address read. ReadCsr and WriteCsr are mutually-exclusive funct
    // arms that both derive the 12-bit CSR index from a micro-op field via
    // readField(...).slice(11,0); muxing the field selector by funct shares that
    // single readField operand mux. Built only when a CSR port exists.
    Logic? csrAddr;
    if (csrRead != null || csrWrite != null) {
      var csrAddrSel = mop['ReadCsr']!['source']!;
      if (csrWrite != null) {
        csrAddrSel = mux(
          functIs(WriteCsrMicroOp.funct),
          mop['WriteCsr']!['field']!,
          csrAddrSel,
        );
      }
      csrAddr = readField(csrAddrSel).slice(11, 0);
    }

    // AMO read-modify-write: combine the loaded ("old") value with src per the
    // 4-bit afunct selector (RiscVAtomicFunct.index). All operands are [bits]
    // wide; the result is [bits] wide. Mirrors the static RiscVAtomicMemory arm.
    // cas (Zacas) needs rd's value as the compare operand and is handled by the
    // static path only; plain rvA never emits it, so it falls through to src.
    Logic amoNewVal(Logic afunct, Logic old, Logic src, int bits) {
      Logic sel(int v) =>
          afunct.eq(Const(v, width: AtomicMemoryMicroOp.functWidth));
      return mux(
        sel(0),
        old + src, // add
        mux(
          sel(1),
          src, // swap
          mux(
            sel(2),
            old ^ src, // xor
            mux(
              sel(3),
              old & src, // and
              mux(
                sel(4),
                old | src, // or
                mux(
                  sel(5),
                  mux(bmSignedLt(old, src, bits), old, src), // min
                  mux(
                    sel(6),
                    mux(bmSignedLt(old, src, bits), src, old), // max
                    mux(
                      sel(7),
                      mux(old.lt(src), old, src), // minu
                      mux(
                        sel(8),
                        mux(old.lt(src), src, old), // maxu
                        src, // cas fallthrough (static path only)
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // AMO read-modify-write combine, computed ONCE at XLEN instead of a 9-way
    // amoNewVal per size. `amoSizeMux` selects an XLEN value by atomic size
    // (word/dword); old and src are sign-extended to XLEN. Signed min/max and
    // unsigned minu/maxu stay correct (32->64 sign-extension is monotonic for
    // both orderings); add/xor/and/or/swap only need correct low bits. The mem
    // port writes only `amoBytes` bytes, so high bits are don't-care.
    Logic amoSizeMux(Logic Function(RiscVMemSize) f) {
      final sizes = MicroOpMemSize.values.where(atomicSize).toList();
      var acc = f(sizes.first);
      for (final s in sizes.skip(1)) {
        acc = mux(
          mop['AtomicMemory']!['size']!.eq(
            Const(s.value, width: MicroOpMemSize.width),
          ),
          f(s),
          acc,
        );
      }
      return acc;
    }

    final amoOldX = amoSizeMux(
      (s) => memRead.data.slice(s.bits - 1, 0).signExtend(mxlen.size),
    );
    final amoNewX = amoNewVal(
      mop['AtomicMemory']!['afunct']!,
      amoOldX,
      amoSizeMux(
        (s) => readField(
          mop['AtomicMemory']!['src']!,
        ).slice(s.bits - 1, 0).signExtend(mxlen.size),
      ),
      mxlen.size,
    );
    final amoBytes = amoSizeMux((s) => Const(s.bytes, width: 7));
    // Stored value: the combine's low size.bits, ZERO-extended to XLEN (the
    // combine is sign-extended for correct min/max, but the store wrote zero
    // high bits before this fold, and the mem model keeps those high bytes).
    final amoStoreVal = amoSizeMux(
      (s) => amoNewX.slice(s.bits - 1, 0).zeroExtend(mxlen.size),
    );

    // MemLoad result: the loaded memRead.data extended to XLEN per the access
    // size ([sizeField]) and signedness ([unsignedField]). Computed once as a
    // size-driven data mux so the MemLoad-completion arm does a single
    // writeField instead of replicating the dest demux per byte/half/word/dword.
    Logic loadSizeMux(Logic sizeField, Logic unsignedField) {
      final sizes = MicroOpMemSize.values
          .where((s) => s.bytes <= mxlen.width)
          .toList();
      Logic ext(RiscVMemSize s) => mux(
        unsignedField,
        memRead.data.slice(s.bits - 1, 0).zeroExtend(mxlen.size),
        memRead.data.slice(s.bits - 1, 0).signExtend(mxlen.size),
      );
      var acc = ext(sizes.first);
      for (final s in sizes.skip(1)) {
        acc = mux(
          sizeField.eq(Const(s.value, width: MicroOpMemSize.width)),
          ext(s),
          acc,
        );
      }
      return acc;
    }

    // Shared rd-commit dest selector. LoadReserved, AMO-write and SC-write all
    // finish with the SAME "commit rd (or advance on x0)" datapath, reading a
    // dest field via readField(dest, register: false).slice(4,0). Mutually
    // exclusive by funct, so muxing the 3-bit dest selector by funct shares ONE
    // readField(dest) cone (mux-bound). Every micro-op type is in the mop table
    // (filtered only by CSR presence), so no key guards needed.
    var commitDest = mop['LoadReserved']!['dest']! as Logic;
    commitDest = mux(
      funct.eq(Const(StoreConditionalMicroOp.funct, width: funct.width)),
      mop['StoreConditional']!['dest']!,
      commitDest,
    );
    commitDest = mux(
      funct.eq(Const(AtomicMemoryMicroOp.funct, width: funct.width)),
      mop['AtomicMemory']!['dest']!,
      commitDest,
    );
    // AMO writes the old memory value, SC writes zero (LR uses the loaded value,
    // handled at its own site since the width/extension differs).
    final scAmoVal = mux(
      funct.eq(Const(AtomicMemoryMicroOp.funct, width: funct.width)),
      amoOld,
      Const(0, width: mxlen.size),
    );

    // x2 (sp) has a SHADOW copy outside the register file. A ReadRegister
    // micro-op whose index resolves to x2 takes `currentSp`, so the shadow IS
    // the architectural sp that every later instruction reads. The
    // WriteRegister micro-op mirrors an x2 write into `nextSp`, but the arms
    // that drive the register write port DIRECTLY (the atomic destination
    // commits and the link-register write) had no mirror. An `amo*.d sp`,
    // `lr.d sp`, `sc.d sp`, `jal sp` or `jalr sp` therefore updated the
    // register file and left the shadow holding the OLD sp, permanently, for
    // every instruction after it. This helper adds the missing mirror: it
    // costs one 5-bit compare per site.
    Conditional mirrorSp(Logic destIdx, Logic value) => If(
      destIdx.eq(Const(Register.x2.value, width: 5)),
      then: [nextSp < value],
    );

    // Floating-point compute result, selected at RUN TIME from the ROM's
    // function and precision fields. The arithmetic units are already wired to
    // the rs1/rs2/rs3 operand latches, so this is selection only, no new
    // datapath. Built as ONE value so the FpuOp arm does a SINGLE writeField
    // instead of replicating the wide dest demux per function, the same shape
    // the MemLoad arm uses. [fpIsArith] and [fpIsSqrt] park the micro-op on
    // the two multi-cycle units.
    Logic? fpResult;
    Logic? fpResultFlags;
    Logic? fpIsArith;
    Logic? fpIsSqrt;
    Logic? fpIsIntCvt;
    if (hasFpu) {
      final fn = mop['FpuOp']!['fpuFunct']!;
      final dp = mop['FpuOp']!['doublePrecision']!;
      // A core with F but no D has no double-precision unit, so every function
      // keeps its single form alone and the precision mux folds away.
      final hasDp = _fpArithD != null;

      Logic isFn(int v) => fn.eq(Const(v, width: MicroOpFpuFunct.width));
      // Coerce a result to the field-latch width. The double arms are FLEN=64
      // and are dead on a core without D, but they still elaborate. #71.
      Logic fit(Logic x) => x.width == mxlen.size
          ? x
          : (x.width > mxlen.size
                ? x.getRange(0, mxlen.size)
                : x.zeroExtend(mxlen.size));
      // Select the single or the double form by the ROM's precision bit. Both
      // forms are already computed, so this is one mux, not a second datapath.
      Logic byPrec(Logic? dbl, Logic single) =>
          (hasDp && dbl != null) ? mux(dp, dbl, single) : single;
      Logic byPrecFit(Logic? dbl, Logic single) =>
          (hasDp && dbl != null) ? mux(dp, fit(dbl), fit(single)) : fit(single);

      // Bit-level results at both precisions (compares, sign injection,
      // min/max, classify). Each is a narrow value, so one precision mux per
      // result is cheaper than a second function-wide mux for the double side.
      final sBits = fpBitOps(_fpOperand(rs1, 32), _fpOperand(rs2, 32), 32);
      final dBits = hasDp ? fpBitOps(rs1, rs2, 64) : null;

      // fp -> int. The precision bit of an fcvt names the SOURCE precision, so
      // fcvt.w.s (single) and fcvt.w.d (double) reach the same result through
      // it: with D the f32 source widens exactly and ONE magnitude path
      // serves both. The shared unit reports the truncated magnitude with a
      // round and a sticky bit, and the per-rm rounding and the saturation
      // happen here.
      final fpToIntFlags = Logic(width: 5);
      final fpToInt = roundSatFpToInt(
        intMag: _fpIntCvt!.intMag,
        roundBit: _fpIntCvt!.roundBit,
        sticky: _fpIntCvt!.sticky,
        ovf: _fpIntCvt!.overflow,
        signBit: byPrec(dBits?.signBit, sBits.signBit),
        isNaN: byPrec(dBits?.isNaN, sBits.isNaN),
        isInf: byPrec(dBits?.isInf, sBits.isInf),
        rm: _fpControlEnabled ? _fpRm : fields['funct3']!,
        flagsOut: fpToIntFlags,
        isL: fields['rs2']![1],
        uns: fields['rs2']![0],
        mxlen: mxlen,
      );

      // int -> fp. The same unit packs at either destination format, so this
      // arm is the unit's answer alone.
      final intToFp = fit(_fpIntCvt!.fpOut);

      // Operand select for the shared adder and multiplier. fsub, the four
      // fused multiply-add forms and the divide iteration are the same two
      // units with different operand signs and sources, so report the form
      // here and let the base datapath hold ONE adder and ONE multiplier per
      // precision.
      final isDivFn = isFn(MicroOpFpuFunct.fdiv).named('fpIsDiv');
      final isFmaFn =
          (isFn(MicroOpFpuFunct.fmadd) |
                  isFn(MicroOpFpuFunct.fmsub) |
                  isFn(MicroOpFpuFunct.fnmsub) |
                  isFn(MicroOpFpuFunct.fnmadd))
              .named('fpSelFmaSrc');
      final isMulFn = isFn(MicroOpFpuFunct.fmul).named('fpSelMulSrc');
      // fcvt.s.d and fcvt.d.s ask the shared unit for the OTHER format, which
      // it does as an add of the operand and a zero.
      final isCvtFn =
          (isFn(MicroOpFpuFunct.fcvtSD) | isFn(MicroOpFpuFunct.fcvtDS)).named(
            'fpSelCvtSrc',
          );
      // The W functs carry the L forms too; rs2 bit 1 picks between them.
      final isToIntFn =
          (isFn(MicroOpFpuFunct.fcvtWS) | isFn(MicroOpFpuFunct.fcvtWD)).named(
            'fpSelToIntSrc',
          );
      // Every integer convert parks on the shared convert unit.
      fpIsIntCvt =
          (isToIntFn |
                  isFn(MicroOpFpuFunct.fcvtSW) |
                  isFn(MicroOpFpuFunct.fcvtDW))
              .named('fpIsIntCvt');
      fpIsSqrt = isFn(MicroOpFpuFunct.fsqrt).named('fpIsSqrt');
      driveFpSelect(
        fma: isFmaFn,
        negA: (isFn(MicroOpFpuFunct.fnmsub) | isFn(MicroOpFpuFunct.fnmadd))
            .named('fpSelNegASrc'),
        negB:
            (isFn(MicroOpFpuFunct.fsub) |
                    isFn(MicroOpFpuFunct.fmsub) |
                    isFn(MicroOpFpuFunct.fnmadd))
                .named('fpSelNegBSrc'),
        div: isDivFn,
        mul: isMulFn,
        cvt: isCvtFn,
        toInt: isToIntFn,
        // The float side is binary32 for fcvt.s.w (destination) and for
        // fcvt.w.s (source) alike, so one select names both.
        fpNarrow: (isFn(MicroOpFpuFunct.fcvtSW) | isFn(MicroOpFpuFunct.fcvtWS))
            .named('fpSelFpNarrowSrc'),
        // The ROM precision bit names the source width of an fcvt and the
        // operand width of everything else, so its complement is exactly the
        // "read the operand as binary32" select.
        single: (~dp).named('fpSelSingleSrc'),
      );

      // Function select. The default is the operand itself, which is what fmv
      // wants and what the static unit's default arm gives; the four fcvt
      // functs the ISA never emits (fcvtLS/fcvtSL/fcvtLD/fcvtDL, whose L forms
      // ride on the W functs through rs2) land there too, exactly as they do on
      // the static path.
      var res = opBase;
      res = mux(
        isFn(MicroOpFpuFunct.fclass),
        byPrec(dBits?.fclass, sBits.fclass).zeroExtend(mxlen.size),
        res,
      );
      res = mux(
        isFn(MicroOpFpuFunct.fmax),
        byPrecFit(dBits?.fmax, sBits.fmax),
        res,
      );
      res = mux(
        isFn(MicroOpFpuFunct.fmin),
        byPrecFit(dBits?.fmin, sBits.fmin),
        res,
      );
      res = mux(
        isFn(MicroOpFpuFunct.fsgnjx),
        byPrecFit(dBits?.fsgnjx, sBits.fsgnjx),
        res,
      );
      res = mux(
        isFn(MicroOpFpuFunct.fsgnjn),
        byPrecFit(dBits?.fsgnjn, sBits.fsgnjn),
        res,
      );
      res = mux(
        isFn(MicroOpFpuFunct.fsgnj),
        byPrecFit(dBits?.fsgnj, sBits.fsgnj),
        res,
      );
      res = mux(
        isFn(MicroOpFpuFunct.fle),
        byPrec(dBits?.le, sBits.le).zeroExtend(mxlen.size),
        res,
      );
      res = mux(
        isFn(MicroOpFpuFunct.flt),
        byPrec(dBits?.lt, sBits.lt).zeroExtend(mxlen.size),
        res,
      );
      res = mux(
        isFn(MicroOpFpuFunct.feq),
        byPrec(dBits?.eq, sBits.eq).zeroExtend(mxlen.size),
        res,
      );
      // The two shared multi-cycle outputs, selected by function. With D this
      // one f64 value also feeds the single narrowing below, so the result mux
      // is built once instead of once per unit.
      final isSqrtRes = fpIsSqrt;
      // Every arithmetic function reads the one iterative unit, so the mop
      // parks on it whatever the form.
      fpIsArith =
          (isMulFn |
                  isDivFn |
                  isFmaFn |
                  isCvtFn |
                  isFn(MicroOpFpuFunct.fsub) |
                  isFn(MicroOpFpuFunct.fadd))
              .named('fpIsArith');
      final arithD = hasDp
          ? mux(isSqrtRes, _fpSqrtD!, _fpArithD!).named('fpArithSel')
          : null;
      res = mux(
        isFn(MicroOpFpuFunct.fcvtDW) | isFn(MicroOpFpuFunct.fcvtSW),
        intToFp,
        res,
      );
      res = mux(
        isFn(MicroOpFpuFunct.fcvtWD) | isFn(MicroOpFpuFunct.fcvtWS),
        fit(fpToInt),
        res,
      );
      // Every arithmetic form and every precision convert reads the one
      // iterative unit, and fsqrt reads the shared root. Both already round at
      // the destination format, so this is ONE result arm with no precision
      // mux and no converter behind it.
      if (hasDp) {
        res = mux(isSqrtRes | fpIsArith, fit(arithD!), res);
      } else {
        res = mux(isSqrtRes, fit(_fpSqrtS!), res);
        res = mux(fpIsArith, fit(_fpArithS!), res);
      }
      final writesFloat =
          fpIsArith |
          fpIsSqrt |
          (fpIsIntCvt & ~isToIntFn) |
          isFn(MicroOpFpuFunct.fsgnj) |
          isFn(MicroOpFpuFunct.fsgnjn) |
          isFn(MicroOpFpuFunct.fsgnjx) |
          isFn(MicroOpFpuFunct.fmin) |
          isFn(MicroOpFpuFunct.fmax);
      fpResult = _fpMoveResult(
        _fpBoxResult(
          res,
          writesFloat &
              mux(
                isCvtFn,
                isFn(MicroOpFpuFunct.fcvtSD),
                mux(fpIsIntCvt, isFn(MicroOpFpuFunct.fcvtSW), ~dp),
              ),
        ),
      ).named('fpResult');
      final bitFlags = mux(
        isFn(MicroOpFpuFunct.feq),
        byPrec(dBits?.eqFlags, sBits.eqFlags),
        mux(
          isFn(MicroOpFpuFunct.flt) | isFn(MicroOpFpuFunct.fle),
          byPrec(dBits?.orderedCompareFlags, sBits.orderedCompareFlags),
          mux(
            isFn(MicroOpFpuFunct.fmin) | isFn(MicroOpFpuFunct.fmax),
            byPrec(dBits?.minMaxFlags, sBits.minMaxFlags),
            Const(0, width: 5),
          ),
        ),
      );
      fpResultFlags = mux(
        fpIsArith,
        _fpArith!.flags,
        mux(
          fpIsSqrt,
          _fsqrt!.flags,
          mux(
            fpIsIntCvt,
            mux(isToIntFn, fpToIntFlags, _fpIntCvt!.fpFlags),
            bitFlags,
          ),
        ),
      );
    }

    Conditional writeField(Logic field, Logic value) => Case(
      field,
      [
        CaseItem(Const(MicroOpField.rd, width: MicroOpField.width), [
          rd < value.zeroExtend(mxlen.size),
        ]),
        CaseItem(Const(MicroOpField.rs1, width: MicroOpField.width), [
          rs1 < value.zeroExtend(mxlen.size),
        ]),
        CaseItem(Const(MicroOpField.rs2, width: MicroOpField.width), [
          rs2 < value.zeroExtend(mxlen.size),
        ]),
        // The fused multiply-add third source. Built only when the ISA has an
        // r4-type op, so a core without one keeps its five-way field demux and
        // does not get an rs3 latch.
        if (hasRs3)
          CaseItem(Const(MicroOpField.rs3, width: MicroOpField.width), [
            _rs3Latch! < value.zeroExtend(mxlen.size),
          ]),
        CaseItem(Const(MicroOpField.imm, width: MicroOpField.width), [
          imm < value.zeroExtend(mxlen.size),
        ]),
        CaseItem(Const(MicroOpField.sp, width: MicroOpField.width), [
          nextSp < value.zeroExtend(mxlen.size),
        ]),
      ],
      defaultItem: [done < 1, valid < 0],
    );

    Conditional clearField(Logic field) =>
        writeField(field, readField(field, register: false));

    // Iterative multiplier for the mul family. The shared [IterativeMultiplier]
    // computes the full 2*XLEN unsigned product over a few cycles (one chunk-
    // multiply reused per cycle) instead of a single-cycle partial-product tree.
    // A mul/mulh* mop holds [_imulStart] while resident (operands stable, mopStep
    // frozen) and reads back the product. mul/mulw/mulh* flavors derive from that
    // registered product: a slice for low/word/high-unsigned, plus the two
    // sign-correction subtracts for signed-high. Mirrors idivArm's handshake.
    final mulA = aluA;
    final mulB = aluB;
    // mul family present whenever the ISA has M. With useIterativeMul the product
    // comes from _imul; otherwise a single-cycle combinational unsigned product.
    // mulw/mulh* flavors derive identically from the 2w-bit product either way.
    final hasMul = microcode.isa.extensions.any((e) => e.name == 'M');
    Logic? mulLowR, mulwR, mulhSSR, mulhSUR, mulhUUR;
    if (hasMul) {
      final w = mxlen.size;
      final z = Const(0, width: w);
      final prod = _imul != null
          ? _imul!
                .product // 2w-bit unsigned product (multi-cycle)
          : (mulA.zeroExtend(w * 2) *
                mulB.zeroExtend(w * 2)); // single-cycle unsigned product
      mulLowR = prod.slice(w - 1, 0);
      mulwR = mulLowR.slice(31, 0).signExtend(w);
      mulhUUR = prod.slice(w * 2 - 1, w);
      // Signed-high corrections: MULHSU treats a as signed, b as unsigned; if a
      // is negative subtract b from the high word. MULH treats both signed; the
      // extra correction for b negative subtracts a.
      mulhSUR = mulhUUR - mux(mulA[w - 1], mulB, z);
      mulhSSR = mulhSUR - mux(mulB[w - 1], mulA, z);
    }

    // One mul-family arm: route to the shared IterativeMultiplier exactly like
    // idivArm routes div/rem. Hold start while resident (operands held stable
    // since mopStep does not advance), and on done commit the selected flavor of
    // the unsigned product and advance. Stub when no M.
    List<Conditional> imulArm(Logic? result) {
      if (!hasMul) {
        // No M extension: unreachable stub (the Case is fully elaborated).
        return [
          alu < Const(0, width: mxlen.size),
          mopStep < mopStep + 1,
          microcodeRead.en < 0,
        ];
      }
      if (_imul == null) {
        // Single-cycle mul: result is combinational, commit and advance now.
        return [alu < result!, mopStep < mopStep + 1, microcodeRead.en < 0];
      }
      return [
        _imulStart! < 1,
        _imulA! < mulA,
        _imulB! < mulB,
        If(
          _imul!.done,
          then: [
            alu < result!,
            _imulStart! < 0,
            mopStep < mopStep + 1,
            microcodeRead.en < 0,
          ],
        ),
      ];
    }

    // Routes a div/rem micro-op to the shared multi-cycle IterativeDivider:
    // hold start while resident, feed unsigned magnitudes (divisor forced
    // non-zero), and on done commit the sign/word/div-by-zero/overflow-fixed
    // result and advance. Reproduces the static unit's semantics. When the ISA
    // has no M extension the divider is absent and these arms are unreachable
    // stubs (still elaborated as part of the full funct Case).
    List<Conditional> idivArm({
      required bool isW,
      required bool isRem,
      required bool isSigned,
    }) {
      if (_idiv == null) {
        return [
          alu < Const(0, width: mxlen.size),
          mopStep < mopStep + 1,
          microcodeRead.en < 0,
        ];
      }
      final w = isW ? 32 : mxlen.size;
      final aOp = isW ? mulA.slice(31, 0) : mulA;
      final bOp = isW ? mulB.slice(31, 0) : mulB;
      final aMag = isSigned ? bmAbs(aOp, w) : aOp;
      final bMag = isSigned ? bmAbs(bOp, w) : bOp;
      final zw = Const(0, width: w);
      final dividend = aMag.zeroExtend(mxlen.size);
      final divisor = mux(
        bMag.eq(zw),
        Const(1, width: w),
        bMag,
      ).zeroExtend(mxlen.size);
      final q = _idiv!.quotient.slice(w - 1, 0);
      final r = _idiv!.remainder.slice(w - 1, 0);
      final resW = isRem
          ? (isSigned ? remFixupS(aOp, bOp, r, w) : remFixupU(aOp, bOp, r, w))
          : (isSigned ? divFixupS(aOp, bOp, q, w) : divFixupU(aOp, bOp, q, w));
      final result = isW ? resW.signExtend(mxlen.size) : resW;
      return [
        _idivStart! < 1,
        _idivDividend! < dividend,
        _idivDivisor! < divisor,
        If(
          _idiv!.done,
          then: [
            alu < result,
            _idivStart! < 0,
            mopStep < mopStep + 1,
            microcodeRead.en < 0,
          ],
        ),
      ];
    }

    return [
      If.block([
        Iff(mopStep.eq(0), [
          microcodeRead.en < 1,
          microcodeRead.addr <
              (instrIndex.zeroExtend(microcodeRead.addr.width) +
                  mopStep.zeroExtend(microcodeRead.addr.width)),
          done < 0,
          valid < 0,
          If(
            microcodeRead.done & microcodeRead.valid,
            then: [
              mopCount < microcodeRead.data.slice(mopCount.width - 1, 0),
              alu < 0,
              fence < 0,
              rs1 < fields['rs1']!.zeroExtend(mxlen.size),
              rs2 < fields['rs2']!.zeroExtend(mxlen.size),
              rd < fields['rd']!.zeroExtend(mxlen.size),
              imm < fields['imm']!.zeroExtend(mxlen.size),
              mopStep < 1,
              microcodeRead.en < 0,
            ],
          ),
          If(
            microcodeRead.done & ~microcodeRead.valid,
            then: [done < 1, valid < 0, microcodeRead.en < 0],
          ),
        ]),
        Iff(rs1Read.en, [
          Case(funct, [
            CaseItem(Const(ReadRegisterMicroOp.funct, width: funct.width), [
              If(
                rs1Read.done & rs1Read.valid,
                then: [
                  writeField(mop['ReadRegister']!['source']!, rs1Read.data),
                  mopStep < mopStep + 1,
                  microcodeRead.en < 0,
                  rs1Read.en < 0,
                ],
              ),
            ]),
          ]),
        ]),
        Iff(rs2Read.en, [
          Case(funct, [
            CaseItem(Const(ReadRegisterMicroOp.funct, width: funct.width), [
              If(
                rs2Read.done & rs2Read.valid,
                then: [
                  writeField(mop['ReadRegister']!['source']!, rs2Read.data),
                  mopStep < mopStep + 1,
                  microcodeRead.en < 0,
                  rs2Read.en < 0,
                ],
              ),
            ]),
          ]),
        ]),
        Iff(rdWrite.en, [
          If(
            rdWrite.done & rdWrite.valid,
            then: [mopStep < mopStep + 1, microcodeRead.en < 0, rdWrite.en < 0],
          ),
        ]),
        // Floating-point completion. The FP register file is a latency-0 flop
        // array, so data is stable in the cycle after the address registers,
        // which is the same handshake the integer ports use.
        if (fprs1Read != null)
          Iff(fprs1Read!.en, [
            Case(funct, [
              CaseItem(Const(ReadRegisterMicroOp.funct, width: funct.width), [
                If(
                  fprs1Read!.done & fprs1Read!.valid,
                  then: [
                    writeField(
                      mop['ReadRegister']!['source']!,
                      fprs1Read!.data.getRange(0, mxlen.size),
                    ),
                    mopStep < mopStep + 1,
                    microcodeRead.en < 0,
                    fprs1Read!.en < 0,
                  ],
                ),
              ]),
            ]),
          ]),
        if (fprs2Read != null)
          Iff(fprs2Read!.en, [
            Case(funct, [
              CaseItem(Const(ReadRegisterMicroOp.funct, width: funct.width), [
                If(
                  fprs2Read!.done & fprs2Read!.valid,
                  then: [
                    writeField(
                      mop['ReadRegister']!['source']!,
                      fprs2Read!.data.getRange(0, mxlen.size),
                    ),
                    mopStep < mopStep + 1,
                    microcodeRead.en < 0,
                    fprs2Read!.en < 0,
                  ],
                ),
              ]),
            ]),
          ]),
        if (fprdWrite != null)
          Iff(fprdWrite!.en, [
            If(
              fprdWrite!.done & fprdWrite!.valid,
              then: [
                mopStep < mopStep + 1,
                microcodeRead.en < 0,
                fprdWrite!.en < 0,
              ],
            ),
          ]),
        Iff(memRead.en, [
          Case(funct, [
            CaseItem(Const(MemLoadMicroOp.funct, width: funct.width), [
              If(
                memRead.done & memRead.valid,
                then: [
                  // Sign/zero-extend the loaded value by size ONCE via a size-
                  // driven data mux, then a SINGLE writeField, instead of a per-
                  // size Case replicating the wide writeField dest-demux for each
                  // of byte/half/word/dword (mux-bound). Result equals the old
                  // per-size value exactly (each arm was the same extend of the
                  // same slice).
                  writeField(
                    mop['MemLoad']!['dest']!,
                    loadSizeMux(
                      mop['MemLoad']!['size']!,
                      mop['MemLoad']!['unsigned']!,
                    ),
                  ),
                  mopStep < mopStep + 1,
                  microcodeRead.en < 0,
                  memRead.en < 0,
                ],
              ),
              If(
                memRead.done & ~memRead.valid,
                then: [
                  memRead.en < 0,
                  ...doTrap(Trap.loadPageFault, opBase + imm),
                ],
              ),
            ]),
            // Load-reserved: commit rd = sign-extended loaded value, arm the
            // reservation, then advance (via the rdWrite wrapper, or directly
            // when rd == x0).
            CaseItem(Const(LoadReservedMicroOp.funct, width: funct.width), [
              If(
                memRead.done & memRead.valid,
                then: [
                  reservationValid < 1,
                  reservationAddr < memRead.addr,
                  memRead.en < 0,
                  Case(mop['LoadReserved']!['size']!, [
                    for (final size in MicroOpMemSize.values.where(atomicSize))
                      CaseItem(Const(size.value, width: MicroOpMemSize.width), [
                        If(
                          readField(
                            commitDest,
                            register: false,
                          ).slice(4, 0).gt(0),
                          then: [
                            mirrorSp(
                              readField(
                                commitDest,
                                register: false,
                              ).slice(4, 0),
                              memRead.data
                                  .slice(size.bits - 1, 0)
                                  .signExtend(mxlen.size),
                            ),
                            rdWrite.addr <
                                readField(
                                  commitDest,
                                  register: false,
                                ).slice(4, 0),
                            rdWrite.data <
                                memRead.data
                                    .slice(size.bits - 1, 0)
                                    .signExtend(mxlen.size),
                            rdWrite.en < 1,
                          ],
                          orElse: [mopStep < mopStep + 1, microcodeRead.en < 0],
                        ),
                      ]),
                  ]),
                ],
              ),
              If(
                memRead.done & ~memRead.valid,
                then: [memRead.en < 0, ...doTrap(Trap.loadPageFault, opBase)],
              ),
            ]),
            // AMO read phase: latch the (sign-extended) old value, compute the
            // new value, and issue the write. rd + advance happen in the
            // memWrite-completion wrapper.
            CaseItem(Const(AtomicMemoryMicroOp.funct, width: funct.width), [
              If(
                memRead.done & memRead.valid,
                then: [
                  // Shared combine (amoNewX) + size-driven byte count; no
                  // per-size Case. The mem port writes only amoBytes bytes.
                  amoOld < amoOldX,
                  // Any store from this hart ends an LR/SC sequence.
                  reservationValid < 0,
                  memWrite.en < 1,
                  memWrite.addr < memRead.addr,
                  memWrite.data < [amoBytes, amoStoreVal].swizzle(),
                  memRead.en < 0,
                ],
              ),
              If(
                memRead.done & ~memRead.valid,
                // Both halves belong to the original store/AMO instruction.
                then: [memRead.en < 0, ...doTrap(Trap.storePageFault, opBase)],
              ),
            ]),
          ]),
        ]),
        Iff(memWrite.en, [
          Case(funct, [
            CaseItem(Const(MemStoreMicroOp.funct, width: funct.width), [
              If(
                memWrite.done & memWrite.valid,
                then: [
                  memWrite.en < 0,
                  mopStep < mopStep + 1,
                  microcodeRead.en < 0,
                ],
              ),
              If(
                memWrite.done & ~memWrite.valid,
                then: [
                  memWrite.en < 0,
                  ...doTrap(Trap.storePageFault, opBase + imm),
                ],
              ),
            ]),
            // AMO write phase: commit rd = old value, then advance (rdWrite
            // wrapper, or directly when rd == x0).
            CaseItem(Const(AtomicMemoryMicroOp.funct, width: funct.width), [
              If(
                memWrite.done & memWrite.valid,
                then: [
                  memWrite.en < 0,
                  If(
                    readField(commitDest, register: false).slice(4, 0).gt(0),
                    then: [
                      mirrorSp(
                        readField(commitDest, register: false).slice(4, 0),
                        scAmoVal,
                      ),
                      rdWrite.addr <
                          readField(commitDest, register: false).slice(4, 0),
                      rdWrite.data < scAmoVal,
                      rdWrite.en < 1,
                    ],
                    orElse: [mopStep < mopStep + 1, microcodeRead.en < 0],
                  ),
                ],
              ),
              If(
                memWrite.done & ~memWrite.valid,
                then: [memWrite.en < 0, ...doTrap(Trap.storePageFault, opBase)],
              ),
            ]),
            // SC hit: the store succeeded -> rd = 0, then advance.
            CaseItem(Const(StoreConditionalMicroOp.funct, width: funct.width), [
              If(
                memWrite.done & memWrite.valid,
                then: [
                  memWrite.en < 0,
                  If(
                    readField(commitDest, register: false).slice(4, 0).gt(0),
                    then: [
                      mirrorSp(
                        readField(commitDest, register: false).slice(4, 0),
                        scAmoVal,
                      ),
                      rdWrite.addr <
                          readField(commitDest, register: false).slice(4, 0),
                      rdWrite.data < scAmoVal,
                      rdWrite.en < 1,
                    ],
                    orElse: [mopStep < mopStep + 1, microcodeRead.en < 0],
                  ),
                ],
              ),
              If(
                memWrite.done & ~memWrite.valid,
                then: [memWrite.en < 0, ...doTrap(Trap.storePageFault, opBase)],
              ),
            ]),
          ]),
        ]),
        if (csrRead != null)
          Iff(csrRead.en, [
            If(
              csrRead.done & csrRead.valid,
              then: [
                writeField(mop['ReadCsr']!['source']!, csrRead.data),
                mopStep < mopStep + 1,
                microcodeRead.en < 0,
                csrRead.en < 0,
              ],
            ),
            If(csrRead.done & ~csrRead.valid, then: doTrap(Trap.illegal)),
          ]),
        if (csrWrite != null)
          Iff(csrWrite.en, [
            If(
              csrWrite.done & csrWrite.valid,
              then: [
                mopStep < mopStep + 1,
                microcodeRead.en < 0,
                csrWrite.en < 0,
              ],
            ),
            // csrrs/csrrc rs1=x0 (csrr*i uimm=0) reading a read-only CSR: the
            // write is illegal (valid=0) but the spec says these forms do not
            // write and must not trap. funct3[1] marks set/clear; instr[19:15]
            // (rs1/uimm field) == 0 is the no-write case. Suppress the trap and
            // complete (rd already has the old value from the read step).
            If(
              csrWrite.done &
                  ~csrWrite.valid &
                  fields['funct3']![1] &
                  fields['rs1']!.eq(Const(0, width: fields['rs1']!.width)),
              then: [
                mopStep < mopStep + 1,
                microcodeRead.en < 0,
                csrWrite.en < 0,
              ],
            ),
            If(
              csrWrite.done &
                  ~csrWrite.valid &
                  ~(fields['funct3']![1] &
                      fields['rs1']!.eq(Const(0, width: fields['rs1']!.width))),
              then: doTrap(Trap.illegal),
            ),
          ]),
        // A terminal fault may wait a cycle for retirement. Do not restart
        // its micro-op (notably SC, whose reservation has already been consumed).
        Iff(~done & (mopStep - 1).lt(mopCount), [
          If(
            microcodeRead.done & microcodeRead.valid,
            then: [
              Case(
                funct,
                [
                  CaseItem(Const(ReadRegisterMicroOp.funct, width: funct.width), [
                    If.block([
                      // An FP operand skips the x0 and x2 special cases: f0
                      // is normal storage, and there is no floating-point
                      // stack pointer. On a core without F/D the fp bit is
                      // always 0 and these terms fold away.
                      Iff(
                        ~mop['ReadRegister']!['fp']! &
                            (readField(
                                      mop['ReadRegister']!['source']!,
                                    ).zeroExtend(mxlen.size) +
                                    mop['ReadRegister']!['offset']!)
                                .slice(4, 0)
                                .eq(Const(Register.x0.value, width: 5)),
                        [mopStep < mopStep + 1, microcodeRead.en < 0],
                      ),
                      Iff(
                        ~mop['ReadRegister']!['fp']! &
                            (readField(
                                      mop['ReadRegister']!['source']!,
                                    ).zeroExtend(mxlen.size) +
                                    mop['ReadRegister']!['offset']!)
                                .slice(4, 0)
                                .eq(Const(Register.x2.value, width: 5)),
                        [
                          writeField(
                            mop['ReadRegister']!['source']!,
                            currentSp,
                          ),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      Else([
                        If(
                          mop['ReadRegister']!['source']!.eq(
                            Const(
                              MicroOpSource.rs2,
                              width: MicroOpSource.width,
                            ),
                          ),
                          then: [
                            if (fprs2Read != null)
                              If(
                                mop['ReadRegister']!['fp']!,
                                then: [
                                  fprs2Read!.en < 1,
                                  fprs2Read!.addr <
                                      (readField(
                                                mop['ReadRegister']!['source']!,
                                                register: false,
                                              ).zeroExtend(mxlen.size) +
                                              mop['ReadRegister']!['offset']!)
                                          .slice(4, 0),
                                ],
                                orElse: [
                                  rs2Read.en < 1,
                                  rs2Read.addr <
                                      (readField(
                                                mop['ReadRegister']!['source']!,
                                                register: false,
                                              ).zeroExtend(mxlen.size) +
                                              mop['ReadRegister']!['offset']!)
                                          .slice(4, 0),
                                ],
                              )
                            else ...[
                              rs2Read.en < 1,
                              rs2Read.addr <
                                  (readField(
                                            mop['ReadRegister']!['source']!,
                                            register: false,
                                          ).zeroExtend(mxlen.size) +
                                          mop['ReadRegister']!['offset']!)
                                      .slice(4, 0),
                            ],
                          ],
                          orElse: [
                            if (fprs1Read != null)
                              If(
                                mop['ReadRegister']!['fp']!,
                                then: [
                                  fprs1Read!.en < 1,
                                  fprs1Read!.addr <
                                      (readField(
                                                mop['ReadRegister']!['source']!,
                                                register: false,
                                              ).zeroExtend(mxlen.size) +
                                              mop['ReadRegister']!['offset']!)
                                          .slice(4, 0),
                                ],
                                orElse: [
                                  rs1Read.en < 1,
                                  rs1Read.addr <
                                      (readField(
                                                mop['ReadRegister']!['source']!,
                                                register: false,
                                              ).zeroExtend(mxlen.size) +
                                              mop['ReadRegister']!['offset']!)
                                          .slice(4, 0),
                                ],
                              )
                            else ...[
                              rs1Read.en < 1,
                              rs1Read.addr <
                                  (readField(
                                            mop['ReadRegister']!['source']!,
                                            register: false,
                                          ).zeroExtend(mxlen.size) +
                                          mop['ReadRegister']!['offset']!)
                                      .slice(4, 0),
                            ],
                          ],
                        ),
                      ]),
                    ]),
                  ]),
                  CaseItem(Const(WriteRegisterMicroOp.funct, width: funct.width), [
                    If(
                      // An FP destination skips the x0 and x2 special cases: f0
                      // is normal storage, and there is no floating-point stack
                      // pointer. On a core without F/D the fp bit is always 0
                      // and these terms fold away.
                      ~mop['WriteRegister']!['fp']! &
                          (readField(
                                mop['WriteRegister']!['field']!,
                                register: false,
                              ).zeroExtend(mxlen.size))
                              .slice(4, 0)
                              .eq(Const(Register.x0.value, width: 5)),
                      then: [mopStep < mopStep + 1, microcodeRead.en < 0],
                      orElse: [
                        // Mirror x2 (sp) writes to the fast-path nextSp, but x2
                        // is a real GPR too: it must ALSO take the normal
                        // regfile write below (whose rdWrite handshake advances
                        // mopStep). Setting nextSp alone left no mopStep advance
                        // and hung the core on any x2 write.
                        If(
                          ~mop['WriteRegister']!['fp']! &
                              (readField(
                                    mop['WriteRegister']!['field']!,
                                    register: false,
                                  ).zeroExtend(mxlen.size))
                                  .slice(4, 0)
                                  .eq(Const(Register.x2.value, width: 5)),
                          then: [
                            nextSp <
                                (sharedSourceVal +
                                    mop['WriteRegister']!['valueOffset']!),
                          ],
                        ),
                        if (fprdWrite != null)
                          If(
                            mop['WriteRegister']!['fp']!,
                            then: [
                              fprdWrite!.en < 1,
                              fprdWrite!.addr <
                                  (readField(
                                    mop['WriteRegister']!['field']!,
                                    register: false,
                                  ).zeroExtend(mxlen.size)).slice(4, 0),
                              fprdWrite!.data < fpWriteData!,
                            ],
                            orElse: [
                              rdWrite.en < 1,
                              rdWrite.addr <
                                  (readField(
                                    mop['WriteRegister']!['field']!,
                                    register: false,
                                  ).zeroExtend(mxlen.size)).slice(4, 0),
                              rdWrite.data <
                                  (sharedSourceVal +
                                      mop['WriteRegister']!['valueOffset']!),
                            ],
                          )
                        else ...[
                          rdWrite.en < 1,
                          rdWrite.addr <
                              (readField(
                                mop['WriteRegister']!['field']!,
                                register: false,
                              ).zeroExtend(mxlen.size)).slice(4, 0),
                          rdWrite.data <
                              (sharedSourceVal +
                                  mop['WriteRegister']!['valueOffset']!),
                        ],
                      ],
                    ),
                  ]),
                  CaseItem(Const(AluMicroOp.funct, width: funct.width), [
                    Case(
                      mop['Alu']!['alu']!,
                      [
                        CaseItem(
                          Const(
                            MicroOpAluFunct.mul,
                            width: MicroOpAluFunct.width,
                          ),
                          imulArm(mulLowR),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.mulw,
                            width: MicroOpAluFunct.width,
                          ),
                          imulArm(mulwR),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.mulh,
                            width: MicroOpAluFunct.width,
                          ),
                          imulArm(mulhSSR),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.mulhsu,
                            width: MicroOpAluFunct.width,
                          ),
                          imulArm(mulhSUR),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.mulhu,
                            width: MicroOpAluFunct.width,
                          ),
                          imulArm(mulhUUR),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.div,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: false, isRem: false, isSigned: true),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.divu,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: false, isRem: false, isSigned: false),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.divuw,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: true, isRem: false, isSigned: false),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.divw,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: true, isRem: false, isSigned: true),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.rem,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: false, isRem: true, isSigned: true),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.remu,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: false, isRem: true, isSigned: false),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.remuw,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: true, isRem: true, isSigned: false),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.remw,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: true, isRem: true, isSigned: true),
                        ),
                      ],
                      defaultItem: [
                        // All single-cycle ALU functs (add/sub/logic/shift/
                        // compare/word/zicond) route to the shared MicrocodeAlu;
                        // only the multi-cycle mul (_imul) and div/rem
                        // (IterativeDivider) arms above are explicit.
                        alu < microcodeAlu,
                        mopStep < mopStep + 1,
                        microcodeRead.en < 0,
                      ],
                    ),
                  ]),
                  CaseItem(Const(UpdatePCMicroOp.funct, width: funct.width), [
                    nextPc <
                        (mux(
                                  mop['UpdatePC']!['absolute']!,
                                  Const(0, width: mxlen.size),
                                  currentPc,
                                ) +
                                mux(
                                  mop['UpdatePC']!['hasField']!,
                                  sharedFieldVal!,
                                  mux(
                                    mop['UpdatePC']!['hasSource']!,
                                    sharedSourceVal,
                                    mop['UpdatePC']!['offset']!,
                                  ),
                                )) &
                            ~mux(
                              mop['UpdatePC']!['align']!,
                              Const(1, width: mxlen.size),
                              Const(0, width: mxlen.size),
                            ),
                    mopStep < mopStep + 1,
                    microcodeRead.en < 0,
                  ]),
                  CaseItem(Const(MemLoadMicroOp.funct, width: funct.width), [
                    Case(mop['MemLoad']!['size']!, [
                      for (final size in MicroOpMemSize.values.where(
                        (s) => s.bytes <= mxlen.width,
                      ))
                        CaseItem(
                          Const(size.value, width: MicroOpMemSize.width),
                          [
                            If(
                              ((opBase + imm) &
                                          Const(
                                            size.bytes - 1,
                                            width: mxlen.size,
                                          ))
                                      .neq(0) &
                                  ~_misalignedLoadAllowed,
                              then: doTrap(Trap.misalignedLoad, opBase + imm),
                              orElse: [
                                if (enableMisalignedLoads)
                                  misalignedLoad <
                                      ((opBase + imm) &
                                              Const(
                                                size.bytes - 1,
                                                width: mxlen.size,
                                              ))
                                          .neq(0),
                                if (enableMisalignedLoads || exactMemoryReads)
                                  loadSize <
                                      Const(size.bytes.bitLength - 1, width: 3),
                                memRead.en < 1,
                                memRead.addr < (opBase + imm),
                              ],
                            ),
                          ],
                        ),
                    ]),
                  ]),
                  CaseItem(Const(MemStoreMicroOp.funct, width: funct.width), [
                    Case(mop['MemStore']!['size']!, [
                      for (final size in MicroOpMemSize.values.where(
                        (s) => s.bytes <= mxlen.width,
                      ))
                        CaseItem(Const(size.value, width: MicroOpMemSize.width), [
                          If(
                            ((opBase + imm) &
                                    Const(size.bytes - 1, width: mxlen.size))
                                .neq(0),
                            then: doTrap(Trap.misalignedStore, opBase + imm),
                            orElse: [
                              // Any store from this hart ends an LR/SC sequence.
                              reservationValid < 0,
                              memWrite.en < 1,
                              memWrite.addr < (opBase + imm),
                              memWrite.data <
                                  [
                                    (Const(1, width: 7) <<
                                        mop['MemStore']!['size']!),
                                    opStoreSrc,
                                  ].swizzle(),
                            ],
                          ),
                        ]),
                    ]),
                  ]),
                  // Load-reserved: issue the read (the memRead-completion wrapper
                  // writes rd, sets the reservation, and advances).
                  CaseItem(
                    Const(LoadReservedMicroOp.funct, width: funct.width),
                    [
                      Case(mop['LoadReserved']!['size']!, [
                        for (final size in MicroOpMemSize.values.where(
                          atomicSize,
                        ))
                          CaseItem(
                            Const(size.value, width: MicroOpMemSize.width),
                            [
                              If(
                                (opBase &
                                        Const(
                                          size.bytes - 1,
                                          width: mxlen.size,
                                        ))
                                    .neq(0),
                                then: doTrap(Trap.misalignedLoad, opBase),
                                orElse: [
                                  if (exactMemoryReads)
                                    loadSize <
                                        Const(
                                          size.bytes.bitLength - 1,
                                          width: 3,
                                        ),
                                  memRead.en < 1,
                                  memRead.addr < opBase,
                                ],
                              ),
                            ],
                          ),
                      ]),
                    ],
                  ),
                  // Store-conditional: on a reservation HIT, issue the write (the
                  // memWrite-completion wrapper writes rd=0 and advances); on a
                  // MISS, write rd=1 and complete here. Always clears the
                  // reservation.
                  CaseItem(
                    Const(StoreConditionalMicroOp.funct, width: funct.width),
                    [
                      Case(mop['StoreConditional']!['size']!, [
                        for (final size in MicroOpMemSize.values.where(
                          atomicSize,
                        ))
                          CaseItem(
                            Const(size.value, width: MicroOpMemSize.width),
                            [
                              If(
                                (opBase &
                                        Const(
                                          size.bytes - 1,
                                          width: mxlen.size,
                                        ))
                                    .neq(0),
                                then: doTrap(Trap.misalignedStore, opBase),
                                orElse: [
                                  reservationValid < 0,
                                  If(
                                    reservationValid &
                                        reservationAddr.eq(opBase),
                                    then: [
                                      memWrite.en < 1,
                                      // opBase IS readField(SC base) here (funct
                                      // selects StoreConditional), so reuse the
                                      // shared base read instead of two more.
                                      memWrite.addr < opBase,
                                      memWrite.data <
                                          [
                                            Const(size.bytes, width: 7),
                                            opStoreSrc,
                                          ].swizzle(),
                                    ],
                                    orElse: [
                                      // Miss: rd = 1 (fail), complete now.
                                      If(
                                        readField(
                                          mop['StoreConditional']!['dest']!,
                                          register: false,
                                        ).slice(4, 0).gt(0),
                                        then: [
                                          mirrorSp(
                                            readField(
                                              mop['StoreConditional']!['dest']!,
                                              register: false,
                                            ).slice(4, 0),
                                            Const(1, width: mxlen.size),
                                          ),
                                          rdWrite.addr <
                                              readField(
                                                mop['StoreConditional']!['dest']!,
                                                register: false,
                                              ).slice(4, 0),
                                          rdWrite.data <
                                              Const(1, width: mxlen.size),
                                          rdWrite.en < 1,
                                        ],
                                        orElse: [
                                          mopStep < mopStep + 1,
                                          microcodeRead.en < 0,
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                      ]),
                    ],
                  ),
                  // AMO: issue the read; the memRead-completion wrapper latches
                  // the old value, computes the new value and issues the write,
                  // and the memWrite-completion wrapper writes rd and advances.
                  CaseItem(
                    Const(AtomicMemoryMicroOp.funct, width: funct.width),
                    [
                      Case(mop['AtomicMemory']!['size']!, [
                        for (final size in MicroOpMemSize.values.where(
                          atomicSize,
                        ))
                          CaseItem(
                            Const(size.value, width: MicroOpMemSize.width),
                            [
                              If(
                                (opBase &
                                        Const(
                                          size.bytes - 1,
                                          width: mxlen.size,
                                        ))
                                    .neq(0),
                                then: doTrap(Trap.misalignedStore, opBase),
                                orElse: [
                                  if (exactMemoryReads)
                                    loadSize <
                                        Const(
                                          size.bytes.bitLength - 1,
                                          width: 3,
                                        ),
                                  memRead.en < 1,
                                  memRead.addr < opBase,
                                ],
                              ),
                            ],
                          ),
                      ]),
                    ],
                  ),
                  CaseItem(Const(TrapMicroOp.funct, width: funct.width), [
                    // The micro-op's own modeCause bit drives the switch: when
                    // set (ecall), rawTrap re-encodes the cause by privilege.
                    // No RTL heuristic on the cause value.
                    ...rawTrap(
                      mop['Trap']!['isInterrupt']!,
                      mop['Trap']!['causeCode']!,
                      null,
                      null,
                      mop['Trap']!['modeCause']!,
                    ),
                  ]),
                  CaseItem(Const(BranchIfMicroOp.funct, width: funct.width), [
                    // Compare the latched rs1/rs2 values DIRECTLY (the branch
                    // microcode reads both before this step). Testing the sign of
                    // the rs1-rs2 difference can't express unsigned bltu/bgeu and
                    // is wrong for signed blt/bge on overflow. Mirrors the static
                    // RiscVBranch path + fu_branch.dart.
                    Case(mop['BranchIf']!['condition']!, [
                      for (final cond in [
                        (MicroOpCondition.eq, rs1.eq(rs2)),
                        (MicroOpCondition.ne, rs1.neq(rs2)),
                        (MicroOpCondition.lt, bmSignedLt(rs1, rs2, mxlen.size)),
                        (
                          MicroOpCondition.ge,
                          ~bmSignedLt(rs1, rs2, mxlen.size),
                        ),
                        (MicroOpCondition.ltu, rs1.lt(rs2)),
                        (MicroOpCondition.geu, ~rs1.lt(rs2)),
                      ])
                        CaseItem(
                          Const(cond.$1, width: MicroOpCondition.width),
                          [
                            If(
                              cond.$2,
                              then: [
                                nextPc < (currentPc + imm),
                                done < 1,
                                valid < 1,
                              ],
                              orElse: [
                                mopStep < mopStep + 1,
                                microcodeRead.en < 0,
                              ],
                            ),
                          ],
                        ),
                    ]),
                  ]),
                  CaseItem(
                    Const(WriteLinkRegisterMicroOp.funct, width: funct.width),
                    [
                      Case(mop['WriteLinkRegister']!['link']!, [
                        for (final link in MicroOpLink.values)
                          CaseItem(Const(link.value, width: MicroOpLink.width), [
                            If(
                              (link.reg != null
                                      ? Const(link.reg!.value, width: 5)
                                      : (link.source != null
                                            ? readSource(
                                                Const(
                                                  link.source!.value,
                                                  width: MicroOpSource.width,
                                                ),
                                              ).slice(4, 0)
                                            : Const(
                                                Register.x0.value,
                                                width: 5,
                                              )))
                                  .neq(Register.x0.value),
                              then: [
                                mirrorSp(
                                  (link.reg != null
                                      ? Const(link.reg!.value, width: 5)
                                      : (link.source != null
                                            ? readSource(
                                                Const(
                                                  link.source!.value,
                                                  width: MicroOpSource.width,
                                                ),
                                              ).slice(4, 0)
                                            : Const(
                                                Register.x0.value,
                                                width: 5,
                                              ))),
                                  nextPc +
                                      mop['WriteLinkRegister']!['pcOffset']!,
                                ),
                                rdWrite.en < 1,
                                rdWrite.addr <
                                    (link.reg != null
                                        ? Const(link.reg!.value, width: 5)
                                        : (link.source != null
                                              ? readSource(
                                                  Const(
                                                    link.source!.value,
                                                    width: MicroOpSource.width,
                                                  ),
                                                ).slice(4, 0)
                                              : Const(
                                                  Register.x0.value,
                                                  width: 5,
                                                ))),
                                rdWrite.data <
                                    (nextPc +
                                        mop['WriteLinkRegister']!['pcOffset']!),
                              ],
                              // rd == x0: a no-link jump (`tail`/`jr`). No write
                              // issues, so the rdWrite.done handshake that
                              // advances mopStep never fires; advance directly
                              // here or the FSM hangs on the jump.
                              orElse: [
                                mopStep < mopStep + 1,
                                microcodeRead.en < 0,
                              ],
                            ),
                          ]),
                      ]),
                    ],
                  ),
                  CaseItem(Const(FenceMicroOp.funct, width: funct.width), [
                    rs1Read.en < 0,
                    rs2Read.en < 0,
                    if (csrRead != null) csrRead.en < 0,
                    if (csrWrite != null) csrWrite.en < 0,
                    memRead.en < 0,
                    memWrite.en < 0,
                    rdWrite.en < 0,
                    fence < 1,
                    mopStep < mopStep + 1,
                    microcodeRead.en < 0,
                  ]),
                  if (mop.containsKey('ValidateField'))
                    CaseItem(
                      Const(ValidateFieldMicroOp.funct, width: funct.width),
                      [
                        Case(mop['ValidateField']!['condition']!, [
                          CaseItem(
                            Const(
                              MicroOpCondition.eq,
                              width: MicroOpCondition.width,
                            ),
                            [
                              If(
                                readField(
                                  mop['ValidateField']!['field']!,
                                ).eq(mop['ValidateField']!['value']!),
                                then: [
                                  mopStep < mopStep + 1,
                                  microcodeRead.en < 0,
                                ],
                                orElse: doTrap(Trap.illegal),
                              ),
                            ],
                          ),
                          CaseItem(
                            Const(
                              MicroOpCondition.ne,
                              width: MicroOpCondition.width,
                            ),
                            [
                              If(
                                readField(
                                  mop['ValidateField']!['field']!,
                                ).neq(mop['ValidateField']!['value']!),
                                then: [
                                  mopStep < mopStep + 1,
                                  microcodeRead.en < 0,
                                ],
                                orElse: doTrap(Trap.illegal),
                              ),
                            ],
                          ),
                          CaseItem(
                            Const(
                              MicroOpCondition.lt,
                              width: MicroOpCondition.width,
                            ),
                            [
                              If(
                                readField(
                                  mop['ValidateField']!['field']!,
                                ).lt(mop['ValidateField']!['value']!),
                                then: [
                                  mopStep < mopStep + 1,
                                  microcodeRead.en < 0,
                                ],
                                orElse: doTrap(Trap.illegal),
                              ),
                            ],
                          ),
                          CaseItem(
                            Const(
                              MicroOpCondition.gt,
                              width: MicroOpCondition.width,
                            ),
                            [
                              If(
                                readField(
                                  mop['ValidateField']!['field']!,
                                ).gt(mop['ValidateField']!['value']!),
                                then: [
                                  mopStep < mopStep + 1,
                                  microcodeRead.en < 0,
                                ],
                                orElse: doTrap(Trap.illegal),
                              ),
                            ],
                          ),
                          CaseItem(
                            Const(
                              MicroOpCondition.ge,
                              width: MicroOpCondition.width,
                            ),
                            [
                              If(
                                readField(
                                  mop['ValidateField']!['field']!,
                                ).gte(mop['ValidateField']!['value']!),
                                then: [
                                  mopStep < mopStep + 1,
                                  microcodeRead.en < 0,
                                ],
                                orElse: doTrap(Trap.illegal),
                              ),
                            ],
                          ),
                          CaseItem(
                            Const(
                              MicroOpCondition.le,
                              width: MicroOpCondition.width,
                            ),
                            [
                              If(
                                readField(
                                  mop['ValidateField']!['field']!,
                                ).lte(mop['ValidateField']!['value']!),
                                then: [
                                  mopStep < mopStep + 1,
                                  microcodeRead.en < 0,
                                ],
                                orElse: doTrap(Trap.illegal),
                              ),
                            ],
                          ),
                        ]),
                      ],
                    ),
                  if (mop.containsKey('ModifyLatch'))
                    CaseItem(
                      Const(ModifyLatchMicroOp.funct, width: funct.width),
                      [
                        If(
                          mop['ModifyLatch']!['replace']!,
                          then: [
                            writeField(
                              mop['ModifyLatch']!['field']!,
                              sharedSourceVal,
                            ),
                            mopStep < mopStep + 1,
                            microcodeRead.en < 0,
                          ],
                          orElse: [
                            clearField(mop['ModifyLatch']!['field']!),
                            mopStep < mopStep + 1,
                            microcodeRead.en < 0,
                          ],
                        ),
                      ],
                    ),
                  if (mop.containsKey('SetField'))
                    CaseItem(Const(SetFieldMicroOp.funct, width: funct.width), [
                      writeField(
                        mop['SetField']!['field']!,
                        mop['SetField']!['value']!,
                      ),
                      mopStep < mopStep + 1,
                      microcodeRead.en < 0,
                    ]),
                  if (functEmitted(InterruptHoldMicroOp.funct))
                    CaseItem(
                      Const(InterruptHoldMicroOp.funct, width: funct.width),
                      [
                        interruptHold < 1,
                        mopStep < mopStep + 1,
                        microcodeRead.en < 0,
                      ],
                    ),
                  if (mop.containsKey('CopyField'))
                    CaseItem(
                      Const(CopyFieldMicroOp.funct, width: funct.width),
                      [
                        writeField(mop['CopyField']!['dest']!, sharedFieldVal!),
                        mopStep < mopStep + 1,
                        microcodeRead.en < 0,
                      ],
                    ),
                  if (mop.containsKey('MoveToField'))
                    CaseItem(
                      Const(SetFieldMicroOpFunct.funct, width: funct.width),
                      [
                        writeField(
                          mop['MoveToField']!['dest']!,
                          sharedSourceVal,
                        ),
                        mopStep < mopStep + 1,
                        microcodeRead.en < 0,
                      ],
                    ),
                  if (csrRead != null)
                    CaseItem(Const(ReadCsrMicroOp.funct, width: funct.width), [
                      If(
                        _virtualUserCsrBlocked,
                        then: doTrap(Trap.illegal),
                        orElse: [csrRead.en < 1, csrRead.addr < csrAddr!],
                      ),
                    ]),
                  if (csrWrite != null)
                    CaseItem(Const(WriteCsrMicroOp.funct, width: funct.width), [
                      If(
                        _virtualUserCsrBlocked,
                        then: doTrap(Trap.illegal),
                        orElse: [
                          csrWrite.en < ~_csrNoWrite,
                          If(
                            _csrNoWrite,
                            then: [mopStep < mopStep + 1, microcodeRead.en < 0],
                          ),
                          csrWrite.addr < csrAddr!,
                          csrWrite.data < sharedSourceVal,
                          // A satp write switches the address space. Both L1
                          // caches are tagged by VIRTUAL address, so every line
                          // they hold now names different memory. Pulse the same
                          // `fence` the core already routes to icFlush/dFlush
                          // instead of giving the caches a second flush source:
                          // this reuses a net that is already placed and adds
                          // only a 12-bit compare. Software need not follow a
                          // satp write with sfence.vma (Linux uses ASIDs, so it
                          // does not), which is why the caches went stale.
                          If(
                            ~_csrNoWrite &
                                csrAddr.eq(
                                  Const(_satpCsrAddress, width: csrAddr.width),
                                ),
                            then: [fence < 1],
                          ),
                        ],
                      ),
                    ]),
                  // Floating-point compute. The operands are already in the
                  // rs1/rs2/rs3 latches (the ReadRegister micro-ops before this
                  // one put them there through the FP ports), and the FP units
                  // are wired to those latches, so this arm only selects a
                  // result and commits it. ONE writeField serves every
                  // function, driven by the shared [fpResult] mux, instead of a
                  // writeField per function replicating the wide dest demux.
                  //
                  // Arithmetic, fsqrt and the integer converts are all
                  // multi-cycle: each holds the micro-op resident while its
                  // unit iterates, so it commits only when that unit reports
                  // done. The commit condition is three AND gates, which is
                  // far smaller than a second copy of the dest demux inside
                  // each branch.
                  if (hasFpu)
                    CaseItem(Const(FpuMicroOp.funct, width: funct.width), [
                      If(
                        (~fpIsArith! | _fpArith!.done) &
                            (~fpIsSqrt! | _fsqrt!.done) &
                            (~fpIsIntCvt! | _fpIntCvt!.done),
                        then: [
                          writeField(mop['FpuOp']!['dest']!, fpResult!),
                          fpFlags < fpResultFlags!,
                        ],
                      ),
                      If(
                        fpIsSqrt,
                        then: [
                          // Park on the shared root until it reports done.
                          _fsqrtStart! < 1,
                          If(
                            _fsqrt!.done,
                            then: [
                              _fsqrtStart! < 0,
                              mopStep < mopStep + 1,
                              microcodeRead.en < 0,
                            ],
                          ),
                        ],
                        orElse: [
                          If(
                            fpIsArith,
                            then: [
                              // Park on the shared add/multiply/divide unit.
                              _fpArithStart! < 1,
                              If(
                                _fpArith!.done,
                                then: [
                                  _fpArithStart! < 0,
                                  mopStep < mopStep + 1,
                                  microcodeRead.en < 0,
                                ],
                              ),
                            ],
                            orElse: [
                              If(
                                fpIsIntCvt,
                                then: [
                                  // Park on the shared integer converter.
                                  _fpIntCvtStart! < 1,
                                  If(
                                    _fpIntCvt!.done,
                                    then: [
                                      _fpIntCvtStart! < 0,
                                      mopStep < mopStep + 1,
                                      microcodeRead.en < 0,
                                    ],
                                  ),
                                ],
                                orElse: [
                                  mopStep < mopStep + 1,
                                  microcodeRead.en < 0,
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ]),
                  if (functEmitted(TlbFenceMicroOp.funct))
                    CaseItem(Const(TlbFenceMicroOp.funct, width: funct.width), [
                      // sfence.vma: pulse fence, which the core routes to the MMU
                      // fetch-TLB flush (it also harmlessly over-flushes the icache).
                      fence < 1,
                      mopStep < mopStep + 1,
                      microcodeRead.en < 0,
                    ]),
                  if (functEmitted(TlbInvalidateMicroOp.funct))
                    CaseItem(
                      Const(TlbInvalidateMicroOp.funct, width: funct.width),
                      [
                        // TODO: once MMU has a TLB
                        mopStep < mopStep + 1,
                        microcodeRead.en < 0,
                      ],
                    ),
                  // MRET/SRET. Terminal single-step: signal the return and target
                  // privilege; core.dart restores PC<-{m,s}epc, mode<-{m,s}status.xPP
                  // and pops the status stack. privilegeLevel from the micro-op
                  // (3=M, 1=S). Mirrors the static RiscVReturnOp path. Missing here
                  // once, so mret looped forever (the creek trap-return hang).
                  CaseItem(Const(ReturnMicroOp.funct, width: funct.width), [
                    output('isReturn') < 1,
                    output('returnLevel') <
                        mop['Return']!['privilegeLevel']!.zeroExtend(
                          output('returnLevel').width,
                        ),
                    done < 1,
                    valid < 1,
                  ]),
                  // wfi: treat the wait as a NOP hint and advance to the next
                  // micro-op (its microcode's UpdatePc retires at pc+4). Without
                  // this arm wfi hit the default case and stalled the core.
                  CaseItem(
                    Const(WaitForInterruptMicroOp.funct, width: funct.width),
                    [mopStep < mopStep + 1, microcodeRead.en < 0],
                  ),
                  CaseItem(Const(0, width: funct.width), []),
                ],
                defaultItem: [done < 1, valid < 0],
              ),
            ],
          ),
          If(
            microcodeRead.en & microcodeRead.done & ~microcodeRead.valid,
            then: [done < 1, valid < 0],
          ),
          If(
            ~microcodeRead.en,
            then: [
              microcodeRead.en < 1,
              microcodeRead.addr <
                  (instrIndex.zeroExtend(microcodeRead.addr.width) +
                      mopStep.zeroExtend(microcodeRead.addr.width)),
            ],
          ),
        ]),
        Else([done < 1, valid < 1]),
      ]),
    ];
  }
}

class StaticExecutionUnit extends ExecutionUnit {
  /// One [BmMulSet] per distinct operand FIELD pair: every mul-family
  /// micro-op shares a single multiplier array instead of elaborating its
  /// own (the static per-arm switch otherwise builds one per opcode). Keyed
  /// by the field enums because readField mints a fresh wire per call; the
  /// underlying field latches are the same signals across micro-ops.
  final _mulSets = <Object, BmMulSet>{};

  BmMulSet _mulSetFor(Object key, Logic a, Logic b, int w) =>
      _mulSets.putIfAbsent(key, () => BmMulSet(a, b, w));

  StaticExecutionUnit(
    super.clk,
    super.reset,
    super.enable,
    super.currentSp,
    super.currentPc,
    super.currentMode,
    super.instrIndex,
    super.instrTypeMap,
    super.fields,
    super.csrRead,
    super.csrWrite,
    super.memRead,
    super.memWrite,
    super.rs1Read,
    super.rs2Read,
    super.rdWrite, {
    super.hasSupervisor = false,
    super.enableMisalignedLoads,
    super.exactMemoryReads,
    super.loadFaultTval,
    super.hasUser = false,
    required super.microcode,
    required super.mxlen,
    super.vlen = 128,
    super.mideleg,
    super.medeleg,
    super.mtvec,
    super.stvec,
    super.interruptTake,
    super.interruptCause,
    super.virtIn,
    super.mstateen0Se0,
    super.hstateen0Se0,
    super.memFaultGuest,
    super.fetchFault,
    super.fetchAccessFault,
    super.fetchFaultTval,
    super.memAccessFault,
    super.frm,
    super.tsr,
    super.tvm,
    super.tw,
    super.fpEnabled,
    super.fpRs1Port,
    super.fpRs2Port,
    super.fpRdPort,
    super.staticInstructions = const [],
    super.counterWidth = 32,
    super.name = 'river_static_execution_unit',
  });

  @override
  List<Conditional> cycle(
    Logic instrIndex,
    Logic mopStep, {
    required Logic alu,
    required Logic rs1,
    required Logic rs2,
    required Logic rd,
    required Logic imm,
    required Map<String, Logic> fields,
    required DataPortInterface memRead,
    required DataPortInterface memWrite,
    required DataPortInterface rs1Read,
    required DataPortInterface rs2Read,
    required DataPortInterface rdWrite,
  }) {
    final csrRead = this.csrRead;
    final csrWrite = this.csrWrite;

    final maxLen = microcode.microOpSequences.values
        .map((s) => s.ops.length * 2)
        .fold(0, (a, b) => a > b ? a : b);

    Logic readSource(RiscVMicroOpSource source) {
      switch (source) {
        case RiscVMicroOpSource.imm:
          return imm;
        case RiscVMicroOpSource.alu:
          return alu;
        case RiscVMicroOpSource.rs1:
          return rs1;
        case RiscVMicroOpSource.rs2:
          return rs2;
        case RiscVMicroOpSource.rd:
          return rd;
        case RiscVMicroOpSource.pc:
          return nextPc;
      }
    }

    Logic readField(RiscVMicroOpField field, {bool register = true}) {
      switch (field) {
        case RiscVMicroOpField.rd:
          return (register ? rd : fields['rd']!).zeroExtend(mxlen.size);
        case RiscVMicroOpField.rs1:
          return (register ? rs1 : fields['rs1']!).zeroExtend(mxlen.size);
        case RiscVMicroOpField.rs2:
          return (register ? rs2 : fields['rs2']!).zeroExtend(mxlen.size);
        case RiscVMicroOpField.imm:
          return register ? imm : fields['imm']!;
        case RiscVMicroOpField.pc:
          return nextPc;
        case RiscVMicroOpField.rs3:
          return (register ? _rs3Latch! : fields['rs3']!).zeroExtend(
            mxlen.size,
          );
      }
    }

    Conditional writeField(RiscVMicroOpField field, Logic value) {
      switch (field) {
        case RiscVMicroOpField.rd:
          return rd < value.zeroExtend(mxlen.size);
        case RiscVMicroOpField.rs1:
          return rs1 < value.zeroExtend(mxlen.size);
        case RiscVMicroOpField.rs2:
          return rs2 < value.zeroExtend(mxlen.size);
        case RiscVMicroOpField.imm:
          return imm < value.zeroExtend(mxlen.size);
        case RiscVMicroOpField.pc:
          return nextPc < value.zeroExtend(mxlen.size);
        case RiscVMicroOpField.rs3:
          return _rs3Latch! < value.zeroExtend(mxlen.size);
      }
    }

    // x2 (sp) has a SHADOW copy outside the register file (`currentSp` /
    // `nextSp`), and a ReadRegister that resolves to x2 takes the shadow, so
    // the shadow IS the architectural sp for every later instruction. The
    // WriteRegister arm mirrors an x2 write into `nextSp`; the arms that drive
    // the register write port DIRECTLY (the atomic destination commits, the
    // hypervisor load, vsetvl and the link-register write) had no mirror, so
    // they left the shadow holding the OLD sp permanently. This helper adds the
    // missing mirror.
    Conditional mirrorSp(Logic destIdx, Logic value) => If(
      destIdx.eq(Const(Register.x2.value, width: 5)),
      then: [nextSp < value.zeroExtend(mxlen.size)],
    );

    final handled = microcode.execLookup.entries.where(
      (entry) => staticInstructions.isNotEmpty
          ? staticInstructions.contains(entry.value.mnemonic)
          : true,
    );

    // Operand select for the shared FP adder and multiplier. The base class
    // holds ONE adder and ONE multiplier per precision, and this unit knows
    // each operation at elaboration time, so the select is a compare of the
    // resident instruction index against the indexes whose micro-code carries
    // the matching FP function. The op index alone is enough: the shared units
    // are read only at that operation's FP micro-op step.
    if (_fpSelFma != null) {
      Logic anyOp(bool Function(RiscVFpuOp mop) want) {
        Logic hit = Const(0);
        for (final entry in handled) {
          final match = entry.value.indexedMicrocode.values.any(
            (mop) => mop is RiscVFpuOp && want(mop),
          );
          if (match) {
            hit =
                hit | instrIndex.eq(Const(entry.key, width: instrIndex.width));
          }
        }
        return hit;
      }

      Logic anyOpWith(Set<RiscVFpuFunct> want) =>
          anyOp((mop) => want.contains(mop.funct));

      final isDiv = anyOpWith({RiscVFpuFunct.fdiv});
      driveFpSelect(
        fma: anyOpWith({
          RiscVFpuFunct.fmadd,
          RiscVFpuFunct.fmsub,
          RiscVFpuFunct.fnmsub,
          RiscVFpuFunct.fnmadd,
        }),
        negA: anyOpWith({RiscVFpuFunct.fnmsub, RiscVFpuFunct.fnmadd}),
        negB: anyOpWith({
          RiscVFpuFunct.fsub,
          RiscVFpuFunct.fmsub,
          RiscVFpuFunct.fnmadd,
        }),
        div: isDiv,
        mul: anyOpWith({RiscVFpuFunct.fmul}),
        // fcvt.s.d and fcvt.d.s ask the shared unit for the OTHER format,
        // which it does as an add of the operand and a zero.
        cvt: anyOpWith({RiscVFpuFunct.fcvtSD, RiscVFpuFunct.fcvtDS}),
        // The W functs carry the L forms too; rs2 bit 1 picks between them.
        toInt: anyOpWith({RiscVFpuFunct.fcvtWS, RiscVFpuFunct.fcvtWD}),
        // The float side is binary32 for fcvt.s.w (destination) and for
        // fcvt.w.s (source) alike, so one select names both.
        fpNarrow: anyOpWith({RiscVFpuFunct.fcvtSW, RiscVFpuFunct.fcvtWS}),
        // The micro-op precision flag names the source width, so its
        // complement is exactly the "read the operand as binary32" select.
        single: anyOp((mop) => !mop.doublePrecision),
      );
    }

    return [
      Case(
        instrIndex,
        handled.map((entry) {
          final op = entry.value;
          final steps = <CaseItem>[];

          // Which micro-op fields name FP registers for this op (from its
          // RfResource declarations). ReadRegister/WriteRegister of these
          // fields route to the FP register file rather than the integer one.
          final fpFields = <RiscVMicroOpField>{};
          for (final r in op.resources) {
            if (r is RfResource && r.regfile is RiscVFloatRegFile) {
              final a = r.access;
              if (a is RfRead) {
                if (a.name == 'RS1') fpFields.add(RiscVMicroOpField.rs1);
                if (a.name == 'RS2') fpFields.add(RiscVMicroOpField.rs2);
                if (a.name == 'RS3') fpFields.add(RiscVMicroOpField.rs3);
              } else if (a is RfWrite && a.name == 'RD') {
                fpFields.add(RiscVMicroOpField.rd);
              }
            }
          }

          // Vector vsetvli: vl = min(AVL, VLMAX), VLMAX = vlen*LMUL/SEW.
          // Special-cased (its only microcode is RiscVUpdatePc): read AVL
          // from rs1, compute vl from the vtypei immediate (zimm_rs2 =
          // bits[30:20]: vsew[5:3], vlmul[2:0]), write rd=vl, advance PC.
          // VLMAX = base<<vlmul for integer LMUL (vlmul 0-3) and base>>(8-vlmul)
          // for fractional LMUL (vlmul 5/6/7 = mf8/mf4/mf2), base = vlen>>(3+vsew).
          // rs1==x0 is special: with rd!=x0 it sets vl=VLMAX; with rd==x0 it
          // keeps the current vl (vtype still updates). The micro-op loop
          // below is skipped for vsetvli.
          final isVsetvli = op.mnemonic == 'vsetvli';
          final isVle = op.mnemonic == 'vle32.v';
          final isVse = op.mnemonic == 'vse32.v';
          // OPIVV/OPIVX/OPIVI integer arithmetic. One handler serves each
          // funct3 group and reads the runtime funct6 to pick the operation,
          // so every mnemonic in the group routes here. The second operand is
          // a vreg (.vv) / scalar broadcast (.vx) / immediate broadcast (.vi).
          const vArithVV = {
            'vadd.vv',
            'vsub.vv',
            'vand.vv',
            'vor.vv',
            'vxor.vv',
          };
          const vArithVX = {'vadd.vx', 'vsub.vx'};
          const vArithVI = {'vadd.vi'};
          // vfadd and vfmul share the OPFVV handler, which selects on the
          // runtime funct6 (add=0x00, mul=0x24).
          const vFloatVV = {'vfadd.vv', 'vfmul.vv'};
          final isVArithVV = vArithVV.contains(op.mnemonic);
          final isVArithVX = vArithVX.contains(op.mnemonic);
          final isVArithVI = vArithVI.contains(op.mnemonic);
          final isVArith = isVArithVV || isVArithVX || isVArithVI;
          final isVFloat = vFloatVV.contains(op.mnemonic);
          final isVecHandled =
              isVsetvli || isVle || isVse || isVArith || isVFloat;
          if (isVsetvli) {
            final vtypei = fields['zimm_rs2']!;
            final vsew = vtypei.slice(5, 3);
            final vlmul = vtypei.slice(2, 0);
            final avlIdx = fields['rs1_uimm']!.slice(4, 0);
            final rdIdx = fields['rd']!.slice(4, 0);
            final shiftAmt = Const(3, width: 6) + vsew.zeroExtend(6);
            final base = Const(vlen, width: mxlen.size) >> shiftAmt;
            // Integer LMUL (vlmul 0-3): base<<vlmul. Fractional LMUL
            // (vlmul[2] set: 5/6/7 = mf8/mf4/mf2): base>>(8-vlmul).
            final vlmaxInt = base << vlmul.zeroExtend(mxlen.size);
            final vlmaxFrac =
                base >> (Const(8, width: 6) - vlmul.zeroExtend(6));
            final vlmax = mux(vlmul[2], vlmaxFrac, vlmaxInt);
            final rs1IsX0 = avlIdx.eq(Const(0, width: 5));
            final rdIsX0 = rdIdx.eq(Const(0, width: 5));
            final minAvl = mux(rs1Read.data.lt(vlmax), rs1Read.data, vlmax);
            // rs1!=x0: min(x[rs1], VLMAX). rs1=x0: VLMAX, or keep vl if rd=x0.
            final vl = mux(rs1IsX0, mux(rdIsX0, _vl!, vlmax), minAvl);
            steps.add(
              CaseItem(Const(1, width: maxLen.bitLength), [
                rs1Read.addr < avlIdx,
                rs1Read.en < 1,
                mopStep < mopStep + 1,
              ]),
            );
            steps.add(
              CaseItem(Const(2, width: maxLen.bitLength), [
                If(
                  rs1Read.done & rs1Read.valid,
                  then: [
                    mirrorSp(rdIdx, vl),
                    rdWrite.addr < rdIdx,
                    rdWrite.data < vl,
                    rdWrite.en < rdIdx.neq(Const(0, width: 5)),
                    // Commit vector config state for subsequent ops.
                    _vtype! < vtypei,
                    _vl! < vl,
                    // nextPc holds into the auto-done step (steps.length+1).
                    nextPc < (currentPc + Const(4, width: mxlen.size)),
                    mopStep < mopStep + 1,
                  ],
                ),
              ]),
            );
          } else if (isVle) {
            // vle32.v vd, (rs1): unit-stride load of the full VLEN-wide vreg
            // from x[rs1], as VLEN/mxlen mxlen-wide chunks. For VLEN=128 /
            // rv64 that's 2 chunks: base is captured in `alu`, chunk 0 in
            // `rs1`, and the final step assembles vd = {chunk1, chunk0}.
            // (vl<VLMAX tail handling is the separate vl/tail polish.)
            final chunkBytes = mxlen.size ~/ 8;
            final regStride = vlen ~/ 8; // bytes per vreg
            final baseIdx = fields['rs1']!.slice(4, 0);
            final vdIdx = fields['vd_vs3']!.slice(4, 0);
            // LMUL grouping: a unit-stride load fills L=1<<vlmul consecutive
            // vregs from contiguous memory. `_vregIdx` (k) walks the group;
            // register k lives at base + k*regStride and writes vd+k. (vl<VLMAX
            // tail handling is still the separate vl/tail polish; the whole
            // group is loaded.)
            final lmaxL = mux(
              _vtype!.slice(2, 0).gte(Const(4, width: 3)),
              Const(1, width: 5),
              (Const(1, width: 5) << _vtype!.slice(2, 0).zeroExtend(5)),
            );
            final kL = _vregIdx!;
            final kOffL =
                (kL.zeroExtend(mxlen.size) *
                        Const(regStride, width: mxlen.size))
                    .slice(mxlen.size - 1, 0);
            final regBaseL = alu + kOffL; // memory base for register k
            final vdRegL = (vdIdx.zeroExtend(6) + kL.zeroExtend(6)).slice(4, 0);
            steps.add(
              CaseItem(Const(1, width: maxLen.bitLength), [
                rs1Read.addr < baseIdx,
                rs1Read.en < 1,
                mopStep < mopStep + 1,
              ]),
            );
            steps.add(
              CaseItem(Const(2, width: maxLen.bitLength), [
                If(
                  rs1Read.done & rs1Read.valid,
                  then: [
                    alu < rs1Read.data, // base (held across the group)
                    mopStep < mopStep + 1,
                  ],
                ),
              ]),
            );
            // Step 3 (per-register loop target): issue chunk 0 for reg k.
            steps.add(
              CaseItem(Const(3, width: maxLen.bitLength), [
                memRead.addr < regBaseL,
                if (exactMemoryReads)
                  loadSize < Const(chunkBytes.bitLength - 1, width: 3),
                memRead.en < 1,
                mopStep < mopStep + 1,
              ]),
            );
            steps.add(
              CaseItem(Const(4, width: maxLen.bitLength), [
                If(
                  memRead.done & memRead.valid,
                  then: [
                    rs1 < memRead.data, // chunk 0
                    memRead.addr <
                        (regBaseL + Const(chunkBytes, width: mxlen.size)),
                    if (exactMemoryReads)
                      loadSize < Const(chunkBytes.bitLength - 1, width: 3),
                    memRead.en < 1, // chunk 1
                    mopStep < mopStep + 1,
                  ],
                ),
              ]),
            );
            steps.add(
              CaseItem(Const(5, width: maxLen.bitLength), [
                If(
                  memRead.done & memRead.valid,
                  then: [
                    vrdWrite!.addr < vdRegL,
                    // {chunk1 (high), chunk0 (low)} = full vreg.
                    vrdWrite!.data <
                        [memRead.data, rs1.slice(mxlen.size - 1, 0)].swizzle(),
                    vrdWrite!.en < 1,
                    // Deassert the read enable so the next register's chunk-0
                    // issue (step 3) is a clean rising edge: the memory only
                    // latches a fresh request on en 0->1. Holding en high and
                    // only changing the address streams stale data (the k>0
                    // load otherwise consumed the previous register's chunk).
                    memRead.en < 0,
                    If(
                      (kL.zeroExtend(5) + Const(1, width: 5)).lt(lmaxL),
                      then: [
                        // Loop to step 1 (re-read base): re-reading the GPR
                        // base is idempotent and lets _vregIdx settle before
                        // the address recomputes.
                        _vregIdx! < (kL + Const(1, width: 4)),
                        mopStep < Const(1, width: maxLen.bitLength),
                      ],
                      orElse: [
                        _vregIdx! < Const(0, width: 4),
                        nextPc < (currentPc + Const(4, width: mxlen.size)),
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ],
                ),
              ]),
            );
          } else if (isVse) {
            // vse32.v vs3, (rs1): store the full VLEN-wide vreg to x[rs1] as
            // VLEN/mxlen sized dword chunks (2 for VLEN=128/rv64). Base in
            // `alu`; vs3 held in vrs1Read across the chunk writes.
            final chunkBytes = mxlen.size ~/ 8;
            final regStride = vlen ~/ 8; // bytes per vreg
            final baseIdx = fields['rs1']!.slice(4, 0);
            final vs3Idx = fields['vd_vs3']!.slice(4, 0);
            // sized-store data {size=8 (dword), value} for a vreg slice.
            Logic stData(Logic v) => [Const(8, width: 7), v].swizzle();
            // LMUL grouping: store L=1<<vlmul consecutive vregs to contiguous
            // memory. `_vregIdx` (k) walks the group; register vs3+k stores to
            // base + k*regStride. The vreg read is re-issued per register (it
            // has 1-cycle latency, so step 3 reads, step 4 consumes).
            final lmaxS = mux(
              _vtype!.slice(2, 0).gte(Const(4, width: 3)),
              Const(1, width: 5),
              (Const(1, width: 5) << _vtype!.slice(2, 0).zeroExtend(5)),
            );
            final kS = _vregIdx!;
            final kOffS =
                (kS.zeroExtend(mxlen.size) *
                        Const(regStride, width: mxlen.size))
                    .slice(mxlen.size - 1, 0);
            final regBaseS = alu + kOffS;
            final vs3RegS = (vs3Idx.zeroExtend(6) + kS.zeroExtend(6)).slice(
              4,
              0,
            );
            steps.add(
              CaseItem(Const(1, width: maxLen.bitLength), [
                rs1Read.addr < baseIdx,
                rs1Read.en < 1,
                mopStep < mopStep + 1,
              ]),
            );
            steps.add(
              CaseItem(Const(2, width: maxLen.bitLength), [
                If(
                  rs1Read.done & rs1Read.valid,
                  then: [
                    alu < rs1Read.data, // base (held across the group)
                    mopStep < mopStep + 1,
                  ],
                ),
              ]),
            );
            // Step 3 (per-register loop target): read vreg vs3+k.
            steps.add(
              CaseItem(Const(3, width: maxLen.bitLength), [
                vrs1Read!.addr < vs3RegS,
                vrs1Read!.en < 1,
                mopStep < mopStep + 1,
              ]),
            );
            steps.add(
              CaseItem(Const(4, width: maxLen.bitLength), [
                If(
                  vrs1Read!.done & vrs1Read!.valid,
                  then: [
                    memWrite.addr < regBaseS, // chunk 0 @ regBase
                    memWrite.data < stData(vrs1Read!.data.slice(63, 0)),
                    // Any store from this hart ends an LR/SC sequence.
                    reservationValid < 0,
                    memWrite.en < 1,
                    mopStep < mopStep + 1,
                  ],
                ),
              ]),
            );
            steps.add(
              CaseItem(Const(5, width: maxLen.bitLength), [
                If(
                  memWrite.done & memWrite.valid,
                  then: [
                    // chunk 1 @ regBase + chunkBytes (vreg[127:64]).
                    memWrite.addr <
                        (regBaseS + Const(chunkBytes, width: mxlen.size)),
                    memWrite.data < stData(vrs1Read!.data.slice(127, 64)),
                    // Any store from this hart ends an LR/SC sequence.
                    reservationValid < 0,
                    memWrite.en < 1,
                    mopStep < mopStep + 1,
                  ],
                ),
              ]),
            );
            steps.add(
              CaseItem(Const(6, width: maxLen.bitLength), [
                If(
                  memWrite.done & memWrite.valid,
                  then: [
                    memWrite.en < 0,
                    If(
                      (kS.zeroExtend(5) + Const(1, width: 5)).lt(lmaxS),
                      then: [
                        // Loop to step 1 (re-read base): lets _vregIdx settle
                        // before recompute.
                        _vregIdx! < (kS + Const(1, width: 4)),
                        mopStep < Const(1, width: maxLen.bitLength),
                      ],
                      orElse: [
                        _vregIdx! < Const(0, width: 4),
                        nextPc < (currentPc + Const(4, width: mxlen.size)),
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ],
                ),
              ]),
            );
          } else if (isVArith) {
            // Integer arithmetic vd = (vs2) OP (vs1 | x[rs1] | imm5),
            // SEW-generic: the lane width is taken from the live vtype.vsew
            // (8<<vsew), with carry/borrow isolated at lane boundaries for
            // add/sub and and/or/xor done full-width. LMUL grouping below.
            // The vs1 field [19:15] is vs1 (.vv) / rs1 (.vx) / imm5 (.vi).
            final src1Idx = fields['vs1']!.slice(4, 0);
            final vs2Idx = fields['vs2']!.slice(4, 0);
            final vdIdx = fields['vd']!.slice(4, 0);
            // SEW-generic segmented op: build per-lane results for a given
            // lane width (carries isolated at lane boundaries).
            final vsew = _vtype!.slice(5, 3); // SEW = 8 << vsew
            // LMUL grouping: the op spans L = 1<<vlmul consecutive vregs
            // (integer LMUL m1/m2/m4/m8; fractional LMUL uses 1 reg). `_vregIdx`
            // (k, 0..L-1) walks the group; per-register operand/dest addresses
            // are (baseField + k) wrapped to 5 bits. The 3-step read-compute-
            // write FSM loops once per register.
            final vlmulF = _vtype!.slice(2, 0);
            final lmax = mux(
              vlmulF.gte(Const(4, width: 3)),
              Const(1, width: 5),
              (Const(1, width: 5) << vlmulF.zeroExtend(5)),
            );
            final k = _vregIdx!; // 4-bit register index within the group
            Logic regAddr(Logic base) =>
                (base.zeroExtend(6) + k.zeroExtend(6)).slice(4, 0);
            final vs2Reg = regAddr(vs2Idx);
            final vs1Reg = regAddr(src1Idx);
            final vdReg = regAddr(vdIdx);
            // Elements per register at the live SEW (= VLEN / SEW).
            final epr =
                (Const(vlen, width: 16) >>
                        (Const(3, width: 4) + vsew.zeroExtend(4)))
                    .zeroExtend(_vl!.width);
            Logic seg(
              int laneW,
              Logic a,
              Logic b,
              Logic Function(Logic, Logic) f,
            ) {
              final lanes = <Logic>[];
              for (var lo = 0; lo + laneW <= vlen; lo += laneW) {
                lanes.add(
                  f(a.slice(lo + laneW - 1, lo), b.slice(lo + laneW - 1, lo)),
                );
              }
              return lanes.reversed.toList().swizzle();
            }

            // Select lane width from the live vsew (default 32).
            Logic segSew(Logic a, Logic b, Logic Function(Logic, Logic) f) =>
                mux(
                  vsew.eq(Const(0, width: 3)),
                  seg(8, a, b, f),
                  mux(
                    vsew.eq(Const(1, width: 3)),
                    seg(16, a, b, f),
                    mux(
                      vsew.eq(Const(3, width: 3)),
                      seg(64, a, b, f),
                      seg(32, a, b, f),
                    ),
                  ),
                );

            // Op from the runtime funct6 (the collided mnemonic is always
            // 'vadd.*'). a = vs2, b = the second operand. funct6: add=0x00,
            // sub=0x02, and=0x09, or=0x0A, xor=0x0B. and/or/xor are
            // SEW-independent (full-width bitwise).
            final f6 = fields['funct6']!;
            Logic f6eq(int v) => f6.eq(Const(v, width: f6.width));
            // Per-lane shift amount = low log2(SEW) bits of b (SEW = x.width).
            Logic sll(Logic x, Logic y) =>
                x << y.slice(x.width.bitLength - 2, 0);
            Logic srl(Logic x, Logic y) =>
                x >>> y.slice(x.width.bitLength - 2, 0);
            Logic arith(Logic a, Logic b) => mux(
              f6eq(0x02),
              segSew(a, b, (x, y) => x - y), // vsub
              mux(
                f6eq(0x09),
                a & b, // vand (SEW-independent)
                mux(
                  f6eq(0x0A),
                  a | b, // vor
                  mux(
                    f6eq(0x0B),
                    a ^ b, // vxor
                    mux(
                      f6eq(0x04),
                      segSew(a, b, (x, y) => mux(x.lt(y), x, y)), // vminu
                      mux(
                        f6eq(0x05),
                        segSew(
                          a,
                          b,
                          (x, y) => mux(bmSignedLt(x, y, x.width), x, y),
                        ),
                        mux(
                          f6eq(0x06),
                          segSew(a, b, (x, y) => mux(x.lt(y), y, x)), // vmaxu
                          mux(
                            f6eq(0x07),
                            segSew(
                              a,
                              b,
                              (x, y) => mux(bmSignedLt(x, y, x.width), y, x),
                            ),
                            mux(
                              f6eq(0x25),
                              segSew(a, b, sll), // vsll
                              mux(
                                f6eq(0x28),
                                segSew(a, b, srl), // vsrl
                                segSew(a, b, (x, y) => x + y), // 0x00 = vadd
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );

            // Broadcast a 32-bit scalar to every SEW=32 lane.
            Logic bcast(Logic s32) => List.filled(vlen ~/ 32, s32).swizzle();
            // .vi immediate: imm5 in the vs1 field, sign-extended to 32.
            final immB = bcast(fields['vs1']!.slice(4, 0).signExtend(32));

            steps.add(
              CaseItem(Const(1, width: maxLen.bitLength), [
                vrs2Read!.addr < vs2Reg,
                vrs2Read!.en < 1,
                if (isVArithVV) ...[vrs1Read!.addr < vs1Reg, vrs1Read!.en < 1],
                if (isVArithVX) ...[rs1Read.addr < src1Idx, rs1Read.en < 1],
                mopStep < mopStep + 1,
              ]),
            );
            final src1Ready = isVArithVV
                ? (vrs1Read!.done & vrs1Read!.valid)
                : isVArithVX
                ? (rs1Read.done & rs1Read.valid)
                : Const(1); // .vi: immediate, no read
            final b = isVArithVV
                ? vrs1Read!.data
                : isVArithVX
                ? bcast(rs1Read.data.slice(31, 0))
                : immB;
            // Step 2: capture the full-width result. Step 3 reads the old vd
            // and merges: active lanes (low vl*SEW bits) take the result,
            // tail bits stay undisturbed (matches the emulator).
            steps.add(
              CaseItem(Const(2, width: maxLen.bitLength), [
                If(
                  vrs2Read!.done & vrs2Read!.valid & src1Ready,
                  then: [
                    _vtmp! < arith(vrs2Read!.data, b),
                    // Re-point a read port to old vd; its data (the vreg
                    // read has 1-cycle latency) is consumed at step 3.
                    vrs2Read!.addr < vdReg,
                    vrs2Read!.en < 1,
                    mopStep < mopStep + 1,
                  ],
                ),
              ]),
            );
            // Per-register vl/tail mask for register k: the active elements
            // are the global indices [k*EPR, (k+1)*EPR) that are below vl, so
            // localVl = clamp(vl - k*EPR, 0, EPR), and the mask is the low
            // (localVl * SEW) bits. Register k beyond vl gets localVl=0 (mask
            // 0 -> vd undisturbed); a fully-active register gets the full mask.
            final kEpr = (k.zeroExtend(_vl!.width) * epr).slice(
              _vl!.width - 1,
              0,
            );
            final remVl = mux(
              _vl!.gt(kEpr),
              _vl! - kEpr,
              Const(0, width: _vl!.width),
            );
            final localVl = mux(remVl.gt(epr), epr, remVl);
            final shiftAmt =
                localVl << (Const(3, width: 4) + vsew.zeroExtend(4));
            final ones = Const(1, width: vlen + 1);
            final mask = ((ones << shiftAmt) - ones).slice(vlen - 1, 0);
            steps.add(
              CaseItem(Const(3, width: maxLen.bitLength), [
                // vrs2Read.data is now old vd (addr set at step 2). Merge:
                // active lanes = result, tail = undisturbed.
                vrdWrite!.addr < vdReg,
                vrdWrite!.data < ((_vtmp! & mask) | (vrs2Read!.data & ~mask)),
                vrdWrite!.en < 1,
                If(
                  (k.zeroExtend(5) + Const(1, width: 5)).lt(lmax),
                  then: [
                    // More registers in the group: advance k and restart the
                    // 3-step FSM at step 1 (mopStep holds the PC unchanged).
                    _vregIdx! < (k + Const(1, width: 4)),
                    mopStep < Const(1, width: maxLen.bitLength),
                  ],
                  orElse: [
                    _vregIdx! < Const(0, width: 4),
                    nextPc < (currentPc + Const(4, width: mxlen.size)),
                    mopStep < mopStep + 1,
                  ],
                ),
              ]),
            );
          } else if (isVFloat) {
            // OPFVV vfadd.vv / vfmul.vv: per-lane FP add or multiply via
            // ROHD-HCL units, selected by funct6 (add=0x00, mul=0x24). The
            // lane width is SEW-generic from the live vtype.vsew: SEW=32
            // (FP32) and SEW=64 (FP64) always, plus SEW=16 (FP16) when Zvfh
            // is configured (see fpLanes below).
            final vs1Idx = fields['vs1']!.slice(4, 0);
            final vs2Idx = fields['vs2']!.slice(4, 0);
            final vdIdx = fields['vd']!.slice(4, 0);
            final f6 = fields['funct6']!;
            // LMUL grouping (mirrors the integer path): the op spans
            // L=1<<vlmul consecutive vregs; `_vregIdx` (k) walks the group
            // and per-register addresses are (baseField + k)[4:0].
            final vlmulF = _vtype!.slice(2, 0);
            final lmax = mux(
              vlmulF.gte(Const(4, width: 3)),
              Const(1, width: 5),
              (Const(1, width: 5) << vlmulF.zeroExtend(5)),
            );
            final k = _vregIdx!;
            Logic regAddr(Logic base) =>
                (base.zeroExtend(6) + k.zeroExtend(6)).slice(4, 0);
            final vs2Reg = regAddr(vs2Idx);
            final vs1Reg = regAddr(vs1Idx);
            final vdReg = regAddr(vdIdx);
            // Elements per register at the live SEW (= VLEN / SEW).
            final epr =
                (Const(vlen, width: 16) >>
                        (Const(3, width: 4) +
                            _vtype!.slice(5, 3).zeroExtend(4)))
                    .zeroExtend(_vl!.width);
            // Per-lane FP add/mul for a given lane width (16, 32 or 64). All
            // widths are built and muxed on vsew (16->vsew==1, 32->2, 64->3),
            // since ROHD elaborates statically. FloatingPointAdder/Multiplier
            // are width-generic over FloatingPoint16/32/64 (Zvfh = SEW=16).
            Logic fpLanesW(Logic a, Logic b, bool mul, int laneW) {
              final lanes = <Logic>[];
              for (var lo = 0; lo + laneW <= vlen; lo += laneW) {
                FloatingPoint mk() => switch (laneW) {
                  16 => FloatingPoint16(),
                  64 => FloatingPoint64(),
                  _ => FloatingPoint32(),
                };
                final fa = mk();
                fa <= a.slice(lo + laneW - 1, lo);
                final fb = mk();
                fb <= b.slice(lo + laneW - 1, lo);
                final r = mul
                    ? FloatingPointMultiplierSimple(fa, fb).product
                    : FloatingPointAdderSinglePath(fa, fb).sum;
                lanes.add([r.sign, r.exponent, r.mantissa].swizzle());
              }
              return lanes.reversed.toList().swizzle();
            }

            final vsewF = _vtype!.slice(5, 3);
            Logic fpLanes(Logic a, Logic b, bool mul) {
              // SEW=32 (single) / SEW=64 (double) are always built.
              final base = mux(
                vsewF.eq(Const(3, width: 3)), // SEW=64 (double)
                fpLanesW(a, b, mul, 64),
                fpLanesW(a, b, mul, 32), // default SEW=32 (single)
              );
              // SEW=16 (half) lanes only when Zvfh is configured: this is a
              // Dart-level gate, so a non-Zvfh core never elaborates the FP16
              // units. Without Zvfh a SEW=16 vfadd falls through to `base`
              // (the SEW=32 datapath), which the spec never reaches anyway.
              if (!hasZvfh) return base;
              return mux(
                vsewF.eq(Const(1, width: 3)), // SEW=16 (Zvfh half-precision)
                fpLanesW(a, b, mul, 16),
                base,
              );
            }

            steps.add(
              CaseItem(Const(1, width: maxLen.bitLength), [
                vrs1Read!.addr < vs1Reg,
                vrs1Read!.en < 1,
                vrs2Read!.addr < vs2Reg,
                vrs2Read!.en < 1,
                mopStep < mopStep + 1,
              ]),
            );
            final fadd = fpLanes(vrs2Read!.data, vrs1Read!.data, false);
            final fmul = fpLanes(vrs2Read!.data, vrs1Read!.data, true);
            // Same vl/tail read-modify-write as the integer path: capture
            // the FP result, re-read old vd, merge active vs tail.
            steps.add(
              CaseItem(Const(2, width: maxLen.bitLength), [
                If(
                  vrs1Read!.done &
                      vrs1Read!.valid &
                      vrs2Read!.done &
                      vrs2Read!.valid,
                  then: [
                    _vtmp! <
                        mux(f6.eq(Const(0x24, width: f6.width)), fmul, fadd),
                    vrs2Read!.addr < vdReg, // old vd (1-cycle latency)
                    vrs2Read!.en < 1,
                    mopStep < mopStep + 1,
                  ],
                ),
              ]),
            );
            final fpVsew = _vtype!.slice(5, 3);
            // Per-register tail mask: localVl = clamp(vl - k*EPR, 0, EPR).
            final fpKEpr = (k.zeroExtend(_vl!.width) * epr).slice(
              _vl!.width - 1,
              0,
            );
            final fpRemVl = mux(
              _vl!.gt(fpKEpr),
              _vl! - fpKEpr,
              Const(0, width: _vl!.width),
            );
            final fpLocalVl = mux(fpRemVl.gt(epr), epr, fpRemVl);
            final fpShift =
                fpLocalVl << (Const(3, width: 4) + fpVsew.zeroExtend(4));
            final fpOnes = Const(1, width: vlen + 1);
            final fpMask = ((fpOnes << fpShift) - fpOnes).slice(vlen - 1, 0);
            steps.add(
              CaseItem(Const(3, width: maxLen.bitLength), [
                vrdWrite!.addr < vdReg,
                vrdWrite!.data <
                    ((_vtmp! & fpMask) | (vrs2Read!.data & ~fpMask)),
                vrdWrite!.en < 1,
                If(
                  (k.zeroExtend(5) + Const(1, width: 5)).lt(lmax),
                  then: [
                    _vregIdx! < (k + Const(1, width: 4)),
                    mopStep < Const(1, width: maxLen.bitLength),
                  ],
                  orElse: [
                    _vregIdx! < Const(0, width: 4),
                    nextPc < (currentPc + Const(4, width: mxlen.size)),
                    mopStep < mopStep + 1,
                  ],
                ),
              ]),
            );
          }

          for (final mop
              in (isVecHandled
                  ? <RiscVMicroOp>[]
                  : op.indexedMicrocode.values)) {
            final i = steps.length + 1;

            if (mop is RiscVReadRegister) {
              final isFp = fpFields.contains(mop.source);
              final addr =
                  (readField(mop.source, register: false) +
                          Const(mop.offset, width: mxlen.size))
                      .slice(4, 0);
              final port = isFp
                  ? (mop.source == RiscVMicroOpField.rs2
                        ? fprs2Read!
                        : fprs1Read!)
                  : (mop.source == RiscVMicroOpField.rs2 ? rs2Read : rs1Read);
              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  // x2/sp shortcut only applies to the integer register
                  // file; FP reads always go through the port.
                  if (isFp) ...[
                    port.addr < addr,
                    port.en < 1,
                    mopStep < mopStep + 1,
                  ] else
                    If(
                      addr.eq(Const(Register.x2.value, width: 5)),
                      then: [
                        writeField(mop.source, currentSp),
                        mopStep < mopStep + 2,
                      ],
                      orElse: [
                        port.addr < addr,
                        port.en < 1,
                        mopStep < mopStep + 1,
                      ],
                    ),
                ]),
              );

              // FP read port is FLEN(64)-wide; take the low mxlen bits for
              // the mxlen-wide intermediate (no-op on rv64; rv32 F's f32 is
              // in the low 32). #71.
              final readData = isFp
                  ? port.data.getRange(0, mxlen.size)
                  : port.data;
              steps.add(
                CaseItem(Const(i + 1, width: maxLen.bitLength), [
                  writeField(
                    mop.source,
                    readData + Const(mop.offset, width: mxlen.size),
                  ),
                  If(port.done & port.valid, then: [mopStep < mopStep + 1]),
                ]),
              );
            } else if (mop is RiscVWriteRegister) {
              final isFp = fpFields.contains(mop.dest);
              final addr =
                  (readField(mop.dest, register: false) +
                          Const(mop.valueOffset, width: mxlen.size))
                      .slice(4, 0);

              final value =
                  (readSource(mop.source) +
                  Const(mop.valueOffset, width: mxlen.size));

              final wport = isFp ? fprdWrite! : rdWrite;
              // The FP regfile is FLEN(64)-wide but values flow through the
              // mxlen-wide intermediate; resize to the write port's width at
              // the boundary (no-op on rv64 where mxlen==64). #71.
              // A single-precision datum must also be NaN-boxed: the upper
              // 32 bits of the 64-bit register go to all ones. The micro-op
              // carries the flag, because the value alone does not say how
              // wide it is.
              final wData = isFp
                  ? (mop.nanBox
                        ? [
                            Const(
                              BigInt.parse('FFFFFFFF', radix: 16),
                              width: 32,
                            ),
                            value.getRange(0, 32),
                          ].swizzle()
                        : value.zeroExtend(64))
                  : value;
              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  // Mirror sp into nextSp only for integer x2 writes.
                  if (!isFp)
                    If(
                      addr.eq(Const(Register.x2.value, width: 5)),
                      then: [nextSp < value],
                    ),
                  wport.addr < addr,
                  wport.data < wData,
                  // FP f0 is a real register (not hardwired zero), so FP
                  // writes always enable; integer x0 writes are dropped.
                  wport.en < (isFp ? Const(1) : addr.gt(0)),
                  mopStep < mopStep + 1,
                ]),
              );
            } else if (mop is RiscVAlu &&
                _kIterativeDivRem.contains(mop.funct)) {
              // Multi-cycle integer divide/remainder. Hold the shared
              // IterativeDivider's start high while this mop is resident,
              // feeding it unsigned magnitudes, and commit the sign/edge-
              // fixed result when it reports done. This is what removes the
              // eight combinational div/rem trees (the static unit's biggest
              // LUT cost). div and rem share the same iteration; signed and
              // word-width variants differ only in the pre/post fixup here.
              final f = mop.funct;
              final isW =
                  f == RiscVAluFunct.divw ||
                  f == RiscVAluFunct.divuw ||
                  f == RiscVAluFunct.remw ||
                  f == RiscVAluFunct.remuw;
              final isRem =
                  f == RiscVAluFunct.rem ||
                  f == RiscVAluFunct.remu ||
                  f == RiscVAluFunct.remw ||
                  f == RiscVAluFunct.remuw;
              final isSigned =
                  f == RiscVAluFunct.div ||
                  f == RiscVAluFunct.divw ||
                  f == RiscVAluFunct.rem ||
                  f == RiscVAluFunct.remw;
              final w = isW ? 32 : mxlen.size;
              final aOp = isW
                  ? readField(mop.a).slice(31, 0)
                  : readField(mop.a);
              final bOp = isW
                  ? readField(mop.b).slice(31, 0)
                  : readField(mop.b);
              // Feed unsigned magnitudes; force the divisor non-zero so the
              // core never divides by zero (the fixup overrides the result
              // when the original divisor is zero anyway).
              final aMag = isSigned ? bmAbs(aOp, w) : aOp;
              final bMag = isSigned ? bmAbs(bOp, w) : bOp;
              final zw = Const(0, width: w);
              final dividend = aMag.zeroExtend(mxlen.size);
              final divisor = mux(
                bMag.eq(zw),
                Const(1, width: w),
                bMag,
              ).zeroExtend(mxlen.size);
              final q = _idiv!.quotient.slice(w - 1, 0);
              final r = _idiv!.remainder.slice(w - 1, 0);
              final resW = isRem
                  ? (isSigned
                        ? remFixupS(aOp, bOp, r, w)
                        : remFixupU(aOp, bOp, r, w))
                  : (isSigned
                        ? divFixupS(aOp, bOp, q, w)
                        : divFixupU(aOp, bOp, q, w));
              final result = isW ? resW.signExtend(mxlen.size) : resW;
              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  _idivStart! < 1,
                  _idivDividend! < dividend,
                  _idivDivisor! < divisor,
                  If(
                    _idiv!.done,
                    then: [
                      alu < result,
                      _idivStart! < 0,
                      mopStep < mopStep + 1,
                    ],
                  ),
                ]),
              );
            } else if (mop is RiscVAlu) {
              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  alu <
                      (switch (mop.funct) {
                        RiscVAluFunct.add =>
                          readField(mop.a) + readField(mop.b),
                        RiscVAluFunct.sub =>
                          readField(mop.a) - readField(mop.b),
                        RiscVAluFunct.and_ =>
                          readField(mop.a) & readField(mop.b),
                        RiscVAluFunct.or_ =>
                          readField(mop.a) | readField(mop.b),
                        RiscVAluFunct.xor_ =>
                          readField(mop.a) ^ readField(mop.b),
                        // Shift amount is masked to log2(XLEN) bits (so a
                        // 6-bit RV64 shamt / a shift-imm whose funct6 bits
                        // leak into the imm field don't over-shift), and srl
                        // is a *logical* (>>>) right shift.
                        RiscVAluFunct.sll =>
                          readField(mop.a) <<
                              (readField(mop.b) &
                                  Const(mxlen.size - 1, width: mxlen.size)),
                        // Zba: shift the zero-extended low word, so the
                        // high bits of rs1 do not reach the result.
                        RiscVAluFunct.slliUw =>
                          readField(
                                mop.a,
                              ).slice(31, 0).zeroExtend(mxlen.size) <<
                              (readField(mop.b) &
                                  Const(mxlen.size - 1, width: mxlen.size)),
                        // Zbc is in no River profile, so this cannot elaborate.
                        // Fail loudly instead of building a wrong product.
                        RiscVAluFunct.clmul ||
                        RiscVAluFunct.clmulh ||
                        RiscVAluFunct.clmulr => throw UnimplementedError(
                          'Zbc ${mop.funct.name} is not implemented',
                        ),
                        RiscVAluFunct.srl =>
                          readField(mop.a) >>>
                              (readField(mop.b) &
                                  Const(mxlen.size - 1, width: mxlen.size)),
                        RiscVAluFunct.sra =>
                          readField(mop.a) >>
                              (readField(mop.b) &
                                  Const(mxlen.size - 1, width: mxlen.size)),
                        RiscVAluFunct.slt => bmSignedLt(
                          readField(mop.a),
                          readField(mop.b),
                          mxlen.size,
                        ).zeroExtend(mxlen.size),
                        RiscVAluFunct.sltu => readField(
                          mop.a,
                        ).lt(readField(mop.b)).zeroExtend(mxlen.size),
                        // The whole mul family shares one multiplier per
                        // operand pair (see BmMulSet for the identity).
                        RiscVAluFunct.mul => _mulSetFor(
                          (mop.a, mop.b),
                          readField(mop.a),
                          readField(mop.b),
                          mxlen.size,
                        ).low,
                        RiscVAluFunct.mulw => _mulSetFor(
                          (mop.a, mop.b),
                          readField(mop.a),
                          readField(mop.b),
                          mxlen.size,
                        ).low.slice(31, 0).signExtend(mxlen.size),
                        RiscVAluFunct.mulh => _mulSetFor(
                          (mop.a, mop.b),
                          readField(mop.a),
                          readField(mop.b),
                          mxlen.size,
                        ).highSS,
                        RiscVAluFunct.mulhsu => _mulSetFor(
                          (mop.a, mop.b),
                          readField(mop.a),
                          readField(mop.b),
                          mxlen.size,
                        ).highSU,
                        RiscVAluFunct.mulhu => _mulSetFor(
                          (mop.a, mop.b),
                          readField(mop.a),
                          readField(mop.b),
                          mxlen.size,
                        ).highUU,
                        // div/rem are handled by the multi-cycle
                        // IterativeDivider in the branch above
                        // (_kIterativeDivRem), never this combinational
                        // switch, so no `/`/`%` tree is elaborated here.
                        RiscVAluFunct.div ||
                        RiscVAluFunct.divu ||
                        RiscVAluFunct.divw ||
                        RiscVAluFunct.divuw ||
                        RiscVAluFunct.rem ||
                        RiscVAluFunct.remu ||
                        RiscVAluFunct.remw ||
                        RiscVAluFunct.remuw => throw StateError(
                          'div/rem (${mop.funct.name}) must use the '
                          'iterative divider path, not the combinational '
                          'ALU switch',
                        ),
                        RiscVAluFunct.addw =>
                          (readField(mop.a) + readField(mop.b))
                              .slice(31, 0)
                              .signExtend(mxlen.size),
                        RiscVAluFunct.subw =>
                          (readField(mop.a) - readField(mop.b))
                              .slice(31, 0)
                              .signExtend(mxlen.size),
                        RiscVAluFunct.sllw =>
                          (readField(mop.a) << readField(mop.b).slice(4, 0))
                              .slice(31, 0)
                              .signExtend(mxlen.size),
                        RiscVAluFunct.srlw =>
                          (readField(mop.a).slice(31, 0) >>>
                                  readField(mop.b).slice(4, 0))
                              .signExtend(mxlen.size),
                        RiscVAluFunct.sraw =>
                          (readField(mop.a).slice(31, 0) >>
                                  readField(mop.b).slice(4, 0))
                              .signExtend(mxlen.size),
                        // Zbb/Zba/Zbs/Zicond/Zcb: full set, matching the
                        // emulator. (w = mxlen.size; helpers above build the
                        // min/max, rotate, clz/ctz/cpop, orc.b, rev8 HW.)
                        RiscVAluFunct.andn =>
                          readField(mop.a) & ~readField(mop.b),
                        RiscVAluFunct.orn =>
                          readField(mop.a) | ~readField(mop.b),
                        RiscVAluFunct.xnor =>
                          ~(readField(mop.a) ^ readField(mop.b)),
                        RiscVAluFunct.sextb => readField(
                          mop.a,
                        ).slice(7, 0).signExtend(mxlen.size),
                        RiscVAluFunct.sexth => readField(
                          mop.a,
                        ).slice(15, 0).signExtend(mxlen.size),
                        RiscVAluFunct.zexth => readField(
                          mop.a,
                        ).slice(15, 0).zeroExtend(mxlen.size),
                        RiscVAluFunct.zextb => readField(
                          mop.a,
                        ).slice(7, 0).zeroExtend(mxlen.size),
                        RiscVAluFunct.zextw => readField(
                          mop.a,
                        ).slice(31, 0).zeroExtend(mxlen.size),
                        RiscVAluFunct.notOp => ~readField(mop.a),
                        RiscVAluFunct.sh1add =>
                          (readField(mop.a) << 1) + readField(mop.b),
                        RiscVAluFunct.sh2add =>
                          (readField(mop.a) << 2) + readField(mop.b),
                        RiscVAluFunct.sh3add =>
                          (readField(mop.a) << 3) + readField(mop.b),
                        // min/max (signed and unsigned)
                        RiscVAluFunct.minOp => mux(
                          bmSignedLt(
                            readField(mop.a),
                            readField(mop.b),
                            mxlen.size,
                          ),
                          readField(mop.a),
                          readField(mop.b),
                        ),
                        RiscVAluFunct.maxOp => mux(
                          bmSignedLt(
                            readField(mop.a),
                            readField(mop.b),
                            mxlen.size,
                          ),
                          readField(mop.b),
                          readField(mop.a),
                        ),
                        RiscVAluFunct.minuOp => mux(
                          readField(mop.a).lt(readField(mop.b)),
                          readField(mop.a),
                          readField(mop.b),
                        ),
                        RiscVAluFunct.maxuOp => mux(
                          readField(mop.a).lt(readField(mop.b)),
                          readField(mop.b),
                          readField(mop.a),
                        ),
                        // rotates
                        RiscVAluFunct.rol => bmRotl(
                          readField(mop.a),
                          readField(mop.b),
                          mxlen.size,
                        ),
                        RiscVAluFunct.ror => bmRotr(
                          readField(mop.a),
                          readField(mop.b),
                          mxlen.size,
                        ),
                        RiscVAluFunct.rolw => bmRotl(
                          readField(mop.a).slice(31, 0),
                          readField(mop.b).slice(31, 0),
                          32,
                        ).signExtend(mxlen.size),
                        RiscVAluFunct.rorw => bmRotr(
                          readField(mop.a).slice(31, 0),
                          readField(mop.b).slice(31, 0),
                          32,
                        ).signExtend(mxlen.size),
                        // counts
                        RiscVAluFunct.clz => bmClz(
                          readField(mop.a),
                          mxlen.size,
                        ),
                        RiscVAluFunct.ctz => bmCtz(
                          readField(mop.a),
                          mxlen.size,
                        ),
                        RiscVAluFunct.cpop => bmPopcount(
                          readField(mop.a),
                          mxlen.size,
                        ),
                        RiscVAluFunct.clzw => bmClz(
                          readField(mop.a).slice(31, 0),
                          32,
                        ).zeroExtend(mxlen.size),
                        RiscVAluFunct.ctzw => bmCtz(
                          readField(mop.a).slice(31, 0),
                          32,
                        ).zeroExtend(mxlen.size),
                        RiscVAluFunct.cpopw => bmPopcount(
                          readField(mop.a).slice(31, 0),
                          32,
                        ).zeroExtend(mxlen.size),
                        // byte ops
                        RiscVAluFunct.orcb => bmOrcb(
                          readField(mop.a),
                          mxlen.size,
                        ),
                        RiscVAluFunct.rev8 => bmRev8(
                          readField(mop.a),
                          mxlen.size,
                        ),
                        // Zba unsigned-word shift-add
                        RiscVAluFunct.adduw =>
                          readField(mop.a).slice(31, 0).zeroExtend(mxlen.size) +
                              readField(mop.b),
                        RiscVAluFunct.sh1adduw =>
                          (readField(
                                    mop.a,
                                  ).slice(31, 0).zeroExtend(mxlen.size) <<
                                  1) +
                              readField(mop.b),
                        RiscVAluFunct.sh2adduw =>
                          (readField(
                                    mop.a,
                                  ).slice(31, 0).zeroExtend(mxlen.size) <<
                                  2) +
                              readField(mop.b),
                        RiscVAluFunct.sh3adduw =>
                          (readField(
                                    mop.a,
                                  ).slice(31, 0).zeroExtend(mxlen.size) <<
                                  3) +
                              readField(mop.b),
                        // Zbs single-bit (shift amount masked to width)
                        RiscVAluFunct.bset =>
                          readField(mop.a) |
                              (Const(1, width: mxlen.size) <<
                                  (readField(mop.b) &
                                      Const(
                                        mxlen.size - 1,
                                        width: mxlen.size,
                                      ))),
                        RiscVAluFunct.bclr =>
                          readField(mop.a) &
                              ~(Const(1, width: mxlen.size) <<
                                  (readField(mop.b) &
                                      Const(
                                        mxlen.size - 1,
                                        width: mxlen.size,
                                      ))),
                        RiscVAluFunct.binv =>
                          readField(mop.a) ^
                              (Const(1, width: mxlen.size) <<
                                  (readField(mop.b) &
                                      Const(
                                        mxlen.size - 1,
                                        width: mxlen.size,
                                      ))),
                        RiscVAluFunct.bext =>
                          (readField(mop.a) >>>
                                  (readField(mop.b) &
                                      Const(
                                        mxlen.size - 1,
                                        width: mxlen.size,
                                      ))) &
                              Const(1, width: mxlen.size),
                        // Zicond
                        RiscVAluFunct.czeroEqz => mux(
                          readField(mop.b).eq(Const(0, width: mxlen.size)),
                          Const(0, width: mxlen.size),
                          readField(mop.a),
                        ),
                        RiscVAluFunct.czeroNez => mux(
                          readField(mop.b).eq(Const(0, width: mxlen.size)),
                          readField(mop.a),
                          Const(0, width: mxlen.size),
                        ),
                      }).named(
                        'alu_${op.mnemonic}_${mop.funct.name}_${mop.a.name}_${mop.b.name}',
                      ),
                  mopStep < mopStep + 1,
                ]),
              );
            } else if (mop is RiscVUpdatePc) {
              Logic value = Const(mop.offset, width: mxlen.size);
              if (mop.offsetField != null) {
                value = readField(mop.offsetField!);
              }
              if (mop.offsetSource != null) {
                value = readSource(mop.offsetSource!);
              }
              if (mop.align) value &= ~Const(1, width: mxlen.size);

              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  nextPc < (mop.absolute ? value : (currentPc + value)),
                  mopStep < mopStep + 1,
                ]),
              );
            } else if (mop is RiscVMemLoad) {
              final base = readField(mop.base);
              final addr = base + imm;

              final unaligned =
                  (addr & Const(mop.size.bytes - 1, width: mxlen.size)).neq(0);

              // Legacy reads return the aligned bus-word and select a lane
              // here. Physical-cache reads send the exact byte address/size;
              // their MMU response is already normalized to lane zero.
              final busBytes = mxlen.size ~/ 8;
              final alignedAddr =
                  addr & ~Const(busBytes - 1, width: mxlen.size);
              final byteOff = addr & Const(busBytes - 1, width: mxlen.size);
              final shifted =
                  memRead.data >> (byteOff * Const(8, width: mxlen.size));
              final raw =
                  (exactMemoryReads
                          ? memRead.data
                          : mux(
                              unaligned & _misalignedLoadAllowed,
                              memRead.data,
                              shifted,
                            ))
                      .slice(mop.size.bits - 1, 0);

              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  If(
                    unaligned & ~_misalignedLoadAllowed,
                    then: doTrap(Trap.misalignedLoad, addr, '_${op.mnemonic}'),
                    orElse: [
                      if (enableMisalignedLoads) misalignedLoad < unaligned,
                      if (enableMisalignedLoads || exactMemoryReads)
                        loadSize <
                            Const(mop.size.bytes.bitLength - 1, width: 3),
                      memRead.en < 1,
                      memRead.addr <
                          (exactMemoryReads
                              ? addr
                              : mux(
                                  unaligned & _misalignedLoadAllowed,
                                  addr,
                                  alignedAddr,
                                )),
                      mopStep < mopStep + 1,
                    ],
                  ),
                ]),
              );

              steps.add(
                CaseItem(Const(i + 1, width: maxLen.bitLength), [
                  If(
                    memRead.en & memRead.done & memRead.valid,
                    then: [
                      writeField(
                        mop.dest,
                        mop.unsigned
                            ? raw.zeroExtend(mxlen.size)
                            : raw.signExtend(mxlen.size),
                      ),
                      memRead.en < 0,
                      mopStep < mopStep + 1,
                    ],
                  ),
                  // A failed completion carries a page/guest-page or physical
                  // access fault. doTrap selects the physical access cause.
                  If(
                    memRead.en & memRead.done & ~memRead.valid,
                    then: [
                      memRead.en < 0,
                      // G-stage walk fault -> guest load page fault (21);
                      // VS/single-stage -> regular load page fault (13).
                      If(
                        memFaultGuest ?? Const(0),
                        then: doTrap(
                          Trap.loadGuestPageFault,
                          addr,
                          '_${op.mnemonic}',
                        ),
                        orElse: doTrap(
                          Trap.loadPageFault,
                          addr,
                          '_${op.mnemonic}',
                        ),
                      ),
                    ],
                  ),
                ]),
              );
            } else if (mop is RiscVMemStore) {
              final base = readField(mop.base);
              final value = readField(mop.src);
              final addr = base + imm;

              final unaligned =
                  (addr & Const(mop.size.bytes - 1, width: mxlen.size)).neq(0);

              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  If(
                    unaligned,
                    then: doTrap(Trap.misalignedStore, addr, '_${op.mnemonic}'),
                    orElse: [
                      // Any store from this hart ends an LR/SC sequence.
                      reservationValid < 0,
                      memWrite.en < 1,
                      memWrite.addr < addr,
                      // Size prefix is the byte count (1<<log2size), which
                      // core.dart decodes back to log2size, not the bit
                      // count, or sb/sh/sd would mis-size (only sw worked).
                      memWrite.data <
                          [Const(mop.size.bytes, width: 7), value].swizzle(),
                      If(
                        memWrite.done & memWrite.valid,
                        then: [memWrite.en < 0, mopStep < mopStep + 1],
                      ),
                      If(
                        memWrite.done & ~memWrite.valid,
                        then: [
                          memWrite.en < 0,
                          ...doTrap(
                            Trap.storePageFault,
                            addr,
                            '_${op.mnemonic}',
                          ),
                        ],
                      ),
                    ],
                  ),
                ]),
              );
            } else if (mop is RiscVHypervisorMemOp) {
              // HLV/HSV: load/store guest memory using the guest two-stage
              // translation (asserts memGuest so the MMU routes through
              // vsatp+hgatp even from HS-mode). Address is rs1 directly (no
              // immediate). Mirrors RiscVMemLoad/Store otherwise.
              final addr = readField(mop.base);
              final unaligned =
                  (addr & Const(mop.size.bytes - 1, width: mxlen.size)).neq(0);
              if (!mop.isStore) {
                final busBytes = mxlen.size ~/ 8;
                final alignedAddr =
                    addr & ~Const(busBytes - 1, width: mxlen.size);
                final byteOff = addr & Const(busBytes - 1, width: mxlen.size);
                final shifted =
                    memRead.data >> (byteOff * Const(8, width: mxlen.size));
                final raw = shifted.slice(mop.size.bits - 1, 0);
                steps.add(
                  CaseItem(Const(i, width: maxLen.bitLength), [
                    If(
                      unaligned,
                      then: doTrap(
                        Trap.misalignedLoad,
                        addr,
                        '_${op.mnemonic}',
                      ),
                      orElse: [
                        memRead.en < 1,
                        memRead.addr < alignedAddr,
                        output('memGuest') < 1,
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ]),
                );
                steps.add(
                  CaseItem(Const(i + 1, width: maxLen.bitLength), [
                    output('memGuest') < 1, // hold across the walk
                    If(
                      memRead.en & memRead.done & memRead.valid,
                      then: [
                        // HLV's microcode has no trailing WriteRegister, so
                        // commit the loaded value directly to rd (like AMO).
                        mirrorSp(
                          readField(mop.dest).slice(4, 0),
                          mop.unsigned
                              ? raw.zeroExtend(mxlen.size)
                              : raw.signExtend(mxlen.size),
                        ),
                        rdWrite.en < 1,
                        rdWrite.addr < readField(mop.dest).slice(4, 0),
                        rdWrite.data <
                            (mop.unsigned
                                ? raw.zeroExtend(mxlen.size)
                                : raw.signExtend(mxlen.size)),
                        memRead.en < 0,
                        mopStep < mopStep + 1,
                      ],
                    ),
                    If(
                      memRead.en & memRead.done & ~memRead.valid,
                      then: [
                        memRead.en < 0,
                        If(
                          memFaultGuest ?? Const(0),
                          then: doTrap(
                            Trap.loadGuestPageFault,
                            addr,
                            '_${op.mnemonic}',
                          ),
                          orElse: doTrap(
                            Trap.loadPageFault,
                            addr,
                            '_${op.mnemonic}',
                          ),
                        ),
                      ],
                    ),
                  ]),
                );
              } else {
                final value = readField(mop.dest); // rs2 = store data
                steps.add(
                  CaseItem(Const(i, width: maxLen.bitLength), [
                    If(
                      unaligned,
                      then: doTrap(
                        Trap.misalignedStore,
                        addr,
                        '_${op.mnemonic}',
                      ),
                      orElse: [
                        // Any store from this hart ends an LR/SC sequence.
                        reservationValid < 0,
                        memWrite.en < 1,
                        memWrite.addr < addr,
                        memWrite.data <
                            [Const(mop.size.bytes, width: 7), value].swizzle(),
                        output('memGuest') < 1,
                        If(
                          memWrite.done & memWrite.valid,
                          then: [memWrite.en < 0, mopStep < mopStep + 1],
                        ),
                        If(
                          memWrite.done & ~memWrite.valid,
                          then: [
                            memWrite.en < 0,
                            If(
                              memFaultGuest ?? Const(0),
                              then: doTrap(
                                Trap.storeGuestPageFault,
                                addr,
                                '_${op.mnemonic}',
                              ),
                              orElse: doTrap(
                                Trap.storePageFault,
                                addr,
                                '_${op.mnemonic}',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ]),
                );
              }
            } else if (mop is RiscVAtomicMemory) {
              // AMO: read-modify-write. base=rs1 (addr, no imm), src=rs2,
              // dest=rd (gets the sign-extended old value). Three steps:
              // issue read, compute+issue write, complete.
              final addr = readField(mop.base);
              final bits = mop.size.bits;
              final raw = memRead.data.slice(bits - 1, 0);
              final src = readField(mop.src).slice(bits - 1, 0);
              final newVal = (switch (mop.funct) {
                RiscVAtomicFunct.add => raw + src,
                RiscVAtomicFunct.swap => src,
                RiscVAtomicFunct.xor_ => raw ^ src,
                RiscVAtomicFunct.and_ => raw & src,
                RiscVAtomicFunct.or_ => raw | src,
                RiscVAtomicFunct.min => mux(
                  bmSignedLt(raw, src, bits),
                  raw,
                  src,
                ),
                RiscVAtomicFunct.max => mux(
                  bmSignedLt(raw, src, bits),
                  src,
                  raw,
                ),
                RiscVAtomicFunct.minu => mux(raw.lt(src), raw, src),
                RiscVAtomicFunct.maxu => mux(raw.lt(src), src, raw),
                // Zacas amocas: store src (rs2) iff the loaded value equals
                // rd's current value; otherwise leave memory unchanged (store
                // the loaded value back). rd still receives the loaded value.
                // The compare operand is rd's VALUE, not its index: the rd
                // latch holds the index (loaded at setup, never read back
                // because the shared AMO microcode has no ReadRegister(rd)),
                // so source the value over the otherwise-idle rs1 read port
                // (its address is the latched rs1, not the port), driven for
                // cas below.
                RiscVAtomicFunct.cas => mux(
                  raw.eq(rs1Read.data.slice(bits - 1, 0)),
                  src,
                  raw,
                ),
              }).named('amo_${mop.funct.name}');
              final unaligned =
                  (addr & Const(mop.size.bytes - 1, width: mxlen.size)).neq(0);

              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  If(
                    unaligned,
                    then: doTrap(Trap.misalignedStore, addr, '_${op.mnemonic}'),
                    orElse: [
                      if (exactMemoryReads)
                        loadSize <
                            Const(mop.size.bytes.bitLength - 1, width: 3),
                      memRead.en < 1,
                      memRead.addr < addr,
                      // cas needs rd's VALUE as the compare operand: read it
                      // over the idle rs1 port (held through the compute step
                      // below). Harmless for other AMOs, so gate on cas.
                      if (mop.funct == RiscVAtomicFunct.cas) ...[
                        rs1Read.en < 1,
                        rs1Read.addr <
                            readField(mop.dest, register: false).slice(4, 0),
                      ],
                      mopStep < mopStep + 1,
                    ],
                  ),
                ]),
              );

              steps.add(
                CaseItem(Const(i + 1, width: maxLen.bitLength), [
                  If(
                    memRead.en & memRead.done & memRead.valid,
                    then: [
                      memRead.en < 0,
                      // Do not change rd until the write succeeds. A failed
                      // AMO write must preserve the pre-instruction destination.
                      amoOld < raw.signExtend(mxlen.size),
                      // Issue the modified-value store.
                      // Any store from this hart ends an LR/SC sequence.
                      reservationValid < 0,
                      memWrite.en < 1,
                      memWrite.addr < addr,
                      memWrite.data <
                          [
                            Const(mop.size.bytes, width: 7),
                            newVal.zeroExtend(mxlen.size),
                          ].swizzle(),
                      mopStep < mopStep + 1,
                    ],
                  ),
                  If(
                    memRead.en & memRead.done & ~memRead.valid,
                    then: [
                      memRead.en < 0,
                      // A failed AMO read is still a store/AMO fault.
                      If(
                        memFaultGuest ?? Const(0),
                        then: doTrap(
                          Trap.storeGuestPageFault,
                          addr,
                          '_${op.mnemonic}',
                        ),
                        orElse: doTrap(
                          Trap.storePageFault,
                          addr,
                          '_${op.mnemonic}',
                        ),
                      ),
                    ],
                  ),
                ]),
              );

              steps.add(
                CaseItem(Const(i + 2, width: maxLen.bitLength), [
                  If(
                    memWrite.done & memWrite.valid,
                    then: [
                      memWrite.en < 0,
                      mirrorSp(
                        readField(mop.dest, register: false).slice(4, 0),
                        amoOld,
                      ),
                      rdWrite.addr <
                          readField(mop.dest, register: false).slice(4, 0),
                      rdWrite.data < amoOld,
                      rdWrite.en <
                          readField(
                            mop.dest,
                            register: false,
                          ).slice(4, 0).gt(0),
                      mopStep < mopStep + 1,
                    ],
                  ),
                  If(
                    memWrite.done & ~memWrite.valid,
                    then: [
                      memWrite.en < 0,
                      // G-stage walk fault -> guest store page fault (23);
                      // VS/single-stage -> regular store page fault (15).
                      If(
                        memFaultGuest ?? Const(0),
                        then: doTrap(
                          Trap.storeGuestPageFault,
                          addr,
                          '_${op.mnemonic}',
                        ),
                        orElse: doTrap(
                          Trap.storePageFault,
                          addr,
                          '_${op.mnemonic}',
                        ),
                      ),
                    ],
                  ),
                ]),
              );
            } else if (mop is RiscVLoadReserved) {
              // LR: load + set the address reservation.
              final addr = readField(mop.base);
              final bits = mop.size.bits;
              final raw = memRead.data.slice(bits - 1, 0);
              final rdIdx = readField(mop.dest, register: false).slice(4, 0);
              final unaligned =
                  (addr & Const(mop.size.bytes - 1, width: mxlen.size)).neq(0);
              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  If(
                    unaligned,
                    then: doTrap(Trap.misalignedLoad, addr, '_${op.mnemonic}'),
                    orElse: [
                      if (exactMemoryReads)
                        loadSize <
                            Const(mop.size.bytes.bitLength - 1, width: 3),
                      memRead.en < 1,
                      memRead.addr < addr,
                      mopStep < mopStep + 1,
                    ],
                  ),
                ]),
              );
              steps.add(
                CaseItem(Const(i + 1, width: maxLen.bitLength), [
                  If(
                    memRead.en & memRead.done & memRead.valid,
                    then: [
                      memRead.en < 0,
                      mirrorSp(rdIdx, raw.signExtend(mxlen.size)),
                      rdWrite.addr < rdIdx,
                      rdWrite.data < raw.signExtend(mxlen.size),
                      rdWrite.en < rdIdx.gt(0),
                      reservationValid < 1,
                      reservationAddr < addr,
                      mopStep < mopStep + 1,
                    ],
                  ),
                  If(
                    memRead.en & memRead.done & ~memRead.valid,
                    then: [
                      memRead.en < 0,
                      // G-stage walk fault -> guest load page fault (21);
                      // VS/single-stage -> regular load page fault (13).
                      If(
                        memFaultGuest ?? Const(0),
                        then: doTrap(
                          Trap.loadGuestPageFault,
                          addr,
                          '_${op.mnemonic}',
                        ),
                        orElse: doTrap(
                          Trap.loadPageFault,
                          addr,
                          '_${op.mnemonic}',
                        ),
                      ),
                    ],
                  ),
                ]),
              );
            } else if (mop is RiscVStoreConditional) {
              // SC: store iff the reservation is still valid for this addr;
              // rd=0 on success, 1 on failure. Always clears the reservation.
              final addr = readField(mop.base);
              final value = readField(mop.src);
              final rdIdx = readField(mop.dest, register: false).slice(4, 0);
              final unaligned =
                  (addr & Const(mop.size.bytes - 1, width: mxlen.size)).neq(0);
              final hit = reservationValid & reservationAddr.eq(addr);
              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  If(
                    unaligned,
                    then: doTrap(Trap.misalignedStore, addr, '_${op.mnemonic}'),
                    orElse: [
                      reservationValid < 0,
                      If(
                        hit,
                        then: [
                          memWrite.en < 1,
                          memWrite.addr < addr,
                          // Byte-count size prefix (see RiscVMemStore).
                          memWrite.data <
                              [
                                Const(mop.size.bytes, width: 7),
                                value,
                              ].swizzle(),
                          mopStep < mopStep + 1,
                        ],
                        orElse: [
                          mirrorSp(rdIdx, Const(1, width: mxlen.size)),
                          rdWrite.addr < rdIdx,
                          rdWrite.data < Const(1, width: mxlen.size),
                          rdWrite.en < rdIdx.gt(0),
                          mopStep < mopStep + 2,
                        ],
                      ),
                    ],
                  ),
                ]),
              );
              steps.add(
                CaseItem(Const(i + 1, width: maxLen.bitLength), [
                  If(
                    memWrite.done & memWrite.valid,
                    then: [
                      memWrite.en < 0,
                      mirrorSp(rdIdx, Const(0, width: mxlen.size)),
                      rdWrite.addr < rdIdx,
                      rdWrite.data < Const(0, width: mxlen.size),
                      rdWrite.en < rdIdx.gt(0),
                      mopStep < mopStep + 1,
                    ],
                  ),
                  If(
                    memWrite.done & ~memWrite.valid,
                    then: [
                      memWrite.en < 0,
                      // G-stage walk fault -> guest store page fault (23);
                      // VS/single-stage -> regular store page fault (15).
                      If(
                        memFaultGuest ?? Const(0),
                        then: doTrap(
                          Trap.storeGuestPageFault,
                          addr,
                          '_${op.mnemonic}',
                        ),
                        orElse: doTrap(
                          Trap.storePageFault,
                          addr,
                          '_${op.mnemonic}',
                        ),
                      ),
                    ],
                  ),
                ]),
              );
            } else if (mop is RiscVFpuOp) {
              // FP compute. Operands are in the rs1/rs2 latches (read
              // FP-routed); the trailing WriteRegister commits rd per
              // fpFields. Add, multiply, divide, the fused forms and the two
              // precision converts all park on the shared iterative unit;
              // fsqrt parks on the shared root; the integer converts park on
              // the shared convert unit; feq/flt/fle use a manual comparator.
              const arithFuncts = {
                RiscVFpuFunct.fadd,
                RiscVFpuFunct.fsub,
                RiscVFpuFunct.fmul,
                RiscVFpuFunct.fdiv,
                RiscVFpuFunct.fmadd,
                RiscVFpuFunct.fmsub,
                RiscVFpuFunct.fnmsub,
                RiscVFpuFunct.fnmadd,
                // A precision convert is an add of the operand and a zero,
                // rounded at the other format.
                RiscVFpuFunct.fcvtSD,
                RiscVFpuFunct.fcvtDS,
              };
              // Integer converts park on the other shared unit. The L forms
              // ride on the W functs through rs2, so these four cover them.
              const intCvtFuncts = {
                RiscVFpuFunct.fcvtWS,
                RiscVFpuFunct.fcvtWD,
                RiscVFpuFunct.fcvtSW,
                RiscVFpuFunct.fcvtDW,
              };
              if (arithFuncts.contains(mop.funct)) {
                // Multi-cycle arithmetic: park at this mopStep with the shared
                // unit started, then write the result and advance. One unit
                // serves every form; FMA retains the full product through the
                // addition and rounds only once at the destination format.
                final resultBits = _fpArithD ?? _fpArithS!;
                steps.add(
                  CaseItem(Const(i, width: maxLen.bitLength), [
                    _fpArithStart! < 1,
                    If(
                      _fpArith!.done,
                      then: [
                        writeField(
                          mop.dest,
                          _fpBoxResult(
                            resultBits.zeroExtend(mxlen.size),
                            Const(_fpSingleResult(mop) ? 1 : 0),
                          ),
                        ),
                        _fpArithStart! < 0,
                        fpFlags < _fpArith!.flags,
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ]),
                );
              } else if (intCvtFuncts.contains(mop.funct)) {
                // Multi-cycle integer convert: park at this mopStep with the
                // shared unit started, then write the result and advance. The
                // fp -> int direction reports a truncated magnitude, and the
                // per-rm rounding and the RISC-V saturation happen here.
                final srcW = mop.doublePrecision ? 64 : 32;
                final srcM = mop.doublePrecision ? 52 : 23;
                final src = _fpOperand(rs1, srcW);
                final srcExp = src.slice(srcW - 2, srcM);
                final srcMan = src.slice(srcM - 1, 0);
                final srcMax = srcExp.and();
                final Logic resultBits;
                final conversionFlags = Logic(width: 5);
                if (mop.funct == RiscVFpuFunct.fcvtWS ||
                    mop.funct == RiscVFpuFunct.fcvtWD) {
                  resultBits = roundSatFpToInt(
                    intMag: _fpIntCvt!.intMag,
                    roundBit: _fpIntCvt!.roundBit,
                    sticky: _fpIntCvt!.sticky,
                    ovf: _fpIntCvt!.overflow,
                    signBit: src[srcW - 1],
                    isNaN: srcMax & srcMan.or(),
                    isInf: srcMax & ~srcMan.or(),
                    rm: _fpControlEnabled ? _fpRm : fields['funct3']!,
                    flagsOut: conversionFlags,
                    isL: fields['rs2']![1],
                    uns: fields['rs2']![0],
                    mxlen: mxlen,
                  );
                } else {
                  resultBits = _fpBoxResult(
                    _fpIntCvt!.fpOut,
                    Const(_fpSingleResult(mop) ? 1 : 0),
                  );
                  conversionFlags <= _fpIntCvt!.fpFlags;
                }
                steps.add(
                  CaseItem(Const(i, width: maxLen.bitLength), [
                    _fpIntCvtStart! < 1,
                    If(
                      _fpIntCvt!.done,
                      then: [
                        writeField(mop.dest, resultBits),
                        _fpIntCvtStart! < 0,
                        fpFlags < conversionFlags,
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ]),
                );
              } else if (mop.funct == RiscVFpuFunct.fsqrt) {
                // Multi-cycle square root: park at this mopStep with the shared
                // root started, then write the result and advance. A single
                // root reads the same core: its operand widened on the way in
                // and it rounds once at the binary32 position on the way out.
                final resultBits = _fpSqrtD ?? _fpSqrtS!;
                steps.add(
                  CaseItem(Const(i, width: maxLen.bitLength), [
                    _fsqrtStart! < 1,
                    If(
                      _fsqrt!.done,
                      then: [
                        writeField(
                          mop.dest,
                          _fpBoxResult(
                            resultBits.zeroExtend(mxlen.size),
                            Const(_fpSingleResult(mop) ? 1 : 0),
                          ),
                        ),
                        _fsqrtStart! < 0,
                        fpFlags < _fsqrt!.flags,
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ]),
                );
              } else {
                // Bit-level FP results at this op's precision: compares
                // (feq/flt/fle write a 0/1 to an integer reg), sign
                // injection, min/max and classify. The shared [fpBitOps]
                // gives the same values to the microcoded unit.
                final w = mop.doublePrecision ? 64 : 32;
                final bits = fpBitOps(
                  _fpOperand(rs1, w),
                  _fpOperand(rs2, w),
                  w,
                );
                final cmpEq = bits.eq.zeroExtend(mxlen.size);
                final cmpLt = bits.lt.zeroExtend(mxlen.size);
                final cmpLe = bits.le.zeroExtend(mxlen.size);
                final fsgnj = bits.fsgnj;
                final fsgnjn = bits.fsgnjn;
                final fsgnjx = bits.fsgnjx;
                final fmin = bits.fmin;
                final fmax = bits.fmax;
                final fclassBits = bits.fclass.zeroExtend(mxlen.size);

                // Coerce a result arm to mxlen so the switch builds with a
                // uniform width. The double-conversion arms produce FLEN=64
                // values that are DEAD in the single-precision path (a single
                // op never has those functs) but still elaborate; on rv32 that
                // 64-bit width clashed with the 32-bit single arms (#71).
                Logic fitM(Logic x) => x.width == mxlen.size
                    ? x
                    : (x.width > mxlen.size
                          ? x.getRange(0, mxlen.size)
                          : x.zeroExtend(mxlen.size));
                final Logic result;
                if (!mop.doublePrecision) {
                  result = switch (mop.funct) {
                    RiscVFpuFunct.feq => fitM(cmpEq),
                    RiscVFpuFunct.flt => fitM(cmpLt),
                    RiscVFpuFunct.fle => fitM(cmpLe),
                    RiscVFpuFunct.fsgnj => fsgnj.zeroExtend(mxlen.size),
                    RiscVFpuFunct.fsgnjn => fsgnjn.zeroExtend(mxlen.size),
                    RiscVFpuFunct.fsgnjx => fsgnjx.zeroExtend(mxlen.size),
                    RiscVFpuFunct.fmin => fmin.zeroExtend(mxlen.size),
                    RiscVFpuFunct.fmax => fmax.zeroExtend(mxlen.size),
                    RiscVFpuFunct.fclass => fclassBits,
                    _ => readField(mop.a),
                  };
                } else {
                  result = switch (mop.funct) {
                    RiscVFpuFunct.feq => cmpEq,
                    RiscVFpuFunct.flt => cmpLt,
                    RiscVFpuFunct.fle => cmpLe,
                    RiscVFpuFunct.fsgnj => fsgnj,
                    RiscVFpuFunct.fsgnjn => fsgnjn,
                    RiscVFpuFunct.fsgnjx => fsgnjx,
                    RiscVFpuFunct.fmin => fmin,
                    RiscVFpuFunct.fmax => fmax,
                    RiscVFpuFunct.fclass => fclassBits,
                    _ => readField(mop.a),
                  };
                }
                steps.add(
                  CaseItem(Const(i, width: maxLen.bitLength), [
                    writeField(
                      mop.dest,
                      _fpMoveResult(
                        _fpBoxResult(
                          result,
                          Const(
                            w == 32 &&
                                    {
                                      RiscVFpuFunct.fsgnj,
                                      RiscVFpuFunct.fsgnjn,
                                      RiscVFpuFunct.fsgnjx,
                                      RiscVFpuFunct.fmin,
                                      RiscVFpuFunct.fmax,
                                    }.contains(mop.funct)
                                ? 1
                                : 0,
                          ),
                        ),
                      ),
                    ),
                    fpFlags <
                        switch (mop.funct) {
                          RiscVFpuFunct.feq => bits.eqFlags,
                          RiscVFpuFunct.flt ||
                          RiscVFpuFunct.fle => bits.orderedCompareFlags,
                          RiscVFpuFunct.fmin ||
                          RiscVFpuFunct.fmax => bits.minMaxFlags,
                          _ => Const(0, width: 5),
                        },
                    mopStep < mopStep + 1,
                  ]),
                );
              }
            } else if (mop is RiscVTrapOp) {
              // The micro-op's modeCause bit decides: ecall re-encodes its
              // cause by privilege (U/VU=8, HS=9, VS=10, M=11); ebreak and
              // the rest keep their fixed cause. Same switch the microcode
              // path uses, driven by the same flag.
              steps.add(
                CaseItem(
                  Const(i, width: maxLen.bitLength),
                  rawTrap(
                    Const(mop.isInterrupt ? 1 : 0),
                    Const(mop.causeCode, width: 6),
                    null,
                    '_${op.mnemonic}',
                    Const(mop.modeCause ? 1 : 0),
                  ),
                ),
              );
            } else if (mop is RiscVBranch) {
              final value = mop.offsetField != null
                  ? readField(mop.offsetField!)
                  : Const(mop.offset, width: mxlen.size);

              // Compare the two source registers directly. ROHD `.lt`/`.gte`
              // are UNSIGNED, so the old sign-of-difference test (target.lt(0))
              // was always false and broke blt/bge/bltu/bgeu. Signed needs
              // bmSignedLt; unsigned needs a real unsigned compare. Mirrors
              // fu_branch.dart.
              final lhs = readField(RiscVMicroOpField.rs1);
              final rhs = readField(RiscVMicroOpField.rs2);
              final condition = switch (mop.condition) {
                RiscVBranchCondition.eq => lhs.eq(rhs),
                RiscVBranchCondition.ne => lhs.neq(rhs),
                RiscVBranchCondition.lt => bmSignedLt(lhs, rhs, mxlen.size),
                RiscVBranchCondition.ge => ~bmSignedLt(lhs, rhs, mxlen.size),
                RiscVBranchCondition.ltu => lhs.lt(rhs),
                RiscVBranchCondition.geu => ~lhs.lt(rhs),
              };

              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  If(
                    condition,
                    // Taken: target is PC-RELATIVE (pc + offset). `value` is
                    // the offset alone; omitting `currentPc +` collapsed the
                    // target to the offset (the in-order taken-branch wedge,
                    // #69). Jumps already do currentPc + value.
                    then: [nextPc < (currentPc + value), done < 1, valid < 1],
                    orElse: [mopStep < mopStep + 1],
                  ),
                ]),
              );
            } else if (mop is RiscVWriteLinkRegister) {
              final value = nextPc + Const(mop.pcOffset, width: mxlen.size);
              final reg = readField(mop.dest).slice(4, 0);

              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  If(
                    reg.neq(Register.x0.value),
                    then: [
                      mirrorSp(reg.slice(4, 0), value),
                      rdWrite.addr < reg.slice(4, 0),
                      rdWrite.data < value,
                      rdWrite.en < 1,
                    ],
                  ),
                  mopStep < mopStep + 1,
                ]),
              );
            } else if (mop is RiscVFenceOp) {
              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  rs1Read.en < 0,
                  rs2Read.en < 0,
                  if (csrRead != null) csrRead.en < 0,
                  if (csrWrite != null) csrWrite.en < 0,
                  memRead.en < 0,
                  memWrite.en < 0,
                  rdWrite.en < 0,
                  fence < 1,
                  mopStep < mopStep + 1,
                ]),
              );
            } else if (mop is RiscVInterruptHold) {
              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  interruptHold < 1,
                  mopStep < mopStep + 1,
                ]),
              );
            } else if (mop is RiscVCopyField) {
              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  writeField(mop.dest, readField(mop.src)),
                  mopStep < mopStep + 1,
                ]),
              );
            } else if (mop is RiscVSetField) {
              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  writeField(mop.dest, readSource(mop.src)),
                  mopStep < mopStep + 1,
                ]),
              );
            } else if (mop is RiscVReadCsr && csrRead != null) {
              final rdCsrAddr = readField(mop.source).slice(11, 0);
              // VS-mode access to an HS-only hypervisor CSR (addr[11:8]==0x6,
              // the 0x6xx range), OR a VS-mode sstateen access that mstateen
              // allows but hstateen0.SE0 blocks, raises a virtual-instruction
              // exception (mstateen-blocked is illegal, handled by the CSR
              // legality path).
              final rdVViol =
                  ((virtIn ?? Const(0)) &
                      rdCsrAddr.slice(11, 8).eq(Const(0x6, width: 4))) |
                  _stateenVsViol(rdCsrAddr);
              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  If(
                    rdVViol,
                    then: doTrap(
                      Trap.virtualInstruction,
                      null,
                      '_${op.mnemonic}',
                    ),
                    orElse: [
                      If(
                        _virtualUserCsrBlocked,
                        then: doTrap(Trap.illegal, null, '_${op.mnemonic}'),
                        orElse: [
                          csrRead.en < 1,
                          csrRead.addr < rdCsrAddr,
                          mopStep < mopStep + 1,
                        ],
                      ),
                    ],
                  ),
                ]),
              );

              steps.add(
                CaseItem(Const(i + 1, width: maxLen.bitLength), [
                  If.block([
                    Iff(csrRead.en & csrRead.done & csrRead.valid, [
                      writeField(mop.source, csrRead.data),
                      mopStep < mopStep + 1,
                    ]),
                    Iff(
                      csrRead.en & csrRead.done & ~csrRead.valid,
                      doTrap(Trap.illegal, null, '_${op.mnemonic}'),
                    ),
                  ]),
                ]),
              );
            } else if (mop is RiscVWriteCsr && csrWrite != null) {
              final wrCsrAddr = readField(mop.dest).slice(11, 0);
              // csrrs/csrrc with rs1=x0 (and csrr*i with uimm=0) must NOT
              // write the CSR and must NOT trap on a read-only CSR. funct3[1]
              // marks the set/clear forms (RS/RC/RSI/RCI); instr[19:15] (the
              // rs1 / uimm field) == 0 is the no-write case. Suppress the port
              // itself: an unchanged-value write still has side effects (FS
              // dirty state for fcsr, for example).
              final csrNoWrite =
                  (fields['funct3']![1] &
                          fields['rs1']!.eq(
                            Const(0, width: fields['rs1']!.width),
                          ))
                      .named('csrNoWrite_${op.mnemonic}');
              final wrVViol =
                  ((virtIn ?? Const(0)) &
                      wrCsrAddr.slice(11, 8).eq(Const(0x6, width: 4))) |
                  _stateenVsViol(wrCsrAddr);
              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  If(
                    wrVViol,
                    then: doTrap(
                      Trap.virtualInstruction,
                      null,
                      '_${op.mnemonic}',
                    ),
                    orElse: [
                      If(
                        _virtualUserCsrBlocked,
                        then: doTrap(Trap.illegal, null, '_${op.mnemonic}'),
                        orElse: [
                          csrWrite.en < ~csrNoWrite,
                          csrWrite.addr < wrCsrAddr,
                          csrWrite.data < readSource(mop.source),
                          mopStep <
                              mopStep +
                                  mux(
                                    csrNoWrite,
                                    Const(2, width: mopStep.width),
                                    Const(1, width: mopStep.width),
                                  ),
                          // See the dynamic path: a satp write invalidates
                          // both virtually tagged L1 caches.
                          If(
                            ~csrNoWrite &
                                wrCsrAddr.eq(
                                  Const(
                                    _satpCsrAddress,
                                    width: wrCsrAddr.width,
                                  ),
                                ),
                            then: [fence < 1],
                          ),
                        ],
                      ),
                    ],
                  ),
                ]),
              );

              steps.add(
                CaseItem(Const(i + 1, width: maxLen.bitLength), [
                  If.block([
                    Iff(csrWrite.en & csrWrite.done & csrWrite.valid, [
                      mopStep < mopStep + 1,
                    ]),
                    // Read-only CSR via csrrs/csrrc x0 (csrr*i 0): no trap,
                    // just complete (the read already delivered rd).
                    Iff(
                      csrWrite.en &
                          csrWrite.done &
                          ~csrWrite.valid &
                          csrNoWrite,
                      [mopStep < mopStep + 1],
                    ),
                    Iff(
                      csrWrite.en &
                          csrWrite.done &
                          ~csrWrite.valid &
                          ~csrNoWrite,
                      doTrap(Trap.illegal, null, '_${op.mnemonic}'),
                    ),
                  ]),
                ]),
              );
            } else if (mop is RiscVReturnOp) {
              // MRET (privilegeLevel 3) / SRET (1). Terminal single-step:
              // signal the return; core.dart restores PC←{m,s}epc and
              // mode←{m,s}status.xPP and pops the status stack.
              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  output('isReturn') < 1,
                  output('returnLevel') < Const(mop.privilegeLevel, width: 3),
                  done < 1,
                  valid < 1,
                ]),
              );
            } else if (mop is RiscVTlbFenceOp) {
              // sfence.vma: pulse fence -> MMU fetch-TLB flush (see static
              // path). Over-flushes the icache harmlessly.
              steps.add(
                CaseItem(Const(i, width: maxLen.bitLength), [
                  fence < 1,
                  mopStep < mopStep + 1,
                ]),
              );
            } else if (mop is RiscVTlbInvalidateOp) {
              // TODO: once MMU has a TLB
            } else {
              // Unhandled micro-op, generate a no-op step that advances
              steps.add(
                CaseItem(Const(steps.length + 1, width: maxLen.bitLength), [
                  mopStep < mopStep + 1,
                ]),
              );
            }
          }

          return CaseItem(Const(entry.key, width: instrIndex.width), [
            Case(mopStep, [
              CaseItem(Const(0, width: maxLen.bitLength), [
                alu < 0,
                fence < 0,
                rs1 < fields['rs1']!.zeroExtend(mxlen.size),
                rs2 < fields['rs2']!.zeroExtend(mxlen.size),
                rd < fields['rd']!.zeroExtend(mxlen.size),
                imm < fields['imm']!.zeroExtend(mxlen.size),
                mopStep < 1,
              ]),
              ...steps,
              CaseItem(Const(steps.length + 1, width: maxLen.bitLength), [
                done < 1,
                valid < 1,
              ]),
            ]),
          ]);
        }).toList(),
        defaultItem: [
          alu < 0,
          mopStep < 0,
          done < 1,
          valid < 0,
          rs1Read.en < 0,
          rs1Read.addr < 0,
          rs2Read.en < 0,
          rs2Read.addr < 0,
          rdWrite.en < 0,
          rdWrite.addr < 0,
          rdWrite.data < 0,
          memRead.en < 0,
          memRead.addr < 0,
          memWrite.en < 0,
          memWrite.addr < 0,
          memWrite.data < 0,
        ],
      ),
    ];
  }
}
