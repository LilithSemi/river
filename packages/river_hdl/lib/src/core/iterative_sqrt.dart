import 'package:rohd/rohd.dart';

import 'fp_status.dart';

/// Shared multi-cycle IEEE-754 square root (radix-2 restoring digit recurrence).
///
/// One square root in flight at a time, matching the in-order exec unit: an
/// fsqrt mop parks the pipeline at its mopStep and waits for [done]. Replaces
/// the unrolled combinational root (a 53-bit subtract array, about 7000 LUTs at
/// binary64) with one subtract per cycle, a few hundred LUTs.
///
/// The result honors the requested RISC-V rounding mode. The recurrence
/// gives the truncated root Q and the exact remainder R = N - Q*Q, and the true
/// root passes the halfway point exactly when R > Q. A square root is never
/// exactly halfway between two floats, so the tie rule never fires.
///
/// The core also reads and writes a NARROWER format on demand ([narrow]),
/// which is what a single-precision root needs. A square root keeps its
/// operand format, so one flag names both sides: the operand fields are read
/// at the narrow width, the recurrence gives the exact truncated root and the
/// exact remainder, and the round happens ONCE at the narrow position. Reading
/// the narrow fields directly is exact and costs a few muxes, which is why
/// there is no widening converter in front of this core. A square root never
/// underflows or overflows, because taking a root halves the exponent, so the
/// narrow pack needs no subnormal or infinity path of its own.
///
/// Handshake (level-based): hold [start] high with [operand] valid; while idle
/// the core latches the operand and begins. [done] rises when [result] is
/// valid, and both hold until [start] drops.
class IterativeFpSqrt extends Module {
  /// Exponent field width (8 for binary32, 11 for binary64).
  final int exponentWidth;

  /// Mantissa field width (23 for binary32, 52 for binary64).
  final int mantissaWidth;

  /// The narrow format this core also rounds to, when it is wider than that
  /// format. A core built AT binary32 has no narrower format and ignores
  /// [narrow].
  final int narrowExponentWidth;
  final int narrowMantissaWidth;

  Logic get busy => output('busy');
  Logic get done => output('done');

  /// The packed {sign, exponent, mantissa} root.
  Logic get result => output('result');

  /// Architectural exception flags, valid with [done].
  Logic get flags => output('flags');

  IterativeFpSqrt(
    Logic clk,
    Logic reset,
    Logic start,
    Logic operand,
    Logic narrow, {
    Logic? rm,
    this.exponentWidth = 11,
    this.mantissaWidth = 52,
    this.narrowExponentWidth = 8,
    this.narrowMantissaWidth = 23,
    super.name = 'iterative_fp_sqrt',
  }) {
    final m = mantissaWidth;
    final e = exponentWidth;
    final w = 1 + e + m;
    // Root bits: the hidden bit and the whole mantissa.
    final n = m + 1;
    // The radicand holds 2 bits per root bit.
    final radW = 2 * n;
    // The running remainder is bounded by 2*root, and the pre-subtract value by
    // 4*that + 3, so it needs 3 bits more than the root.
    final remW = n + 3;
    // The working exponent is signed and goes as low as 1 - bias - m.
    final expW = e + 2;
    final bias = (1 << (e - 1)) - 1;
    // The narrow format. Its significand keeps the top [nN] root bits and
    // everything below them decides the rounding.
    final eN = narrowExponentWidth;
    final mN = narrowMantissaWidth;
    final nN = mN + 1;
    final wN = 1 + eN + mN;
    final dual = e > eN && m > mN;
    final expOffset = bias - ((1 << (eN - 1)) - 1);
    // Root bits below the narrow significand.
    final lowN = n - nN;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    start = addInput('start', start);
    operand = addInput('operand', operand, width: w);
    narrow = addInput('narrow', narrow);
    final roundingInput = addInput('rm', rm ?? Const(0, width: 3), width: 3);

    final busy = addOutput('busy');
    final done = addOutput('done');
    final result = addOutput('result', width: w);
    final flags = addOutput('flags', width: 5);

    // Operand classes. The square root of a negative number and of a NaN is the
    // canonical quiet NaN; +-0 and +infinity give themselves back.
    //
    // A narrow operand is read from its own fields. Its mantissa moves up into
    // the wide significand, which is exact because the low bits fill with
    // zeros, and its exponent is UNBIASED here, so it needs no offset: the
    // unbiased exponent of a value does not depend on the format.
    final wideExp = operand.slice(w - 2, m);
    final wideMan = operand.slice(m - 1, 0);
    final wideExp0 = ~wideExp.or();
    final wideMan0 = ~wideMan.or();
    final wideMax = wideExp.eq(Const((1 << e) - 1, width: e));
    final narrowExp = dual ? operand.slice(wN - 2, mN) : wideExp;
    final narrowMan = dual ? operand.slice(mN - 1, 0) : wideMan;
    final narrowExp0 = ~narrowExp.or();
    final narrowMan0 = ~narrowMan.or();
    final narrowMax = narrowExp.eq(Const((1 << eN) - 1, width: eN));

    final sign = dual
        ? mux(narrow, operand[wN - 1], operand[w - 1])
        : operand[w - 1];
    final exp0 = dual ? mux(narrow, narrowExp0, wideExp0) : wideExp0;
    final man0 = dual ? mux(narrow, narrowMan0, wideMan0) : wideMan0;
    final expAll1 = dual ? mux(narrow, narrowMax, wideMax) : wideMax;
    // The significand, and the unbiased exponent a normal operand carries.
    final sigLoad = dual
        ? mux(
            narrow,
            [~exp0, narrowMan, Const(0, width: m - mN)].swizzle(),
            [~exp0, wideMan].swizzle(),
          )
        : [~exp0, wideMan].swizzle();
    final expNormal = dual
        ? mux(
            narrow,
            narrowExp.zeroExtend(expW) -
                Const((1 << (eN - 1)) - 1, width: expW),
            wideExp.zeroExtend(expW) - Const(bias, width: expW),
          )
        : wideExp.zeroExtend(expW) - Const(bias, width: expW);
    // The smallest normal unbiased exponent, which a subnormal starts from.
    final expSub = dual
        ? mux(
            narrow,
            Const((1 - ((1 << (eN - 1)) - 1)) & ((1 << expW) - 1), width: expW),
            Const((1 - bias) & ((1 << expW) - 1), width: expW),
          )
        : Const((1 - bias) & ((1 << expW) - 1), width: expW);
    final isNaN = expAll1 & ~man0;
    final isInf = expAll1 & man0;
    final isZero = exp0 & man0;
    final isSub = exp0 & ~man0;
    final quiet = dual
        ? mux(narrow, narrowMan[mN - 1], wideMan[m - 1])
        : wideMan[m - 1];
    final invalid = (isNaN & ~quiet) | (sign & ~isZero & ~isNaN);
    final isSpecial = isNaN | isInf | isZero | sign;
    // The root of a NaN, and of any negative number that is not -0, is the
    // canonical quiet NaN. +infinity gives itself; +-0 keeps its sign. Each
    // one is a constant, so the pack below builds it from two flags instead of
    // carrying the operand through a wide mux.
    final resNaN = isNaN | (sign & ~isZero);
    final resInf = ~resNaN & isInf;
    final resSign = ~resNaN & sign;
    final specWide = [
      resSign,
      mux(resNaN | resInf, Const((1 << e) - 1, width: e), Const(0, width: e)),
      resNaN,
      Const(0, width: m - 1),
    ].swizzle();
    final specialVal = dual
        ? mux(
            narrow,
            [
              Const(0, width: w - wN),
              resSign,
              mux(
                resNaN | resInf,
                Const((1 << eN) - 1, width: eN),
                Const(0, width: eN),
              ),
              resNaN,
              Const(0, width: mN - 1),
            ].swizzle(),
            specWide,
          )
        : specWide;

    // State machine: 0 = idle, 1 = normalise a subnormal, 2 = run, 3 = done.
    const sIdle = 0, sNorm = 1, sRun = 2, sDone = 3;
    final state = Logic(name: 'state', width: 2);
    final cnt = Logic(name: 'cnt', width: n.bitLength);
    final sig = Logic(name: 'sig', width: n);
    final expA = Logic(name: 'expA', width: expW);
    final rad = Logic(name: 'rad', width: radW);
    final rem = Logic(name: 'rem', width: remW);
    final root = Logic(name: 'root', width: n);
    final special = Logic(name: 'special');
    final specialHold = Logic(name: 'specialHold', width: w);
    // The answer takes the narrow format. Latched, because the pack stage runs
    // many cycles after the operand went in.
    final narrowOut = Logic(name: 'narrowOut');
    final roundingMode = Logic(name: 'roundingMode', width: 3);
    final invalidHold = Logic(name: 'invalidHold');

    // One restoring step: pull the next two radicand bits into the remainder,
    // then subtract the trial root (4*root + 1) if it fits.
    final remNext = [
      rem.slice(remW - 3, 0),
      rad.slice(radW - 1, radW - 2),
    ].swizzle();
    final trial = [
      Const(0, width: remW - n - 2),
      root,
      Const(1, width: 2),
    ].swizzle();
    final fits = remNext.gte(trial);
    final remStep = mux(fits, remNext - trial, remNext);
    final rootStep = [root.slice(n - 2, 0), fits].swizzle();

    // Rounding. The remainder passes the halfway point exactly when it is
    // greater than the truncated root, and a carry out of the mantissa means
    // the root rounded up to 2.0, so the exponent takes the carry instead.
    final roundUp = fpRoundUp(
      rm: roundingMode,
      sign: Const(0),
      guard: rem.gt(root.zeroExtend(remW)),
      sticky: rem.or(),
      lsb: root[0],
    );
    final rounded = root.zeroExtend(n + 1) + roundUp.zeroExtend(n + 1);
    final carry = rounded[n];
    // The result exponent is floor(E/2), so the working exponent shifts right
    // arithmetically. Its low bit says the input needed a doubling first.
    final expHalf = [expA[expW - 1], expA.slice(expW - 1, 1)].swizzle();
    final expBiased =
        expHalf + Const(bias, width: expW) + carry.zeroExtend(expW);
    final computedWide = [
      Const(0),
      expBiased.slice(e - 1, 0),
      mux(carry, Const(0, width: m), rounded.slice(m - 1, 0)),
    ].swizzle();

    // Narrow rounding, taken once at the narrow position. The bits of the true
    // root below the narrow significand are the low root bits together with the
    // remainder, and the remainder is non-zero exactly when the root is
    // inexact, so guard and sticky are exact here.
    final Logic computed;
    if (dual) {
      final sigN = root.slice(n - 1, lowN);
      final guardN = root[lowN - 1];
      final stickyN = root.slice(lowN - 2, 0).or() | rem.or();
      final roundUpN = fpRoundUp(
        rm: roundingMode,
        sign: Const(0),
        guard: guardN,
        sticky: stickyN,
        lsb: root[lowN],
      );
      final roundedN = sigN.zeroExtend(nN + 1) + roundUpN.zeroExtend(nN + 1);
      final carryN = roundedN[nN];
      final expN =
          expHalf +
          Const(bias - expOffset, width: expW) +
          carryN.zeroExtend(expW);
      computed = mux(
        narrowOut,
        [
          Const(0, width: w - wN),
          Const(0),
          expN.slice(eN - 1, 0),
          mux(carryN, Const(0, width: mN), roundedN.slice(mN - 1, 0)),
        ].swizzle(),
        computedWide,
      );
    } else {
      computed = computedWide;
    }

    busy <= state.neq(Const(sIdle, width: 2));
    done <= state.eq(Const(sDone, width: 2));
    result <= mux(special, specialHold, computed);
    final inexact = dual
        ? mux(narrowOut, root.slice(lowN - 1, 0).or() | rem.or(), rem.or())
        : rem.or();
    flags <=
        mux(
          special,
          fpExceptionFlags(invalid: invalidHold),
          fpExceptionFlags(inexact: inexact),
        );

    // Entry into the run phase: X is the significand, doubled when the working
    // exponent is odd, and the radicand is X shifted up by the mantissa width.
    final radLoad = mux(
      expA[0],
      sig.zeroExtend(radW) << (m + 1),
      sig.zeroExtend(radW) << m,
    );

    Sequential(clk, [
      If(
        reset,
        then: [
          state < sIdle,
          cnt < 0,
          sig < 0,
          expA < 0,
          rad < 0,
          rem < 0,
          root < 0,
          special < 0,
          specialHold < 0,
          narrowOut < 0,
          roundingMode < 0,
          invalidHold < 0,
        ],
        orElse: [
          Case(state, [
            CaseItem(Const(sIdle, width: 2), [
              If(
                start,
                then: [
                  special < isSpecial,
                  specialHold < specialVal,
                  narrowOut < narrow,
                  roundingMode < roundingInput,
                  invalidHold < invalid,
                  rem < 0,
                  root < 0,
                  cnt < n,
                  // A subnormal carries no hidden bit and needs normalising;
                  // its exponent starts at the smallest normal one.
                  sig < sigLoad,
                  expA < mux(isSub, expSub, expNormal),
                  If(isSpecial, then: [state < sDone], orElse: [state < sNorm]),
                ],
              ),
            ]),
            // Shift a subnormal up until the hidden bit appears. A normal
            // operand passes through in one cycle.
            CaseItem(Const(sNorm, width: 2), [
              If(
                sig[n - 1],
                then: [rad < radLoad, state < sRun],
                orElse: [
                  sig < [sig.slice(n - 2, 0), Const(0)].swizzle(),
                  expA < expA - 1,
                ],
              ),
            ]),
            CaseItem(Const(sRun, width: 2), [
              rem < remStep,
              root < rootStep,
              rad < [rad.slice(radW - 3, 0), Const(0, width: 2)].swizzle(),
              cnt < cnt - 1,
              If(cnt.eq(Const(1, width: cnt.width)), then: [state < sDone]),
            ]),
            CaseItem(Const(sDone, width: 2), [
              If(~start, then: [state < sIdle]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
