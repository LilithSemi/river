import 'package:harbor/harbor.dart';

/// Supplementary F/D operations that Harbor's `rvF`/`rvD` extensions do not
/// yet define as instructions, but whose [RiscVFpuFunct] values already exist
/// (and which the emulator implements): sign-injection (fsgnj/fsgnjn/fsgnjx),
/// fmin/fmax, fclass, and the raw bit-move fmv. Kept on the river side so
/// Harbor stays untouched; add to a config's extension list alongside rvF/rvD.
///
/// misaBit is null (mask 0) so this does not affect the reported misa, rvF/rvD
/// already set the F/D bits. All ops are OP-FP (opcode 0x53), distinguished by
/// funct7/funct3, with no collisions against the existing F/D encodings.

const _fp32 = RiscVFloatRegFile(32);
const _fp64 = RiscVFloatRegFile(64);
const _int = RiscVIntRegFile(32);

// Binary FP op (two FP sources, FP dest): fsgnj*/fmin/fmax.
RiscVOperation _binFp(
  String mnemonic,
  int funct7,
  int funct3,
  RiscVFpuFunct funct,
  RiscVFloatRegFile fp, {
  required bool dp,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: 0x53,
  funct7: funct7,
  funct3: funct3,
  format: rType,
  resources: [
    RfResource(fp, rs1),
    RfResource(fp, rs2),
    RfResource(fp, rd),
    FpuResource(),
  ],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
    RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
    RiscVFpuOp(
      funct,
      RiscVMicroOpField.rs1,
      RiscVMicroOpField.rd,
      b: RiscVMicroOpField.rs2,
      doublePrecision: dp,
    ),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd, fp: true),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

// Unary FP->int op: fclass, fmv.x.w/fmv.x.d.
RiscVOperation _fpToInt(
  String mnemonic,
  int funct7,
  int funct3,
  RiscVFpuFunct funct,
  RiscVFloatRegFile fp, {
  required bool dp,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: 0x53,
  funct7: funct7,
  funct3: funct3,
  format: rType,
  resources: [RfResource(fp, rs1), RfResource(_int, rd), FpuResource()],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
    RiscVFpuOp(
      funct,
      RiscVMicroOpField.rs1,
      RiscVMicroOpField.rd,
      doublePrecision: dp,
    ),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

// Unary int->FP op: fmv.w.x/fmv.d.x (raw bit move).
RiscVOperation _intToFp(
  String mnemonic,
  int funct7,
  int funct3,
  RiscVFloatRegFile fp, {
  required bool dp,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: 0x53,
  funct7: funct7,
  funct3: funct3,
  format: rType,
  resources: [RfResource(_int, rs1), RfResource(fp, rd), FpuResource()],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1),
    RiscVFpuOp(
      RiscVFpuFunct.fmv,
      RiscVMicroOpField.rs1,
      RiscVMicroOpField.rd,
      doublePrecision: dp,
    ),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd, fp: true),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

/// Supplementary single-precision (F) ops.
final RiscVExtension rvFExtra = RiscVExtension(
  name: 'Fx',
  operations: [
    _binFp('fsgnj.s', 0x10, 0x0, RiscVFpuFunct.fsgnj, _fp32, dp: false),
    _binFp('fsgnjn.s', 0x10, 0x1, RiscVFpuFunct.fsgnjn, _fp32, dp: false),
    _binFp('fsgnjx.s', 0x10, 0x2, RiscVFpuFunct.fsgnjx, _fp32, dp: false),
    _binFp('fmin.s', 0x14, 0x0, RiscVFpuFunct.fmin, _fp32, dp: false),
    _binFp('fmax.s', 0x14, 0x1, RiscVFpuFunct.fmax, _fp32, dp: false),
    _fpToInt('fclass.s', 0x70, 0x1, RiscVFpuFunct.fclass, _fp32, dp: false),
    _fpToInt('fmv.x.w', 0x70, 0x0, RiscVFpuFunct.fmv, _fp32, dp: false),
    _intToFp('fmv.w.x', 0x78, 0x0, _fp32, dp: false),
  ],
);

/// Supplementary double-precision (D) ops.
final RiscVExtension rvDExtra = RiscVExtension(
  name: 'Dx',
  operations: [
    _binFp('fsgnj.d', 0x11, 0x0, RiscVFpuFunct.fsgnj, _fp64, dp: true),
    _binFp('fsgnjn.d', 0x11, 0x1, RiscVFpuFunct.fsgnjn, _fp64, dp: true),
    _binFp('fsgnjx.d', 0x11, 0x2, RiscVFpuFunct.fsgnjx, _fp64, dp: true),
    _binFp('fmin.d', 0x15, 0x0, RiscVFpuFunct.fmin, _fp64, dp: true),
    _binFp('fmax.d', 0x15, 0x1, RiscVFpuFunct.fmax, _fp64, dp: true),
    _fpToInt('fclass.d', 0x71, 0x1, RiscVFpuFunct.fclass, _fp64, dp: true),
    _fpToInt('fmv.x.d', 0x71, 0x0, RiscVFpuFunct.fmv, _fp64, dp: true),
    _intToFp('fmv.d.x', 0x79, 0x0, _fp64, dp: true),
  ],
);
