import 'package:rohd/rohd.dart';
import 'package:river/river.dart';

import '../compat.dart' show MicroOpAluFunct;
import 'alu_ops.dart' show bmSignedLt;

/// Shared, control-driven integer ALU for the microcode exec datapath.
///
/// One reusable unit instead of the DynamicExecutionUnit computing every ALU op
/// inline in a ~30-arm Case (separate adders/shifters per arm). [funct] (a
/// [MicroOpAluFunct] value) selects a single [result]. The adder is shared
/// across add/sub/addw/subw via operand-invert (yosys will not merge that on its
/// own). Multiply/divide stay on their own units (BmMulSet / IterativeDivider);
/// this covers single-cycle integer ops only.
class MicrocodeAlu extends Module {
  /// The selected ALU result, XLEN wide.
  Logic get result => output('result');

  MicrocodeAlu(
    Logic a,
    Logic b,
    Logic funct, {
    required RiscVMxlen mxlen,
    super.name = 'microcode_alu',
  }) {
    final xlen = mxlen.size;
    a = addInput('a', a, width: xlen);
    b = addInput('b', b, width: xlen);
    funct = addInput('funct', funct, width: MicroOpAluFunct.width);
    final result = addOutput('result', width: xlen);

    Logic f(int v) => funct.eq(Const(v, width: MicroOpAluFunct.width));

    // ONE shared adder: add/sub/addw/subw. sub-family inverts b and carries in.
    final isSub = f(MicroOpAluFunct.sub) | f(MicroOpAluFunct.subw);
    final addB = mux(isSub, ~b, b);
    Logic sum;
    if (xlen == 64) {
      // Carry-select halves keep operand inversion off a full XLEN carry
      // chain. Both upper carry outcomes are computed in parallel.
      final low =
          a.slice(31, 0).zeroExtend(33) +
          addB.slice(31, 0).zeroExtend(33) +
          isSub.zeroExtend(33);
      final high0 = a.slice(63, 32) + addB.slice(63, 32);
      final high1 = a.slice(63, 32) + addB.slice(63, 32) + Const(1, width: 32);
      sum = [mux(low[32], high1, high0), low.slice(31, 0)].swizzle();
    } else {
      sum = a + addB + isSub.zeroExtend(xlen);
    }
    final sumW = sum.slice(31, 0).signExtend(xlen);

    // Bitwise.
    final andR = a & b;
    final orR = a | b;
    final xorR = a ^ b;
    final masked = a & ~b; // MicroOpAluFunct.masked (andn-style)

    // 64-bit shifts (shamt masked to log2(XLEN)).
    final shamt = b & Const(xlen - 1, width: xlen);
    final sll = a << shamt;
    final srl = a >>> shamt;
    final sra = a >> shamt; // arithmetic

    // 32-bit (W) shifts, sign-extended to XLEN.
    final shamtW = b.slice(4, 0);
    final sllw = (a << shamtW).slice(31, 0).signExtend(xlen);
    final srlw = (a.slice(31, 0) >>> shamtW).signExtend(xlen);
    final sraw = (a.slice(31, 0) >> shamtW).signExtend(xlen);

    // Compares (the raw bits are reused by min/max below).
    final sLtBit = bmSignedLt(a, b, xlen);
    final uLtBit = a.lt(b);
    final slt = sLtBit.zeroExtend(xlen);
    final sltu = uLtBit.zeroExtend(xlen);

    // Zbb min/max: select a or b on the same comparators. Not emitted by the
    // rc1-f ROM, but the AMO combine drives these functs to reuse this unit.
    final minR = mux(sLtBit, a, b);
    final maxR = mux(sLtBit, b, a);
    final minuR = mux(uLtBit, a, b);
    final maxuR = mux(uLtBit, b, a);

    // Zicond conditional-zero.
    final bZero = b.eq(Const(0, width: xlen));
    final czE = mux(bZero, Const(0, width: xlen), a); // czero.eqz
    final czN = mux(bZero, a, Const(0, width: xlen)); // czero.nez

    // Result selection: a parallel Case over funct (balanced mux, not a priority
    // chain) selecting the precomputed shared-datapath result.
    CaseItem item(int fn, Logic value) =>
        CaseItem(Const(fn, width: MicroOpAluFunct.width), [result < value]);
    Combinational([
      Case(
        funct,
        [
          item(MicroOpAluFunct.add, sum),
          item(MicroOpAluFunct.sub, sum), // shared adder (b inverted)
          item(MicroOpAluFunct.addw, sumW),
          item(MicroOpAluFunct.subw, sumW),
          item(MicroOpAluFunct.and, andR),
          item(MicroOpAluFunct.or, orR),
          item(MicroOpAluFunct.xor, xorR),
          item(MicroOpAluFunct.masked, masked),
          item(MicroOpAluFunct.sll, sll),
          item(MicroOpAluFunct.srl, srl),
          item(MicroOpAluFunct.sra, sra),
          item(MicroOpAluFunct.sllw, sllw),
          item(MicroOpAluFunct.srlw, srlw),
          item(MicroOpAluFunct.sraw, sraw),
          item(MicroOpAluFunct.slt, slt),
          item(MicroOpAluFunct.sltu, sltu),
          item(MicroOpAluFunct.minOp, minR),
          item(MicroOpAluFunct.maxOp, maxR),
          item(MicroOpAluFunct.minuOp, minuR),
          item(MicroOpAluFunct.maxuOp, maxuR),
          item(MicroOpAluFunct.czeroEqz, czE),
          item(MicroOpAluFunct.czeroNez, czN),
        ],
        defaultItem: [result < Const(0, width: xlen)],
      ),
    ]);
  }
}
