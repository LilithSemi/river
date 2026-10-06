/// Compatibility layer for migrating from old riscv package types
/// to Harbor equivalents.
library;

import 'package:harbor/harbor.dart' hide PrivilegeMode;
import 'package:river/river.dart' show Trap, Register, RiscVMxlen;
import 'microcode_rom.dart' show MicroOpEncoding, BitRange, BitStruct;

/// Compatibility wrapper for RiscVMicroOp with encoding fields.
abstract class MicroOp {
  /// Bit range of the funct field in the micro-op encoding.
  static const BitRange functRange = BitRange(0, 4);
}

// Funct constants for each micro-op type, matching MicrocodeRom._mopFunct
abstract class ReadCsrMicroOp {
  static const int funct = 22;
}

abstract class WriteCsrMicroOp {
  static const int funct = 1;
}

abstract class ReadRegisterMicroOp {
  static const int funct = 2;
}

abstract class WriteRegisterMicroOp {
  static const int funct = 3;
}

abstract class AluMicroOp {
  static const int funct = 5;
}

abstract class UpdatePCMicroOp {
  static const int funct = 7;
}

abstract class MemLoadMicroOp {
  static const int funct = 8;
}

abstract class MemStoreMicroOp {
  static const int funct = 9;
}

abstract class TrapMicroOp {
  static const int funct = 10;
}

abstract class ReturnMicroOp {
  static const int funct = 14;
}

// wfi's wait micro-op. funct mirrors MicrocodeRom._mopFunct (20). A real funct,
// not the 0 catch-all (which is the dynamic interpreter's empty padding case).
abstract class WaitForInterruptMicroOp {
  static const int funct = 20;
}

abstract class BranchIfMicroOp {
  static const int funct = 6;
}

abstract class WriteLinkRegisterMicroOp {
  static const int funct = 15;
}

abstract class FenceMicroOp {
  static const int funct = 13;
}

abstract class TlbFenceMicroOp {
  static const int funct = 11;
}

abstract class TlbInvalidateMicroOp {
  static const int funct = 12;
}

abstract class InterruptHoldMicroOp {
  static const int funct = 16;
}

abstract class CopyFieldMicroOp {
  static const int funct = 23;
}

abstract class SetFieldMicroOpFunct {
  static const int funct = 24;
}

/// Placeholder micro-op types that don't exist in Harbor.
abstract class ValidateFieldMicroOp {
  static const int funct = 100;
}

abstract class SetFieldMicroOp {
  static const int funct = 101;
}

abstract class ModifyLatchMicroOp {
  static const int funct = 102;
}

abstract class FpuMicroOp {
  static const int funct = 25;
}

// Atomic micro-ops (funct values mirror MicrocodeRom._mopFunct).
abstract class LoadReservedMicroOp {
  static const int funct = 17;
}

abstract class StoreConditionalMicroOp {
  static const int funct = 18;
}

abstract class AtomicMemoryMicroOp {
  static const int funct = 19;
  // RiscVAtomicFunct has 10 members -> 4-bit op selector in the ROM word.
  static const int functWidth = 4;
}

class MicroOpFpuFunct {
  static int get width => RiscVFpuFunct.values.length.bitLength;

  static const int fadd = 0;
  static const int fsub = 1;
  static const int fmul = 2;
  static const int fdiv = 3;
  static const int fsqrt = 4;
  static const int fcvtWS = 5;
  static const int fcvtSW = 6;
  static const int fcvtLS = 7;
  static const int fcvtSL = 8;
  static const int fcvtWD = 9;
  static const int fcvtDW = 10;
  static const int fcvtLD = 11;
  static const int fcvtDL = 12;
  static const int fcvtSD = 13;
  static const int fcvtDS = 14;
  static const int feq = 15;
  static const int flt = 16;
  static const int fle = 17;
  static const int fmv = 18;
  static const int fclass = 19;
  static const int fsgnj = 20;
  static const int fsgnjn = 21;
  static const int fsgnjx = 22;
  static const int fmin = 23;
  static const int fmax = 24;
  // Fused multiply-add (R4-type): rd = +-(a*b) +- c.
  static const int fmadd = 25;
  static const int fmsub = 26;
  static const int fnmsub = 27;
  static const int fnmadd = 28;

  MicroOpFpuFunct._();
}

/// ALU function codes with old API names.
class MicroOpAluFunct {
  static int get width => RiscVAluFunct.values.length.bitLength;

  static const int add = 0;
  static const int sub = 1;
  static const int and = 2;
  static const int or = 3;
  static const int xor = 4;
  static const int sll = 5;
  static const int srl = 6;
  static const int sra = 7;
  static const int slt = 8;
  static const int sltu = 9;
  static const int mul = 10;
  static const int mulh = 11;
  static const int mulhsu = 12;
  static const int mulhu = 13;
  static const int div = 14;
  static const int divu = 15;
  static const int rem = 16;
  static const int remu = 17;
  static const int addw = 18;
  static const int subw = 19;
  static const int sllw = 20;
  static const int srlw = 21;
  static const int sraw = 22;
  static const int mulw = 23;
  static const int divw = 24;
  static const int divuw = 25;
  static const int remw = 26;
  static const int remuw = 27;
  static const int masked = 28;
  // Zbb min/max (RiscVAluFunct enum indices). rc1-f has no Zbb so the ROM never
  // emits these, but the shared ALU implements them (reusing slt/sltu) so the
  // AMO read-modify-write combine can route min/max/minu/maxu through this ONE
  // unit instead of a dedicated 9-way afunct mux.
  static const int minOp = 31;
  static const int maxOp = 32;
  static const int minuOp = 33;
  static const int maxuOp = 34;
  // Zicond: conditional-zero. Values are the RiscVAluFunct enum indices (the
  // funct stored in the microcode ROM), not a dense local numbering.
  static const int czeroEqz = 61;
  static const int czeroNez = 62;

  MicroOpAluFunct._();
}

/// Branch/comparison conditions with old API names.
class MicroOpCondition {
  static const int width = 4;

  static const int eq = 0;
  static const int ne = 1;
  static const int lt = 2;
  static const int ge = 3;
  static const int ltu = 4;
  static const int geu = 5;
  static const int gt = 6;
  static const int le = 7;

  MicroOpCondition._();
}

/// Micro-op field references with old API names.
class MicroOpField {
  static const int width = 3;

  static const int rd = 0;
  static const int rs1 = 1;
  static const int rs2 = 2;
  static const int rs3 = 3;
  static const int imm = 4;
  static const int pc = 5;
  static const int sp = 5;

  MicroOpField._();
}

/// Micro-op data sources with old API names.
class MicroOpSource {
  static const int width = 3;

  static const int alu = 0;
  static const int imm = 1;
  static const int rs1 = 2;
  static const int rs2 = 3;
  static const int pc = 4;
  static const int rd = 5;

  MicroOpSource._();
}

/// Memory size encoding with old API names.
class MicroOpMemSize {
  static int get width => RiscVMemSize.values.length.bitLength;

  static const List<RiscVMemSize> values = RiscVMemSize.values;

  MicroOpMemSize._();
}

/// Link register targets for WriteLinkRegister micro-op.
enum MicroOpLink {
  rd,
  ra;

  int get value => index;
  static int get width => MicroOpLink.values.length.bitLength;

  /// Register target for the link.
  Register? get reg => switch (this) {
    MicroOpLink.ra => Register.x1,
    _ => null,
  };

  /// Source for dynamic link register.
  RiscVMicroOpSource? get source => switch (this) {
    MicroOpLink.rd => RiscVMicroOpSource.rd,
    _ => null,
  };
}

/// Extension to add `bits` and `value` getters to RiscVMemSize.
extension RiscVMemSizeBitsExt on RiscVMemSize {
  int get bits => bytes * 8;
  int get value => index;
}

/// Extension to add `value` getter to RiscVMicroOpSource.
extension RiscVMicroOpSourceValueExt on RiscVMicroOpSource {
  int get value => id;
}

/// Extension to add `value` getter to RiscVMicroOpField.
extension RiscVMicroOpFieldValueExt on RiscVMicroOpField {
  int get value => id;
}

/// Extension to add `mcauseCode` getter to Trap.
extension TrapMcauseCodeExt on Trap {
  int get mcauseCode => causeCode;
}

/// Extension to add `width` (bytes) getter to RiscVMxlen.
extension RiscVMxlenWidthExt on RiscVMxlen {
  int get width => bytes;
}

/// Extension to add `indexedMicrocode` to RiscVOperation.
extension RiscVOperationIndexedExt on RiscVOperation {
  /// Returns microcode as a map indexed by position.
  Map<int, RiscVMicroOp> get indexedMicrocode => Map.fromEntries(
    microcode.asMap().entries.map((e) => MapEntry(e.key, e.value)),
  );
}

/// Microcode table: maps each micro-op type to its ROM encoding layout.
final List<MicroOpEncoding> kMicroOpTable = [
  MicroOpEncoding(
    name: 'ReadRegister',
    funct: ReadRegisterMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'source': BitRange(5, 5 + MicroOpField.width - 1),
      'offset': BitRange(
        5 + MicroOpField.width,
        5 + MicroOpField.width + mxlen.size - 1,
      ),
      // 1 = the operand names a floating-point register. `valueOffset` used to
      // sit here as a second XLEN-wide field, but toMap always wrote 0 to it,
      // so it was 64 bits of ROM and 64 bits of decode that could never do
      // anything. Dropping it also narrows the ROM word, which shortens the
      // bus from the ROM block RAM into the operand mux.
      'fp': BitRange(
        5 + MicroOpField.width + mxlen.size,
        5 + MicroOpField.width + mxlen.size,
      ),
    }),
    toMap: (mop) {
      final m = mop as RiscVReadRegister;
      return {
        'funct': ReadRegisterMicroOp.funct,
        'source': m.source.id,
        'offset': m.offset,
        'fp': m.fp ? 1 : 0,
      };
    },
  ),
  MicroOpEncoding(
    name: 'WriteRegister',
    funct: WriteRegisterMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'field': BitRange(5, 5 + MicroOpField.width - 1),
      'source': BitRange(
        5 + MicroOpField.width,
        5 + MicroOpField.width + MicroOpSource.width - 1,
      ),
      // `offset` used to sit here as an XLEN-wide field, but toMap always
      // wrote 0 to it, so it was 64 bits of ROM and 64 bits of decode that
      // could never do anything. It is gone.
      'valueOffset': BitRange(
        5 + MicroOpField.width + MicroOpSource.width,
        5 + MicroOpField.width + MicroOpSource.width + mxlen.size - 1,
      ),
      // 1 = the destination names a floating-point register.
      'fp': BitRange(
        5 + MicroOpField.width + MicroOpSource.width + mxlen.size,
        5 + MicroOpField.width + MicroOpSource.width + mxlen.size,
      ),
      // 1 = the value is a 32-bit single-precision datum, so the write must set
      // all the upper bits of the 64-bit FP register (NaN boxing).
      'nanBox': BitRange(
        5 + MicroOpField.width + MicroOpSource.width + mxlen.size + 1,
        5 + MicroOpField.width + MicroOpSource.width + mxlen.size + 1,
      ),
    }),
    toMap: (mop) {
      final m = mop as RiscVWriteRegister;
      return {
        'funct': WriteRegisterMicroOp.funct,
        'field': m.dest.id,
        'source': m.source.id,
        'valueOffset': m.valueOffset,
        'fp': m.fp ? 1 : 0,
        'nanBox': m.nanBox ? 1 : 0,
      };
    },
  ),
  MicroOpEncoding(
    name: 'Alu',
    funct: AluMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'alu': BitRange(5, 5 + MicroOpAluFunct.width - 1),
      'a': BitRange(
        5 + MicroOpAluFunct.width,
        5 + MicroOpAluFunct.width + MicroOpField.width - 1,
      ),
      'b': BitRange(
        5 + MicroOpAluFunct.width + MicroOpField.width,
        5 + MicroOpAluFunct.width + MicroOpField.width * 2 - 1,
      ),
    }),
    toMap: (mop) {
      final m = mop as RiscVAlu;
      return {
        'funct': AluMicroOp.funct,
        'alu': m.funct.index,
        'a': m.a.id,
        'b': m.b.id,
      };
    },
  ),
  MicroOpEncoding(
    name: 'BranchIf',
    funct: BranchIfMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'condition': BitRange(5, 5 + MicroOpCondition.width - 1),
      'target': BitRange(
        5 + MicroOpCondition.width,
        5 + MicroOpCondition.width + MicroOpField.width - 1,
      ),
      'hasField': BitRange(
        5 + MicroOpCondition.width + MicroOpField.width,
        5 + MicroOpCondition.width + MicroOpField.width,
      ),
      'offset': BitRange(
        5 + MicroOpCondition.width + MicroOpField.width + 1,
        5 + MicroOpCondition.width + MicroOpField.width + mxlen.size,
      ),
      'offsetField': BitRange(
        5 + MicroOpCondition.width + MicroOpField.width + mxlen.size + 1,
        5 + MicroOpCondition.width + MicroOpField.width * 2 + mxlen.size,
      ),
    }),
    toMap: (mop) {
      final m = mop as RiscVBranch;
      return {
        'funct': BranchIfMicroOp.funct,
        'condition': m.condition.index,
        'target': 0,
        'hasField': 0,
        'offset': 0,
        'offsetField': 0,
      };
    },
  ),
  MicroOpEncoding(
    name: 'UpdatePC',
    funct: UpdatePCMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'absolute': BitRange(5, 5),
      'align': BitRange(6, 6),
      'hasField': BitRange(7, 7),
      'hasSource': BitRange(8, 8),
      'offset': BitRange(9, 9 + mxlen.size - 1),
      'offsetField': BitRange(
        9 + mxlen.size,
        9 + mxlen.size + MicroOpField.width - 1,
      ),
      'offsetSource': BitRange(
        9 + mxlen.size + MicroOpField.width,
        9 + mxlen.size + MicroOpField.width + MicroOpSource.width - 1,
      ),
    }),
    toMap: (mop) {
      final m = mop as RiscVUpdatePc;
      return {
        'funct': UpdatePCMicroOp.funct,
        'absolute': m.absolute ? 1 : 0,
        'align': m.align ? 1 : 0,
        'hasField': m.offsetField != null ? 1 : 0,
        'hasSource': m.offsetSource != null ? 1 : 0,
        'offset': m.offset,
        'offsetField': m.offsetField?.id ?? 0,
        'offsetSource': m.offsetSource?.id ?? 0,
      };
    },
  ),
  MicroOpEncoding(
    name: 'MemLoad',
    funct: MemLoadMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'base': BitRange(5, 5 + MicroOpField.width - 1),
      'dest': BitRange(5 + MicroOpField.width, 5 + MicroOpField.width * 2 - 1),
      'size': BitRange(
        5 + MicroOpField.width * 2,
        5 + MicroOpField.width * 2 + MicroOpMemSize.width - 1,
      ),
      'unsigned': BitRange(
        5 + MicroOpField.width * 2 + MicroOpMemSize.width,
        5 + MicroOpField.width * 2 + MicroOpMemSize.width,
      ),
    }),
    toMap: (mop) {
      final m = mop as RiscVMemLoad;
      return {
        'funct': MemLoadMicroOp.funct,
        'base': m.base.id,
        'dest': m.dest.id,
        'size': m.size.index,
        'unsigned': m.unsigned ? 1 : 0,
      };
    },
  ),
  MicroOpEncoding(
    name: 'MemStore',
    funct: MemStoreMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'base': BitRange(5, 5 + MicroOpField.width - 1),
      'src': BitRange(5 + MicroOpField.width, 5 + MicroOpField.width * 2 - 1),
      'size': BitRange(
        5 + MicroOpField.width * 2,
        5 + MicroOpField.width * 2 + MicroOpMemSize.width - 1,
      ),
    }),
    toMap: (mop) {
      final m = mop as RiscVMemStore;
      return {
        'funct': MemStoreMicroOp.funct,
        'base': m.base.id,
        'src': m.src.id,
        'size': m.size.index,
      };
    },
  ),
  MicroOpEncoding(
    name: 'Trap',
    funct: TrapMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'causeCode': BitRange(5, 10),
      'isInterrupt': BitRange(11, 11),
      'modeCause': BitRange(12, 12),
    }),
    toMap: (mop) {
      final m = mop as RiscVTrapOp;
      return {
        'funct': TrapMicroOp.funct,
        'causeCode': m.causeCode,
        'isInterrupt': m.isInterrupt ? 1 : 0,
        'modeCause': m.modeCause ? 1 : 0,
      };
    },
  ),
  // MRET/SRET. The interpreter recovers the target privilege (3=M mret, 1=S
  // sret) from this encoded field so core.dart picks {m,s}epc / {m,s}status.xPP.
  // Without it the ROM stores a bare funct=14 and mret/sret are indistinguishable.
  MicroOpEncoding(
    name: 'Return',
    funct: ReturnMicroOp.funct,
    struct: (mxlen) =>
        BitStruct({'funct': BitRange(0, 4), 'privilegeLevel': BitRange(5, 7)}),
    toMap: (mop) {
      final m = mop as RiscVReturnOp;
      return {'funct': ReturnMicroOp.funct, 'privilegeLevel': m.privilegeLevel};
    },
  ),
  MicroOpEncoding(
    name: 'WriteLinkRegister',
    funct: WriteLinkRegisterMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'link': BitRange(5, 5 + MicroOpLink.width - 1),
      'pcOffset': BitRange(
        5 + MicroOpLink.width,
        5 + MicroOpLink.width + mxlen.size - 1,
      ),
    }),
    toMap: (mop) {
      // pcOffset is the instruction length that forms the link (return) address
      // = PC + len. It MUST come from the op, not a fixed 4: compressed calls
      // (c.jalr, rv_c.dart) carry pcOffset: 2, and hardcoding 4 here returned
      // two bytes too far, breaking every function-pointer/vtable call on rc1-s.
      final m = mop as RiscVWriteLinkRegister;
      return {
        'funct': WriteLinkRegisterMicroOp.funct,
        'link': MicroOpLink.rd.value,
        'pcOffset': m.pcOffset,
      };
    },
  ),
  MicroOpEncoding(
    name: 'ReadCsr',
    funct: ReadCsrMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'source': BitRange(5, 5 + MicroOpField.width - 1),
    }),
    toMap: (mop) {
      final m = mop as RiscVReadCsr;
      return {'funct': ReadCsrMicroOp.funct, 'source': m.source.id};
    },
  ),
  MicroOpEncoding(
    name: 'WriteCsr',
    funct: WriteCsrMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'field': BitRange(5, 5 + MicroOpField.width - 1),
      'source': BitRange(
        5 + MicroOpField.width,
        5 + MicroOpField.width + MicroOpSource.width - 1,
      ),
    }),
    toMap: (mop) {
      final m = mop as RiscVWriteCsr;
      return {
        'funct': WriteCsrMicroOp.funct,
        'field': m.dest.id,
        'source': m.source.id,
      };
    },
  ),
  MicroOpEncoding(
    name: 'Fence',
    funct: FenceMicroOp.funct,
    struct: (mxlen) => BitStruct({'funct': BitRange(0, 4)}),
    toMap: (mop) => {'funct': FenceMicroOp.funct},
  ),
  MicroOpEncoding(
    name: 'InterruptHold',
    funct: InterruptHoldMicroOp.funct,
    struct: (mxlen) => BitStruct({'funct': BitRange(0, 4)}),
    toMap: (mop) => {'funct': InterruptHoldMicroOp.funct},
  ),
  MicroOpEncoding(
    name: 'CopyField',
    funct: CopyFieldMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'src': BitRange(5, 5 + MicroOpField.width - 1),
      'dest': BitRange(5 + MicroOpField.width, 5 + MicroOpField.width * 2 - 1),
    }),
    toMap: (mop) {
      final m = mop as RiscVCopyField;
      return {
        'funct': CopyFieldMicroOp.funct,
        'src': m.src.id,
        'dest': m.dest.id,
      };
    },
  ),
  MicroOpEncoding(
    name: 'MoveToField',
    funct: SetFieldMicroOpFunct.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'src': BitRange(5, 5 + MicroOpSource.width - 1),
      'dest': BitRange(
        5 + MicroOpSource.width,
        5 + MicroOpSource.width + MicroOpField.width - 1,
      ),
    }),
    toMap: (mop) {
      final m = mop as RiscVSetField;
      return {
        'funct': SetFieldMicroOpFunct.funct,
        'src': m.src.id,
        'dest': m.dest.id,
      };
    },
  ),
  MicroOpEncoding(
    name: 'TlbFence',
    funct: TlbFenceMicroOp.funct,
    struct: (mxlen) => BitStruct({'funct': BitRange(0, 4)}),
    toMap: (mop) => {'funct': TlbFenceMicroOp.funct},
  ),
  MicroOpEncoding(
    name: 'TlbInvalidate',
    funct: TlbInvalidateMicroOp.funct,
    struct: (mxlen) => BitStruct({'funct': BitRange(0, 4)}),
    toMap: (mop) => {'funct': TlbInvalidateMicroOp.funct},
  ),
  MicroOpEncoding(
    name: 'FpuOp',
    funct: FpuMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'fpuFunct': BitRange(5, 5 + MicroOpFpuFunct.width - 1),
      'a': BitRange(
        5 + MicroOpFpuFunct.width,
        5 + MicroOpFpuFunct.width + MicroOpField.width - 1,
      ),
      'dest': BitRange(
        5 + MicroOpFpuFunct.width + MicroOpField.width,
        5 + MicroOpFpuFunct.width + MicroOpField.width * 2 - 1,
      ),
      'hasB': BitRange(
        5 + MicroOpFpuFunct.width + MicroOpField.width * 2,
        5 + MicroOpFpuFunct.width + MicroOpField.width * 2,
      ),
      'b': BitRange(
        5 + MicroOpFpuFunct.width + MicroOpField.width * 2 + 1,
        5 + MicroOpFpuFunct.width + MicroOpField.width * 3,
      ),
      'doublePrecision': BitRange(
        5 + MicroOpFpuFunct.width + MicroOpField.width * 3 + 1,
        5 + MicroOpFpuFunct.width + MicroOpField.width * 3 + 1,
      ),
      // Third source operand (rs3), used only by the fused multiply-add ops.
      // Appended after 'doublePrecision' so no existing bit position moves.
      'hasC': BitRange(
        5 + MicroOpFpuFunct.width + MicroOpField.width * 3 + 2,
        5 + MicroOpFpuFunct.width + MicroOpField.width * 3 + 2,
      ),
      'c': BitRange(
        5 + MicroOpFpuFunct.width + MicroOpField.width * 3 + 3,
        5 + MicroOpFpuFunct.width + MicroOpField.width * 4 + 2,
      ),
    }),
    toMap: (mop) {
      final m = mop as RiscVFpuOp;
      return {
        'funct': FpuMicroOp.funct,
        'fpuFunct': m.funct.index,
        'a': m.a.id,
        'dest': m.dest.id,
        'hasB': m.b != null ? 1 : 0,
        'b': m.b?.id ?? 0,
        'doublePrecision': m.doublePrecision ? 1 : 0,
        'hasC': m.c != null ? 1 : 0,
        'c': m.c?.id ?? 0,
      };
    },
  ),
  // Load-reserved: like MemLoad (base -> dest, size) but tags a reservation.
  MicroOpEncoding(
    name: 'LoadReserved',
    funct: LoadReservedMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'base': BitRange(5, 5 + MicroOpField.width - 1),
      'dest': BitRange(5 + MicroOpField.width, 5 + MicroOpField.width * 2 - 1),
      'size': BitRange(
        5 + MicroOpField.width * 2,
        5 + MicroOpField.width * 2 + MicroOpMemSize.width - 1,
      ),
    }),
    toMap: (mop) {
      final m = mop as RiscVLoadReserved;
      return {
        'funct': LoadReservedMicroOp.funct,
        'base': m.base.id,
        'dest': m.dest.id,
        'size': m.size.index,
      };
    },
  ),
  // Store-conditional: store src to [base], write success/fail flag to dest.
  MicroOpEncoding(
    name: 'StoreConditional',
    funct: StoreConditionalMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'base': BitRange(5, 5 + MicroOpField.width - 1),
      'src': BitRange(5 + MicroOpField.width, 5 + MicroOpField.width * 2 - 1),
      'dest': BitRange(
        5 + MicroOpField.width * 2,
        5 + MicroOpField.width * 3 - 1,
      ),
      'size': BitRange(
        5 + MicroOpField.width * 3,
        5 + MicroOpField.width * 3 + MicroOpMemSize.width - 1,
      ),
    }),
    toMap: (mop) {
      final m = mop as RiscVStoreConditional;
      return {
        'funct': StoreConditionalMicroOp.funct,
        'base': m.base.id,
        'src': m.src.id,
        'dest': m.dest.id,
        'size': m.size.index,
      };
    },
  ),
  // AMO: read-modify-write. afunct selects the operation, old value -> dest.
  MicroOpEncoding(
    name: 'AtomicMemory',
    funct: AtomicMemoryMicroOp.funct,
    struct: (mxlen) => BitStruct({
      'funct': BitRange(0, 4),
      'afunct': BitRange(5, 5 + AtomicMemoryMicroOp.functWidth - 1),
      'base': BitRange(
        5 + AtomicMemoryMicroOp.functWidth,
        5 + AtomicMemoryMicroOp.functWidth + MicroOpField.width - 1,
      ),
      'src': BitRange(
        5 + AtomicMemoryMicroOp.functWidth + MicroOpField.width,
        5 + AtomicMemoryMicroOp.functWidth + MicroOpField.width * 2 - 1,
      ),
      'dest': BitRange(
        5 + AtomicMemoryMicroOp.functWidth + MicroOpField.width * 2,
        5 + AtomicMemoryMicroOp.functWidth + MicroOpField.width * 3 - 1,
      ),
      'size': BitRange(
        5 + AtomicMemoryMicroOp.functWidth + MicroOpField.width * 3,
        5 +
            AtomicMemoryMicroOp.functWidth +
            MicroOpField.width * 3 +
            MicroOpMemSize.width -
            1,
      ),
    }),
    toMap: (mop) {
      final m = mop as RiscVAtomicMemory;
      return {
        'funct': AtomicMemoryMicroOp.funct,
        'afunct': m.funct.index,
        'base': m.base.id,
        'src': m.src.id,
        'dest': m.dest.id,
        'size': m.size.index,
      };
    },
  ),
];
