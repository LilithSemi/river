/// Exact IEEE binary fused multiply-add, rounded once to nearest/even.
/// Integer significands and powers of two avoid the host's separately rounded
/// `a * b + c` expression. Inputs/outputs are packed IEEE bit patterns.
int fusedBits(
  int aBits,
  int bBits,
  int cBits, {
  required int exponentBits,
  required int fractionBits,
  bool negateProduct = false,
  bool negateAddend = false,
}) {
  final width = 1 + exponentBits + fractionBits;
  final signMask = BigInt.one << (width - 1);
  final fractionMask = (BigInt.one << fractionBits) - BigInt.one;
  final maxExponent = (1 << exponentBits) - 1;
  final bias = (1 << (exponentBits - 1)) - 1;
  ({bool negative, bool nan, bool inf, BigInt significand, int exponent})
  unpack(int bits) {
    final raw = BigInt.from(bits).toUnsigned(width);
    final exp = ((raw >> fractionBits) & BigInt.from(maxExponent)).toInt();
    final fraction = raw & fractionMask;
    return (
      negative: (raw & signMask) != BigInt.zero,
      nan: exp == maxExponent && fraction != BigInt.zero,
      inf: exp == maxExponent && fraction == BigInt.zero,
      significand: exp == 0
          ? fraction
          : (BigInt.one << fractionBits) | fraction,
      exponent: (exp == 0 ? 1 : exp) - bias - fractionBits,
    );
  }

  final a = unpack(aBits), b = unpack(bBits), c = unpack(cBits);
  final productSign = a.negative ^ b.negative ^ negateProduct;
  final cSign = c.negative ^ negateAddend;
  final infinity = BigInt.from(maxExponent) << fractionBits;
  final nan = infinity | (BigInt.one << (fractionBits - 1));
  int bits(BigInt value) => value.toSigned(64).toInt();
  final invalidProduct =
      (a.inf && b.significand == BigInt.zero) ||
      (b.inf && a.significand == BigInt.zero);
  if (a.nan ||
      b.nan ||
      c.nan ||
      invalidProduct ||
      ((a.inf || b.inf) && c.inf && productSign != cSign)) {
    return bits(nan);
  }
  if (a.inf || b.inf)
    return bits(infinity | (productSign ? signMask : BigInt.zero));
  if (c.inf) return bits(infinity | (cSign ? signMask : BigInt.zero));
  final product = a.significand * b.significand;
  final productExponent = a.exponent + b.exponent;
  final common = productExponent < c.exponent ? productExponent : c.exponent;
  final p = product << (productExponent - common);
  final q = c.significand << (c.exponent - common);
  final sum = (productSign ? -p : p) + (cSign ? -q : q);
  if (sum == BigInt.zero) {
    return bits(
      product == BigInt.zero &&
              c.significand == BigInt.zero &&
              productSign &&
              cSign
          ? signMask
          : BigInt.zero,
    );
  }
  final sign = sum.isNegative ? signMask : BigInt.zero;
  final magnitude = sum.abs();
  final leadingExponent = magnitude.bitLength - 1 + common;
  final minQuantum = 1 - bias - fractionBits;
  final normalQuantum = leadingExponent - fractionBits;
  final quantum = normalQuantum < minQuantum ? minQuantum : normalQuantum;
  final shift = quantum - common;
  BigInt rounded;
  if (shift <= 0) {
    rounded = magnitude << -shift;
  } else {
    rounded = magnitude >> shift;
    final remainder = magnitude - (rounded << shift);
    final half = BigInt.one << (shift - 1);
    if (remainder > half || (remainder == half && rounded.isOdd))
      rounded += BigInt.one;
  }
  if (rounded == BigInt.zero) return bits(sign);
  final exponent = rounded.bitLength - 1 + quantum;
  if (exponent > maxExponent - 1 - bias) return bits(sign | infinity);
  if (exponent < 1 - bias) return bits(sign | rounded);
  final significand = rounded >> (rounded.bitLength - 1 - fractionBits);
  return bits(
    sign |
        (BigInt.from(exponent + bias) << fractionBits) |
        (significand & fractionMask),
  );
}
