import 'package:rohd/rohd.dart';

/// Shared multi-cycle IEEE-754 add, multiply, divide and precision convert.
///
/// One operation is in flight at a time, which matches the in-order execution
/// unit: an FP arithmetic micro-op parks at its mopStep and waits for [done].
/// The unit replaces the combinational adder and multiplier (an align shifter,
/// a normaliser, a rounder and a full 53x53 partial-product array, together the
/// largest block in the FP datapath) with one narrow step per cycle. It also
/// replaces the Newton-Raphson divide that borrowed those two units.
///
/// The align, add, normalise and divide steps are all carry logic, which is
/// what an FPGA slice does well, so they iterate one step per cycle. The
/// mantissa multiply is the exception: it stays a single wide product, because
/// yosys maps it onto DSP48E1 tiles and the DSP columns are nearly empty on
/// this part while the LUTs are the scarce resource. Measured on xc7s50, the
/// 53x53 product costs 12 DSP tiles and 144 LUTs, so iterating it would only
/// move work out of free silicon and into the resource that decides the route.
/// What the shared unit removes is the rest of the multiplier: the exponent
/// path, the normaliser and the rounder, which the add path already holds.
///
/// Every result is CORRECTLY ROUNDED to nearest, ties to even, because the
/// iteration keeps the exact low bits: the multiply keeps the full 2n-bit
/// product, the divide keeps the exact remainder, and the add keeps a guard,
/// a round and a sticky bit. Divide is therefore bit exact, which the older
/// Newton-Raphson form was not.
///
/// The unit serves the whole arithmetic family through operand-side selects,
/// the same ones the combinational units used:
///   fadd    a + b
///   fsub    a + (-b)                       [selNegB]
///   fmul    a * b                          [selMul]
///   fdiv    a / b                          [selDiv]
///   fmadd   (a*b) + c                      [selFma]
///   fmsub   (a*b) + (-c)                   [selFma, selNegB]
///   fnmsub  (-(a*b)) + c                   [selFma, selNegA]
///   fnmadd  (-(a*b)) + (-c)                [selFma, selNegA, selNegB]
///   fcvt    a, re-rounded at the other precision   [selCvt]
/// A fused multiply-add runs TWO passes through the unit: pass 0 multiplies
/// a by b, pass 1 adds c to that product. Each pass rounds, so the answer is
/// the same one the golden model gives, which computes the product and the
/// sum as two separate roundings.
///
/// PRECISION. A unit wider than binary32 also serves the binary32 family, and
/// it does so without a converter on either side: [selSingle] tells it to read
/// the operand fields at binary32 and to round the answer back to binary32.
/// The widening is exact, and the answer is rounded ONCE, so it is the
/// correctly rounded binary32 answer. That matches what the golden model gives,
/// because binary64 keeps 53 bits where the bound for innocuous double
/// rounding into binary32 is 2*24 + 2 = 50.
///
/// [selCvt] flips the destination precision against the source, which is what
/// fcvt.s.d and fcvt.d.s ask for. Such a convert runs as an add of the operand
/// and a zero, so it costs no state of its own: the normalise, denormalise and
/// round stages already do the whole job.
///
/// Handshake (level-based, the same one [IterativeFpSqrt] uses): hold [start]
/// high with the operands valid; while idle the unit latches them and begins.
/// [done] rises when [result] is valid, and both hold until [start] drops.
class IterativeFpArith extends Module {
  /// Exponent field width (8 for binary32, 11 for binary64).
  final int exponentWidth;

  /// Mantissa field width (23 for binary32, 52 for binary64).
  final int mantissaWidth;

  /// The narrow format this unit also serves, when it is wider than that
  /// format. A unit built AT binary32 has no narrower format and ignores
  /// [selSingle] and [selCvt].
  final int singleExponentWidth;
  final int singleMantissaWidth;

  Logic get busy => output('busy');
  Logic get done => output('done');

  /// The packed {sign, exponent, mantissa} answer. A binary32 answer sits in
  /// the low bits with zeros above it.
  Logic get result => output('result');

  IterativeFpArith(
    Logic clk,
    Logic reset,
    Logic start,
    Logic opA,
    Logic opB,
    Logic opC,
    Logic selFma,
    Logic selNegA,
    Logic selNegB,
    Logic selDiv,
    Logic selMul,
    Logic selCvt,
    Logic selSingle, {
    this.exponentWidth = 11,
    this.mantissaWidth = 52,
    this.singleExponentWidth = 8,
    this.singleMantissaWidth = 23,
    super.name = 'iterative_fp_arith',
  }) {
    final m = mantissaWidth;
    final e = exponentWidth;
    final w = 1 + e + m;
    // Significand bits: the hidden bit and the whole mantissa.
    final n = m + 1;
    // Working register: one carry bit, the significand, then guard, round and
    // sticky. Three low bits are enough because the only case that shifts left
    // by more than one is a cancelling subtract, and such a subtract loses no
    // bits in the alignment, so guard and round are zero there.
    final ww = n + 4;
    // The working exponent is signed and reaches about -(2*bias + 2*m).
    final expW = e + 3;
    final bias = (1 << (e - 1)) - 1;
    final cntW = (ww + 2).bitLength;

    // The narrow format. Every internal value stays in the WIDE exponent
    // domain, so a narrow operand adds this offset on the way in and a narrow
    // answer takes it off on the way out.
    final eS = singleExponentWidth;
    final mS = singleMantissaWidth;
    final nS = mS + 1;
    final wS = 1 + eS + mS;
    final biasS = (1 << (eS - 1)) - 1;
    final expOffset = bias - biasS;
    final dual = e > eS && m > mS;
    // Where the narrow significand sits in the working register: its top bit
    // stays at ww-2 and its guard, round and sticky follow underneath.
    final loS = ww - 1 - nS;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    start = addInput('start', start);
    opA = addInput('opA', opA, width: w);
    opB = addInput('opB', opB, width: w);
    opC = addInput('opC', opC, width: w);
    selFma = addInput('selFma', selFma);
    selNegA = addInput('selNegA', selNegA);
    selNegB = addInput('selNegB', selNegB);
    selDiv = addInput('selDiv', selDiv);
    selMul = addInput('selMul', selMul);
    selCvt = addInput('selCvt', selCvt);
    selSingle = addInput('selSingle', selSingle);

    final busy = addOutput('busy');
    final done = addOutput('done');
    final result = addOutput('result', width: w);

    const sIdle = 0,
        sNormA = 1,
        sNormB = 2,
        sAlign = 3,
        sAddSub = 4,
        sDiv = 5,
        sLoad = 6,
        sNorm = 7,
        sDenorm = 8,
        sRound = 9,
        sDone = 10;
    Logic st(int v) => Const(v, width: 4);

    const opAdd = 0, opMul = 1, opDiv = 2;
    Logic oc(int v) => Const(v, width: 2);

    final state = Logic(name: 'state', width: 4);
    final cnt = Logic(name: 'cnt', width: cntW);
    final sigA = Logic(name: 'sigA', width: n);
    final sigB = Logic(name: 'sigB', width: n);
    final expA = Logic(name: 'expA', width: expW);
    final expB = Logic(name: 'expB', width: expW);
    // Running remainder for the divide.
    final acc = Logic(name: 'acc', width: n + 2);
    // The working significand: the aligned addend, then the sum, then the
    // normalised and rounded answer. It also collects the quotient bits.
    final rw = Logic(name: 'rw', width: ww);
    final expR = Logic(name: 'expR', width: expW);
    final sgn = Logic(name: 'sgn');
    final effSub = Logic(name: 'effSub');
    final curOp = Logic(name: 'curOp', width: 2);
    final phase = Logic(name: 'phase');
    // The answer takes the narrow format. Latched, because the pack stage
    // reads it many cycles after the operands went in.
    final dstNarrow = Logic(name: 'dstNarrow');
    final special = Logic(name: 'special');
    final specialHold = Logic(name: 'specialHold', width: w);
    final resReg = Logic(name: 'resReg', width: w);

    // ---------------------------------------------------------------- decode

    // Which operands this pass takes. A fused multiply-add gives pass 0 the
    // raw a and b, and pass 1 the product it just made and c. The sign flips
    // belong to the ADD pass, so pass 0 never applies them.
    final ph0 = selFma & ~phase;
    final ph1 = selFma & phase;
    final negAeff = ~ph0 & ~selDiv & selNegA;
    final negBeff = ~ph0 & ~selDiv & selNegB;
    final rawA = mux(ph1, resReg, opA);
    final rawB = mux(ph1, opC, opB);

    final cvt = dual ? selCvt : Const(0);
    // The product a fused multiply-add makes on pass 0 is a WIDE value, so
    // pass 1 reads its left operand at the wide format whatever the operation
    // precision is, and pass 0 writes a wide product for it to read.
    final narrowA = dual ? (selSingle & ~ph1) : Const(0);
    final narrowB = dual ? selSingle : Const(0);
    final narrowOut = dual
        ? (~ph0 & mux(cvt, ~selSingle, selSingle))
        : Const(0);

    final opNew = mux(
      selDiv,
      oc(opDiv),
      mux(selMul | ph0, oc(opMul), oc(opAdd)),
    );
    final newIsAdd = opNew.eq(oc(opAdd));
    final newIsMul = opNew.eq(oc(opMul));

    final allOne = Const((1 << e) - 1, width: e);

    // Unpack one operand into the wide domain. A narrow operand widens here
    // exactly: its mantissa moves up and its exponent takes the bias offset.
    // A subnormal carries no hidden bit and its exponent starts at the
    // smallest normal one, so the normalise states below shift it up.
    ({Logic sign, Logic sig, Logic exp, Logic isNaN, Logic isInf, Logic isZero})
    unpack(Logic raw, Logic narrow, Logic neg) {
      final wExp = raw.slice(w - 2, m);
      final wMan = raw.slice(m - 1, 0);
      final wExp0 = ~wExp.or();
      final wMan0 = ~wMan.or();
      final wMax = wExp.eq(allOne);
      if (!dual) {
        return (
          sign: raw[w - 1] ^ neg,
          sig: [~wExp0, wMan].swizzle(),
          exp: mux(wExp0, Const(1, width: expW), wExp.zeroExtend(expW)),
          isNaN: wMax & ~wMan0,
          isInf: wMax & wMan0,
          isZero: wExp0 & wMan0,
        );
      }
      final sExp = raw.slice(wS - 2, mS);
      final sMan = raw.slice(mS - 1, 0);
      final sExp0 = ~sExp.or();
      final sMan0 = ~sMan.or();
      final sMax = sExp.eq(Const((1 << eS) - 1, width: eS));
      final exp0 = mux(narrow, sExp0, wExp0);
      final man0 = mux(narrow, sMan0, wMan0);
      final expMax = mux(narrow, sMax, wMax);
      return (
        sign: mux(narrow, raw[wS - 1], raw[w - 1]) ^ neg,
        sig: mux(
          narrow,
          [~exp0, sMan, Const(0, width: m - mS)].swizzle(),
          [~exp0, wMan].swizzle(),
        ),
        exp: mux(
          narrow,
          mux(
            sExp0,
            Const(1 + expOffset, width: expW),
            sExp.zeroExtend(expW) + Const(expOffset, width: expW),
          ),
          mux(wExp0, Const(1, width: expW), wExp.zeroExtend(expW)),
        ),
        isNaN: expMax & ~man0,
        isInf: expMax & man0,
        isZero: exp0 & man0,
      );
    }

    final ua = unpack(rawA, narrowA, negAeff);
    final ub = unpack(rawB, narrowB, negBeff);

    // A convert reads one operand only. It runs as an add of that operand and
    // a zero, so the right side is silenced here: same exponent, so nothing
    // shifts, and a zero significand, so the sum is the operand itself.
    final bSig = mux(cvt, Const(0, width: n), ub.sig);
    final bExp = mux(cvt, ua.exp, ub.exp);
    final bSign = mux(cvt, ua.sign, ub.sign);
    final bNaN = ~cvt & ub.isNaN;
    final bInf = ~cvt & ub.isInf;
    // A convert of a zero must still give a signed zero, so the b side reports
    // the a side's zero and the both-zero rule below returns it.
    final bZeroRaw = mux(cvt, ua.isZero, ub.isZero);

    // An add wants the larger magnitude first, so the alignment only ever
    // shifts the right operand and the subtract never borrows. The compare is
    // on the unpacked exponent and significand, because a fused multiply-add
    // holds its two operands at DIFFERENT formats on the second pass.
    final aBigger = ua.exp.gt(bExp) | (ua.exp.eq(bExp) & ua.sig.gte(bSig));
    final swapAB = newIsAdd & ~aBigger;

    final signA = mux(swapAB, bSign, ua.sign);
    final signB = mux(swapAB, ua.sign, bSign);
    final sigAload = mux(swapAB, bSig, ua.sig);
    final sigBload = mux(swapAB, ua.sig, bSig);
    final expAload = mux(swapAB, bExp, ua.exp);
    final expBload = mux(swapAB, ua.exp, bExp);
    final aNaN = mux(swapAB, bNaN, ua.isNaN);
    final bNaNs = mux(swapAB, ua.isNaN, bNaN);
    final aInf = mux(swapAB, bInf, ua.isInf);
    final bInfs = mux(swapAB, ua.isInf, bInf);
    final aZero = mux(swapAB, bZeroRaw, ua.isZero);
    final bZero = mux(swapAB, ua.isZero, bZeroRaw);

    // Special operands. Every special answer is a constant, so the whole
    // family costs one narrow mux and no wide one. An add with ONE zero
    // operand is not special: it runs the ordinary path with a zero addend,
    // which re-rounds the other operand at the destination format. That is
    // what a convert needs and what a fused multiply-add needs when its third
    // operand is zero and the product still has to round.
    final xorSign = signA ^ signB;
    final anyNaN = aNaN | bNaNs;
    final mulBad = (aInf & bZero) | (bInfs & aZero);
    final divBad = (aInf & bInfs) | (aZero & bZero);
    final addBad = aInf & bInfs & (signA ^ signB);
    final opBad = mux(newIsAdd, addBad, mux(newIsMul, mulBad, divBad));
    final isNaNres = anyNaN | opBad;
    // An add gives an infinity when the larger operand is infinite, and the
    // swap put that one first. Divide by zero gives an infinity too.
    final isInfRes =
        ~isNaNres &
        mux(newIsAdd, aInf, mux(newIsMul, aInf | bInfs, aInf | bZero));
    // Two zeros added give +0 unless both are negative, which is the
    // round-to-nearest rule. A NaN is always the positive canonical one.
    final constSign =
        ~isNaNres & mux(newIsAdd, mux(aInf, signA, signA & signB), xorSign);
    final specHit = mux(
      newIsAdd,
      anyNaN | aInf | bInfs | (aZero & bZero),
      anyNaN | opBad | aInf | bInfs | aZero | bZero,
    );

    // Pack a constant at one format: all-ones exponent for a NaN or an
    // infinity, top mantissa bit for a NaN, zero for everything else.
    Logic constWide() => [
      constSign,
      mux(isNaNres | isInfRes, allOne, Const(0, width: e)),
      isNaNres,
      Const(0, width: m - 1),
    ].swizzle();
    Logic constNarrow() => [
      Const(0, width: w - wS),
      constSign,
      mux(
        isNaNres | isInfRes,
        Const((1 << eS) - 1, width: eS),
        Const(0, width: eS),
      ),
      isNaNres,
      Const(0, width: mS - 1),
    ].swizzle();
    final specVal = dual
        ? mux(narrowOut, constNarrow(), constWide())
        : constWide();

    // ------------------------------------------------------------- iteration

    // Sticky-preserving right shift: bit 0 keeps the OR of everything that has
    // left the significand, so no low bit is ever lost.
    Logic stickyRight(Logic v) =>
        [Const(0), v.slice(ww - 1, 2), v[1] | v[0]].swizzle();

    // Setup taken when both significands are normalised.
    final dDiff = expA - expB;
    final dCap = mux(
      dDiff.gt(Const(ww, width: expW)),
      Const(ww, width: expW),
      dDiff,
    );
    final alignLoad = [Const(0), sigB, Const(0, width: 3)].swizzle();

    // Divide: a radix-2 restoring recurrence against twice the divisor, so the
    // running remainder always stays below it and one subtract per step is
    // enough. n+2 steps give n significand bits plus a guard bit.
    final divisor = [Const(0), sigB, Const(0)].swizzle();
    final rem2 = [acc.slice(n, 0), Const(0)].swizzle();
    final divGe = rem2.gte(divisor);
    final accDiv = mux(divGe, rem2 - divisor, rem2);
    final rwDiv = [rw.slice(ww - 2, 0), divGe].swizzle();

    // Add: the left operand sits at the significand position with the guard,
    // round and sticky bits below it. The magnitude order was fixed at load,
    // so a subtract never borrows.
    final aWide = [Const(0), sigA, Const(0, width: 3)].swizzle();
    final addRes = mux(effSub, aWide - rw, aWide + rw);

    // Load the multiply or divide answer into the working register. The
    // product of two normalised significands has its top bit in one of two
    // places, and so has the quotient, so each is a two-way shift.
    //
    // The full 2n-bit significand product. This one wide operation stays
    // combinational because yosys maps it onto DSP48E1 tiles.
    final prod = sigA.zeroExtend(2 * n) * sigB.zeroExtend(2 * n);
    final prodHi = prod[2 * n - 1];
    final mulR = [
      Const(0),
      mux(prodHi, prod.slice(2 * n - 1, n), prod.slice(2 * n - 2, n - 1)),
      mux(prodHi, prod[n - 1], prod[n - 2]),
      Const(0),
      mux(prodHi, prod.slice(n - 2, 0).or(), prod.slice(n - 3, 0).or()),
    ].swizzle();
    final mulExp =
        expA + expB - Const(bias, width: expW) + prodHi.zeroExtend(expW);

    final quotHi = rw[n + 1];
    final remNz = acc.or();
    final divR =
        mux(
          quotHi,
          [rw.slice(ww - 2, 0), Const(0)].swizzle(),
          [rw.slice(ww - 3, 0), Const(0, width: 2)].swizzle(),
        ) |
        remNz.zeroExtend(ww);
    final divExp =
        expA - expB + Const(bias, width: expW) - (~quotHi).zeroExtend(expW);

    final loadIsMul = curOp.eq(oc(opMul));

    // Normalise. A carry out of the significand shifts right once; a cancelling
    // subtract shifts left until the top bit appears.
    final normCarry = rw[ww - 1];
    final normHit = rw[ww - 2];
    final rZero = ~rw.or();
    // Where the answer stops being normal. The wide format runs out at 1; the
    // narrow one runs out that many wide exponents higher.
    final expThresh = dual
        ? mux(
            dstNarrow,
            Const(1 + expOffset, width: expW),
            Const(1, width: expW),
          )
        : Const(1, width: expW);
    // Exponent still to make up before the answer becomes subnormal. It is
    // positive exactly when the answer underflows.
    final downAmt = expThresh - expR;
    final underflow = ~downAmt[expW - 1] & downAmt.or();
    final downCap = mux(
      downAmt.gt(Const(ww, width: expW)),
      Const(ww, width: expW),
      downAmt,
    );

    // Round to nearest, ties to even, then pack. The destination format picks
    // where the significand stops and where guard and sticky begin.
    final sigOutW = rw.slice(ww - 2, 3);
    final sigOut = dual
        ? mux(dstNarrow, rw.slice(ww - 2, loS).zeroExtend(n), sigOutW)
        : sigOutW;
    final gBit = dual ? mux(dstNarrow, rw[loS - 1], rw[2]) : rw[2];
    final sBit = dual
        ? mux(dstNarrow, rw.slice(loS - 2, 0).or(), rw[1] | rw[0])
        : rw[1] | rw[0];
    final lBit = dual ? mux(dstNarrow, rw[loS], rw[3]) : rw[3];
    final roundUp = gBit & (sBit | lBit);
    final rounded = sigOut.zeroExtend(n + 1) + roundUp.zeroExtend(n + 1);
    final roundCarry = dual
        ? mux(dstNarrow, rounded[nS], rounded[n])
        : rounded[n];
    final hidden =
        roundCarry |
        (dual
            ? mux(dstNarrow, rounded[nS - 1], rounded[n - 1])
            : rounded[n - 1]);
    // The answer exponent, brought back to the destination bias.
    final expFin = expR + roundCarry.zeroExtend(expW);
    final expDst = dual
        ? mux(dstNarrow, expFin - Const(expOffset, width: expW), expFin)
        : expFin;
    final overflow =
        ~expDst[expW - 1] &
        expDst.gte(
          dual
              ? mux(
                  dstNarrow,
                  Const((1 << eS) - 1, width: expW),
                  Const((1 << e) - 1, width: expW),
                )
              : Const((1 << e) - 1, width: expW),
        );

    Logic packWide() => [
      sgn,
      mux(hidden, expDst.slice(e - 1, 0), Const(0, width: e)),
      mux(roundCarry, Const(0, width: m), rounded.slice(m - 1, 0)),
    ].swizzle();
    Logic packNarrow() => [
      Const(0, width: w - wS),
      sgn,
      mux(hidden, expDst.slice(eS - 1, 0), Const(0, width: eS)),
      mux(roundCarry, Const(0, width: mS), rounded.slice(mS - 1, 0)),
    ].swizzle();
    Logic infWide() => [sgn, allOne, Const(0, width: m)].swizzle();
    Logic infNarrow() => [
      Const(0, width: w - wS),
      sgn,
      Const((1 << eS) - 1, width: eS),
      Const(0, width: mS),
    ].swizzle();
    final packed = dual
        ? mux(
            overflow,
            mux(dstNarrow, infNarrow(), infWide()),
            mux(dstNarrow, packNarrow(), packWide()),
          )
        : mux(overflow, infWide(), packWide());

    busy <= state.neq(st(sIdle));
    done <= state.eq(st(sDone));
    result <= resReg;

    Sequential(clk, [
      If(
        reset,
        then: [
          state < sIdle,
          cnt < 0,
          sigA < 0,
          sigB < 0,
          expA < 0,
          expB < 0,
          acc < 0,
          rw < 0,
          expR < 0,
          sgn < 0,
          effSub < 0,
          curOp < 0,
          phase < 0,
          dstNarrow < 0,
          special < 0,
          specialHold < 0,
          resReg < 0,
        ],
        orElse: [
          Case(state, [
            CaseItem(st(sIdle), [
              If(
                start,
                then: [
                  curOp < opNew,
                  sgn < mux(newIsAdd, signA, xorSign),
                  effSub < (newIsAdd & (signA ^ signB)),
                  sigA < sigAload,
                  sigB < sigBload,
                  expA < expAload,
                  expB < expBload,
                  dstNarrow < narrowOut,
                  special < specHit,
                  specialHold < specVal,
                  If(specHit, then: [state < sRound], orElse: [state < sNormA]),
                ],
              ),
            ]),
            // Shift a subnormal up until the hidden bit appears. A normal
            // operand passes through in one cycle. The zero test only guards
            // against a hang: an add with a zero addend reaches sNormB with a
            // zero significand on purpose.
            CaseItem(st(sNormA), [
              If(
                sigA[n - 1] | ~sigA.or(),
                then: [state < sNormB],
                orElse: [
                  sigA < [sigA.slice(n - 2, 0), Const(0)].swizzle(),
                  expA < expA - 1,
                ],
              ),
            ]),
            CaseItem(st(sNormB), [
              If(
                sigB[n - 1] | ~sigB.or(),
                then: [
                  Case(
                    curOp,
                    [
                      // The product is combinational off the two significand
                      // registers, so the multiply needs no iteration state.
                      CaseItem(oc(opMul), [state < sLoad]),
                      CaseItem(oc(opDiv), [
                        acc < sigA.zeroExtend(n + 2),
                        // The quotient bits shift into the working register.
                        rw < 0,
                        cnt < Const(n + 2, width: cntW),
                        state < sDiv,
                      ]),
                    ],
                    defaultItem: [
                      rw < alignLoad,
                      expR < expA,
                      cnt < dCap.getRange(0, cntW),
                      state < sAlign,
                    ],
                  ),
                ],
                orElse: [
                  sigB < [sigB.slice(n - 2, 0), Const(0)].swizzle(),
                  expB < expB - 1,
                ],
              ),
            ]),
            CaseItem(st(sDiv), [
              acc < accDiv,
              rw < rwDiv,
              cnt < cnt - 1,
              If(cnt.eq(Const(1, width: cntW)), then: [state < sLoad]),
            ]),
            CaseItem(st(sAlign), [
              If(
                cnt.eq(Const(0, width: cntW)),
                then: [state < sAddSub],
                orElse: [rw < stickyRight(rw), cnt < cnt - 1],
              ),
            ]),
            CaseItem(st(sAddSub), [rw < addRes, state < sNorm]),
            CaseItem(st(sLoad), [
              rw < mux(loadIsMul, mulR, divR),
              expR < mux(loadIsMul, mulExp, divExp),
              state < sNorm,
            ]),
            CaseItem(st(sNorm), [
              If(
                normCarry,
                then: [rw < stickyRight(rw), expR < expR + 1],
                orElse: [
                  If(
                    normHit,
                    then: [
                      cnt <
                          mux(
                            underflow,
                            downCap.getRange(0, cntW),
                            Const(0, width: cntW),
                          ),
                      expR < mux(underflow, expThresh, expR),
                      state < sDenorm,
                    ],
                    orElse: [
                      // A subtract that cancels every bit gives +0 under
                      // round to nearest, whatever the operand signs were.
                      If(
                        rZero,
                        then: [
                          special < 1,
                          specialHold < Const(0, width: w),
                          state < sRound,
                        ],
                        orElse: [
                          rw < [rw.slice(ww - 2, 0), Const(0)].swizzle(),
                          expR < expR - 1,
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(st(sDenorm), [
              If(
                cnt.eq(Const(0, width: cntW)),
                then: [state < sRound],
                orElse: [rw < stickyRight(rw), cnt < cnt - 1],
              ),
            ]),
            CaseItem(st(sRound), [
              resReg < mux(special, specialHold, packed),
              // A fused multiply-add takes a second pass: the product goes
              // back in as the left operand and c comes in as the right one.
              If(
                selFma & ~phase,
                then: [phase < 1, state < sIdle],
                orElse: [state < sDone],
              ),
            ]),
            CaseItem(st(sDone), [
              If(~start, then: [state < sIdle, phase < 0]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
