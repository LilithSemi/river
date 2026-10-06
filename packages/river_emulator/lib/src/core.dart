import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:river/river.dart' hide InterruptController;
import 'cache.dart';
import 'csr.dart';
import 'decoded_instruction.dart';
import 'dev.dart';
import 'mmu.dart';
import 'int.dart';
import 'pipeline.dart';
import 'plugins/csr_plugin.dart';
import 'plugins/mmu_plugin.dart';
import 'plugins/cache_plugin.dart';
import 'plugins/trap_plugin.dart';

// IEEE-754 bit<->double conversions (little-endian), shared by scalar and
// vector FP. SEW selects half (16, Zvfh) / single (32) / double (64).
double fpBitsToDouble(int bits, int sewBits) {
  if (sewBits == 16) return _halfBitsToDouble(bits & 0xFFFF);
  final bd = ByteData(8);
  if (sewBits >= 64) {
    bd.setUint64(0, bits, Endian.little);
    return bd.getFloat64(0, Endian.little);
  }
  bd.setUint32(0, bits & 0xFFFFFFFF, Endian.little);
  return bd.getFloat32(0, Endian.little);
}

int fpDoubleToBits(double v, int sewBits) {
  final bd = ByteData(8);
  if (sewBits == 16) {
    bd.setFloat32(0, v, Endian.little);
    return _f32BitsToHalf(bd.getUint32(0, Endian.little));
  }
  if (sewBits >= 64) {
    bd.setFloat64(0, v, Endian.little);
    return bd.getUint64(0, Endian.little);
  }
  bd.setFloat32(0, v, Endian.little);
  return bd.getUint32(0, Endian.little);
}

// IEEE-754 half (Zvfh): 1 sign / 5 exp / 10 mantissa. half->double is exact.
double _halfBitsToDouble(int h) {
  final sign = (h >> 15) & 1;
  final e = (h >> 10) & 0x1F;
  final mant = h & 0x3FF;
  double v;
  if (e == 0) {
    v = mant * math.pow(2, -24).toDouble(); // subnormal
  } else if (e == 0x1F) {
    v = mant == 0 ? double.infinity : double.nan;
  } else {
    v = (1 + mant / 1024.0) * math.pow(2, e - 15).toDouble();
  }
  return sign == 1 ? -v : v;
}

// float32 bits -> half bits, round-to-nearest-even.
int _f32BitsToHalf(int f) {
  final sign = (f >> 16) & 0x8000;
  final e = (f >> 23) & 0xFF;
  final mant = f & 0x7FFFFF;
  if (e == 0xFF) return sign | 0x7C00 | (mant != 0 ? 0x200 : 0); // inf/NaN
  final exp = e - 127 + 15;
  if (exp >= 0x1F) return sign | 0x7C00; // overflow -> inf
  if (exp <= 0) {
    if (exp < -10) return sign; // underflow -> +/-0
    final m = mant | 0x800000;
    final shift = 14 - exp;
    var h = m >> shift;
    final round = (m >> (shift - 1)) & 1;
    final sticky = (m & ((1 << (shift - 1)) - 1)) != 0;
    if (round == 1 && (sticky || (h & 1) == 1)) h++;
    return sign | h;
  }
  final h = mant >> 13;
  final round = (mant >> 12) & 1;
  final sticky = (mant & 0xFFF) != 0;
  var out = (exp << 10) | h;
  if (round == 1 && (sticky || (h & 1) == 1)) out++; // carry into exp is ok
  return sign | out;
}

class AbortException extends TrapException {
  final String message;

  const AbortException(super.trap, this.message, [super.tval, super.stack]);
  const AbortException.illegalInstruction(this.message, [StackTrace? stack])
    : super(Trap.illegal, null, stack);

  @override
  String toString() => 'AbortException($trap, "$message", $tval, $stack)';
}

class TrapException implements Exception {
  final Trap trap;
  final StackTrace? stack;

  const TrapException(this.trap, [this.tval, this.stack]);
  const TrapException.illegalInstruction([this.stack])
    : trap = Trap.illegal,
      tval = null;

  final int? tval;

  TrapException relocate(int offset) {
    switch (trap) {
      case Trap.loadAccess:
      case Trap.storeAccess:
        return TrapException(trap, offset + (tval ?? 0), stack);
      default:
        return this;
    }
  }

  @override
  String toString() =>
      'TrapException($trap, ${tval != null ? '0x${tval!.toRadixString(16)}' : null}, $stack)';
}

class RiverCoreState {
  int pc;
  int? _rs1;
  int? _rs2;
  int? _rs3;
  int? _rd;
  int? _imm;

  DecodedInstruction ir;

  RiverCoreState(this.pc, this.ir, this.sp) : alu = 0;

  int alu;
  int sp;
  int get rs1 => _rs1 ?? ir.rs1;
  int get rs2 => _rs2 ?? ir.rs2;
  int get rs3 => _rs3 ?? ir.rs3;
  int get rd => _rd ?? ir.rd;
  int get imm => _imm ?? ir.imm;

  int readSource(RiscVMicroOpSource source) {
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
        return pc;
    }
  }

  int readField(RiscVMicroOpField field, {bool register = true}) {
    switch (field) {
      case RiscVMicroOpField.rd:
        return register ? rd : ir.rd;
      case RiscVMicroOpField.rs1:
        return register ? rs1 : ir.rs1;
      case RiscVMicroOpField.rs2:
        return register ? rs2 : ir.rs2;
      case RiscVMicroOpField.rs3:
        return register ? rs3 : ir.rs3;
      case RiscVMicroOpField.imm:
        return register ? imm : ir.imm;
      case RiscVMicroOpField.pc:
        return pc;
    }
  }

  void clearField(RiscVMicroOpField field) {
    switch (field) {
      case RiscVMicroOpField.rd:
        _rd = null;
      case RiscVMicroOpField.rs1:
        _rs1 = null;
      case RiscVMicroOpField.rs2:
        _rs2 = null;
      case RiscVMicroOpField.rs3:
        _rs3 = null;
      case RiscVMicroOpField.imm:
        _imm = null;
      default:
        throw 'Invalid field $field';
    }
  }

  void writeField(RiscVMicroOpField field, int value) {
    switch (field) {
      case RiscVMicroOpField.rd:
        _rd = value;
      case RiscVMicroOpField.rs1:
        _rs1 = value;
      case RiscVMicroOpField.rs2:
        _rs2 = value;
      case RiscVMicroOpField.rs3:
        _rs3 = value;
      case RiscVMicroOpField.imm:
        _imm = value;
      default:
        throw 'Invalid field $field';
    }
  }

  @override
  String toString() =>
      'RiverCoreState($pc, $ir, rd: $rd, rs1: $rs1, rs2: $rs2, imm: $imm, alu: $alu, sp: $sp, pc: $pc)';
}

/// Couples [RiverCore] to an external debugger so an `ebreak` can enter Debug
/// Mode (halt) instead of trapping to mtvec. Set by [RiverDebugTarget] when a
/// debugger is attached, null when standalone.
abstract class DebugHook {
  /// Whether an `ebreak` executed in [mode] should enter Debug Mode, i.e. the
  /// matching dcsr.ebreakm/ebreaks/ebreaku bit is set.
  bool ebreakEntersDebug(PrivilegeMode mode);

  /// Enter Debug Mode: halt the hart, latch [dpc] (the ebreak's address) and the
  /// halt [cause] (1 = ebreak) into dcsr.
  void enterDebug(int dpc, int cause);
}

class RiverCore implements CsrContext {
  @override
  final RiverCoreConfig config;

  /// Optional hook to an attached external debugger (see [DebugHook]). When set
  /// and the relevant dcsr.ebreak* bit is armed, an `ebreak` halts into Debug
  /// Mode rather than raising a breakpoint trap.
  DebugHook? debugHook;

  final MmuPlugin _mmuPlugin;
  final CsrPlugin _csrPlugin;
  final CachePlugin _cachePlugin;
  final TrapPlugin _trapPlugin;

  Map<Register, int> xregs;
  // Raw 64-bit FP register bits, not a Dart double. The golden model must be
  // bit-exact, and a double cannot hold a NaN payload or a NaN-boxed f32.
  Map<int, int> fregs;
  List<int> _reservationSet;
  bool idle;

  // Vector (V) state, only present when the V extension is configured; a
  // V-less core never allocates [vregs] and traps OP-V as illegal. 32 registers
  // of VLEN bits (config.vlen), little-endian byte arrays, plus vl/vtype/vstart.
  late final bool hasVector = config.extensions.any((e) => e.name == 'V');
  late final int _vlenBytes = config.vlen ~/ 8;
  late final List<List<int>> vregs = List.generate(
    32,
    (_) => List<int>.filled(_vlenBytes, 0),
  );
  int vl = 0;
  int vtype = 0;
  int vstart = 0;
  int vxsat = 0; // fixed-point saturation flag (vcsr bit 0)
  int vxrm = 0; // fixed-point rounding mode (vcsr bits 2:1)

  /// Read element [idx] (sewBits wide) of vector register [vreg], little-endian.
  /// Element indices beyond one register span the register group (LMUL>1):
  /// element idx lives in physical register vreg + idx/elemsPerReg.
  int vreadElem(int vreg, int idx, int sewBits) {
    final bytes = sewBits ~/ 8;
    final perReg = _vlenBytes ~/ bytes;
    final r = (vreg + idx ~/ perReg) & 0x1F;
    final off = (idx % perReg) * bytes;
    var v = 0;
    for (var b = 0; b < bytes; b++) {
      v |= (vregs[r][off + b] & 0xFF) << (b * 8);
    }
    return v;
  }

  /// Write element [idx] (sewBits wide) of vector register [vreg]; spans the
  /// register group for LMUL>1 (see [vreadElem]).
  void vwriteElem(int vreg, int idx, int sewBits, int value) {
    final bytes = sewBits ~/ 8;
    final perReg = _vlenBytes ~/ bytes;
    final r = (vreg + idx ~/ perReg) & 0x1F;
    final off = (idx % perReg) * bytes;
    for (var b = 0; b < bytes; b++) {
      vregs[r][off + b] = (value >> (b * 8)) & 0xFF;
    }
  }

  CsrFile get csrs => _csrPlugin.csrs;

  @override
  PrivilegeMode get mode => _csrPlugin.mode;
  set mode(PrivilegeMode v) {
    // A privilege change ends any LR/SC sequence. Without this a reservation
    // placed in one context can be consumed by another and the SC succeeds
    // incorrectly. QEMU does the same in riscv_cpu_set_mode and cites ISA
    // version 2.2 as requiring it. This covers MRET/SRET; trap entry clears via
    // [trap] below. The RTL clears in exec.dart rawTrap and the return arms.
    _reservationSet.clear();
    _csrPlugin.mode = v;
  }

  /// Virtualization bit (H extension): true while executing in VS/VU mode.
  bool get virt => _csrPlugin.virt;
  set virt(bool v) => _csrPlugin.virt = v;

  /// Smstateen access gating. Returns the trap to raise when the current mode is
  /// denied access to a state-enable CSR (sstateen*/hstateen*) because the
  /// controlling SE0 bit (bit 63) is clear in the higher-level *stateen CSR, or
  /// null when the access is allowed. Only SE0 is implemented; it gates access to
  /// the lower-level state-enable CSRs themselves. mstateen0.SE0 denial is an
  /// illegal-instruction exception (from any mode below M); hstateen0.SE0 denial
  /// of a VS-mode sstateen access is a virtual-instruction exception.
  TrapException? _stateenDenied(int reg) {
    if (!config.hasStateen) return null;
    final isSstateen = reg >= 0x10C && reg <= 0x10F;
    final isHstateen = reg >= 0x60C && reg <= 0x60F;
    if (!isSstateen && !isHstateen) return null;
    if (mode.id >= 3) return null; // M-mode is never gated.
    final mse0 = (csrs.read(CsrAddress.mstateen0.address, this) >> 63) & 1;
    if (mse0 == 0) {
      return TrapException.illegalInstruction(StackTrace.current);
    }
    if (virt && isSstateen && config.hasHypervisor) {
      final hse0 = (csrs.read(CsrAddress.hstateen0.address, this) >> 63) & 1;
      if (hse0 == 0) {
        return TrapException(Trap.virtualInstruction, 0, StackTrace.current);
      }
    }
    return null;
  }

  @override
  Mmu get mmu => _mmuPlugin.mmu;

  Cache? get l1i => _cachePlugin.l1i;
  Cache? get l1d => _cachePlugin.l1d;

  final List<InterruptController> _interrupts;

  UnmodifiableListView<InterruptController> get interrupts =>
      UnmodifiableListView(_interrupts);

  UnmodifiableListView<int> get reservationSet =>
      UnmodifiableListView(_reservationSet);

  RiverCore(
    this.config, {
    Map<BusAddressRange, DeviceAccessor> memDevices = const {},
  }) : _mmuPlugin = MmuPlugin(config.mmu, memDevices),
       _csrPlugin = CsrPlugin(config),
       _cachePlugin = CachePlugin(config),
       _trapPlugin = TrapPlugin(),
       xregs = {},
       fregs = {},
       _reservationSet = [],
       _interrupts = config.interrupts
           .map((config) => InterruptController(config))
           .toList(),
       idle = false,
       pipeline = EmulatorPipeline() {
    // Wire plugins together (sync, bypassing PluginHost elaboration)
    _mmuPlugin.mmu = Mmu(config.mmu, memDevices);
    _csrPlugin.bind(_mmuPlugin.mmu);
    _cachePlugin.bind(_mmuPlugin, _csrPlugin);
    _trapPlugin.csr = _csrPlugin;

    // Cache control CSR handler
    csrs.onWrite = (address, value, context) {
      if (address == CsrAddress.rcachectl.address) {
        final addr = csrs.read(CsrAddress.rcacheaddr.address, this);
        final size = csrs.read(CsrAddress.rcachesize.address, this);
        if (value == 1 && l1d != null) {
          l1d!.lockRange(addr, size);
        } else if (value == 0 && l1d != null) {
          l1d!.unlockRange(addr, size);
        }
      }
    };

    // Vector CSRs read/write the live vector-unit state (not plain registers).
    // vl/vtype/vlenb are read-only; vstart/vxsat/vxrm/vcsr are writable.
    if (hasVector) {
      final f = csrs.csrs;
      f[CsrAddress.vstart.address] = CallbackCsr(
        CsrAddress.vstart.address,
        () => vstart,
        (v) => vstart = v & (config.vlen - 1),
      );
      f[CsrAddress.vxsat.address] = CallbackCsr(
        CsrAddress.vxsat.address,
        () => vxsat,
        (v) => vxsat = v & 0x1,
      );
      f[CsrAddress.vxrm.address] = CallbackCsr(
        CsrAddress.vxrm.address,
        () => vxrm,
        (v) => vxrm = v & 0x3,
      );
      f[CsrAddress.vcsr.address] = CallbackCsr(
        CsrAddress.vcsr.address,
        () => (vxrm << 1) | vxsat,
        (v) {
          vxsat = v & 0x1;
          vxrm = (v >> 1) & 0x3;
        },
      );
      f[CsrAddress.vl.address] = CallbackCsr(CsrAddress.vl.address, () => vl);
      f[CsrAddress.vtype.address] = CallbackCsr(
        CsrAddress.vtype.address,
        () => vtype,
      );
      f[CsrAddress.vlenb.address] = CallbackCsr(
        CsrAddress.vlenb.address,
        () => _vlenBytes,
      );
    }

    // Register pipeline stage handlers
    pipeline.at(EmulatorStage.interrupt, _handleInterrupt);
    pipeline.at(EmulatorStage.fetch, _handleFetch);
    pipeline.at(EmulatorStage.decode, _handleDecode);
    pipeline.at(EmulatorStage.execute, _handleExecute);
  }

  final EmulatorPipeline pipeline;

  void clearReservationSet() => _reservationSet.clear();

  /// Drops any cached copy of [phys] after a write that went straight to the
  /// MMU. LR/SC and the AMOs write with [Mmu.write], not with [write], so they
  /// miss the invalidation that [write] does. Without this a load after the
  /// atomic reads the stale line that the LR or an earlier load put in the
  /// modelled L1, and the golden state stops matching the hardware.
  void _invalidateCachedLine(int phys) {
    l1d?.invalidate(phys);
    l1i?.invalidate(phys);
  }

  void reset() {
    xregs = {};
    fregs = {};
    _reservationSet = [];
    idle = false;
    if (hasVector) {
      vl = 0;
      vtype = 0;
      vstart = 0;
      vxsat = 0;
      vxrm = 0;
      for (final v in vregs) {
        v.fillRange(0, v.length, 0);
      }
    }
    _csrPlugin.reset();
    _mmuPlugin.reset();
    _cachePlugin.reset();
  }

  int trap(int pc, TrapException e) {
    // Trap entry ends any LR/SC sequence (see the [mode] setter). The trap
    // plugin writes csr.mode directly, so it does not pass through that setter
    // and needs its own clear here.
    _reservationSet.clear();
    return _trapPlugin.trap(pc, e, config);
  }

  PrivilegeMode _effectiveMemPrivilege() {
    final mstatus = csrs.read(CsrAddress.mstatus.address, this);

    final mprv = (mstatus >> 17) & 1;
    if (mprv == 1 && mode == PrivilegeMode.machine) {
      final mpp = (mstatus >> 11) & 0x3;
      switch (mpp) {
        case 0:
          return PrivilegeMode.user;
        case 1:
          return PrivilegeMode.supervisor;
        case 3:
          return PrivilegeMode.machine;
        default:
          return PrivilegeMode.machine;
      }
    }

    return mode;
  }

  Future<int> translate(int addr, MemoryAccess access) async {
    addr = addr.toUnsigned(config.mxlen.size);
    final eff = _effectiveMemPrivilege();

    // M-mode accesses are PHYSICAL. satp does not translate them, so a walk
    // through the supervisor page tables would fault on an address that is
    // already physical. mstatus.MPRV can make M-mode DATA accesses use MPP's
    // translation, and _effectiveMemPrivilege already resolves that, so gate on
    // the EFFECTIVE privilege rather than the current mode.
    //
    // The HDL does the same (mmu.dart `dataPagingOn`). Without this gate the two
    // engines diverge the moment satp is set in M-mode, which is exactly what
    // test/parity/core_parity_test.dart 'MMU Sv39 translated load' caught.
    //
    // Known gap left alone here: MPRV must NOT affect instruction fetch, but
    // fetch() also translates with the effective privilege, so M-mode with
    // MPRV=1 and MPP=S would wrongly translate a fetch.
    if (eff == PrivilegeMode.machine) return addr;

    int mstatus = csrs.read(CsrAddress.mstatus.address, this);
    final mxr = ((mstatus >> 19) & 1) != 0;
    final sum = ((mstatus >> 18) & 1) != 0;

    return await mmu.translate(
      addr,
      access,
      privilege: eff,
      sum: sum,
      mxr: mxr,
    );
  }

  Future<int> fetch(int pc) async {
    final phys = await translate(pc, MemoryAccess.instr);

    if (l1i != null) {
      final firstHalfword = await l1i!.read(phys, 2);
      if (firstHalfword != null) {
        if ((firstHalfword & 0x3) != 0x3) {
          return firstHalfword;
        }
      }

      final value = await l1i!.read(phys, 4);
      if (value != null) return value;
    }

    final mstatus = csrs.read(CsrAddress.mstatus.address, this);
    final mxr = ((mstatus >> 19) & 1) != 0;
    final sum = ((mstatus >> 18) & 1) != 0;

    final firstHalfword = await mmu.read(
      phys,
      2,
      pageTranslate: false,
      sum: sum,
      mxr: mxr,
    );

    if ((firstHalfword & 0x3) != 0x3) {
      return firstHalfword;
    }

    return await mmu.read(phys, 4, pageTranslate: false, sum: sum, mxr: mxr);
  }

  Future<int> read(int addr, int width) async {
    final phys = await translate(addr, MemoryAccess.read);

    // Locked cache lines act as RAM
    if (l1d != null) {
      final line = l1d!.findLockedLine(phys);
      if (line != null) {
        return (await l1d!.read(phys, width))!;
      }
    }

    final mstatus = csrs.read(CsrAddress.mstatus.address, this);
    final mxr = ((mstatus >> 19) & 1) != 0;
    final sum = ((mstatus >> 18) & 1) != 0;

    bool cachable = false;
    if (l1d != null) {
      cachable = await mmu.canCache(
        phys,
        privilege: mode,
        pageTranslate: false,
        mxr: mxr,
        sum: sum,
      );
      if (cachable) {
        final value = await l1d!.read(phys, width);
        if (value != null) return value;
      }
    }

    final value = await mmu.read(
      phys,
      width,
      pageTranslate: false,
      sum: sum,
      mxr: mxr,
    );

    if (l1d != null && cachable) {
      await l1d!.write(phys, value, width);
    }

    return value;
  }

  Future<void> write(int addr, int value, int width) async {
    final phys = await translate(addr, MemoryAccess.write);

    if (_reservationSet.isNotEmpty) {
      if (!_reservationSet.contains(phys)) {
        _reservationSet.clear();
      }
    }

    _reservationSet.clear();

    // Locked cache lines act as RAM -- skip MMU write
    if (l1d != null) {
      final line = l1d!.findLockedLine(phys);
      if (line != null) {
        await l1d!.write(phys, value, width);
        return;
      }
    }

    final mstatus = csrs.read(CsrAddress.mstatus.address, this);
    final mxr = ((mstatus >> 19) & 1) != 0;
    final sum = ((mstatus >> 18) & 1) != 0;

    await mmu.write(
      phys,
      value,
      width,
      pageTranslate: false,
      privilege: mode,
      sum: sum,
      mxr: mxr,
    );

    if (await mmu.canCache(
      phys,
      privilege: mode,
      pageTranslate: false,
      mxr: mxr,
      sum: sum,
    )) {
      if (l1d != null) {
        if (l1d!.invalidate(phys)) return;
      }

      if (l1i != null) {
        l1i!.invalidate(phys);
      }
    }
  }

  Future<RiverCoreState> _innerExecute(
    RiverCoreState state,
    RiscVOperation op,
  ) async {
    // Check privilege level
    if (op.privilegeLevel != null) {
      if (mode.id < op.privilegeLevel!) {
        state.pc = trap(
          state.pc,
          TrapException.illegalInstruction(StackTrace.current),
        );
        return state;
      }
    }

    final hasAtomics = config.extensions.any((e) => e.name == 'A');

    for (final mop in op.microcode) {
      if (mop is RiscVWriteRegister) {
        final value = state.readSource(mop.source) + mop.valueOffset;
        final index = state.readField(mop.dest, register: false);
        if (mop.fp) {
          // f0 is normal storage and there is no floating-point stack pointer,
          // so the x0 and x2 cases do not apply.
          fregs[index] = value;
          continue;
        }
        final reg = Register.values[index];
        if (reg == Register.x0) {
          continue;
        }

        xregs[reg] = value;
        // sp (x2) is mirrored in state.sp, which _handleExecute writes back
        // after the microcode runs; keep it in sync or the write is reverted.
        if (reg == Register.x2) state.sp = value;
      } else if (mop is RiscVReadRegister) {
        final index = mop.offset + state.readField(mop.source, register: false);
        if (mop.fp) {
          state.writeField(mop.source, fregs[index] ?? 0);
          continue;
        }
        final reg = Register.values[index];
        final value = xregs[reg] ?? 0;
        state.writeField(mop.source, value);
      } else if (mop is RiscVAlu) {
        final a = state.readField(mop.a);
        final b = state.readField(mop.b);
        switch (mop.funct) {
          case RiscVAluFunct.add:
            state.alu = a + b;
          case RiscVAluFunct.sub:
            state.alu = a - b;
          case RiscVAluFunct.mul:
            state.alu = a * b;
          case RiscVAluFunct.and_:
            state.alu = a & b;
          case RiscVAluFunct.or_:
            state.alu = a | b;
          case RiscVAluFunct.xor_:
            state.alu = a ^ b;
          case RiscVAluFunct.sll:
            // Shift amount masked to log2(xlen) bits (RISC-V).
            state.alu = a << (b & (config.mxlen.size - 1));
          case RiscVAluFunct.srl:
            // Logical right shift (was arithmetic `>>`, which sign-extends).
            state.alu =
                a.toUnsigned(config.mxlen.size) >>>
                (b & (config.mxlen.size - 1));
          case RiscVAluFunct.sra:
            // Arithmetic right shift on the sign-extended operand.
            state.alu =
                a.toSigned(config.mxlen.size) >> (b & (config.mxlen.size - 1));
          case RiscVAluFunct.slt:
            // Signed strict less-than (was `<=`, which is wrong when a == b).
            state.alu =
                a.toSigned(config.mxlen.size) < b.toSigned(config.mxlen.size)
                ? 1
                : 0;
          case RiscVAluFunct.sltu:
            // Unsigned strict less-than. toUnsigned(64) is a no-op on Dart's
            // 64-bit-signed int, so at xlen=64 flip the top bit to map unsigned
            // order onto signed order.
            state.alu =
                (config.mxlen.size < 64
                    ? a.toUnsigned(config.mxlen.size) <
                          b.toUnsigned(config.mxlen.size)
                    : (a ^ 0x8000000000000000) < (b ^ 0x8000000000000000))
                ? 1
                : 0;
          case RiscVAluFunct.mulh:
            final xlen = config.mxlen.size;
            final aS = a.toSigned(xlen);
            final bS = b.toSigned(xlen);
            final wide = BigInt.from(aS) * BigInt.from(bS);
            final high = wide >> xlen;
            state.alu = (high & ((BigInt.one << xlen) - BigInt.one))
                .toSigned(64)
                .toInt();
          case RiscVAluFunct.mulhsu:
            final xlen = config.mxlen.size;
            // b is unsigned: unsign at BigInt width (Dart toUnsigned(64) no-ops).
            final wide =
                BigInt.from(a.toSigned(xlen)) * BigInt.from(b).toUnsigned(xlen);
            final high = wide >> xlen;
            state.alu = (high & ((BigInt.one << xlen) - BigInt.one))
                .toSigned(64)
                .toInt();
          case RiscVAluFunct.mulhu:
            final xlen = config.mxlen.size;
            final wide =
                BigInt.from(a).toUnsigned(xlen) *
                BigInt.from(b).toUnsigned(xlen);
            final high = wide >> xlen;
            state.alu = (high & ((BigInt.one << xlen) - BigInt.one))
                .toSigned(64)
                .toInt();
          case RiscVAluFunct.div:
            final xlen = config.mxlen.size;
            final dividend = a.toSigned(xlen);
            final divisor = b.toSigned(xlen);
            if (divisor == 0) {
              state.alu = -1;
            } else {
              final intMin = 1 << (xlen - 1);
              if (dividend == intMin && divisor == -1) {
                state.alu = intMin;
              } else {
                state.alu = (dividend ~/ divisor);
              }
            }
          case RiscVAluFunct.divu:
            final xlen = config.mxlen.size;
            final mask = (BigInt.one << xlen) - BigInt.one;
            final dividend = BigInt.from(a) & mask;
            final divisor = BigInt.from(b) & mask;
            if (divisor == BigInt.zero) {
              // all-ones; toSigned avoids BigInt.toInt() clamping at >= 2^63.
              state.alu = mask.toSigned(64).toInt();
            } else {
              final q = dividend ~/ divisor;
              state.alu = (q & mask).toSigned(64).toInt();
            }
          case RiscVAluFunct.rem:
            final xlen = config.mxlen.size;
            final dividend = a.toSigned(xlen);
            final divisor = b.toSigned(xlen);
            if (divisor == 0) {
              state.alu = dividend;
            } else {
              final intMin = 1 << (xlen - 1);
              if (dividend == intMin && divisor == -1) {
                state.alu = 0;
              } else {
                final q = dividend ~/ divisor;
                final r = dividend - q * divisor;
                state.alu = r;
              }
            }
          case RiscVAluFunct.remu:
            final xlen = config.mxlen.size;
            // toUnsigned(64) is a no-op on Dart ints; unsign at BigInt width.
            final mask = (BigInt.one << xlen) - BigInt.one;
            final dividend = BigInt.from(a) & mask;
            final divisor = BigInt.from(b) & mask;
            state.alu = (divisor == BigInt.zero ? dividend : dividend % divisor)
                .toSigned(xlen)
                .toInt();
          case RiscVAluFunct.addw:
            state.alu = ((a + b) & 0xFFFFFFFF).toSigned(32);
          case RiscVAluFunct.subw:
            state.alu = ((a - b) & 0xFFFFFFFF).toSigned(32);
          case RiscVAluFunct.sllw:
            state.alu = ((a << (b & 0x1F)) & 0xFFFFFFFF).toSigned(32);
          case RiscVAluFunct.srlw:
            state.alu = (a.toUnsigned(32) >> (b & 0x1F)).toSigned(32);
          case RiscVAluFunct.sraw:
            state.alu = (a.toSigned(32) >> (b & 0x1F));
          case RiscVAluFunct.mulw:
            final prod = (a.toSigned(32) * b.toSigned(32)) & 0xFFFFFFFF;
            state.alu = prod.toSigned(32);
          case RiscVAluFunct.divw:
            final dividend = a.toSigned(32);
            final divisor = b.toSigned(32);
            if (divisor == 0) {
              state.alu = -1;
            } else if (dividend == -0x80000000 && divisor == -1) {
              state.alu = -0x80000000;
            } else {
              state.alu = (dividend ~/ divisor).toSigned(32);
            }
          case RiscVAluFunct.divuw:
            final dividend = a.toUnsigned(32);
            final divisor = b.toUnsigned(32);
            // W ops sign-extend the 32-bit result to 64 (even unsigned ones).
            if (divisor == 0) {
              state.alu = 0xFFFFFFFF.toSigned(32); // all-ones -> -1
            } else {
              state.alu = (dividend ~/ divisor).toSigned(32);
            }
          case RiscVAluFunct.remw:
            final dividend = a.toSigned(32);
            final divisor = b.toSigned(32);
            if (divisor == 0) {
              state.alu = dividend.toSigned(32);
            } else if (dividend == -0x80000000 && divisor == -1) {
              state.alu = 0;
            } else {
              final q = dividend ~/ divisor;
              state.alu = (dividend - q * divisor).toSigned(32);
            }
          case RiscVAluFunct.remuw:
            final dividend = a.toUnsigned(32);
            final divisor = b.toUnsigned(32);
            // 32-bit result sign-extended to 64.
            state.alu = (divisor == 0 ? dividend : dividend % divisor).toSigned(
              32,
            );
          // Zbb / Zba / Zbs bit manipulation
          case RiscVAluFunct.andn:
            state.alu = a & ~b;
          case RiscVAluFunct.orn:
            state.alu = a | ~b;
          case RiscVAluFunct.xnor:
            state.alu = ~(a ^ b);
          case RiscVAluFunct.minOp:
            state.alu =
                a.toSigned(config.mxlen.size) <= b.toSigned(config.mxlen.size)
                ? a
                : b;
          case RiscVAluFunct.maxOp:
            state.alu =
                a.toSigned(config.mxlen.size) >= b.toSigned(config.mxlen.size)
                ? a
                : b;
          case RiscVAluFunct.minuOp:
            state.alu =
                BigInt.from(a).toUnsigned(config.mxlen.size) <=
                    BigInt.from(b).toUnsigned(config.mxlen.size)
                ? a
                : b;
          case RiscVAluFunct.maxuOp:
            state.alu =
                BigInt.from(a).toUnsigned(config.mxlen.size) >=
                    BigInt.from(b).toUnsigned(config.mxlen.size)
                ? a
                : b;
          case RiscVAluFunct.rol:
          case RiscVAluFunct.ror:
            {
              final x = config.mxlen.size;
              final sh = b & (x - 1);
              final u = BigInt.from(a).toUnsigned(x);
              final mask = (BigInt.one << x) - BigInt.one;
              final r = mop.funct == RiscVAluFunct.ror
                  ? ((u >> sh) | (u << (x - sh))) & mask
                  : ((u << sh) | (u >> (x - sh))) & mask;
              state.alu = r.toSigned(x).toInt();
            }
          case RiscVAluFunct.rolw:
          case RiscVAluFunct.rorw:
            {
              final sh = b & 31;
              final u = BigInt.from(a).toUnsigned(32);
              final mask = (BigInt.one << 32) - BigInt.one;
              final r = mop.funct == RiscVAluFunct.rorw
                  ? ((u >> sh) | (u << (32 - sh))) & mask
                  : ((u << sh) | (u >> (32 - sh))) & mask;
              state.alu = r.toInt().toSigned(32);
            }
          case RiscVAluFunct.clz:
            state.alu =
                config.mxlen.size -
                BigInt.from(a).toUnsigned(config.mxlen.size).bitLength;
          case RiscVAluFunct.clzw:
            state.alu = 32 - BigInt.from(a).toUnsigned(32).bitLength;
          case RiscVAluFunct.ctz:
          case RiscVAluFunct.ctzw:
            {
              final x = mop.funct == RiscVAluFunct.ctzw
                  ? 32
                  : config.mxlen.size;
              final u = BigInt.from(a).toUnsigned(x);
              state.alu = u == BigInt.zero ? x : (u & (-u)).bitLength - 1;
            }
          case RiscVAluFunct.cpop:
          case RiscVAluFunct.cpopw:
            {
              final x = mop.funct == RiscVAluFunct.cpopw
                  ? 32
                  : config.mxlen.size;
              var v = BigInt.from(a).toUnsigned(x);
              var c = 0;
              while (v > BigInt.zero) {
                if ((v & BigInt.one) == BigInt.one) c++;
                v >>= 1;
              }
              state.alu = c;
            }
          case RiscVAluFunct.sextb:
            state.alu = (a & 0xFF).toSigned(8);
          case RiscVAluFunct.sexth:
            state.alu = (a & 0xFFFF).toSigned(16);
          case RiscVAluFunct.zexth:
            state.alu = a & 0xFFFF;
          case RiscVAluFunct.rev8:
            {
              final x = config.mxlen.size;
              var r = 0;
              for (var i = 0; i < x ~/ 8; i++) {
                r |= ((a >> (i * 8)) & 0xFF) << ((x ~/ 8 - 1 - i) * 8);
              }
              state.alu = r;
            }
          case RiscVAluFunct.orcb:
            {
              final x = config.mxlen.size;
              var r = 0;
              for (var i = 0; i < x ~/ 8; i++) {
                if (((a >> (i * 8)) & 0xFF) != 0) r |= 0xFF << (i * 8);
              }
              state.alu = r;
            }
          case RiscVAluFunct.sh1add:
            state.alu = (a << 1) + b;
          case RiscVAluFunct.sh2add:
            state.alu = (a << 2) + b;
          case RiscVAluFunct.sh3add:
            state.alu = (a << 3) + b;
          case RiscVAluFunct.adduw:
            state.alu = (a & 0xFFFFFFFF) + b;
          case RiscVAluFunct.sh1adduw:
            state.alu = ((a & 0xFFFFFFFF) << 1) + b;
          case RiscVAluFunct.sh2adduw:
            state.alu = ((a & 0xFFFFFFFF) << 2) + b;
          case RiscVAluFunct.sh3adduw:
            state.alu = ((a & 0xFFFFFFFF) << 3) + b;
          case RiscVAluFunct.bset:
            state.alu = a | (1 << (b & (config.mxlen.size - 1)));
          case RiscVAluFunct.bclr:
            state.alu = a & ~(1 << (b & (config.mxlen.size - 1)));
          case RiscVAluFunct.binv:
            state.alu = a ^ (1 << (b & (config.mxlen.size - 1)));
          case RiscVAluFunct.bext:
            state.alu = (a >> (b & (config.mxlen.size - 1))) & 1;
          // Zicond
          case RiscVAluFunct.czeroEqz:
            state.alu = b == 0 ? 0 : a;
          case RiscVAluFunct.czeroNez:
            state.alu = b != 0 ? 0 : a;
          // Zcb unary helpers
          case RiscVAluFunct.zextb:
            state.alu = a & 0xFF;
          case RiscVAluFunct.zextw:
            state.alu = a & 0xFFFFFFFF;
          case RiscVAluFunct.notOp:
            state.alu = ~a;
        }
      } else if (mop is RiscVUpdatePc) {
        int value = mop.offset;
        if (mop.offsetField != null) value = state.readField(mop.offsetField!);
        if (mop.offsetSource != null) {
          value = state.readSource(mop.offsetSource!);
        }
        if (mop.align) value &= ~1;
        state.pc = (mop.absolute ? 0 : state.pc) + value;
      } else if (mop is RiscVMemLoad) {
        final base = state.readField(mop.base);
        final addr = (base + state.imm).toUnsigned(config.mxlen.size);
        final sizeBytes = mop.size.bytes;
        final sizeBits = sizeBytes * 8;

        if (sizeBytes > 1 && (addr & (sizeBytes - 1)) != 0) {
          state.pc = trap(
            state.pc,
            TrapException(Trap.misalignedLoad, addr, StackTrace.current),
          );
          return state;
        }

        try {
          final loaded = await read(addr, sizeBytes);

          final finalValue = mop.unsigned
              ? loaded.toUnsigned(sizeBits)
              : loaded.toSigned(sizeBits);

          state.writeField(mop.dest, finalValue);
        } on TrapException catch (e) {
          state.pc = trap(state.pc, e);
          return state;
        }
      } else if (mop is RiscVMemStore) {
        final base = state.readField(mop.base);
        final value = state.readField(mop.src);
        final addr = (base + state.imm).toUnsigned(config.mxlen.size);
        final sizeBytes = mop.size.bytes;
        final sizeBits = sizeBytes * 8;

        if (sizeBytes > 1 && (addr & (sizeBytes - 1)) != 0) {
          state.pc = trap(
            state.pc,
            TrapException(Trap.misalignedStore, addr, StackTrace.current),
          );
          return state;
        }

        try {
          await write(addr, value.toUnsigned(sizeBits), sizeBytes);
        } on TrapException catch (e) {
          state.pc = trap(state.pc, e);
          return state;
        }
      } else if (mop is RiscVTrapOp) {
        var trapKind = Trap.values.firstWhere(
          (t) => t.causeCode == mop.causeCode && t.interrupt == mop.isInterrupt,
          orElse: () => Trap.illegal,
        );
        // The micro-op's modeCause bit re-encodes the cause by originating
        // mode (ecall: U/VU=8, HS=9, VS=10 (H), M=11), matching the RTL.
        if (mop.modeCause && !mop.isInterrupt) {
          trapKind = switch (mode) {
            PrivilegeMode.machine => Trap.ecallM,
            PrivilegeMode.supervisor => virt ? Trap.ecallVS : Trap.ecallS,
            _ => Trap.ecallU,
          };
        }
        // External-debug ebreak: when a debugger has armed dcsr.ebreak* for the
        // current mode, an ebreak halts into Debug Mode instead of trapping to
        // mtvec (which on a bare debug target can be the program itself).
        if (trapKind == Trap.breakpoint &&
            debugHook != null &&
            debugHook!.ebreakEntersDebug(mode)) {
          debugHook!.enterDebug(state.pc, 1);
          return state; // pc stays at the ebreak; the run loop sees the halt
        }
        state.pc = trap(state.pc, TrapException(trapKind));
        return state;
      } else if (mop is RiscVBranch) {
        final target = state.readSource(mop.target);

        final value = mop.offsetField != null
            ? state.readField(mop.offsetField!)
            : mop.offset;

        // Unsigned conditions cannot come from the sign of the signed rs1-rs2
        // difference (`target`), so compare the operands as unsigned, same width
        // handling as SLTU above (flip the top bit at xlen=64).
        final xlen = config.mxlen.size;
        final lhs = state.readField(RiscVMicroOpField.rs1);
        final rhs = state.readField(RiscVMicroOpField.rs2);
        final ltu = xlen < 64
            ? lhs.toUnsigned(xlen) < rhs.toUnsigned(xlen)
            : (lhs ^ 0x8000000000000000) < (rhs ^ 0x8000000000000000);

        final condition = switch (mop.condition) {
          RiscVBranchCondition.eq => target == 0,
          RiscVBranchCondition.ne => target != 0,
          RiscVBranchCondition.lt => target < 0,
          RiscVBranchCondition.ge => target >= 0,
          RiscVBranchCondition.ltu => ltu,
          RiscVBranchCondition.geu => !ltu,
        };

        if (condition) {
          state.pc += value;
          return state;
        }
      } else if (mop is RiscVWriteLinkRegister) {
        final value = state.pc + mop.pcOffset;
        final rdIndex = state.readField(mop.dest, register: false);
        final reg = Register.values[rdIndex];
        if (reg != Register.x0) {
          xregs[reg] = value;
        }
      } else if (mop is RiscVReadCsr && config.hasCsrs) {
        // CSR address is the unsigned 12-bit field; the imm latch is
        // sign-extended, so mask it (else CSRs >= 0x800 like cycle/mcycle miss).
        var reg = state.readField(mop.source) & 0xFFF;

        // H VS-mode (virt=1): a VS access to an HS-only hypervisor CSR (0x6xx)
        // raises a virtual-instruction exception, ahead of the privilege check.
        if (config.hasHypervisor && virt && (reg & 0xF00) == 0x600) {
          state.pc = trap(
            state.pc,
            TrapException(Trap.virtualInstruction, 0, StackTrace.current),
          );
          return state;
        }

        final csrPriv = (reg >> 8) & 0x3;
        if (mode.id < csrPriv) {
          state.pc = trap(
            state.pc,
            TrapException.illegalInstruction(StackTrace.current),
          );
          return state;
        }

        // Smstateen: deny access to a state-enable CSR when SE0 is clear above.
        final stTrap = _stateenDenied(reg);
        if (stTrap != null) {
          state.pc = trap(state.pc, stTrap);
          return state;
        }

        // H VS-mode: supervisor CSRs (0x1xx) redirect to their VS shadow
        // (+0x100, e.g. sstatus->vsstatus, satp->vsatp). Done after the priv
        // check so the original (S, priv 1) address is what's privilege-checked.
        // State-enable CSRs (sstateen*) have no VS shadow, so exclude them.
        if (config.hasHypervisor &&
            virt &&
            (reg & 0xF00) == 0x100 &&
            !(reg >= 0x10C && reg <= 0x10F)) {
          reg += 0x100;
        }

        try {
          final value = csrs.read(reg, this);
          state.writeField(mop.source, value);
        } on TrapException catch (e) {
          state.pc = trap(state.pc, e);
          return state;
        }
      } else if (mop is RiscVWriteCsr && config.hasCsrs) {
        final value = state.readSource(mop.source);
        var reg = state.readField(mop.dest) & 0xFFF;

        // H VS-mode: virtual-instruction on a VS access to an HS hypervisor CSR.
        if (config.hasHypervisor && virt && (reg & 0xF00) == 0x600) {
          state.pc = trap(
            state.pc,
            TrapException(Trap.virtualInstruction, 0, StackTrace.current),
          );
          return state;
        }

        final csrPriv = (reg >> 8) & 0x3;
        if (mode.id < csrPriv) {
          state.pc = trap(
            state.pc,
            TrapException.illegalInstruction(StackTrace.current),
          );
          return state;
        }

        // Smstateen: deny access to a state-enable CSR when SE0 is clear above.
        final stTrap = _stateenDenied(reg);
        if (stTrap != null) {
          state.pc = trap(state.pc, stTrap);
          return state;
        }

        // H VS-mode: supervisor CSRs redirect to their VS shadow (+0x100);
        // state-enable CSRs have no VS shadow, so exclude them.
        if (config.hasHypervisor &&
            virt &&
            (reg & 0xF00) == 0x100 &&
            !(reg >= 0x10C && reg <= 0x10F)) {
          reg += 0x100;
        }

        try {
          // CSRRS/CSRRC with rs1=x0 (e.g. rdcycle/rdtime/rdinstret) and
          // CSRRSI/CSRRCI with uimm=0 compute an unchanged value and must not
          // write the CSR. Skipping no-op writes lets them read read-only
          // counters without faulting, while real writes to RO CSRs still trap.
          final unchanged =
              csrs.csrs.containsKey(reg) && csrs.read(reg, this) == value;
          if (!unchanged) csrs.write(reg, value, this);
        } on TrapException catch (e) {
          state.pc = trap(state.pc, e);
          return state;
        }
      } else if (mop is RiscVReturnOp) {
        final returnMode = PrivilegeMode.find(mop.privilegeLevel);
        if (returnMode == null) {
          state.pc = trap(
            state.pc,
            TrapException.illegalInstruction(StackTrace.current),
          );
          return state;
        }

        var mstatus = csrs.read(CsrAddress.mstatus.address, this);

        try {
          switch (returnMode) {
            case PrivilegeMode.machine:
              {
                final mpp = (mstatus >> 11) & 0x3;

                final newMode =
                    PrivilegeMode.find(mpp) ??
                    (throw TrapException.illegalInstruction(
                      StackTrace.current,
                    ));

                final mpie = (mstatus >> 7) & 1;
                mstatus = (mstatus & ~(1 << 3)) | (mpie << 3);

                mstatus |= (1 << 7);
                mstatus &= ~(0x3 << 11);

                csrs.write(CsrAddress.mstatus.address, mstatus, this);

                mode = newMode;
                // MRET enters virtualized mode when MPV is set (never for M).
                if (config.hasHypervisor) {
                  virt =
                      newMode != PrivilegeMode.machine &&
                      ((mstatus >> 39) & 1) == 1;
                }

                state.pc = csrs.read(CsrAddress.mepc.address, this);
                break;
              }
            case PrivilegeMode.supervisor:
              {
                final spp = (mstatus >> 8) & 1;
                final newMode = spp == 0
                    ? PrivilegeMode.user
                    : PrivilegeMode.supervisor;
                final spie = (mstatus >> 5) & 1;
                mstatus = (mstatus & ~(1 << 1)) | (spie << 1);

                mstatus |= (1 << 5);
                mstatus &= ~(1 << 8);

                csrs.write(CsrAddress.mstatus.address, mstatus, this);

                mode = newMode;
                // An SRET from HS-mode enters the guest when hstatus.SPV is set;
                // SPV is then cleared. (A guest-mode SRET is left to the normal
                // supervisor path here.)
                if (config.hasHypervisor && !virt) {
                  final hstatus = csrs.read(CsrAddress.hstatus.address, this);
                  virt = ((hstatus >> 7) & 1) == 1; // SPV
                  csrs.write(
                    CsrAddress.hstatus.address,
                    hstatus & ~(1 << 7),
                    this,
                  );
                }

                state.pc = csrs.read(CsrAddress.sepc.address, this);
                break;
              }
            case PrivilegeMode.user:
              {
                final upie = (mstatus >> 4) & 1;
                mstatus = (mstatus & ~1) | upie;

                mstatus |= (1 << 4);

                mode = PrivilegeMode.user;

                csrs.write(CsrAddress.mstatus.address, mstatus, this);

                state.pc = csrs.read(CsrAddress.uepc.address, this);
                break;
              }
          }
        } on TrapException catch (e) {
          state.pc = trap(state.pc, e);
          return state;
        }
      } else if (mop is RiscVInterruptHold) {
        final mstatus = csrs.read(CsrAddress.mstatus.address, this);
        final mie = (mstatus >> 3) & 1;
        if (mie == 0) continue;

        final pending = _nextPendingIrq();
        if (pending != null) return state;

        idle = true;
      } else if (mop is RiscVWaitForInterrupt) {
        idle = true;
      } else if (mop is RiscVLoadReserved) {
        final base = state.readField(mop.base);
        final addr = base + state.imm;
        final sizeBytes = mop.size.bytes;
        final sizeBits = sizeBytes * 8;

        if (sizeBytes > 1 && (addr & (sizeBytes - 1)) != 0) {
          state.pc = trap(
            state.pc,
            TrapException(Trap.misalignedLoad, addr, StackTrace.current),
          );
          return state;
        }

        try {
          final loaded = await read(addr, config.mxlen.bytes);

          final value = loaded.toSigned(sizeBits);

          final rd = Register.values[state.readField(mop.dest)];
          xregs[rd] = value;

          final phys = await translate(addr, MemoryAccess.read);
          _reservationSet
            ..clear()
            ..add(phys);
        } on TrapException catch (e) {
          state.pc = trap(state.pc, e);
          return state;
        }
      } else if (mop is RiscVStoreConditional && hasAtomics) {
        final base = state.readField(mop.base);
        final addr = base + state.imm;
        final sizeBytes = mop.size.bytes;

        if (sizeBytes > 1 && (addr & (sizeBytes - 1)) != 0) {
          state.pc = trap(
            state.pc,
            TrapException(Trap.misalignedStore, addr, StackTrace.current),
          );
          return state;
        }

        final srcValue = state.readField(mop.src);

        try {
          final phys = await translate(addr, MemoryAccess.write);

          final hasReservation =
              _reservationSet.isNotEmpty && _reservationSet.contains(phys);

          int result;

          if (hasReservation) {
            final mstatus = csrs.read(CsrAddress.mstatus.address, this);
            final mxr = ((mstatus >> 19) & 1) != 0;
            final sum = ((mstatus >> 18) & 1) != 0;

            await mmu.write(
              phys,
              srcValue.toUnsigned(sizeBytes * 8),
              sizeBytes,
              pageTranslate: false,
              sum: sum,
              mxr: mxr,
            );
            _invalidateCachedLine(phys);

            result = 0;
            _reservationSet.clear();
          } else {
            result = 1;
            _reservationSet.clear();
          }

          final rdIndex = state.readField(mop.dest);
          final rdReg = Register.values[rdIndex];
          if (rdReg != Register.x0) {
            xregs[rdReg] = result;
          }
        } on TrapException catch (e) {
          state.pc = trap(state.pc, e);
          return state;
        }
      } else if (mop is RiscVAtomicMemory && hasAtomics) {
        final base = state.readField(mop.base);
        final addr = base + state.imm;
        final sizeBytes = mop.size.bytes;
        final sizeBits = sizeBytes * 8;

        if (sizeBytes > 1 && (addr & (sizeBytes - 1)) != 0) {
          state.pc = trap(
            state.pc,
            TrapException(Trap.misalignedLoad, addr, StackTrace.current),
          );
          return state;
        }

        final srcRaw = state.readField(mop.src);

        try {
          final phys = await translate(addr, MemoryAccess.read);

          final mstatus = csrs.read(CsrAddress.mstatus.address, this);
          final mxr = ((mstatus >> 19) & 1) != 0;
          final sum = ((mstatus >> 18) & 1) != 0;

          // Read only the bytes the atomic names. Reading a full machine word
          // for a `.w` atomic reaches past the operand, which can run off the
          // end of a device.
          final loaded = await mmu.read(
            phys,
            sizeBytes,
            pageTranslate: false,
            sum: sum,
            mxr: mxr,
          );

          final mask = (sizeBits == 64) ? -1 : ((1 << sizeBits) - 1);

          final oldVal = loaded & mask;
          final srcVal = srcRaw & mask;

          int newVal;

          int sx(int v) {
            return v.toSigned(sizeBits);
          }

          switch (mop.funct) {
            case RiscVAtomicFunct.add:
              newVal = (sx(oldVal) + sx(srcVal)) & mask;
            case RiscVAtomicFunct.swap:
              newVal = srcVal;
            case RiscVAtomicFunct.xor_:
              newVal = (oldVal ^ srcVal) & mask;
            case RiscVAtomicFunct.and_:
              newVal = (oldVal & srcVal) & mask;
            case RiscVAtomicFunct.or_:
              newVal = (oldVal | srcVal) & mask;
            case RiscVAtomicFunct.min:
              newVal = sx(srcVal) < sx(oldVal) ? srcVal : oldVal;
            case RiscVAtomicFunct.max:
              newVal = sx(srcVal) > sx(oldVal) ? srcVal : oldVal;
            case RiscVAtomicFunct.minu:
              newVal = srcVal.toUnsigned(sizeBits) < oldVal.toUnsigned(sizeBits)
                  ? srcVal
                  : oldVal;
            case RiscVAtomicFunct.maxu:
              newVal = srcVal.toUnsigned(sizeBits) > oldVal.toUnsigned(sizeBits)
                  ? srcVal
                  : oldVal;
            case RiscVAtomicFunct.cas:
              // Zacas amocas: store rs2 (srcVal) only if mem == rd's current
              // value. readField(dest) gives the register index, so read the
              // compare value out of xregs; rd then receives the loaded value.
              final cmpIdx = state.readField(mop.dest);
              final cmpReg = Register.values[cmpIdx];
              final cmp =
                  (cmpReg == Register.x0 ? 0 : (xregs[cmpReg] ?? 0)) & mask;
              newVal = (oldVal == cmp) ? srcVal : oldVal;
          }

          // Write only the bytes the atomic names. This used to write a full
          // machine word, so an `amoadd.w` on rv64 wrote 8 bytes and cleared
          // the 4 bytes beside its operand: the golden model corrupted the
          // neighbour of every `.w` atomic.
          await mmu.write(
            phys,
            newVal,
            sizeBytes,
            pageTranslate: false,
            sum: sum,
            mxr: mxr,
          );
          _invalidateCachedLine(phys);

          final rdIndex = state.readField(mop.dest);
          final rdReg = Register.values[rdIndex];
          if (rdReg != Register.x0) {
            final xlen = config.mxlen.size;
            final oldXlen = oldVal.toSigned(sizeBits).toSigned(xlen);
            xregs[rdReg] = oldXlen;
          }
        } on TrapException catch (e) {
          state.pc = trap(state.pc, e);
          return state;
        }
      } else if (mop is RiscVTlbFenceOp) {
        final rs1Val = state.readField(RiscVMicroOpField.rs1, register: false);
        final rs2Val = state.readField(RiscVMicroOpField.rs2, register: false);
        final vaddr = rs1Val != 0 ? xregs[Register.values[rs1Val]] : null;
        final asid = rs2Val != 0 ? xregs[Register.values[rs2Val]] : null;
        mmu.flushTlb(asid: asid, vaddr: vaddr);
      } else if (mop is RiscVTlbInvalidateOp) {
        mmu.flushTlb();
      } else if (mop is RiscVCopyField) {
        state.writeField(mop.dest, state.readField(mop.src));
      } else if (mop is RiscVSetField) {
        state.writeField(mop.dest, state.readSource(mop.src));
      } else if (mop is RiscVFpuOp) {
        final aVal = state.readField(mop.a);
        final bVal = mop.b != null ? state.readField(mop.b!) : 0;
        final cVal = mop.c != null ? state.readField(mop.c!) : 0;

        double toF32(int bits) {
          final bd = ByteData(4);
          bd.setUint32(0, bits & 0xFFFFFFFF, Endian.little);
          return bd.getFloat32(0, Endian.little);
        }

        double toF64(int bits) {
          final bd = ByteData(8);
          bd.setUint64(0, bits, Endian.little);
          return bd.getFloat64(0, Endian.little);
        }

        int fromF32(double v) {
          final bd = ByteData(4);
          bd.setFloat32(0, v, Endian.little);
          return bd.getUint32(0, Endian.little);
        }

        int fromF64(double v) {
          final bd = ByteData(8);
          bd.setFloat64(0, v, Endian.little);
          return bd.getUint64(0, Endian.little);
        }

        // fcvt int<->fp width/sign is carried in the rs2 field (NOT a register):
        // bit1 = 64-bit (L) vs 32-bit (W), bit0 = unsigned vs signed. funct7
        // (captured in the op enum's precision) picks f32 vs f64. The HDL reads
        // rs2 the same way, so fcvt.{w,wu,l,lu}.{s,d} stay in lockstep.
        final cvtRs2 = state.readField(RiscVMicroOpField.rs2, register: false);
        final cvtWide = (cvtRs2 & 2) != 0;
        final cvtUns = (cvtRs2 & 1) != 0;
        // Rounding mode from the instruction's funct3 (rm). 0=RNE, 1=RTZ, 2=RDN,
        // 3=RUP, 4=RMM, 7=DYN. The frm CSR is not modelled, so DYN falls back to
        // RNE (its reset value); the HDL does the same, keeping parity.
        final cvtRmRaw = (state.ir.raw >> 12) & 0x7;
        final cvtRm = cvtRmRaw == 7 ? 0 : cvtRmRaw;
        // Round a float to an integer-valued double per rm (used before fp->int).
        double roundRm(double f) {
          if (f.isNaN || f.isInfinite) return f;
          final t = f.truncateToDouble();
          final frac = f - t;
          if (frac == 0.0) return f;
          switch (cvtRm) {
            case 1: // RTZ
              return t;
            case 2: // RDN (toward -inf)
              return f.floorToDouble();
            case 3: // RUP (toward +inf)
              return f.ceilToDouble();
            case 4: // RMM (nearest, ties away from zero) == Dart round()
              return f.roundToDouble();
            default: // RNE (nearest, ties to even)
              final af = frac.abs();
              final step = f.isNegative ? -1.0 : 1.0;
              if (af < 0.5) return t;
              if (af > 0.5) return t + step;
              // exact tie: round to the even neighbour
              return (t % 2.0 == 0.0) ? t : t + step;
          }
        }

        // fp -> int with RISC-V rounding (per rm) then saturation: NaN -> max
        // (unsigned: all-ones), out-of-range saturates to the destination min/max.
        // 32-bit results are sign-extended to XLEN (even unsigned).
        int fpToInt(double fRaw) {
          final f = roundRm(fRaw);
          if (cvtWide) {
            if (cvtUns) {
              if (f.isNaN || f >= 18446744073709551616.0) return -1;
              if (f <= 0.0) return 0;
              return BigInt.from(f).toSigned(64).toInt();
            }
            if (f.isNaN || f >= 9223372036854775808.0) {
              return 0x7FFFFFFFFFFFFFFF;
            }
            if (f < -9223372036854775808.0) return -0x8000000000000000;
            return f.toInt();
          }
          if (cvtUns) {
            int u;
            if (f.isNaN || f >= 4294967296.0) {
              u = 0xFFFFFFFF;
            } else if (f <= 0.0) {
              u = 0;
            } else {
              u = f.toInt();
            }
            return u.toSigned(32);
          }
          int s;
          if (f.isNaN || f >= 2147483648.0) {
            s = 0x7FFFFFFF;
          } else if (f < -2147483648.0) {
            s = -2147483648;
          } else {
            s = f.toInt();
          }
          return s.toSigned(32);
        }

        // int -> fp: interpret the source register per width+sign from rs2.
        double intToFpVal(int raw) {
          if (cvtWide) {
            if (cvtUns) {
              return raw >= 0
                  ? raw.toDouble()
                  : BigInt.from(raw).toUnsigned(64).toDouble();
            }
            return raw.toDouble();
          }
          final lo = raw & 0xFFFFFFFF;
          return cvtUns ? lo.toDouble() : lo.toSigned(32).toDouble();
        }

        double a, b, c;
        if (mop.doublePrecision) {
          a = toF64(aVal);
          b = toF64(bVal);
          c = toF64(cVal);
        } else {
          a = toF32(aVal);
          b = toF32(bVal);
          c = toF32(cVal);
        }

        int result;
        switch (mop.funct) {
          case RiscVFpuFunct.fadd:
            result = mop.doublePrecision ? fromF64(a + b) : fromF32(a + b);
          // Fused multiply-add: rd = +-(a*b) +- c. The product a*b is a Dart
          // f64, so it is computed at higher precision before the add (as the
          // fused op intends); fromF32 rounds the final result to single.
          case RiscVFpuFunct.fmadd:
            result = mop.doublePrecision
                ? fromF64(a * b + c)
                : fromF32(a * b + c);
          case RiscVFpuFunct.fmsub:
            result = mop.doublePrecision
                ? fromF64(a * b - c)
                : fromF32(a * b - c);
          case RiscVFpuFunct.fnmsub:
            result = mop.doublePrecision
                ? fromF64(-(a * b) + c)
                : fromF32(-(a * b) + c);
          case RiscVFpuFunct.fnmadd:
            result = mop.doublePrecision
                ? fromF64(-(a * b) - c)
                : fromF32(-(a * b) - c);
          case RiscVFpuFunct.fsub:
            result = mop.doublePrecision ? fromF64(a - b) : fromF32(a - b);
          case RiscVFpuFunct.fmul:
            result = mop.doublePrecision ? fromF64(a * b) : fromF32(a * b);
          case RiscVFpuFunct.fdiv:
            result = mop.doublePrecision ? fromF64(a / b) : fromF32(a / b);
          case RiscVFpuFunct.fsqrt:
            result = mop.doublePrecision
                ? fromF64(math.sqrt(a))
                : fromF32(math.sqrt(a));
          case RiscVFpuFunct.feq:
            result = a == b ? 1 : 0;
          case RiscVFpuFunct.flt:
            result = a < b ? 1 : 0;
          case RiscVFpuFunct.fle:
            result = a <= b ? 1 : 0;
          // f32/f64 -> int (width+sign from rs2). fcvtWS/fcvtLS both name the
          // f32->int family; the actual width/sign comes from rs2 via fpToInt.
          case RiscVFpuFunct.fcvtWS || RiscVFpuFunct.fcvtLS:
            result = fpToInt(toF32(aVal));
          case RiscVFpuFunct.fcvtWD || RiscVFpuFunct.fcvtLD:
            result = fpToInt(toF64(aVal));
          // int -> f32/f64 (width+sign from rs2).
          case RiscVFpuFunct.fcvtSW || RiscVFpuFunct.fcvtSL:
            result = fromF32(intToFpVal(aVal));
          case RiscVFpuFunct.fcvtDW || RiscVFpuFunct.fcvtDL:
            result = fromF64(intToFpVal(aVal));
          case RiscVFpuFunct.fcvtSD:
            result = fromF32(toF64(aVal));
          case RiscVFpuFunct.fcvtDS:
            result = fromF64(toF32(aVal));
          case RiscVFpuFunct.fmv:
            result = aVal;
          case RiscVFpuFunct.fclass:
            final v = mop.doublePrecision ? toF64(aVal) : toF32(aVal);
            if (v.isNaN) {
              result = (aVal >> (mop.doublePrecision ? 51 : 22)) & 1 == 1
                  ? 0x200
                  : 0x100;
            } else if (v.isInfinite) {
              result = v.isNegative ? 0x1 : 0x80;
            } else if (v == 0.0) {
              result = aVal == 0 ? 0x10 : 0x8;
            } else {
              final isDenorm = mop.doublePrecision
                  ? (aVal >> 52) & 0x7FF == 0
                  : (aVal >> 23) & 0xFF == 0;
              if (v.isNegative) {
                result = isDenorm ? 0x4 : 0x2;
              } else {
                result = isDenorm ? 0x20 : 0x40;
              }
            }
          case RiscVFpuFunct.fsgnj:
            final signB = mop.doublePrecision
                ? (bVal >> 63) & 1
                : (bVal >> 31) & 1;
            final mask = mop.doublePrecision ? (1 << 63) - 1 : (1 << 31) - 1;
            result = (aVal & mask) | (signB << (mop.doublePrecision ? 63 : 31));
          case RiscVFpuFunct.fsgnjn:
            final signB = mop.doublePrecision
                ? (bVal >> 63) & 1
                : (bVal >> 31) & 1;
            final mask = mop.doublePrecision ? (1 << 63) - 1 : (1 << 31) - 1;
            result =
                (aVal & mask) |
                ((1 - signB) << (mop.doublePrecision ? 63 : 31));
          case RiscVFpuFunct.fsgnjx:
            final signA = mop.doublePrecision
                ? (aVal >> 63) & 1
                : (aVal >> 31) & 1;
            final signB = mop.doublePrecision
                ? (bVal >> 63) & 1
                : (bVal >> 31) & 1;
            final mask = mop.doublePrecision ? (1 << 63) - 1 : (1 << 31) - 1;
            result =
                (aVal & mask) |
                ((signA ^ signB) << (mop.doublePrecision ? 63 : 31));
          case RiscVFpuFunct.fmin:
            result = mop.doublePrecision
                ? fromF64(a < b ? a : b)
                : fromF32(a < b ? a : b);
          case RiscVFpuFunct.fmax:
            result = mop.doublePrecision
                ? fromF64(a > b ? a : b)
                : fromF32(a > b ? a : b);
        }

        state.writeField(mop.dest, result);
      } else if (mop is RiscVFenceOp) {
        l1i?.reset();
        l1d?.reset();
      } else if (mop is RiscVHypervisorFenceOp) {
        // HFENCE.VVMA / HFENCE.GVMA: with a single shared TLB model, flush all.
        mmu.flushTlb();
      } else if (mop is RiscVHypervisorMemOp) {
        // HLV/HSV: access guest memory using two-stage (VS + G) translation.
        final vsatp = csrs.read(CsrAddress.vsatp.address, this);
        final hgatp = csrs.read(CsrAddress.hgatp.address, this);
        final gva = state.readField(mop.base);
        final bytes = mop.size.bytes;
        try {
          if (mop.isStore) {
            final hpa = await mmu.translateGuest(
              gva,
              MemoryAccess.write,
              vsatpVal: vsatp,
              hgatpVal: hgatp,
            );
            await mmu.write(
              hpa,
              state.readField(mop.dest),
              bytes,
              pageTranslate: false,
            );
          } else {
            final hpa = await mmu.translateGuest(
              gva,
              MemoryAccess.read,
              vsatpVal: vsatp,
              hgatpVal: hgatp,
            );
            var value = await mmu.read(hpa, bytes, pageTranslate: false);
            if (!mop.unsigned && bytes < 8) value = value.toSigned(bytes * 8);
            // The HLV microcode has no trailing RiscVWriteRegister, so commit the
            // loaded value to the register file here (mirroring that handler).
            final reg =
                Register.values[state.readField(mop.dest, register: false)];
            if (reg != Register.x0) {
              xregs[reg] = value;
              if (reg == Register.x2) state.sp = value;
            }
          }
        } on TrapException catch (e) {
          // A two-stage fault (regular VS-stage cause, or a guest cause from the
          // G-stage) traps like any other memory access.
          state.pc = trap(state.pc, e);
          return state;
        }
      }
    }

    return state;
  }

  /// Special-cased execution of the V (vector) extension. Returns the next PC
  /// when [instr] is a vector op, else null so [cycle] uses the normal path.
  /// Emulator-first: handles OP-V / vector load-store opcodes directly against
  /// [vregs] + vl/vtype, bypassing the (stub) rv_v microcode.
  Future<int?> executeVector(int pc, int instr) async {
    if (!hasVector) return null;
    final opcode = instr & 0x7F;
    final funct3 = (instr >> 12) & 0x7;
    const opV = 0x57, vLoad = 0x07, vStore = 0x27;
    bool vWidth(int f) => f == 0 || f == 5 || f == 6 || f == 7;
    int reg(int field) => xregs[Register.values[field]] ?? 0;
    const widthSew = {0: 8, 5: 16, 6: 32, 7: 64};

    if (opcode == opV && funct3 == 7) {
      // vset{i}vl{i}: configure vtype/vl. vl = min(AVL, VLMAX).
      final rd = (instr >> 7) & 0x1F;
      final rs1 = (instr >> 15) & 0x1F;
      final int newVtype;
      int avl; // -1 = "use VLMAX" (rs1=x0, rd!=x0)
      if (((instr >> 30) & 0x3) == 0x3) {
        newVtype = (instr >> 20) & 0x3FF; // vsetivli: vtype=zimm[9:0]
        avl = rs1; // uimm5 in the rs1 field
      } else if (((instr >> 31) & 1) == 1) {
        newVtype = reg((instr >> 20) & 0x1F); // vsetvl: vtype from rs2
        avl = rs1 != 0 ? reg(rs1) : (rd != 0 ? -1 : vl);
      } else {
        newVtype = (instr >> 20) & 0x7FF; // vsetvli: vtype=zimm[10:0]
        avl = rs1 != 0 ? reg(rs1) : (rd != 0 ? -1 : vl);
      }
      final sew = 8 << ((newVtype >> 3) & 0x7);
      final lmulField = newVtype & 0x7;
      final vlmax = lmulField <= 3
          ? (config.vlen * (1 << lmulField)) ~/ sew
          : (config.vlen ~/ sew) >> (8 - lmulField);
      vtype = newVtype;
      vstart = 0;
      vl = avl < 0 ? vlmax : (avl < vlmax ? avl : vlmax);
      if (rd != 0) xregs[Register.values[rd]] = vl;
      return pc + 4;
    }

    if (opcode == opV &&
        (funct3 == 2 || funct3 == 6) &&
        ((instr >> 26) & 0x3F) == 0x10) {
      // funct6=0x10: scalar<->vector moves and mask popcount/first.
      final vd = (instr >> 7) & 0x1F;
      final f1 = (instr >> 15) & 0x1F; // sub-op (OPMVV) / rs1 (OPMVX)
      final vs2 = (instr >> 20) & 0x1F;
      final sew = 8 << ((vtype >> 3) & 0x7);
      if (funct3 == 6) {
        // vmv.s.x: v[vd][0] = x[rs1]; element 0 only.
        vwriteElem(vd, 0, sew, reg(f1));
        vstart = 0;
        return pc + 4;
      }
      final rd = vd; // OPMVV: bits[11:7] is the int dest
      if (f1 == 0x00) {
        // vmv.x.s: x[rd] = sign-extended v[vs2][0]
        final e = vreadElem(vs2, 0, sew);
        final v = sew >= 64 ? e : e.toSigned(sew);
        if (rd != 0) xregs[Register.values[rd]] = v;
      } else if (f1 == 0x10) {
        // vcpop.m: count set mask bits over vl
        var cnt = 0;
        for (var i = vstart; i < vl; i++) {
          if (((vregs[vs2][i >> 3] >> (i & 7)) & 1) == 1) cnt++;
        }
        if (rd != 0) xregs[Register.values[rd]] = cnt;
      } else if (f1 == 0x11) {
        // vfirst.m: index of first set mask bit, or -1
        var idx = -1;
        for (var i = vstart; i < vl; i++) {
          if (((vregs[vs2][i >> 3] >> (i & 7)) & 1) == 1) {
            idx = i;
            break;
          }
        }
        if (rd != 0) xregs[Register.values[rd]] = idx;
      }
      vstart = 0;
      return pc + 4;
    }

    if (opcode == opV &&
        funct3 == 2 &&
        ((instr >> 26) & 0x3F) >= 0x18 &&
        ((instr >> 26) & 0x3F) <= 0x1F) {
      // Mask logical ops (.mm): per-element bit of v[vd] = v[vs2] op v[vs1].
      // Always unmasked, operate over vl bits.
      final funct6 = (instr >> 26) & 0x3F;
      final vd = (instr >> 7) & 0x1F;
      final vs1 = (instr >> 15) & 0x1F;
      final vs2 = (instr >> 20) & 0x1F;
      for (var i = vstart; i < vl; i++) {
        final a = (vregs[vs2][i >> 3] >> (i & 7)) & 1;
        final b = (vregs[vs1][i >> 3] >> (i & 7)) & 1;
        final r = switch (funct6) {
          0x18 => a & (~b & 1), // vmandn
          0x19 => a & b, // vmand
          0x1A => a | b, // vmor
          0x1B => a ^ b, // vmxor
          0x1C => a | (~b & 1), // vmorn
          0x1D => (~(a & b)) & 1, // vmnand
          0x1E => (~(a | b)) & 1, // vmnor
          _ => (~(a ^ b)) & 1, // 0x1F vmxnor
        };
        if (r == 1) {
          vregs[vd][i >> 3] |= (1 << (i & 7));
        } else {
          vregs[vd][i >> 3] &= ~(1 << (i & 7));
        }
      }
      vstart = 0;
      return pc + 4;
    }

    if (opcode == opV &&
        (funct3 == 0 || funct3 == 3 || funct3 == 4) &&
        ((instr >> 26) & 0x3F) == 0x0C) {
      // vrgather: vd[i] = (idx < VLMAX) ? vs2[idx] : 0. idx from vs1[i] (.vv) /
      // x[rs1] (.vx) / uimm5 (.vi).
      final vm = (instr >> 25) & 0x1;
      final vd = (instr >> 7) & 0x1F;
      final f1 = (instr >> 15) & 0x1F;
      final vs2 = (instr >> 20) & 0x1F;
      final sew = 8 << ((vtype >> 3) & 0x7);
      final mask = sew >= 64 ? -1 : ((1 << sew) - 1);
      final vlmax = config.vlen ~/ sew;
      final scalarIdx = funct3 == 4 ? reg(f1) : f1; // .vx reg / .vi uimm5
      bool active(int i) => vm == 1 || ((vregs[0][i >> 3] >> (i & 7)) & 1) == 1;
      for (var i = vstart; i < vl; i++) {
        if (!active(i)) continue;
        final idx = funct3 == 0 ? vreadElem(f1, i, sew) : scalarIdx;
        final v = (idx >= 0 && idx < vlmax) ? vreadElem(vs2, idx, sew) : 0;
        vwriteElem(vd, i, sew, v & mask);
      }
      vstart = 0;
      return pc + 4;
    }

    if (opcode == opV && funct3 == 2 && ((instr >> 26) & 0x3F) == 0x17) {
      // vcompress.vm: pack vs2 elements selected by mask v[vs1] into vd from 0.
      final vd = (instr >> 7) & 0x1F;
      final vs1 = (instr >> 15) & 0x1F; // mask source
      final vs2 = (instr >> 20) & 0x1F;
      final sew = 8 << ((vtype >> 3) & 0x7);
      final mask = sew >= 64 ? -1 : ((1 << sew) - 1);
      var dst = 0;
      for (var i = vstart; i < vl; i++) {
        if (((vregs[vs1][i >> 3] >> (i & 7)) & 1) == 1) {
          vwriteElem(vd, dst, sew, vreadElem(vs2, i, sew) & mask);
          dst++;
        }
      }
      vstart = 0;
      return pc + 4;
    }

    if (opcode == opV &&
        funct3 == 6 &&
        (((instr >> 26) & 0x3F) == 0x0E || ((instr >> 26) & 0x3F) == 0x0F)) {
      // vslide1up (0x0E) / vslide1down (0x0F): shift by one, inserting x[rs1].
      final vm = (instr >> 25) & 0x1;
      final vd = (instr >> 7) & 0x1F;
      final f1 = (instr >> 15) & 0x1F; // rs1 (scalar inserted)
      final vs2 = (instr >> 20) & 0x1F;
      final sew = 8 << ((vtype >> 3) & 0x7);
      final mask = sew >= 64 ? -1 : ((1 << sew) - 1);
      final up = ((instr >> 26) & 0x3F) == 0x0E;
      bool active(int i) => vm == 1 || ((vregs[0][i >> 3] >> (i & 7)) & 1) == 1;
      for (var i = vstart; i < vl; i++) {
        if (!active(i)) continue;
        final int v;
        if (up) {
          v = i == 0 ? reg(f1) : vreadElem(vs2, i - 1, sew);
        } else {
          v = i == vl - 1 ? reg(f1) : vreadElem(vs2, i + 1, sew);
        }
        vwriteElem(vd, i, sew, v & mask);
      }
      vstart = 0;
      return pc + 4;
    }

    if (opcode == opV &&
        (funct3 == 3 || funct3 == 4) &&
        (((instr >> 26) & 0x3F) == 0x0E || ((instr >> 26) & 0x3F) == 0x0F)) {
      // vslideup (0x0E) / vslidedown (0x0F): shift elements by an offset
      // (x[rs1] for .vx, uimm5 for .vi).
      final funct6 = (instr >> 26) & 0x3F;
      final vm = (instr >> 25) & 0x1;
      final vd = (instr >> 7) & 0x1F;
      final f1 = (instr >> 15) & 0x1F;
      final vs2 = (instr >> 20) & 0x1F;
      final sew = 8 << ((vtype >> 3) & 0x7);
      final mask = sew >= 64 ? -1 : ((1 << sew) - 1);
      final vlmax = config.vlen ~/ sew;
      final offset = funct3 == 4 ? reg(f1) : f1; // .vx reg, .vi uimm5
      final up = funct6 == 0x0E;
      bool active(int i) => vm == 1 || ((vregs[0][i >> 3] >> (i & 7)) & 1) == 1;
      for (var i = vstart; i < vl; i++) {
        if (!active(i)) continue;
        if (up) {
          if (i < offset) continue; // vd[0..offset-1] undisturbed
          vwriteElem(vd, i, sew, vreadElem(vs2, i - offset, sew) & mask);
        } else {
          final src = i + offset;
          final v = src < vlmax
              ? vreadElem(vs2, src, sew)
              : 0; // past VLMAX => 0
          vwriteElem(vd, i, sew, v & mask);
        }
      }
      vstart = 0;
      return pc + 4;
    }

    if (opcode == opV &&
        funct3 == 1 &&
        ((instr >> 26) & 0x3F) == 0x12 &&
        ((instr >> 15) & 0x1F) >= 0x08) {
      // Widening / narrowing converts (VFUNARY0, funct6=0x12, vs1>=0x08):
      // vs1 0x08-0x0F widen SEW->2*SEW, 0x10-0x17 narrow 2*SEW->SEW. The low 3
      // bits of vs1 select the kind: xu.f float->uint (0/6=rtz), x.f float->int
      // (1/7=rtz), f.xu uint->float (2), f.x int->float (3), f.f float->float
      // (4; 5=rod narrow). (Same-width vfcvt + vfclass are in the OPFV block
      // below; SEW=16/Zvfh deferred.)
      final vm = (instr >> 25) & 0x1;
      final vd = (instr >> 7) & 0x1F;
      final vs1sel = (instr >> 15) & 0x1F;
      final vs2 = (instr >> 20) & 0x1F;
      final sew = 8 << ((vtype >> 3) & 0x7);
      final narrow = vs1sel >= 0x10;
      final srcSew = narrow ? sew * 2 : sew;
      final dstSew = narrow ? sew : sew * 2;
      final dmask = dstSew >= 64 ? -1 : ((1 << dstSew) - 1);
      // float->int saturation bounds at the destination width (RISC-V fcvt:
      // NaN/overflow saturate; truncate toward zero).
      final dsmax = dstSew >= 64 ? 0x7FFFFFFFFFFFFFFF : (1 << (dstSew - 1)) - 1;
      final dsmin = dstSew >= 64 ? (1 << 63) : -(1 << (dstSew - 1));
      // Double base (2.0): 2^63/2^64 overflow a signed int, so an int base
      // would wrap negative and break the saturation comparisons.
      final dp2 = math.pow(2.0, dstSew).toDouble(); // 2^dstSew
      final dp2m1 = math.pow(2.0, dstSew - 1).toDouble(); // 2^(dstSew-1)
      double srcUToDouble(int bits) => srcSew >= 64
          ? (bits >= 0
                ? bits.toDouble()
                : bits.toDouble() + math.pow(2.0, srcSew).toDouble())
          : (bits & ((1 << srcSew) - 1)).toDouble();
      final kind = vs1sel & 0x7; // low 3 bits select the conversion kind
      bool active(int i) => vm == 1 || ((vregs[0][i >> 3] >> (i & 7)) & 1) == 1;
      for (var i = vstart; i < vl; i++) {
        if (!active(i)) continue;
        final aBits = vreadElem(vs2, i, srcSew);
        // Float reinterpretation of the source (used by the float->* kinds; a
        // harmless no-op double for the int-source f.x/f.xu kinds).
        final a = fpBitsToDouble(aBits, srcSew);
        final r = switch (kind) {
          // f.f float->float (widen 0x0C / narrow 0x14; 0x15 rod ~ f.f)
          0x4 || 0x5 => fpDoubleToBits(a, dstSew) & dmask,
          // xu.f float->unsigned int (0x6 = rtz)
          0x0 || 0x6 =>
            a.isNaN ? dmask : (a <= 0 ? 0 : (a >= dp2 ? dmask : a.toInt())),
          // x.f float->signed int (0x7 = rtz)
          0x1 || 0x7 =>
            (a.isNaN
                    ? dsmax
                    : (a >= dp2m1 ? dsmax : (a < -dp2m1 ? dsmin : a.toInt()))) &
                dmask,
          // f.xu unsigned int->float
          0x2 => fpDoubleToBits(srcUToDouble(aBits), dstSew) & dmask,
          // f.x signed int->float
          0x3 =>
            fpDoubleToBits(aBits.toSigned(srcSew).toDouble(), dstSew) & dmask,
          _ => aBits & dmask,
        };
        vwriteElem(vd, i, dstSew, r);
      }
      vstart = 0;
      return pc + 4;
    }

    if (opcode == opV &&
        (funct3 == 1 || funct3 == 5) &&
        ((instr >> 26) & 0x3F) >= 0x30 &&
        ((instr >> 26) & 0x3F) <= 0x3F) {
      // FP widening (.vv/.vf): result is 2*SEW float. vfwadd/vfwsub/vfwmul.
      final funct6 = (instr >> 26) & 0x3F;
      final vm = (instr >> 25) & 0x1;
      final vd = (instr >> 7) & 0x1F;
      final f1 = (instr >> 15) & 0x1F;
      final vs2 = (instr >> 20) & 0x1F;
      final sew = 8 << ((vtype >> 3) & 0x7);
      final wsew = sew * 2;
      final isVf = funct3 == 5;
      final scalar = isVf
          ? fpBitsToDouble(reg(f1) & (sew >= 64 ? -1 : ((1 << sew) - 1)), sew)
          : 0.0;
      bool active(int i) => vm == 1 || ((vregs[0][i >> 3] >> (i & 7)) & 1) == 1;
      for (var i = vstart; i < vl; i++) {
        if (!active(i)) continue;
        final a = fpBitsToDouble(vreadElem(vs2, i, sew), sew);
        final b = isVf ? scalar : fpBitsToDouble(vreadElem(f1, i, sew), sew);
        final double r = switch (funct6) {
          0x30 => a + b, // vfwadd
          0x32 => a - b, // vfwsub
          0x38 => a * b, // vfwmul
          _ => a,
        };
        vwriteElem(vd, i, wsew, fpDoubleToBits(r, wsew));
      }
      vstart = 0;
      return pc + 4;
    }

    if (opcode == opV && (funct3 == 1 || funct3 == 5)) {
      // Vector floating-point: OPFVV (.vv, funct3==1) and OPFVF (.vf,
      // funct3==5; second operand is the FP scalar in x[rs1], the emulator
      // uses a unified regfile). SEW selects float(32)/double(64). Includes
      // same-width vfcvt (funct6 0x12) and vfclass (0x13). (SEW=16/Zvfh
      // deferred.)
      final funct6 = (instr >> 26) & 0x3F;
      final vm = (instr >> 25) & 0x1;
      final vd = (instr >> 7) & 0x1F;
      final vs1 = (instr >> 15) & 0x1F; // vs1 (.vv) / rs1 scalar (.vf)
      final vs2 = (instr >> 20) & 0x1F;
      final sew = 8 << ((vtype >> 3) & 0x7);
      final mask = sew >= 64 ? -1 : ((1 << sew) - 1);
      final signMask = 1 << (sew - 1);
      final isVf = funct3 == 5;
      final scalarBits = isVf ? (reg(vs1) & mask) : 0;
      // float<->int conversion bounds (RISC-V fcvt: NaN/overflow saturate).
      final smax = sew >= 64 ? 0x7FFFFFFFFFFFFFFF : (1 << (sew - 1)) - 1;
      final smin = sew >= 64 ? (1 << 63) : -(1 << (sew - 1));
      // Double base (2.0): 2^64 overflows a signed int at SEW=64.
      final p2 = math.pow(2.0, sew).toDouble(); // 2^SEW
      final p2m1 = math.pow(2.0, sew - 1).toDouble(); // 2^(SEW-1)
      double uToDouble(int bits) => sew >= 64
          ? (bits >= 0 ? bits.toDouble() : bits.toDouble() + p2)
          : (bits & mask).toDouble();
      // vfclass: 10-bit classification (bit0 -inf … bit9 qNaN).
      int classify(double v, int bits) {
        final sign = (bits & signMask) != 0;
        if (v.isNaN) {
          final quiet = sew >= 64 ? (1 << 51) : (1 << 22);
          return (bits & quiet) != 0 ? (1 << 9) : (1 << 8);
        }
        if (v.isInfinite) return sign ? 1 : (1 << 7);
        if (v == 0.0) return sign ? (1 << 3) : (1 << 4);
        final expMask = sew >= 64 ? (0x7FF << 52) : (0xFF << 23);
        if ((bits & expMask) == 0)
          return sign ? (1 << 2) : (1 << 5); // subnormal
        return sign ? (1 << 1) : (1 << 6); // normal
      }

      bool active(int i) => vm == 1 || ((vregs[0][i >> 3] >> (i & 7)) & 1) == 1;
      // Compares write a bit-per-element mask to v[vd] (NaN => false except
      // vmfne; Dart's comparisons already match that ordering). vmfgt/vmfge are
      // .vf-only.
      final isCompare =
          funct6 == 0x18 || // vmfeq
          funct6 == 0x19 || // vmfle
          funct6 == 0x1B || // vmflt
          funct6 == 0x1C || // vmfne
          funct6 == 0x1D || // vmfgt (.vf)
          funct6 == 0x1F; // vmfge (.vf)
      // Reductions (.vs): vd[0] = reduce(vs1[0], all active vs2 elements).
      final isReduce =
          funct6 == 0x01 || // vfredusum
          funct6 == 0x03 || // vfredosum
          funct6 == 0x05 || // vfredmin
          funct6 == 0x07; // vfredmax
      if (isReduce) {
        var acc = fpBitsToDouble(vreadElem(vs1, 0, sew), sew);
        for (var i = vstart; i < vl; i++) {
          if (!active(i)) continue;
          final e = fpBitsToDouble(vreadElem(vs2, i, sew), sew);
          acc = switch (funct6) {
            0x01 || 0x03 => acc + e,
            0x05 => acc < e ? acc : e,
            _ => acc > e ? acc : e, // 0x07
          };
        }
        vwriteElem(vd, 0, sew, fpDoubleToBits(acc, sew) & mask);
        vstart = 0;
        return pc + 4;
      }
      for (var i = vstart; i < vl; i++) {
        if (!active(i)) continue;
        final aBits = vreadElem(vs2, i, sew);
        final bBits = isVf ? scalarBits : vreadElem(vs1, i, sew);
        final a = fpBitsToDouble(aBits, sew);
        final b = fpBitsToDouble(bBits, sew);
        if (isCompare) {
          final cmp = switch (funct6) {
            0x18 => a == b,
            0x19 => a <= b,
            0x1B => a < b,
            0x1D => a > b, // vmfgt (.vf)
            0x1F => a >= b, // vmfge (.vf)
            _ => a != b, // 0x1C vmfne
          };
          if (cmp) {
            vregs[vd][i >> 3] |= (1 << (i & 7));
          } else {
            vregs[vd][i >> 3] &= ~(1 << (i & 7));
          }
          continue;
        }
        // vd element, used as the third operand by the fused multiply-adds.
        final d = fpBitsToDouble(vreadElem(vd, i, sew), sew);
        final int r;
        switch (funct6) {
          case 0x00: // vfadd
            r = fpDoubleToBits(a + b, sew);
          case 0x02: // vfsub
            r = fpDoubleToBits(a - b, sew);
          case 0x24: // vfmul
            r = fpDoubleToBits(a * b, sew);
          case 0x20: // vfdiv
            r = fpDoubleToBits(a / b, sew);
          case 0x04: // vfmin
            r = fpDoubleToBits(a < b ? a : b, sew);
          case 0x06: // vfmax
            r = fpDoubleToBits(a > b ? a : b, sew);
          case 0x08: // vfsgnj: sign of b, magnitude of a
            r = (aBits & ~signMask) | (bBits & signMask);
          case 0x09: // vfsgnjn: ~sign of b
            r = (aBits & ~signMask) | ((~bBits) & signMask);
          case 0x0A: // vfsgnjx: sign a^b
            r = aBits ^ (bBits & signMask);
          case 0x12: // vfunary0 = vfcvt; vs1 selects direction
            r = switch (vs1) {
              0x02 => fpDoubleToBits(
                uToDouble(aBits),
                sew,
              ), // f.xu: uint->float
              0x03 => fpDoubleToBits(
                aBits.toSigned(sew).toDouble(),
                sew,
              ), // f.x: int->float
              0x00 || 0x06 =>
                a
                        .isNaN // xu.f: float->uint (rtz, saturate)
                    ? mask
                    : (a <= 0 ? 0 : (a >= p2 ? mask : a.toInt())),
              0x01 || 0x07 =>
                a
                        .isNaN // x.f: float->int (rtz, saturate)
                    ? smax
                    : (a >= p2m1 ? smax : (a < -p2m1 ? smin : a.toInt())),
              _ => aBits,
            };
          case 0x13: // vfunary1: vs1=0 vfsqrt, vs1=0x10 vfclass
            r = vs1 == 0x00
                ? fpDoubleToBits(math.sqrt(a), sew)
                : (vs1 == 0x10 ? classify(a, aBits) : aBits);
          // Fused multiply-add family (a=vs2, b=vs1, d=vd). The *macc forms use
          // vd as the addend; the *madd forms use vd as a multiplicand.
          case 0x2C: // vfmacc:  vd = a*b + vd
            r = fpDoubleToBits(a * b + d, sew);
          case 0x2D: // vfnmacc: vd = -(a*b) - vd
            r = fpDoubleToBits(-(a * b) - d, sew);
          case 0x2E: // vfmsac:  vd = a*b - vd
            r = fpDoubleToBits(a * b - d, sew);
          case 0x2F: // vfnmsac: vd = -(a*b) + vd
            r = fpDoubleToBits(-(a * b) + d, sew);
          case 0x28: // vfmadd:  vd = b*vd + a
            r = fpDoubleToBits(b * d + a, sew);
          case 0x29: // vfnmadd: vd = -(b*vd) - a
            r = fpDoubleToBits(-(b * d) - a, sew);
          case 0x2A: // vfmsub:  vd = b*vd - a
            r = fpDoubleToBits(b * d - a, sew);
          case 0x2B: // vfnmsub: vd = -(b*vd) + a
            r = fpDoubleToBits(-(b * d) + a, sew);
          default:
            r = aBits;
        }
        vwriteElem(vd, i, sew, r & mask);
      }
      vstart = 0;
      return pc + 4;
    }

    if (opcode == opV &&
        (funct3 == 0 || funct3 == 3 || funct3 == 4) &&
        (((instr >> 26) & 0x3F) == 0x2C || ((instr >> 26) & 0x3F) == 0x2D)) {
      // Narrowing shift-right: vd[SEW] = (vs2[2*SEW] >> shamt). vnsrl (0x2C,
      // logical) / vnsra (0x2D, arithmetic). shamt from vs1[SEW]/x[rs1]/uimm5.
      final funct6 = (instr >> 26) & 0x3F;
      final vm = (instr >> 25) & 0x1;
      final vd = (instr >> 7) & 0x1F;
      final f1 = (instr >> 15) & 0x1F;
      final vs2 = (instr >> 20) & 0x1F;
      final sew = 8 << ((vtype >> 3) & 0x7);
      final wsew = sew * 2;
      final mask = sew >= 64 ? -1 : ((1 << sew) - 1);
      final scalar = funct3 == 4 ? reg(f1) : f1; // .wx reg / .wi uimm5
      bool active(int i) => vm == 1 || ((vregs[0][i >> 3] >> (i & 7)) & 1) == 1;
      for (var i = vstart; i < vl; i++) {
        if (!active(i)) continue;
        final wide = vreadElem(vs2, i, wsew);
        final sh = (funct3 == 0 ? vreadElem(f1, i, sew) : scalar) & (wsew - 1);
        final r = funct6 == 0x2C
            ? wide >>>
                  sh // vnsrl (logical)
            : wide.toSigned(wsew) >> sh; // vnsra (arithmetic)
        vwriteElem(vd, i, sew, r & mask);
      }
      vstart = 0;
      return pc + 4;
    }

    if (opcode == opV && funct3 == 2 && ((instr >> 26) & 0x3F) == 0x12) {
      // vxunary0: vzext/vsext by factor 2/4/8 (vs1 selects). Source element is
      // SEW/factor wide, result is SEW.
      final vm = (instr >> 25) & 0x1;
      final vd = (instr >> 7) & 0x1F;
      final f1 = (instr >> 15) & 0x1F;
      final vs2 = (instr >> 20) & 0x1F;
      final sew = 8 << ((vtype >> 3) & 0x7);
      final mask = sew >= 64 ? -1 : ((1 << sew) - 1);
      final factor = f1 >= 0x06 ? 2 : (f1 >= 0x04 ? 4 : 8);
      final signed = (f1 & 1) == 1; // odd vs1 => sext, even => zext
      final ssew = sew ~/ factor;
      final smask = ssew >= 64 ? -1 : ((1 << ssew) - 1);
      bool active(int i) => vm == 1 || ((vregs[0][i >> 3] >> (i & 7)) & 1) == 1;
      for (var i = vstart; i < vl; i++) {
        if (!active(i)) continue;
        final src = vreadElem(vs2, i, ssew);
        final r = signed ? src.toSigned(ssew) : (src & smask);
        vwriteElem(vd, i, sew, r & mask);
      }
      vstart = 0;
      return pc + 4;
    }

    if (opcode == opV &&
        (funct3 == 2 || funct3 == 6) &&
        ((instr >> 26) & 0x3F) >= 0x30 &&
        ((instr >> 26) & 0x3F) <= 0x3F) {
      // Widening integer arithmetic: result is 2*SEW (spans the vd group, which
      // the LMUL-aware element accessors handle). Valid for SEW<=32 (a 2*SEW=128
      // result for SEW=64 would need BigInt; truncated here).
      final funct6 = (instr >> 26) & 0x3F;
      final vm = (instr >> 25) & 0x1;
      final vd = (instr >> 7) & 0x1F;
      final f1 = (instr >> 15) & 0x1F;
      final vs2 = (instr >> 20) & 0x1F;
      final sew = 8 << ((vtype >> 3) & 0x7);
      final wsew = sew * 2;
      final wmask = wsew >= 64 ? -1 : ((1 << wsew) - 1);
      final smask = sew >= 64 ? -1 : ((1 << sew) - 1);
      int sx(int x) => x.toSigned(sew); // sign-extend from SEW
      int zx(int x) => x & smask; // zero-extend from SEW
      final scalar = funct3 == 6 ? reg(f1) : 0;
      bool active(int i) => vm == 1 || ((vregs[0][i >> 3] >> (i & 7)) & 1) == 1;
      for (var i = vstart; i < vl; i++) {
        if (!active(i)) continue;
        final aRaw = vreadElem(vs2, i, sew);
        final bRaw = funct3 == 6 ? scalar : vreadElem(f1, i, sew);
        final r = switch (funct6) {
          0x30 => zx(aRaw) + zx(bRaw), // vwaddu
          0x31 => sx(aRaw) + sx(bRaw), // vwadd
          0x32 => zx(aRaw) - zx(bRaw), // vwsubu
          0x33 => sx(aRaw) - sx(bRaw), // vwsub
          0x38 => zx(aRaw) * zx(bRaw), // vwmulu
          0x3A => sx(aRaw) * zx(bRaw), // vwmulsu
          0x3B => sx(aRaw) * sx(bRaw), // vwmul
          _ => sx(aRaw),
        };
        vwriteElem(vd, i, wsew, r & wmask);
      }
      vstart = 0;
      return pc + 4;
    }

    if (opcode == opV) {
      // Integer / multiply vector arithmetic. funct6 = bits[31:26]; funct3
      // selects operand source & category:
      //   0=OPIVV 3=OPIVI 4=OPIVX (integer), 2=OPMVV 6=OPMVX (mul/div/misc).
      final funct6 = (instr >> 26) & 0x3F;
      final vm = (instr >> 25) & 0x1; // 0 => element-masked by v0
      final vd = (instr >> 7) & 0x1F;
      final f1 = (instr >> 15) & 0x1F; // vs1 (vv) / rs1 (vx) / simm5 (vi)
      final vs2 = (instr >> 20) & 0x1F;
      final sew = 8 << ((vtype >> 3) & 0x7);
      final mask = sew >= 64 ? -1 : ((1 << sew) - 1);
      final minInt = 1 << 63;

      int us(int x) => x & mask; // unsigned within SEW
      int ss(int x) => x.toSigned(sew); // signed within SEW
      bool ltu(int x, int y) =>
          sew < 64 ? us(x) < us(y) : (x ^ minInt) < (y ^ minInt);
      BigInt big(int x, {required bool signed}) => signed
          ? BigInt.from(ss(x))
          : BigInt.from(us(x)) & ((BigInt.one << sew) - BigInt.one);
      bool active(int i) => vm == 1 || ((vregs[0][i >> 3] >> (i & 7)) & 1) == 1;

      final isMul = funct3 == 2 || funct3 == 6; // OPMVV / OPMVX
      final isMerge = !isMul && funct6 == 0x17; // vmerge / vmv.v.*
      // .vx/OPMVX scalar from rs1; .vi simm5; .vv/OPMVV take vs1 elements.
      final scalar = (funct3 == 4 || funct3 == 6) ? reg(f1) : f1.toSigned(5);

      for (var i = vstart; i < vl; i++) {
        // vmerge writes every element (selecting source by mask); ordinary
        // masked ops leave inactive elements undisturbed.
        if (!isMerge && !active(i)) continue;
        final a = vreadElem(vs2, i, sew);
        final b = (funct3 == 0 || funct3 == 2)
            ? vreadElem(f1, i, sew) // .vv / OPMVV: vs1 element
            : scalar;
        final int r;
        if (isMerge) {
          r = active(i) ? b : a; // vm==1 => vmv.v (always b)
        } else if (isMul) {
          r = switch (funct6) {
            0x25 => a * b, // vmul (low bits)
            0x24 =>
              (big(a, signed: false) * big(b, signed: false) >> sew)
                  .toInt(), // vmulhu
            0x27 =>
              (big(a, signed: true) * big(b, signed: true) >> sew)
                  .toInt(), // vmulh
            0x26 =>
              (big(a, signed: true) * big(b, signed: false) >> sew)
                  .toInt(), // vmulhsu
            0x20 => us(b) == 0 ? -1 : us(a) ~/ us(b), // vdivu (/0 => all-ones)
            0x21 => ss(b) == 0 ? -1 : ss(a) ~/ ss(b), // vdiv
            0x22 => us(b) == 0 ? a : us(a) % us(b), // vremu (/0 => dividend)
            0x23 => ss(b) == 0 ? a : ss(a).remainder(ss(b)), // vrem
            0x14 => i, // vid.v (element index)
            _ => a,
          };
        } else {
          final sh = b & (sew - 1);
          r = switch (funct6) {
            0x00 => a + b, // vadd
            0x02 => a - b, // vsub
            0x03 => b - a, // vrsub (.vx/.vi)
            0x04 => ltu(a, b) ? a : b, // vminu
            0x05 => ss(a) < ss(b) ? a : b, // vmin
            0x06 => ltu(a, b) ? b : a, // vmaxu
            0x07 => ss(a) < ss(b) ? b : a, // vmax
            0x09 => a & b, // vand
            0x0A => a | b, // vor
            0x0B => a ^ b, // vxor
            0x25 => a << sh, // vsll
            0x28 => us(a) >> sh, // vsrl (logical)
            0x29 => ss(a) >> sh, // vsra (arithmetic)
            _ => a,
          };
        }
        vwriteElem(vd, i, sew, r & mask);
      }
      vstart = 0;
      return pc + 4;
    }

    // Unit-stride load/store only (mop bits[27:26] == 0). vm bit[25]: 0 masks
    // by v0, skipping inactive elements (undisturbed/unmodified memory).
    bool vActive(int vm, int i) =>
        vm == 1 || ((vregs[0][i >> 3] >> (i & 7)) & 1) == 1;

    // Unit-stride (mop==0) and strided (mop==2) loads. For strided the byte
    // stride is x[rs2]; for unit-stride it is the element size.
    if (opcode == vLoad &&
        vWidth(funct3) &&
        (((instr >> 26) & 0x3) == 0 || ((instr >> 26) & 0x3) == 2)) {
      final mop = (instr >> 26) & 0x3;
      final vm = (instr >> 25) & 0x1;
      final vd = (instr >> 7) & 0x1F;
      final base = reg((instr >> 15) & 0x1F);
      final sew = widthSew[funct3]!;
      final bytes = sew ~/ 8;
      final stride = mop == 2 ? reg((instr >> 20) & 0x1F) : bytes;
      for (var i = vstart; i < vl; i++) {
        if (!vActive(vm, i)) continue;
        vwriteElem(vd, i, sew, await mmu.read(base + i * stride, bytes));
      }
      vstart = 0;
      return pc + 4;
    }

    if (opcode == vStore &&
        vWidth(funct3) &&
        (((instr >> 26) & 0x3) == 0 || ((instr >> 26) & 0x3) == 2)) {
      final mop = (instr >> 26) & 0x3;
      final vm = (instr >> 25) & 0x1;
      final vs3 = (instr >> 7) & 0x1F;
      final base = reg((instr >> 15) & 0x1F);
      final sew = widthSew[funct3]!;
      final bytes = sew ~/ 8;
      final stride = mop == 2 ? reg((instr >> 20) & 0x1F) : bytes;
      for (var i = vstart; i < vl; i++) {
        if (!vActive(vm, i)) continue;
        await mmu.write(base + i * stride, vreadElem(vs3, i, sew), bytes);
      }
      vstart = 0;
      return pc + 4;
    }

    return null;
  }

  Future<int> cycle(int pc, int instr) async {
    // Only the V opcodes take the (async) vector path. Gate it so the common
    // path doesn't gain an early await, some callers don't await cycle() and
    // rely on it completing synchronously up to the first real suspension.
    final op7 = instr & 0x7F;
    if (hasVector && (op7 == 0x57 || op7 == 0x07 || op7 == 0x27)) {
      final vec = await executeVector(pc, instr);
      if (vec != null) return vec;
    }

    RiscVOperation? op;
    if ((instr & 0x3) != 0x3) {
      final opcode = instr & 0x3;
      final funct3 = (instr >> 13) & 0x7;
      for (final ext in config.extensions) {
        op = ext.findOperation(
          opcode,
          funct3: funct3,
          instruction: instr,
          mxlen: config.mxlen,
        );
        if (op != null) break;
      }
    } else {
      op = config.isa.findOperation(instr);
    }

    if (op != null) {
      final ir = DecodedInstruction.decode(instr, op);
      var state = RiverCoreState(pc, ir, xregs[Register.x2] ?? 0);
      state = await _innerExecute(state, op);
      xregs[Register.x2] = state.sp;
      return state.pc;
    }

    return trap(pc, TrapException.illegalInstruction(StackTrace.current));
  }

  int? _nextPendingIrq() {
    int? bestIrq;

    for (final ctl in _interrupts) {
      final irq = ctl.nextPending();
      if (irq == null) continue;

      if (bestIrq == null || irq < bestIrq) {
        bestIrq = irq;
      }
    }

    return bestIrq;
  }

  Trap _selectExternalInterruptTrap() {
    if (!config.hasSupervisor) {
      return Trap.machineExternal;
    }

    final mideleg = csrs.read(CsrAddress.mideleg.address, this);
    final delegated = ((mideleg >> Trap.machineExternal.causeCode) & 1) != 0;
    return delegated ? Trap.supervisorExternal : Trap.machineExternal;
  }

  Future<void> _handleInterrupt(PipelineContext ctx) async {
    if (idle) {
      ctx.halted = true;
      return;
    }

    final irq = _nextPendingIrq();
    if (irq != null) {
      final mie = csrs.read(CsrAddress.mie.address, this);
      final mstatus = csrs.read(CsrAddress.mstatus.address, this);

      final mieMeie = ((mie >> Trap.machineExternal.causeCode) & 1) != 0;
      final mstatusMie = ((mstatus >> 3) & 1) != 0;

      if (mieMeie && mstatusMie) {
        final trapTarget = _selectExternalInterruptTrap();
        ctx.pc = trap(ctx.pc, TrapException(trapTarget));
        ctx.halted = true;
      }
    }
  }

  Future<void> _handleFetch(PipelineContext ctx) async {
    ctx.instruction = await fetch(ctx.pc);
  }

  Future<void> _handleDecode(PipelineContext ctx) async {
    final instr = ctx.instruction!;

    if ((instr & 0x3) != 0x3) {
      final opcode = instr & 0x3;
      final funct3 = (instr >> 13) & 0x7;
      for (final ext in config.extensions) {
        ctx.op = ext.findOperation(
          opcode,
          funct3: funct3,
          instruction: instr,
          mxlen: config.mxlen,
        );
        if (ctx.op != null) break;
      }
    } else {
      ctx.op = config.isa.findOperation(instr);
    }

    if (ctx.op != null) {
      final ir = DecodedInstruction.decode(instr, ctx.op!);
      ctx.state = RiverCoreState(ctx.pc, ir, xregs[Register.x2] ?? 0);
    }
  }

  Future<void> _handleExecute(PipelineContext ctx) async {
    if (ctx.op == null) {
      ctx.pc = trap(
        ctx.pc,
        TrapException.illegalInstruction(StackTrace.current),
      );
      return;
    }

    final state = await _innerExecute(ctx.state!, ctx.op!);
    xregs[Register.x2] = state.sp;
    ctx.pc = state.pc;
  }

  Future<int> runPipeline(int pc) async {
    final ctx = PipelineContext(pc);
    try {
      await pipeline.run(ctx);
    } on TrapException catch (e) {
      ctx.pc = trap(ctx.pc, e);
    }
    return ctx.pc;
  }

  @override
  String toString() =>
      'RiverCore(xregs: $xregs, mmu: $mmu, csrs: ${csrs.toStringWithCore(this)}, mode: $mode, interrupts: $interrupts)';
}
