import 'package:river/river.dart';
import 'package:test/test.dart';

/// Zcd decode regression: c.fld / c.fsd / c.fldsp / c.fsdsp on rc1-f.
///
/// rc1-f gained these four compressed FP instructions. Adding encodings to the
/// compressed space can shadow an existing instruction, and a shadowed decode
/// is very hard to tell from a corrupt image: the board takes an illegal
/// instruction and nothing says whether the bytes or the decode were wrong.
///
/// The differential sweep below is the important part. It walks EVERY 16-bit
/// compressed encoding and asserts that adding Zcd changes the decode of
/// nothing at all except the four new instructions.
void main() {
  final config = RiverCoreConfigV1.full(
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

  final withZcd = config.extensions;
  final withoutZcd = config.extensions
      .where((e) => e.name != 'Zcd')
      .toList(growable: false);

  const zcdMnemonics = {'c.fld', 'c.fsd', 'c.fldsp', 'c.fsdsp'};

  String? decode(List<RiscVExtension> exts, int instr) {
    final opcode = instr & 0x3;
    final funct3 = (instr >> 13) & 0x7;
    for (final ext in exts) {
      final op = ext.findOperation(opcode, funct3: funct3, instruction: instr);
      if (op != null) return op.mnemonic;
    }
    return null;
  }

  test('Zcd is actually configured on rc1-f', () {
    expect(withZcd.length, withoutZcd.length + 1);
    expect(withZcd.any((e) => e.name == 'Zcd'), isTrue);
  });

  test('the four Zcd instructions decode', () {
    // Reference words from GNU as, -march=rv64gc, not hand arithmetic.
    final cases = {
      0x2d18: 'c.fld',
      0x25e4: 'c.fld',
      0xad10: 'c.fsd',
      0xa6fc: 'c.fsd',
      0x2122: 'c.fldsp',
      0x2fb2: 'c.fldsp',
      0xa822: 'c.fsdsp',
      0xa282: 'c.fsdsp',
    };
    cases.forEach((word, mnemonic) {
      expect(
        decode(withZcd, word),
        mnemonic,
        reason: '0x${word.toRadixString(16)} should decode as $mnemonic',
      );
    });
  });

  test('the integer siblings still win their own encodings', () {
    // These share the quadrant with the Zcd ops and differ only in funct3.
    final cases = {0x6118: 'c.ld', 0xe118: 'c.sd'};
    cases.forEach((word, mnemonic) {
      expect(decode(withZcd, word), mnemonic);
    });
  });

  test('Zcd shadows nothing across the whole compressed space', () {
    final shadowed = <String>[];
    final rejected = <String>[];
    var newlyDecoded = 0;
    for (var instr = 0; instr <= 0xFFFF; instr++) {
      // A compressed instruction has op != 0b11. 0x0000 is the defined illegal.
      if ((instr & 0x3) == 0x3 || instr == 0) continue;
      final base = decode(withoutZcd, instr);
      final zcd = decode(withZcd, instr);
      if (base == zcd) continue;
      final hex = '0x${instr.toRadixString(16).padLeft(4, '0')}';
      if (base == null && zcdMnemonics.contains(zcd)) {
        newlyDecoded++; // the intended new coverage
      } else if (base != null && zcd == null) {
        rejected.add('$hex: $base -> illegal');
      } else {
        shadowed.add('$hex: $base -> $zcd');
      }
    }
    expect(
      shadowed,
      isEmpty,
      reason: 'Zcd changed the meaning of existing instructions',
    );
    expect(
      rejected,
      isEmpty,
      reason: 'Zcd made previously valid instructions illegal',
    );
    expect(newlyDecoded, greaterThan(0), reason: 'Zcd decoded nothing new');
  });
}
