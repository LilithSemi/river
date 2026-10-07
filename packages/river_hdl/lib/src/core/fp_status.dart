import 'package:rohd/rohd.dart';

/// Increment the truncated magnitude for a legal RISC-V rounding mode.
/// The caller must reject reserved encodings before starting the operation.
Logic fpRoundUp({
  required Logic rm,
  required Logic sign,
  required Logic guard,
  required Logic sticky,
  required Logic lsb,
}) {
  final inexact = guard | sticky;
  return (rm.eq(Const(0, width: 3)) & guard & (sticky | lsb)) |
      (rm.eq(Const(2, width: 3)) & sign & inexact) |
      (rm.eq(Const(3, width: 3)) & ~sign & inexact) |
      (rm.eq(Const(4, width: 3)) & guard);
}

/// Select infinity rather than the largest finite magnitude on overflow.
Logic fpOverflowToInfinity(Logic rm, Logic sign) =>
    rm.eq(Const(0, width: 3)) |
    rm.eq(Const(4, width: 3)) |
    (rm.eq(Const(2, width: 3)) & sign) |
    (rm.eq(Const(3, width: 3)) & ~sign);

/// Architectural fflags ordering: NV, DZ, OF, UF, NX.
Logic fpExceptionFlags({
  Logic? invalid,
  Logic? divideByZero,
  Logic? overflow,
  Logic? underflow,
  Logic? inexact,
}) => [
  invalid ?? Const(0),
  divideByZero ?? Const(0),
  overflow ?? Const(0),
  underflow ?? Const(0),
  inexact ?? Const(0),
].swizzle();
