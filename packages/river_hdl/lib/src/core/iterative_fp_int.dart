import 'package:rohd/rohd.dart';

import 'fp_status.dart';

/// Shared multi-cycle integer to floating-point and floating-point to integer
/// conversion.
///
/// One conversion is in flight at a time, which matches the in-order execution
/// unit: an fcvt micro-op parks at its mopStep and waits for [done]. The unit
/// replaces the two combinational converters the FP datapath used to hold: a
/// FixedToFloat per destination format (a 65-bit leading-zero count and the
/// barrel shifter behind it) and a FloatToFixed (a 117-bit barrel shifter and
/// its overflow test). Both are shift and compare logic with nothing for a DSP
/// tile to do, so one shift per cycle trades cycles for the resource that
/// decides whether the design routes.
///
/// Both directions run on ONE register: an integer field with a round bit and
/// a sticky bit under it. Integer to float loads the magnitude and shifts it
/// up until the top bit appears; float to integer loads the significand and
/// shifts it to the integer position, up or down, keeping a sticky bit. The
/// round and pack stage is shared.
///
/// [narrow] names the format of the FLOAT side, whichever way the conversion
/// runs: it picks the destination format for fcvt.s.w against fcvt.d.w, and
/// the source format for fcvt.w.s against fcvt.w.d. Reading the narrow source
/// fields directly is exact, because the mantissa moves up into the wide
/// significand and the low bits fill with zeros, which is why there is no
/// widening converter in front of this unit.
///
/// The integer side reports a magnitude with a round and a sticky bit rather
/// than a rounded integer, because the caller applies the RISC-V rounding mode
/// and the saturation rules; see `roundSatFpToInt` in `exec.dart`.
///
/// Handshake (level-based, the same one [IterativeFpSqrt] uses): hold [start]
/// high with the operands valid; while idle the unit latches them and begins.
/// [done] rises when the outputs are valid, and both hold until [start] drops.
class IterativeFpIntConvert extends Module {
  /// Exponent field width of the wide float format.
  final int exponentWidth;

  /// Mantissa field width of the wide float format.
  final int mantissaWidth;

  /// The narrow float format an integer can convert into.
  final int narrowExponentWidth;
  final int narrowMantissaWidth;

  /// Integer width, which is XLEN at its widest.
  final int intWidth;

  Logic get busy => output('busy');
  Logic get done => output('done');

  /// The packed float, for the integer to float direction.
  Logic get fpOut => output('fpOut');

  /// Integer-to-float exception flags, valid with [done]. Float-to-integer
  /// flags are determined by the caller's rounding and saturation logic.
  Logic get fpFlags => output('fpFlags');

  /// The magnitude of the float, truncated toward zero, for the other
  /// direction. [roundBit] and [sticky] carry everything below it.
  Logic get intMag => output('intMag');
  Logic get roundBit => output('roundBit');
  Logic get sticky => output('sticky');

  /// True when the magnitude does not fit, that is when |f| >= 2^intWidth.
  Logic get overflow => output('overflow');

  IterativeFpIntConvert(
    Logic clk,
    Logic reset,
    Logic start,
    Logic fpIn,
    Logic intIn,
    Logic intSigned,
    Logic toInt,
    Logic narrow, {
    Logic? rm,
    this.exponentWidth = 11,
    this.mantissaWidth = 52,
    this.narrowExponentWidth = 8,
    this.narrowMantissaWidth = 23,
    this.intWidth = 64,
    super.name = 'iterative_fp_int',
  }) {
    final m = mantissaWidth;
    final e = exponentWidth;
    final w = 1 + e + m;
    final n = m + 1;
    final bias = (1 << (e - 1)) - 1;
    final eN = narrowExponentWidth;
    final mN = narrowMantissaWidth;
    final nN = mN + 1;
    final wN = 1 + eN + mN;
    final dual = e > eN && m > mN;
    // Working register: the integer field, then a round bit and a sticky bit.
    final vw = intWidth + 2;
    final expW = e + 3;
    final cntW = (vw + 2).bitLength;
    // Where the significand sits so that no shift is needed when the value's
    // exponent puts its low bit exactly at integer bit 0.
    final pivot = bias + m;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    start = addInput('start', start);
    fpIn = addInput('fpIn', fpIn, width: w);
    intIn = addInput('intIn', intIn, width: intWidth);
    intSigned = addInput('intSigned', intSigned);
    toInt = addInput('toInt', toInt);
    narrow = addInput('narrow', narrow);
    final roundingInput = addInput('rm', rm ?? Const(0, width: 3), width: 3);

    final busy = addOutput('busy');
    final done = addOutput('done');
    final fpOut = addOutput('fpOut', width: w);
    final fpFlags = addOutput('fpFlags', width: 5);
    final intMag = addOutput('intMag', width: intWidth);
    final roundBit = addOutput('roundBit');
    final sticky = addOutput('sticky');
    final overflow = addOutput('overflow');

    const sIdle = 0, sNormInt = 1, sShiftFp = 2, sRound = 3, sDone = 4;
    Logic st(int v) => Const(v, width: 3);

    final state = Logic(name: 'state', width: 3);
    final cnt = Logic(name: 'cnt', width: cntW);
    final val = Logic(name: 'val', width: vw);
    final expv = Logic(name: 'expv', width: expW);
    final sgn = Logic(name: 'sgn');
    final dirLeft = Logic(name: 'dirLeft');
    final narrowOut = Logic(name: 'narrowOut');
    final ovfHold = Logic(name: 'ovfHold');
    final zeroInt = Logic(name: 'zeroInt');
    final resReg = Logic(name: 'resReg', width: w);
    final roundingMode = Logic(name: 'roundingMode', width: 3);
    final flagsReg = Logic(name: 'flagsReg', width: 5);

    // ------------------------------------------------------- integer to float

    // Sign and magnitude of the source. The caller has already selected the
    // source width and its extension, so this is one negate.
    final intNeg = intSigned & intIn[intWidth - 1];
    final intAbs = mux(
      intNeg,
      ~intIn + Const(1, width: intWidth),
      intIn,
    ).named('intAbs');
    // The integer sits in the top field with the round and sticky bits clear.
    // Its top bit therefore carries weight 2^(intWidth-1).
    final intLoad = [intAbs, Const(0, width: 2)].swizzle();

    // ------------------------------------------------------- float to integer

    final wideExp = fpIn.slice(w - 2, m);
    final wideMan = fpIn.slice(m - 1, 0);
    final wideExp0 = ~wideExp.or();
    final narrowExp = dual ? fpIn.slice(wN - 2, mN) : wideExp;
    final narrowMan = dual ? fpIn.slice(mN - 1, 0) : wideMan;
    final narrowExp0 = ~narrowExp.or();
    final fpExp0 = dual ? mux(narrow, narrowExp0, wideExp0) : wideExp0;
    // A subnormal carries no hidden bit and behaves as the smallest normal
    // exponent, which puts it far below one, so it shifts entirely into the
    // sticky bit. A narrow source widens here exactly: its mantissa moves up
    // and its exponent takes the bias offset, so everything below stays in the
    // wide exponent domain.
    final narrowOffset = bias - ((1 << (eN - 1)) - 1);
    final fpSig = dual
        ? mux(
            narrow,
            [~fpExp0, narrowMan, Const(0, width: m - mN)].swizzle(),
            [~fpExp0, wideMan].swizzle(),
          )
        : [~fpExp0, wideMan].swizzle();
    final wideExpv = mux(
      wideExp0,
      Const(1, width: expW),
      wideExp.zeroExtend(expW),
    );
    final fpExpv =
        (dual
                ? mux(
                    narrow,
                    mux(
                      narrowExp0,
                      Const(1 + narrowOffset, width: expW),
                      narrowExp.zeroExtend(expW) +
                          Const(narrowOffset, width: expW),
                    ),
                    wideExpv,
                  )
                : wideExpv)
            .named('fpExpv');
    // Load the significand so that no shift is needed when the exponent is
    // exactly the pivot; above it the value shifts up, below it down.
    final fpLoad = [
      Const(0, width: vw - n - 2),
      fpSig,
      Const(0, width: 2),
    ].swizzle();
    final upAmt = fpExpv - Const(pivot, width: expW);
    final downAmt = Const(pivot, width: expW) - fpExpv;
    final shiftUp = ~upAmt[expW - 1] & upAmt.or();
    // |f| >= 2^intWidth does not fit. An infinity and a NaN land here too,
    // which is what the caller's saturation expects.
    final fpOvf = fpExpv.gte(Const(bias + intWidth, width: expW));
    final downCap = mux(
      downAmt.gt(Const(vw, width: expW)),
      Const(vw, width: expW),
      downAmt,
    );
    final fpAmt = mux(shiftUp, upAmt, downCap);

    // -------------------------------------------------------------- iteration

    // Sticky-preserving right shift: bit 0 keeps the OR of everything that has
    // left the register, so no low bit is ever lost.
    Logic stickyRight(Logic v) =>
        [Const(0), v.slice(vw - 1, 2), v[1] | v[0]].swizzle();
    final shiftStep = mux(
      dirLeft,
      [val.slice(vw - 2, 0), Const(0)].swizzle(),
      stickyRight(val),
    );

    // Round in the accepted instruction's mode at the destination format. The
    // significand always starts at the top bit, because the normalise loop put
    // it there, so the only choice is where it stops.
    final loW = vw - n;
    final loN = vw - nN;
    final sigW = val.slice(vw - 1, loW);
    final sigOut = dual
        ? mux(narrowOut, val.slice(vw - 1, loN).zeroExtend(n), sigW)
        : sigW;
    final gBit = dual
        ? mux(narrowOut, val[loN - 1], val[loW - 1])
        : val[loW - 1];
    final sBit = dual
        ? mux(narrowOut, val.slice(loN - 2, 0).or(), val.slice(loW - 2, 0).or())
        : val.slice(loW - 2, 0).or();
    final lBit = dual ? mux(narrowOut, val[loN], val[loW]) : val[loW];
    final roundUp = fpRoundUp(
      rm: roundingMode,
      sign: sgn,
      guard: gBit,
      sticky: sBit,
      lsb: lBit,
    );
    final rounded = sigOut.zeroExtend(n + 1) + roundUp.zeroExtend(n + 1);
    final carry = dual ? mux(narrowOut, rounded[nN], rounded[n]) : rounded[n];
    final expFin = expv + carry.zeroExtend(expW);
    // A magnitude below 2^intWidth cannot overflow either float format and
    // cannot be subnormal, so the pack is a plain field assembly.
    Logic packWide() => [
      sgn,
      expFin.slice(e - 1, 0),
      mux(carry, Const(0, width: m), rounded.slice(m - 1, 0)),
    ].swizzle();
    Logic packNarrow() => [
      Const(0, width: w - wN),
      sgn,
      (expFin - Const(bias - ((1 << (eN - 1)) - 1), width: expW)).slice(
        eN - 1,
        0,
      ),
      mux(carry, Const(0, width: mN), rounded.slice(mN - 1, 0)),
    ].swizzle();
    final packed = mux(
      zeroInt,
      Const(0, width: w),
      dual ? mux(narrowOut, packNarrow(), packWide()) : packWide(),
    );

    busy <= state.neq(st(sIdle));
    done <= state.eq(st(sDone));
    fpOut <= resReg;
    fpFlags <= flagsReg;
    intMag <= val.slice(vw - 1, 2);
    roundBit <= val[1];
    sticky <= val[0];
    overflow <= ovfHold;

    Sequential(clk, [
      If(
        reset,
        then: [
          state < sIdle,
          cnt < 0,
          val < 0,
          expv < 0,
          sgn < 0,
          dirLeft < 0,
          narrowOut < 0,
          ovfHold < 0,
          zeroInt < 0,
          resReg < 0,
          roundingMode < 0,
          flagsReg < 0,
        ],
        orElse: [
          Case(state, [
            CaseItem(st(sIdle), [
              If(
                start,
                then: [
                  narrowOut < narrow,
                  roundingMode < roundingInput,
                  flagsReg < 0,
                  If(
                    toInt,
                    then: [
                      val < fpLoad,
                      dirLeft < shiftUp,
                      cnt < fpAmt.getRange(0, cntW),
                      ovfHold < fpOvf,
                      sgn < fpIn[w - 1],
                      state < sShiftFp,
                    ],
                    orElse: [
                      val < intLoad,
                      // The top bit already carries this weight, so the
                      // normalise loop counts the exponent down from here.
                      expv < Const(bias + intWidth - 1, width: expW),
                      sgn < intNeg,
                      zeroInt < ~intAbs.or(),
                      ovfHold < 0,
                      state < sNormInt,
                    ],
                  ),
                ],
              ),
            ]),
            // Shift the magnitude up until its top bit appears. A zero source
            // has no top bit, so the zero test also stops the loop.
            CaseItem(st(sNormInt), [
              If(
                val[vw - 1] | zeroInt,
                then: [state < sRound],
                orElse: [
                  val < [val.slice(vw - 2, 0), Const(0)].swizzle(),
                  expv < expv - 1,
                ],
              ),
            ]),
            // Shift the significand to the integer position, up or down. A
            // right shift keeps everything it drops in the sticky bit.
            CaseItem(st(sShiftFp), [
              If(
                cnt.eq(Const(0, width: cntW)),
                then: [state < sDone],
                orElse: [val < shiftStep, cnt < cnt - 1],
              ),
            ]),
            CaseItem(st(sRound), [
              resReg < packed,
              flagsReg < fpExceptionFlags(inexact: gBit | sBit),
              state < sDone,
            ]),
            CaseItem(st(sDone), [
              If(~start, then: [state < sIdle]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
