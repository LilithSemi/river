import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:rohd_hcl/rohd_hcl.dart' as hcl show DataPortInterface;
import 'package:river/river.dart';
import '../data_port.dart';

class RiscVMstatusCsr extends CsrConfig {
  // mstatus holds the WHOLE status state of the hart. sstatus is only a
  // restricted view of these same bits (see [RiscVCsrFile], which aliases the
  // sstatus address onto this register), so every S-visible field must live
  // here. Only declared field bits are read back, so a field that is absent
  // reads as 0 and drops its writes.
  //
  // [sup] adds the supervisor fields SIE/SPIE/SPP. [sum] adds SUM and [mxr]
  // adds MXR, which the MMU reads to allow an S-mode access to a user page and
  // a load from an execute-only page. [fp] adds FS and [vec] adds VS, the
  // extension context-status fields the OS uses to track a dirty context.
  // [hyp] adds MPV (bit 39, RV64 hypervisor) so the V-bit can be pushed and
  // popped on trap/MRET.
  RiscVMstatusCsr({
    bool sup = false,
    bool mprv = false,
    bool sum = false,
    bool mxr = false,
    bool fp = false,
    bool vec = false,
    bool hyp = false,
  }) : super(
         name: 'mstatus',
         access: CsrAccess.readWrite,
         fields: [
           if (sup)
             CsrFieldConfig(
               start: 1,
               width: 1,
               name: 'sie',
               access: CsrFieldAccess.readWrite,
             ),
           CsrFieldConfig(
             start: 3,
             width: 1,
             name: 'mie',
             access: CsrFieldAccess.readWrite,
           ),
           if (sup)
             CsrFieldConfig(
               start: 5,
               width: 1,
               name: 'spie',
               access: CsrFieldAccess.readWrite,
             ),
           CsrFieldConfig(
             start: 7,
             width: 1,
             name: 'mpie',
             access: CsrFieldAccess.readWrite,
           ),
           if (sup)
             CsrFieldConfig(
               start: 8,
               width: 1,
               name: 'spp',
               access: CsrFieldAccess.readWrite,
             ),
           if (vec)
             CsrFieldConfig(
               start: 9,
               width: 2,
               name: 'vs',
               access: CsrFieldAccess.readWrite,
             ),
           CsrFieldConfig(
             start: 11,
             width: 2,
             name: 'mpp',
             access: CsrFieldAccess.readWrite,
           ),
           if (fp)
             CsrFieldConfig(
               start: 13,
               width: 2,
               name: 'fs',
               access: CsrFieldAccess.readWrite,
             ),
           if (mprv)
             CsrFieldConfig(
               start: 17,
               width: 1,
               name: 'mprv',
               access: CsrFieldAccess.readWrite,
             ),
           if (sum)
             CsrFieldConfig(
               start: 18,
               width: 1,
               name: 'sum',
               access: CsrFieldAccess.readWrite,
             ),
           if (mxr)
             CsrFieldConfig(
               start: 19,
               width: 1,
               name: 'mxr',
               access: CsrFieldAccess.readWrite,
             ),
           if (hyp)
             CsrFieldConfig(
               start: 39,
               width: 1,
               name: 'mpv',
               access: CsrFieldAccess.readWrite,
             ),
         ],
       );
}

class ReadOnlyNoFieldCsr extends CsrConfig {
  // A full-width read-only field is needed for the value to be readable: a
  // CsrTop register with no fields reads back as X (only declared field bits are
  // reconstructed). The reset value still drives the bits.
  ReadOnlyNoFieldCsr(String name, int width)
    : super(
        name: name,
        access: CsrAccess.readOnly,
        fields: [
          CsrFieldConfig(
            start: 0,
            width: width,
            name: 'value',
            access: CsrFieldAccess.readOnly,
          ),
        ],
      );
}

class SimpleRwCsr extends CsrConfig {
  // Full-width read/write field so csrr reads back the stored value (a no-field
  // register reads as X). Per-CSR WARL masking is applied in _maskWriteData.
  SimpleRwCsr(String name, int width)
    : super(
        name: name,
        access: CsrAccess.readWrite,
        fields: [
          CsrFieldConfig(
            start: 0,
            width: width,
            name: 'value',
            access: CsrFieldAccess.readWrite,
          ),
        ],
      );
}

class CounterCsr extends CsrConfig {
  // mcycle/minstret are M-mode read/write per the privileged spec, so the
  // access MUST be readWrite. The access also gates the backdoor write path:
  // rohd_hcl runs every backdoor write value through Csr.getWriteData, which
  // for a readOnly register returns the CURRENT value and drops the new data.
  // With readOnly the per-cycle hardware increment (see _wireCounters) was
  // silently discarded, so the counters stayed stuck at their reset value 0.
  CounterCsr(String name)
    : super(name: name, access: CsrAccess.readWrite, fields: const []);
}

class RiscVCsrFile extends Module {
  final RiscVMxlen mxlen;

  final int misaValue;
  final int mvendoridValue;
  final int marchidValue;
  final int mimpidValue;
  final int mhartidValue;
  final int rpipelineCapValue;

  final bool hasSupervisor;
  final bool hasUser;
  final bool hasPaging;
  final bool hasMxr;
  final bool hasSum;
  final bool hasHypervisor;
  final bool hasStateen;

  late final Logic clk;
  late final Logic reset;
  late final Logic mode;

  late final DataPortInterface csrRead;
  late final DataPortInterface csrWrite;

  late final CsrTop _csrTop;

  late final hcl.DataPortInterface _fdRead;
  late final hcl.DataPortInterface _fdWrite;

  late final List<int> _implementedAddrs;
  late final Set<int> _frontdoorWritableAddrs;

  CsrBackdoorInterface? _mcycleBd;
  CsrBackdoorInterface? _minstretBd;

  // The live machine-timer value (CLINT mtime), read out for the `time` CSR
  // (rdtime). Null when the SoC has no CLINT, in which case `time` is not added.
  Logic? _timeIn;

  // The PLIC supervisor-external interrupt line. Null when the SoC has no
  // supervisor-external context. See mip.SEIP below.
  Logic? _seiPendingIn;

  // Asserted for one cycle when an FP register write retires. It sets the
  // sticky FP-dirty flop below. Null when the core has no FP register file.
  Logic? _fpDirtyIn;

  // H needs VS/host FS legality and dirty-state handling together. Preserve
  // its current unsupported-FCSR behavior until that separate integration.
  final bool enableFcsr;
  bool get hasFcsr => enableFcsr && _hasFloat && !hasHypervisor;
  Logic? get frm => hasFcsr ? output('frm') : null;
  Logic? _fcsr;
  Logic? _fpFlagsValid;
  Logic? _fpFlags;
  Logic? _fcsrDirty;

  // Asserted for one cycle when an instruction retires. It advances minstret.
  // Null when nothing drives it, in which case minstret does not count.
  Logic? _retireIn;

  // The sticky FP-dirty flop. It is set by [_fpDirtyIn] and it is cleared or
  // set by a software write of the mstatus/sstatus FS field. Every mstatus and
  // sstatus READ shows FS=Dirty while it is set. See [_statusRead].
  Logic? _fsDirty;

  // Trap save-state / xRET restore controls (driven by core.dart). All
  // optional; when null the trap CSRs are not hardware-written (csrr/csrw work).
  Logic? _trapActive; // 1-cycle pulse: a synchronous trap is retiring
  Logic? _trapTargetIsM; // 1 = trap delegated/routed to M, 0 = to S
  Logic? _trapPc; // PC of the trapping instruction → {m,s}epc
  Logic? _trapCauseVal; // full mcause value (interrupt<<xlen-1 | cause)
  Logic? _trapTval; // → {m,s}tval
  Logic? _returnActive; // 1-cycle pulse: an xRET is retiring
  Logic? _returnFromM; // 1 = MRET, 0 = SRET
  Logic?
  _virtInput; // current V-bit: in VS-mode, S-CSR accesses redirect to vs*
  Logic? _trapToVS; // pulse: a trap is being delegated to VS-mode (save to vs*)

  RiscVCsrFile(
    Logic clk,
    Logic reset,
    Logic mode, {
    required this.mxlen,
    required int misa,
    int mvendorid = 0,
    int marchid = riverArchId,
    int mimpid = 0,
    int mhartid = 0,
    int rpipelineCap = 0,
    Logic? externalPending,
    Logic? supervisorExternalPending,
    // Asserted when an FP register write retires. Sets mstatus.FS to Dirty.
    Logic? fpDirty,
    // Disable where precise FP retirement is not integrated (currently OoO).
    this.enableFcsr = true,
    // Exception flags from a successfully retiring FP instruction (NV..NX).
    Logic? fpFlagsValid,
    Logic? fpFlags,
    // Asserted when an instruction retires. Advances minstret.
    Logic? retire,
    Logic? timerPending,
    Logic? swPending,
    Logic? timeIn,
    this.hasSupervisor = false,
    this.hasUser = false,
    this.hasPaging = false,
    this.hasMxr = false,
    this.hasSum = false,
    this.hasHypervisor = false,
    this.hasStateen = false,
    Logic? trapActive,
    Logic? trapTargetIsM,
    Logic? trapPc,
    Logic? trapCauseVal,
    Logic? trapTval,
    Logic? returnActive,
    Logic? returnFromM,
    Logic? virtInput,
    Logic? trapToVS,
    required DataPortInterface csrRead,
    required DataPortInterface csrWrite,
    super.name = 'riscv_csr_file',
  }) : misaValue = misa,
       mvendoridValue = mvendorid,
       marchidValue = marchid,
       mimpidValue = mimpid,
       mhartidValue = mhartid,
       rpipelineCapValue = rpipelineCap {
    this.clk = addInput('clk', clk);
    this.reset = addInput('reset', reset);
    this.mode = addInput('mode', mode, width: 3);

    if (externalPending != null) {
      externalPending = addInput(
        'externalPending',
        externalPending,
        width: externalPending.width,
      );
    }
    // The PLIC supervisor-external line -> mip.SEIP (bit 9). The spec makes a
    // read of mip.SEIP the OR of this wire and the software-writable bit, so
    // the wire is folded into every READ path but never into the value written
    // back to the register. If it were written back, software could not tell
    // its own bit from the wire, and clearing the bit would fight the PLIC.
    if (supervisorExternalPending != null) {
      _seiPendingIn = addInput('seiPending', supervisorExternalPending);
    }
    if (fpDirty != null) {
      _fpDirtyIn = addInput('fpDirty', fpDirty);
    }
    if (hasFcsr) {
      _fcsr = Logic(name: 'fcsr', width: 8);
      _fpFlagsValid = addInput('fpFlagsValid', fpFlagsValid ?? Const(0));
      _fpFlags = addInput('fpFlags', fpFlags ?? Const(0, width: 5), width: 5);
      _fcsrDirty = Logic(name: 'fcsrDirty');
      addOutput('frm', width: 3) <= _fcsr!.slice(7, 5);
    }
    if (retire != null) {
      _retireIn = addInput('retire', retire);
    }
    // Machine timer/software interrupt-pending lines, driven by the CLINT
    // (timer_irq = mtime>=mtimecmp -> mip.MTIP; sw_irq = msip -> mip.MSIP).
    // Read-only to software, hardware-owned, mirroring externalPending -> MEIP.
    if (timerPending != null) {
      timerPending = addInput('timerPending', timerPending);
    }
    if (swPending != null) {
      swPending = addInput('swPending', swPending);
    }
    // Live CLINT mtime, exposed to software through the read-only `time` CSR.
    if (timeIn != null) {
      _timeIn = addInput('timeIn', timeIn, width: timeIn.width);
    }

    _trapActive = trapActive == null
        ? null
        : addInput('trapActive', trapActive);
    _trapTargetIsM = trapTargetIsM == null
        ? null
        : addInput('trapTargetIsM', trapTargetIsM);
    _trapPc = trapPc == null
        ? null
        : addInput('trapPc', trapPc, width: mxlen.size);
    _trapCauseVal = trapCauseVal == null
        ? null
        : addInput('trapCauseVal', trapCauseVal, width: mxlen.size);
    _trapTval = trapTval == null
        ? null
        : addInput('trapTval', trapTval, width: mxlen.size);
    _returnActive = returnActive == null
        ? null
        : addInput('returnActive', returnActive);
    _returnFromM = returnFromM == null
        ? null
        : addInput('returnFromM', returnFromM);
    _virtInput = virtInput == null ? null : addInput('virtIn', virtInput);
    _trapToVS = trapToVS == null ? null : addInput('trapToVS', trapToVS);

    addOutput('mstatus', width: mxlen.size);
    addOutput('mie', width: mxlen.size);
    addOutput('mip', width: mxlen.size);
    addOutput('mideleg', width: mxlen.size);
    addOutput('medeleg', width: mxlen.size);
    addOutput('mtvec', width: mxlen.size);
    // Exposed for the core's xRET PC/mode restore (output port, not a raw
    // backdoor read, to respect ROHD module boundaries).
    addOutput('mepc', width: mxlen.size);
    // Speculation/pipeline control. The core slices its low bits (DTLBFC + the
    // pipeline specCtl), so it must be a real output port (same boundary reason).
    addOutput('rpipelinectl', width: mxlen.size);
    // Microcode-update staging inputs: the core reads these stored CSR values
    // (the patch address/data) and drives the ROM write port on a ctl pulse.
    addOutput('rmicrocodeaddr', width: mxlen.size);
    addOutput('rmicrocodedata', width: mxlen.size);

    if (hasSupervisor) {
      addOutput('stvec', width: mxlen.size);
      addOutput('satp', width: mxlen.size);
      addOutput('sepc', width: mxlen.size);
      addOutput('sstatus', width: mxlen.size);
      addOutput('sie', width: mxlen.size);
      addOutput('sip', width: mxlen.size);
    }

    if (hasHypervisor) {
      addOutput('hstatus', width: mxlen.size);
      addOutput('hedeleg', width: mxlen.size);
      addOutput('vstvec', width: mxlen.size);
    }

    // Smstateen SE0 bits, exposed so the pipeline raises the correct exception
    // for a VS-mode state-enable access: mstateen0.SE0 clear -> illegal (below
    // M); set but hstateen0.SE0 clear in VS -> virtual.
    if (hasStateen) {
      addOutput('mstateen0_se0');
      if (hasHypervisor) addOutput('hstateen0_se0');
    }

    void checkFits(String n, int v) {
      if (mxlen.size < 64 && v < 0) {
        throw ArgumentError('$n must be non-negative, got $v');
      }
      if (mxlen.size < 63) {
        final max = 1 << mxlen.size;
        if (v >= max) {
          throw ArgumentError(
            '$n (0x${v.toRadixString(16)}) does not fit in XLEN=${mxlen.size}',
          );
        }
      }
    }

    checkFits('misa', misaValue);
    checkFits('mvendorid', mvendoridValue);
    checkFits('marchid', marchidValue);
    checkFits('mimpid', mimpidValue);
    checkFits('mhartid', mhartidValue);

    this.csrRead = csrRead.clone()
      ..connectIO(
        this,
        csrRead,
        outputTags: {DataPortGroup.data, DataPortGroup.integrity},
        inputTags: {DataPortGroup.control},
        uniquify: (og) => 'csrRead_$og',
      );

    this.csrWrite = csrWrite.clone()
      ..connectIO(
        this,
        csrWrite,
        outputTags: {DataPortGroup.integrity},
        inputTags: {DataPortGroup.control, DataPortGroup.data},
        uniquify: (og) => 'csrWrite_$og',
      );

    final cfg = _buildConfig(mxlen);

    _fdRead = hcl.DataPortInterface(mxlen.size, 12);
    _fdWrite = hcl.DataPortInterface(mxlen.size, 12);

    // Created here because the mstatus/sstatus read paths below consume it.
    // It is DRIVEN in _wireFsDirty, which needs the frontdoor write port.
    _fsDirty = _fpDirtyIn == null && !hasFcsr
        ? null
        : Logic(name: 'fsDirtySticky');

    _csrTop = CsrTop(
      config: cfg,
      clk: this.clk,
      reset: this.reset,
      frontRead: _fdRead,
      frontWrite: _fdWrite,
      allowLargerRegisters: true,
    );

    _implementedAddrs = [
      ...cfg.blocks.single.registers.map((r) => r.addr),
      // sstatus/sie/sip have no registers of their own; they are views of
      // mstatus/mie/mip. They must still exist for the legality check, which
      // uses the ARCHITECTURAL address so an S-mode access to 0x100/0x104/0x144
      // is legal while the M-mode target address stays M-only.
      ...(hasSupervisor ? _supervisorAliases.keys : const <int>[]),
      if (hasFcsr) ...[1, 2, 3],
    ];

    _frontdoorWritableAddrs = <int>{};
    for (final r in cfg.blocks.single.registers) {
      if (r.arch.access == CsrAccess.readWrite) {
        _frontdoorWritableAddrs.add(r.addr);
      }
    }
    if (hasSupervisor) _frontdoorWritableAddrs.addAll(_supervisorAliases.keys);
    if (hasFcsr) _frontdoorWritableAddrs.addAll([1, 2, 3]);

    _wireLegalityAndFrontdoor();

    _wireFsDirty();
    _bindBackdoorForCounters();
    _wireCounters();
    _wireTrapState();

    // The FS and SD bits are added on the READ path only. The register itself
    // keeps what software last wrote. See [_statusRead].
    mstatus <= _statusRead(_mstatusRaw);
    mie <= _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mie.address).rdData!;
    // mip is the ONLY interrupt-pending state. Its SEIP bit reads as the OR of
    // the PLIC line and the software bit, so the output port (and every read
    // path) carries the OR while the register itself keeps only the software
    // bit. The backdoor writer below therefore starts from the RAW value.
    mip <= _mipWithSei(_mipRaw);
    mideleg <=
        _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mideleg.address).rdData!;
    medeleg <=
        _csrTop.getBackdoorPortsByAddr(0, CsrAddress.medeleg.address).rdData!;
    mtvec <=
        _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mtvec.address).rdData!;
    mepc <= _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mepc.address).rdData!;
    output('rpipelinectl') <=
        _csrTop
            .getBackdoorPortsByAddr(0, CsrAddress.rpipelinectl.address)
            .rdData!;
    output('rmicrocodeaddr') <=
        _csrTop
            .getBackdoorPortsByAddr(0, CsrAddress.rmicrocodeaddr.address)
            .rdData!;
    output('rmicrocodedata') <=
        _csrTop
            .getBackdoorPortsByAddr(0, CsrAddress.rmicrocodedata.address)
            .rdData!;

    if (hasSupervisor) {
      stvec! <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.stvec.address).rdData!;

      satp! <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.satp.address).rdData!;

      output('sepc') <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.sepc.address).rdData!;
      // sstatus is the S-visible window on mstatus, so the output port carries
      // the same physical bits. The core reads SPP (bit 8) from here on SRET.
      output('sstatus') <= (mstatus & _maskConst(_sstatusMask));
      // sie and sip are the S-visible windows on mie and mip: the same physical
      // bits, narrowed to the supervisor set and to what mideleg delegates. The
      // core reads these for the S-interrupt take, so the pending/enable model
      // and the trap-target model (exec.dart, also mideleg) now agree.
      output('sie') <= (mie & _sInterruptMask);
      output('sip') <= (mip & _sInterruptMask);
    }

    if (hasHypervisor) {
      output('hstatus') <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.hstatus.address).rdData!;
      output('hedeleg') <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.hedeleg.address).rdData!;
      output('vstvec') <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.vstvec.address).rdData!;
    }

    if (hasStateen) {
      output('mstateen0_se0') <=
          _csrTop
              .getBackdoorPortsByAddr(0, CsrAddress.mstateen0.address)
              .rdData![mxlen.size - 1];
      if (hasHypervisor) {
        output('hstateen0_se0') <=
            _csrTop
                .getBackdoorPortsByAddr(0, CsrAddress.hstateen0.address)
                .rdData![mxlen.size - 1];
      }
    }

    final mipBd = _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mip.address);
    // Hardware owns the machine interrupt-pending bits: MEIP(11)<-externalPending,
    // MTIP(7)<-timerPending, MSIP(3)<-swPending. Each is set from its line when
    // present; the other mip bits (the WARL S-bits, if any) pass through the
    // read-back value so a software write to them survives.
    if (externalPending != null || timerPending != null || swPending != null) {
      // Start from the RAW register, not the `mip` output: the output folds in
      // the PLIC SEIP line, and writing that back would make the wire
      // indistinguishable from software's own bit.
      var mipNext = _mipRaw;
      if (externalPending != null)
        mipNext = mipNext.withSet(11, externalPending);
      if (timerPending != null) mipNext = mipNext.withSet(7, timerPending);
      if (swPending != null) mipNext = mipNext.withSet(3, swPending);
      mipBd.wrEn! <= Const(1);
      mipBd.wrData! <= mipNext;
    } else {
      // Must still drive the backdoor write port: an undriven wrEn floats to X
      // and the CsrBlock's ElseIf(backdoorWrEn) corrupts mip to X.
      mipBd.wrEn! <= Const(0);
      mipBd.wrData! <= Const(0, width: mxlen.size);
    }

    // mscratch has no hardware writer but is backdoor-writable so tests can seed
    // it via setData. Tie wrEn to 0 (as for mip) so it never floats to X;
    // setData's inject overrides this during seeding.
    final mscratchBd = _csrTop.getBackdoorPortsByAddr(
      0,
      CsrAddress.mscratch.address,
    );
    mscratchBd.wrEn! <= Const(0);
    mscratchBd.wrData! <= Const(0, width: mxlen.size);
  }

  // The F/D and V bits of misa. They decide if mstatus carries the FS and VS
  // extension context-status fields.
  bool get _hasFloat =>
      ((misaValue >> 3) & 1) != 0 || ((misaValue >> 5) & 1) != 0;
  bool get _hasVector => ((misaValue >> 21) & 1) != 0;

  CsrTopConfig _buildConfig(RiscVMxlen mxlen) {
    // The S-visible subset of mstatus: UIE, SIE, UPIE, SPIE, SPP, FS, XS, SUM,
    // MXR and SD, plus UXL on RV64. A read of sstatus returns mstatus AND this
    // mask, and a write of sstatus changes only these mstatus bits. Bits with no
    // mstatus field (UIE/UPIE/XS/UXL/SD) stay 0.
    final sstatusMask = mxlen == RiscVMxlen.rv64
        ? 0x80000003000DE133
        : 0x800DE133;
    const ustatusMask = 0x11;
    const supervisorInterruptMask = 0x222;
    const userInterruptMask = 0x111;

    final regs = <CsrInstanceConfig>[
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('mvendorid', mxlen.size),
        addr: CsrAddress.mvendorid.address,
        width: mxlen.size,
        resetValue: mvendoridValue,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('marchid', mxlen.size),
        addr: CsrAddress.marchid.address,
        width: mxlen.size,
        resetValue: marchidValue,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('mimpid', mxlen.size),
        addr: CsrAddress.mimpid.address,
        width: mxlen.size,
        resetValue: mimpidValue,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('mhartid', mxlen.size),
        addr: CsrAddress.mhartid.address,
        width: mxlen.size,
        resetValue: mhartidValue,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('misa', mxlen.size),
        addr: CsrAddress.misa.address,
        width: mxlen.size,
        resetValue: misaValue,
        isBackdoorWritable: false,
      ),

      CsrInstanceConfig(
        arch: RiscVMstatusCsr(
          sup: hasSupervisor,
          // H effective-context selection is not implemented yet. Preserve its
          // existing read-only-zero MPRV rather than advertise partial support.
          mprv: hasUser && !hasHypervisor,
          sum: hasSum,
          mxr: hasMxr,
          fp: _hasFloat,
          vec: _hasVector,
          hyp: hasHypervisor,
        ),
        addr: CsrAddress.mstatus.address,
        resetValue: !hasHypervisor && !hasUser ? 3 << 11 : 0,
        width: mxlen.size,
        // Hardware-written on trap entry / xRET; wrEn driven in _wireTrapState.
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mie', mxlen.size),
        addr: CsrAddress.mie.address,
        resetValue: 0,
        width: mxlen.size,
        // No hardware writer, must be false or the undriven backdoor wrEn floats
        // to X and corrupts the register.
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mip', mxlen.size),
        addr: CsrAddress.mip.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mtvec', mxlen.size),
        addr: CsrAddress.mtvec.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mscratch', mxlen.size),
        addr: CsrAddress.mscratch.address,
        resetValue: 0,
        width: mxlen.size,
        // Backdoor-writable so tests can seed it via setData; its wrEn is tied
        // to 0 below (see mip) so it never floats to X in normal operation.
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mepc', mxlen.size),
        addr: CsrAddress.mepc.address,
        resetValue: 0,
        width: mxlen.size,
        // Hardware-written on trap entry (wrEn driven in _wireTrapState).
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mcause', mxlen.size),
        addr: CsrAddress.mcause.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mtval', mxlen.size),
        addr: CsrAddress.mtval.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('medeleg', mxlen.size),
        addr: CsrAddress.medeleg.address,
        resetValue: 0,
        width: mxlen.size,
        // No hardware writer, must be false (undriven backdoor wrEn -> X, which
        // silently broke S/VS-mode trap delegation when medeleg[cause] read X).
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mideleg', mxlen.size),
        addr: CsrAddress.mideleg.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),

      // mcounteren: the machine counter-enable register. The privileged spec
      // requires it when U-mode is implemented. It gates U-mode access to the
      // cycle/time/instret counters. Only CY/TM/IR (bits 2:0) are writable, one
      // per implemented counter; the HPM bits are WARL-0 (mask in
      // _maskWriteData). Weir writes 0x7 to it during the S-mode handoff, and a
      // Linux kernel likewise programs it, so an absent register would trap the
      // write as illegal.
      if (hasUser)
        CsrInstanceConfig(
          arch: SimpleRwCsr('mcounteren', mxlen.size),
          addr: CsrAddress.mcounteren.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),

      // menvcfg: the machine environment-configuration register. The privileged
      // spec requires it when S-mode is implemented. OpenSBI/Weir and Linux
      // both read/write it (Sstc STCE, PBMTE, CBZE/CBIE, FIOM). River supports
      // none of those features, so every field is WARL-0 (mask 0 in
      // _maskWriteData): writes are dropped, reads return 0. That is the correct
      // "feature absent" report - e.g. Linux's try_to_set_pmm reads PMM back as
      // 0 and gracefully concludes pointer masking is unavailable. An ABSENT
      // register would instead trap the access as illegal.
      if (hasSupervisor)
        CsrInstanceConfig(
          arch: SimpleRwCsr('menvcfg', mxlen.size),
          addr: CsrAddress.menvcfg.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),

      // Smstateen machine-level state-enable CSRs. Only SE0 (bit 63) is writable
      // (masked in _maskWriteData); the access gating lives in the legality path.
      if (hasStateen)
        for (final a in [
          CsrAddress.mstateen0,
          CsrAddress.mstateen1,
          CsrAddress.mstateen2,
          CsrAddress.mstateen3,
        ])
          CsrInstanceConfig(
            arch: SimpleRwCsr(a.name, mxlen.size),
            addr: a.address,
            resetValue: 0,
            width: mxlen.size,
            isBackdoorWritable: false,
          ),

      if (hasSupervisor) ...[
        // NOTE: sstatus (0x100) has NO register of its own. The privileged spec
        // makes it a restricted VIEW of mstatus, so its address is aliased onto
        // the mstatus register in _wireLegalityAndFrontdoor and its bits are
        // masked with _sstatusMask. A separate register would let SPP, SUM and
        // MXR read back values the trap logic and the MMU never see.
        // sie (0x104) and sip (0x144) have no registers of their own either.
        // They are views of mie and mip, masked with _sInterruptMask. Separate
        // registers let S-mode enable an interrupt the delivery path reads from
        // mie, and hid the PLIC SEIP line from a `csrr sip` entirely.
        // Ssstateen supervisor-level state-enable CSRs. No U-accessible
        // state-enabled features in River, so all bits are WARL-0 (mask 0).
        if (hasStateen)
          for (final a in [
            CsrAddress.sstateen0,
            CsrAddress.sstateen1,
            CsrAddress.sstateen2,
            CsrAddress.sstateen3,
          ])
            CsrInstanceConfig(
              arch: SimpleRwCsr(a.name, mxlen.size),
              addr: a.address,
              resetValue: 0,
              width: mxlen.size,
              isBackdoorWritable: false,
            ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('stvec', mxlen.size),
          addr: CsrAddress.stvec.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('sscratch', mxlen.size),
          addr: CsrAddress.sscratch.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('sepc', mxlen.size),
          addr: CsrAddress.sepc.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: true,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('scause', mxlen.size),
          addr: CsrAddress.scause.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: true,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('stval', mxlen.size),
          addr: CsrAddress.stval.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: true,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('satp', mxlen.size),
          addr: CsrAddress.satp.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        // scounteren: the supervisor counter-enable register. The privileged
        // spec requires it when S-mode is implemented. It gates U-mode access to
        // the cycle/time/instret counters. Only CY/TM/IR (bits 2:0) are
        // writable; the HPM bits are WARL-0 (mask in _maskWriteData). The Linux
        // RISC-V head code writes it unconditionally, so an absent register
        // traps the write as illegal and stops the kernel before start_kernel.
        CsrInstanceConfig(
          arch: SimpleRwCsr('scounteren', mxlen.size),
          addr: CsrAddress.scounteren.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        // senvcfg: the supervisor environment-configuration register. Required
        // when S-mode is implemented (priv spec 1.12+). Linux writes it from the
        // context-switch path (envcfg_update_bits) and probes it in
        // try_to_set_pmm/tagged_addr_init. River implements none of its features
        // (Zicbo CBIE/CBCFE/CBZE, pointer-masking PMM, FIOM), so every field is
        // WARL-0 (mask 0 in _maskWriteData): writes drop, reads return 0. That
        // correctly reports "feature absent"; an ABSENT register would trap the
        // csrw/csrr as illegal (fu_csr raises cause 2 on an unimplemented CSR).
        CsrInstanceConfig(
          arch: SimpleRwCsr('senvcfg', mxlen.size),
          addr: CsrAddress.senvcfg.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
      ],

      // Hypervisor (H) + VS-shadow CSRs. Gated on hasHypervisor. hgeip is
      // read-only.
      if (hasHypervisor) ...[
        // hstatus is hardware-touched (SRET clears SPV), so backdoor-writable
        // and exposed as an output; the rest are plain RW CSRs.
        CsrInstanceConfig(
          arch: SimpleRwCsr('hstatus', mxlen.size),
          addr: CsrAddress.hstatus.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: true,
        ),
        // Hypervisor state-enable CSRs (only SE0 writable on hstateen0).
        if (hasStateen)
          for (final a in [
            CsrAddress.hstateen0,
            CsrAddress.hstateen1,
            CsrAddress.hstateen2,
            CsrAddress.hstateen3,
          ])
            CsrInstanceConfig(
              arch: SimpleRwCsr(a.name, mxlen.size),
              addr: a.address,
              resetValue: 0,
              width: mxlen.size,
              isBackdoorWritable: false,
            ),
        for (final name in const [
          'hedeleg',
          'hideleg',
          'hie',
          'hcounteren',
          'hgeie',
          'htval',
          'hip',
          'hvip',
          'htinst',
          'henvcfg',
          'htimedelta',
          'hgatp',
          'vsie',
          'vstvec',
          'vsscratch',
          'vsip',
          'vsatp',
        ])
          CsrInstanceConfig(
            arch: SimpleRwCsr(name, mxlen.size),
            addr: CsrAddress.values.firstWhere((a) => a.name == name).address,
            resetValue: 0,
            width: mxlen.size,
            isBackdoorWritable: false,
          ),
        // VS trap save-state CSRs: hardware-written when a trap is delegated to
        // VS-mode (vsepc/vscause/vstval + vsstatus push), so backdoor-writable.
        for (final name in const ['vsstatus', 'vsepc', 'vscause', 'vstval'])
          CsrInstanceConfig(
            arch: SimpleRwCsr(name, mxlen.size),
            addr: CsrAddress.values.firstWhere((a) => a.name == name).address,
            resetValue: 0,
            width: mxlen.size,
            isBackdoorWritable: true,
          ),
        CsrInstanceConfig(
          arch: ReadOnlyNoFieldCsr('hgeip', mxlen.size),
          addr: CsrAddress.hgeip.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
      ],

      if (hasUser) ...[
        CsrInstanceConfig(
          arch: SimpleRwCsr('ustatus', mxlen.size),
          addr: CsrAddress.ustatus.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('uie', mxlen.size),
          addr: CsrAddress.uie.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('uip', mxlen.size),
          addr: CsrAddress.uip.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('utvec', mxlen.size),
          addr: CsrAddress.utvec.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('uscratch', mxlen.size),
          addr: CsrAddress.uscratch.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('uepc', mxlen.size),
          addr: CsrAddress.uepc.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('ucause', mxlen.size),
          addr: CsrAddress.ucause.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('utval', mxlen.size),
          addr: CsrAddress.utval.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
      ],

      CsrInstanceConfig(
        arch: CounterCsr('mcycle'),
        addr: CsrAddress.mcycle.address,
        width: mxlen.size,
        resetValue: 0,
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: CounterCsr('minstret'),
        addr: CsrAddress.minstret.address,
        width: mxlen.size,
        resetValue: 0,
        isBackdoorWritable: true,
      ),

      // NOTE: `time` (rdtime, 0xC01) is NOT registered as a CsrBlock CSR (that
      // perturbs rohd_hcl's backdoor indexing). Its read legality and data are
      // handled directly in _wireLegalityAndFrontdoor from the live CLINT mtime.

      // River custom cache control CSRs
      CsrInstanceConfig(
        arch: SimpleRwCsr('rcachectl', mxlen.size),
        addr: CsrAddress.rcachectl.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      // Pipeline / speculation control. WARL bits [3:0]
      // (SSBD/BPD/SERIALIZE/DTLBFC), masked in _maskWriteData. Read back through
      // the rpipelinectl output port.
      CsrInstanceConfig(
        arch: SimpleRwCsr('rpipelinectl', mxlen.size),
        addr: CsrAddress.rpipelinectl.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      // Read-only pipeline feature-discovery bitmap (writes trap, RO address).
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('rpipelinecap', mxlen.size),
        addr: CsrAddress.rpipelinecap.address,
        width: mxlen.size,
        resetValue: rpipelineCapValue,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('rcacheaddr', mxlen.size),
        addr: CsrAddress.rcacheaddr.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('rcachesize', mxlen.size),
        addr: CsrAddress.rcachesize.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      // Microcode update: addr/data are plain RW (their stored values feed the
      // core's ROM-patch staging); ctl is RW too but the core acts on the
      // csrWrite write-pulse for its address, not the stored bits (so the
      // strobes self-clear and never re-fire).
      CsrInstanceConfig(
        arch: SimpleRwCsr('rmicrocodeaddr', mxlen.size),
        addr: CsrAddress.rmicrocodeaddr.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('rmicrocodedata', mxlen.size),
        addr: CsrAddress.rmicrocodedata.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('rmicrocodectl', mxlen.size),
        addr: CsrAddress.rmicrocodectl.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
    ];

    final block = CsrBlockConfig(name: 'csr', baseAddr: 0, registers: regs);

    final top = CsrTopConfig(
      name: 'riscv_csr_top_cfg',
      blockOffsetWidth: 12,
      blocks: [block],
    );

    _sstatusMask = sstatusMask;
    _ustatusMask = ustatusMask;
    _sieSipMask = supervisorInterruptMask;
    _uieUipMask = userInterruptMask;

    return top;
  }

  // A full-width constant from a mask literal. The RV64 sstatus mask has bit 63
  // set, so as a Dart int it is negative; BigInt.toUnsigned keeps every bit.
  Const _maskConst(int mask) => Const(
    LogicValue.ofBigInt(BigInt.from(mask).toUnsigned(mxlen.size), mxlen.size),
  );

  // The stored mip register, without the PLIC line folded in. Every WRITE path
  // starts here; every READ path goes through [_mipWithSei].
  //
  // FLATTENED into a plain net on purpose. The backdoor rdData is a CsrTop
  // LogicStructure, and `withSet` on a structure does not behave like `withSet`
  // on a Logic: driving the mip backdoor from the structure silently stopped
  // MEIP/MTIP reaching the register, so no machine interrupt was ever taken.
  Logic? _mipRawCache;
  Logic get _mipRaw => _mipRawCache ??= (Logic(
    name: 'mipRawValue',
    width: mxlen.size,
  )..gets(_csrTop.getBackdoorPortsByAddr(0, CsrAddress.mip.address).rdData!));

  // The stored mstatus register, without the read-path overlay. Flattened into
  // a plain net for the same reason as [_mipRaw]: the backdoor rdData is a
  // CsrTop LogicStructure, and `withSet` on a structure does not behave like
  // `withSet` on a Logic.
  Logic? _mstatusRawCache;
  Logic get _mstatusRaw =>
      _mstatusRawCache ??= (Logic(name: 'mstatusRawValue', width: mxlen.size)
        ..gets(
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mstatus.address).rdData!,
        ));

  // The mstatus/sstatus READ overlay. It supplies two bits that no register
  // field holds:
  //
  //  * FS (bits 14:13) reads Dirty while [_fsDirty] is set. Linux saves the FP
  //    context on a context switch ONLY when FS reads Dirty, so without this
  //    the context is never saved and a task resumes with the FP registers of
  //    another task.
  //  * SD (bit XLEN-1) is the summary bit. It reads 1 when FS, VS or XS is
  //    Dirty. River has no XS, so the term is FS or VS.
  //
  // This is a READ path, like [_mipWithSei]. It must never write the register
  // back. mstatus has ONE hardware writer, the trap/xRET state machine in
  // [_wireTrapState], and that writer starts from the backdoor read, which is
  // one cycle behind. A second writer that echoed the stale value in a cycle
  // with no trap would undo the SIE/SPIE update of a preceding sret.
  Logic _statusRead(Logic raw) {
    if (!_hasFloat && !_hasVector) return raw;
    var v = raw;
    if (_fsDirty != null) {
      v = mux(_fsDirty!, v.withSet(13, Const(3, width: 2)), v);
    }
    final fsIsDirty = _hasFloat
        ? v.slice(14, 13).eq(Const(3, width: 2))
        : Const(0);
    final vsIsDirty = _hasVector
        ? v.slice(10, 9).eq(Const(3, width: 2))
        : Const(0);
    final out = Logic(name: 'mstatusReadValue', width: mxlen.size);
    out <= v.withSet(mxlen.size - 1, fsIsDirty | vsIsDirty);
    return out;
  }

  // The sticky FP-dirty flop. An FP register write sets it. A software write of
  // mstatus or sstatus loads it from the FS field the write puts in place, so
  // software clears it by writing FS=Clean, Initial or Off. sstatus writes come
  // through the same physical address, so both names agree by construction.
  void _wireFsDirty() {
    if (_fsDirty == null) return;
    final swWrite =
        _fdWrite.en &
        _fdWrite.addr.eq(Const(CsrAddress.mstatus.address, width: 12));
    // The masked write data is the value that lands in the register, so the
    // sstatus write mask is already applied to it.
    final swDirty = _fdWrite.data.slice(14, 13).eq(Const(3, width: 2));
    final hwDirty = (_fpDirtyIn ?? Const(0)) | (_fcsrDirty ?? Const(0));
    Sequential(clk, [
      If(
        swWrite,
        then: [_fsDirty! < (swDirty | hwDirty)],
        orElse: [
          If(hwDirty, then: [_fsDirty! < 1]),
        ],
      ),
    ], reset: reset);
  }

  // The stored mideleg register. Read from the backdoor rather than the output
  // port because the masks below are built before the port is driven.
  Logic get _midelegRaw =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mideleg.address).rdData!;

  // mip.SEIP (bit 9) reads as the OR of the PLIC supervisor-external line and
  // the software-writable bit, per the privileged spec. The result goes into a
  // plain net: the backdoor rdData is a CsrTop structure, and rohd_hcl refuses
  // to clone (rename) one, so `.named` on it throws.
  Logic _mipWithSei(Logic raw) {
    if (_seiPendingIn == null) return raw;
    final out = Logic(name: 'mipSeipOr', width: mxlen.size);
    out <= raw.withSet(9, raw[9] | _seiPendingIn!);
    return out;
  }

  // What sie/sip may show and change: the supervisor interrupt set (SSI/STI/SEI)
  // narrowed to the causes mideleg actually delegates. A cause that is not
  // delegated reads as zero and is not writable through the S alias, which is
  // what makes this model agree with the trap-target choice in exec.dart.
  Logic? _sIntMaskCache;
  Logic get _sInterruptMask =>
      _sIntMaskCache ??= (Logic(name: 'sIntCsrMask', width: mxlen.size)
        ..gets(_maskConst(_sieSipMask) & _midelegRaw));

  late final int _sstatusMask;
  late final int _ustatusMask;
  late final int _sieSipMask;
  late final int _uieUipMask;

  Logic _privOk(Logic addr12) {
    final privBits = addr12.getRange(8, 10);

    // CSR address bits[9:8] encode the lowest privilege: 00=user, 01=supervisor,
    // 10=hypervisor (accessible from HS-mode or M), 11=machine. Hypervisor (2)
    // maps to supervisor-level for the mode check; its existence is gated on
    // hasHypervisor via _addrExists.
    final req = mux(
      privBits.eq(Const(0, width: 2)),
      Const(PrivilegeMode.user.id, width: 3),
      mux(
        privBits.eq(Const(3, width: 2)),
        Const(PrivilegeMode.machine.id, width: 3),
        Const(PrivilegeMode.supervisor.id, width: 3), // 01 and 10
      ),
    );

    final isUser = req.eq(Const(PrivilegeMode.user.id, width: 3));
    final isSup = req.eq(Const(PrivilegeMode.supervisor.id, width: 3));
    final userOk = mux(isUser, Const(hasUser ? 1 : 0), Const(1));
    final supOk = mux(isSup, Const(hasSupervisor ? 1 : 0), Const(1));

    return mode.gte(req) & userOk & supOk;
  }

  // Smstateen access gating: deny a lower-level state-enable CSR
  // (sstateen*/hstateen*) from any mode below M when mstateen0.SE0 (MSB) is
  // clear, else allow. Only SE0 is implemented; the VS-mode virtual-instruction
  // distinction (hstateen0.SE0) is not modelled here.
  Logic _stateenOk(Logic addr12) {
    if (!hasStateen) return Const(1);
    Logic inRange(int lo, int hi) =>
        addr12.gte(Const(lo, width: 12)) & addr12.lte(Const(hi, width: 12));
    final isSstateen = inRange(0x10C, 0x10F);
    final isHstateen = hasHypervisor ? inRange(0x60C, 0x60F) : Const(0);
    final isGated = isSstateen | isHstateen;
    final belowM = ~mode.gte(
      Const(PrivilegeMode.machine.id, width: mode.width),
    );
    final mse0 = _csrTop
        .getBackdoorPortsByAddr(0, CsrAddress.mstateen0.address)
        .rdData![mxlen.size - 1];
    return ~(isGated & belowM & ~mse0);
  }

  Logic _addrExists(Logic addr12) {
    Logic hit = Const(0, width: 1);
    for (final a in _implementedAddrs) {
      hit |= addr12.eq(Const(a, width: addr12.width));
    }
    return hit;
  }

  Logic _isFrontdoorWritable(Logic addr12) {
    Logic hit = Const(0, width: 1);
    for (final a in _frontdoorWritableAddrs) {
      hit |= addr12.eq(Const(a, width: addr12.width));
    }
    return hit;
  }

  Logic _maskWriteData(Logic addr12, Logic data) {
    Logic out = data;
    if (!hasHypervisor) {
      final mpp = data.slice(12, 11);
      final legalMpp =
          mpp.eq(3) |
          (hasSupervisor ? mpp.eq(1) : Const(0)) |
          (hasUser ? mpp.eq(0) : Const(0));
      // WARL policy: reserved or unimplemented privileges become M, never an
      // unchecked privilege encoding at the data-port permission boundary.
      out = mux(
        addr12.eq(CsrAddress.mstatus.address),
        data.withSet(11, mux(legalMpp, mpp, Const(3, width: 2))),
        data,
      );
    }

    // *tvec BASE is the full XLEN address (bits [xlen-1:2]); only the 2-bit MODE
    // field [1:0] is WARL (River implements direct=0). A 0xFFFFFFFC literal here
    // truncated the base to 32 bits, so an RV64 high-virtual trap vector
    // (0xffffffff8000xxxx, e.g. Linux relocate_enable_mmu's stvec) read back as
    // its low 32 bits and the trampoline fault looped. Mask all base bits.
    final vecMask = Const(
      LogicValue.ofBigInt(
        (BigInt.one << mxlen.size) - BigInt.from(4),
        mxlen.size,
      ),
    );
    final fullMask = Const(~0, width: mxlen.size);

    // Merge the write into the register the address selects, keeping every bit
    // the mask leaves clear. [physAddr] names the register that actually holds
    // the state; it differs from [addr] only for an aliased CSR (sstatus, whose
    // state lives in mstatus).
    Logic applyMask(int addr, Logic mask, {int? physAddr}) {
      final hit = addr12.eq(Const(addr, width: addr12.width));
      final current = _csrTop
          .getBackdoorPortsByAddr(0, physAddr ?? addr)
          .rdData!;
      final masked = (current & ~mask) | (data & mask);
      out = mux(hit, masked, out);
      return out;
    }

    out = applyMask(CsrAddress.mtvec.address, vecMask);
    if (hasSupervisor) out = applyMask(CsrAddress.stvec.address, vecMask);
    if (hasUser) out = applyMask(CsrAddress.utvec.address, vecMask);

    if (hasSupervisor) {
      // Aliased supervisor writes land in the M register they view. Each mask
      // keeps the bits that alias does not expose exactly as they are, so
      // S-mode cannot reach MIE/MPIE/MPP through sstatus, cannot reach an
      // undelegated interrupt through sie/sip, and cannot clear the PLIC's
      // SEIP line through sip.
      for (final e in _supervisorAliases.entries) {
        out = applyMask(e.key, _aliasWriteMask(e.key), physAddr: e.value);
      }
      out = applyMask(CsrAddress.satp.address, fullMask);
      // TM is writable only when time is backed by a live source. Without
      // one, rdtime must trap for firmware emulation.
      out = applyMask(
        CsrAddress.scounteren.address,
        Const(_timeIn == null ? 0x5 : 0x7, width: mxlen.size),
      );
      // senvcfg/menvcfg: River implements none of the envcfg-controlled features
      // (Zicbo, pointer-masking, Sstc, Svpbmt), so all fields are WARL-0. Mask 0
      // drops every write and the register reads back its reset value (0). This
      // is the correct "feature absent" report and, crucially, makes Linux's
      // try_to_set_pmm read PMM back as 0 and disable pointer masking instead of
      // assuming a masking feature River does not actually provide.
      out = applyMask(CsrAddress.senvcfg.address, Const(0, width: mxlen.size));
      out = applyMask(CsrAddress.menvcfg.address, Const(0, width: mxlen.size));
    }

    if (hasUser) {
      // Same counter set as scounteren, including TM only with a live source.
      out = applyMask(
        CsrAddress.mcounteren.address,
        Const(_timeIn == null ? 0x5 : 0x7, width: mxlen.size),
      );
      out = applyMask(
        CsrAddress.ustatus.address,
        Const(_ustatusMask, width: mxlen.size),
      );
      out = applyMask(
        CsrAddress.uie.address,
        Const(_uieUipMask, width: mxlen.size),
      );
      out = applyMask(
        CsrAddress.uip.address,
        Const(_uieUipMask, width: mxlen.size),
      );
    }

    if (hasStateen) {
      // Only SE0 (bit 63) is writable on *stateen0; everything else is WARL-0
      // (gates features River does not implement).
      final se0Mask = (Const(1, width: mxlen.size) << (mxlen.size - 1)).named(
        'stateenSe0Mask',
      );
      final zeroMask = Const(0, width: mxlen.size);
      out = applyMask(CsrAddress.mstateen0.address, se0Mask);
      out = applyMask(CsrAddress.mstateen1.address, zeroMask);
      out = applyMask(CsrAddress.mstateen2.address, zeroMask);
      out = applyMask(CsrAddress.mstateen3.address, zeroMask);
      if (hasSupervisor) {
        out = applyMask(CsrAddress.sstateen0.address, zeroMask);
        out = applyMask(CsrAddress.sstateen1.address, zeroMask);
        out = applyMask(CsrAddress.sstateen2.address, zeroMask);
        out = applyMask(CsrAddress.sstateen3.address, zeroMask);
      }
      if (hasHypervisor) {
        out = applyMask(CsrAddress.hstateen0.address, se0Mask);
        out = applyMask(CsrAddress.hstateen1.address, zeroMask);
        out = applyMask(CsrAddress.hstateen2.address, zeroMask);
        out = applyMask(CsrAddress.hstateen3.address, zeroMask);
      }
    }

    // rpipelinectl: only the low 4 control bits are writable (WARL).
    out = applyMask(
      CsrAddress.rpipelinectl.address,
      Const(0xF, width: mxlen.size),
    );

    return out;
  }

  // With V=0, machine counter enables apply below M-mode; supervisor enables
  // further restrict U-mode when S-mode exists. Address privilege alone cannot
  // enforce this because the counter aliases have U-level addresses.
  Logic _counterReadOk(Logic addr) {
    if (!hasUser) return Const(1);
    final mc = _csrTop
        .getBackdoorPortsByAddr(0, CsrAddress.mcounteren.address)
        .rdData!;
    final sc = hasSupervisor
        ? _csrTop
              .getBackdoorPortsByAddr(0, CsrAddress.scounteren.address)
              .rdData!
        : null;
    Logic allowed = Const(1);
    for (var bit = 0; bit < 3; bit++) {
      final hit =
          addr.eq(0xc00 + bit) |
          (mxlen == RiscVMxlen.rv32 ? addr.eq(0xc80 + bit) : Const(0));
      final enabled =
          mode.eq(PrivilegeMode.machine.id) |
          (mc[bit] &
              (mode.neq(PrivilegeMode.user.id) |
                  (sc == null ? Const(1) : sc[bit])));
      allowed &= ~hit | enabled;
    }
    // This port changes non-virtual M/S/U only. Preserve virtual-mode behavior
    // until hcounteren and cause-22 selection are implemented together; the
    // executor still rejects VU CSR accesses before they reach this port.
    return allowed | (_virtInput ?? Const(0));
  }

  void _wireLegalityAndFrontdoor() {
    final rdAddr12 = Logic(width: 12, name: 'csrReadAddr12');
    final wrAddr12 = Logic(width: 12, name: 'csrWriteAddr12');

    // VS-mode CSR redirect: when virt=1, a supervisor-CSR access (addr[9:8]==01,
    // 0x1xx) is redirected to the VS shadow CSR (0x2xx) by adding 0x100
    // (sstatus->vsstatus, satp->vsatp, …).
    Logic vsRedirect(Logic a, String tag) {
      if (_virtInput == null) return a;
      final isSup = a.slice(9, 8).eq(Const(1, width: 2)).named('csrIsSup_$tag');
      return mux(
        _virtInput! & isSup,
        a + Const(0x100, width: 12),
        a,
      ).named('csrVsRed_$tag');
    }

    rdAddr12 <= vsRedirect(csrRead.addr.slice(11, 0), 'rd');
    wrAddr12 <= vsRedirect(csrWrite.addr.slice(11, 0), 'wr');

    // Supervisor CSR aliases: sstatus/sie/sip hold no state of their own, so the
    // CsrTop port sees the mstatus/mie/mip address. The legality checks below
    // keep the ARCHITECTURAL address, because 0x100/0x104/0x144 are S-level CSRs
    // and their targets are M-level. The vsRedirect above already sent a VS-mode
    // access to the vs* shadow (0x200/0x204/0x244), which IS a register, so it
    // never reaches these aliases.
    final aliases = hasSupervisor ? _supervisorAliases : const <int, int>{};
    Logic aliasHit(Logic a, int archAddr, String tag) => a
        .eq(Const(archAddr, width: 12))
        .named('csrIsAlias${archAddr.toRadixString(16)}_$tag');
    Logic aliasAddr(Logic a, String tag) {
      if (aliases.isEmpty) return a;
      var out = a;
      for (final e in aliases.entries) {
        out = mux(aliasHit(a, e.key, tag), Const(e.value, width: 12), out);
      }
      return out.named('csrPhysAddr_$tag');
    }

    // `time` (0xC01) is served from the live CLINT mtime, not the CsrBlock, so
    // it is legal to read (at any privilege, U-level CSR) whenever mtime is
    // wired. Its data is muxed in below.
    final isTimeRd = (_timeIn == null)
        ? Const(0)
        : rdAddr12
              .eq(Const(CsrAddress.time.address, width: 12))
              .named('csrIsTime');
    final rdFp = hasFcsr ? rdAddr12.gte(1) & rdAddr12.lte(3) : Const(0);
    final wrFp = hasFcsr ? wrAddr12.gte(1) & wrAddr12.lte(3) : Const(0);
    final fpEnabled = _statusRead(_mstatusRaw).slice(14, 13).neq(0);
    final rdLegal =
        (~rdFp | fpEnabled) &
        (_addrExists(rdAddr12) | isTimeRd) &
        _privOk(rdAddr12) &
        _counterReadOk(rdAddr12) &
        _stateenOk(rdAddr12);
    // _isFrontdoorWritable is a strict subset of _addrExists (same register
    // list, readWrite regs only), so it implies _addrExists. Dropping the
    // redundant existence term removes the _addrExists OR-tree from
    // write-legality (area diet). Read-legality still uses _addrExists.
    final wrLegal =
        (~wrFp | fpEnabled) &
        _privOk(wrAddr12) &
        _stateenOk(wrAddr12) &
        _isFrontdoorWritable(wrAddr12);

    _fdRead.addr <= aliasAddr(rdAddr12, 'rd');
    _fdRead.en <= csrRead.en & rdLegal & ~rdFp;
    // An aliased S read gets the whole M register back, so narrow it to what
    // that S CSR is allowed to show. A plain `csrr mip` also has to show the
    // PLIC SEIP line, which the register itself does not hold.
    var rdData = _mipWithSei(_fdRead.data);
    rdData = mux(
      rdAddr12.eq(Const(CsrAddress.mip.address, width: 12)).named('csrIsMipRd'),
      rdData,
      _fdRead.data,
    );
    // `csrr mstatus` shows the derived FS and SD bits. The sstatus alias picks
    // them up in _aliasReadData, below the alias loop that follows.
    rdData = mux(
      rdAddr12
          .eq(Const(CsrAddress.mstatus.address, width: 12))
          .named('csrIsMstatusRd'),
      _statusRead(_fdRead.data),
      rdData,
    );
    for (final e in aliases.entries) {
      rdData = mux(
        aliasHit(rdAddr12, e.key, 'rdMask'),
        _aliasReadData(e.key, _fdRead.data),
        rdData,
      );
    }
    if (hasFcsr) {
      rdData = mux(
        rdFp,
        mux(
          rdAddr12.eq(1),
          _fcsr!.slice(4, 0).zeroExtend(mxlen.size),
          mux(
            rdAddr12.eq(2),
            _fcsr!.slice(7, 5).zeroExtend(mxlen.size),
            _fcsr!.zeroExtend(mxlen.size),
          ),
        ),
        rdData,
      );
      final softwareWrite = csrWrite.en & wrLegal & wrFp;
      final softwareData = mux(
        wrAddr12.eq(1),
        [_fcsr!.slice(7, 5), csrWrite.data.slice(4, 0)].swizzle(),
        mux(
          wrAddr12.eq(2),
          [csrWrite.data.slice(2, 0), _fcsr!.slice(4, 0)].swizzle(),
          csrWrite.data.slice(7, 0),
        ),
      );
      // Software writes replace the addressed field; hardware flags accrue.
      // A serialized CSR write takes precedence over a coincident flag update.
      Sequential(clk, [
        If(
          reset,
          then: [_fcsr! < 0],
          orElse: [
            If(
              softwareWrite,
              then: [_fcsr! < softwareData],
              orElse: [
                If(
                  _fpFlagsValid!,
                  then: [_fcsr! < (_fcsr! | _fpFlags!.zeroExtend(8))],
                ),
              ],
            ),
          ],
        ),
      ]);
      _fcsrDirty! <= softwareWrite | (_fpFlagsValid! & _fpFlags!.or());
    }
    // `time` (rdtime) returns the live CLINT mtime, not a stored register, so the
    // OS clocksource tracks the same counter its timer events compare against.
    if (_timeIn != null) {
      csrRead.data <= mux(isTimeRd, _timeIn!.getRange(0, mxlen.size), rdData);
    } else {
      csrRead.data <= rdData;
    }
    csrRead.done <= csrRead.en;
    csrRead.valid <= csrRead.en & rdLegal;

    _fdWrite.addr <= aliasAddr(wrAddr12, 'wr');

    final maskedWriteData = _maskWriteData(wrAddr12, csrWrite.data);
    _fdWrite.data <= maskedWriteData;

    _fdWrite.en <= csrWrite.en & wrLegal & ~wrFp;
    csrWrite.done <= csrWrite.en;
    csrWrite.valid <= csrWrite.en & wrLegal;
  }

  void _bindBackdoorForCounters() {
    _mcycleBd = _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mcycle.address);
    _minstretBd = _csrTop.getBackdoorPortsByAddr(
      0,
      CsrAddress.minstret.address,
    );

    if (_mcycleBd!.hasWrite) {
      _mcycleBd!.wrEn!.put(0);
      _mcycleBd!.wrData!.put(0);
    }
    if (_minstretBd!.hasWrite) {
      _minstretBd!.wrEn!.put(0);
      _minstretBd!.wrData!.put(0);
    }
  }

  /// mcycle and minstret.
  ///
  /// Each counter is driven from a LOCAL accumulator flop, never from its own
  /// backdoor read.
  ///
  /// The old code did `wrData < rdData + 1` inside a Sequential, so wrEn and
  /// wrData were flop outputs. rohd_hcl samples them one clock later, and by
  /// then rdData had not moved yet, so the SAME value was sent twice and the
  /// register advanced once every TWO cycles. Measured on silicon: mcycle read
  /// 10.000 MHz on a 20 MHz bus clock, exactly half.
  ///
  /// The backdoor is now driven combinationally from the accumulator, so the
  /// register and the accumulator hold the same value in every cycle.
  ///
  /// minstret counts RETIRED instructions, not cycles. It advances only when
  /// [_retireIn] is high. A multi-cycle microcoded instruction gives one pulse,
  /// so it counts once. The old code used the same per-cycle expression as
  /// mcycle, which made IPC read exactly 1.000000 on silicon.
  ///
  /// Both counters stay read/write to software. A frontdoor write has priority
  /// inside rohd_hcl, and the backdoor write is disabled in that cycle as well,
  /// so the software value lands and the accumulator loads it. Counting then
  /// continues from the written value.
  void _wireCounters() {
    final xlen = mxlen.size;

    Logic swWriteTo(int addr) =>
        _fdWrite.en & _fdWrite.addr.eq(Const(addr, width: 12));

    void wireOne(CsrBackdoorInterface? bd, int addr, Logic step, String label) {
      if (bd == null || !bd.hasWrite) return;
      final swWrite = swWriteTo(addr).named('${label}SwWrite');
      final acc = Logic(name: '${label}Acc', width: xlen);
      final next = (acc + step).named('${label}Next');
      Sequential(clk, [
        If(swWrite, then: [acc < _fdWrite.data], orElse: [acc < next]),
      ], reset: reset);
      bd.wrEn! <= ~swWrite;
      bd.wrData! <= next;
    }

    wireOne(
      _mcycleBd,
      CsrAddress.mcycle.address,
      Const(1, width: xlen),
      'mcycle',
    );
    wireOne(
      _minstretBd,
      CsrAddress.minstret.address,
      (_retireIn ?? Const(0)).zeroExtend(xlen),
      'minstret',
    );
  }

  /// Hardware trap save-state and xRET restore, driven by core.dart's
  /// retire-cycle controls. On a synchronous trap: {m,s}epc←pc, {m,s}cause←cause,
  /// {m,s}tval←tval, and the status privilege stack is pushed (xPP←currentMode,
  /// xPIE←xIE, xIE←0). On xRET: xIE←xPIE, xPIE←1, xPP←U. All backdoor wrEn lines
  /// are driven every cycle (0 when idle). PC/mode restore itself is in
  /// core.dart; this method only manages the CSR contents.
  void _wireTrapState() {
    if (_trapActive == null) {
      // Optional trap controls must leave the hardware write ports idle, not
      // floating: FS legality also reads mstatus in standalone CSR instances.
      for (final address in [
        CsrAddress.mstatus,
        CsrAddress.mepc,
        CsrAddress.mcause,
        CsrAddress.mtval,
        if (hasSupervisor) ...[
          CsrAddress.sepc,
          CsrAddress.scause,
          CsrAddress.stval,
        ],
        if (hasHypervisor) ...[
          CsrAddress.hstatus,
          CsrAddress.vsstatus,
          CsrAddress.vsepc,
          CsrAddress.vscause,
          CsrAddress.vstval,
        ],
      ]) {
        final port = getBackdoor(LogicValue.ofInt(address.address, 12));
        port.wrEn! <= Const(0);
        port.wrData! <= Const(0, width: mxlen.size);
      }
      return;
    }

    final trapToM = _trapActive! & _trapTargetIsM!;
    final retFromM = _returnActive! & _returnFromM!;

    CsrBackdoorInterface bd(int addr) =>
        getBackdoor(LogicValue.ofInt(addr, 12));

    final mstatusBd = bd(CsrAddress.mstatus.address);
    final mepcBd = bd(CsrAddress.mepc.address);
    final mcauseBd = bd(CsrAddress.mcause.address);
    final mtvalBd = bd(CsrAddress.mtval.address);

    final mcur = mstatusBd.rdData!;
    // mstatus bits: MIE=3, MPIE=7, MPP=[12:11].
    final mTrap = mcur
        .withSet(3, Const(0, width: 1)) // MIE <- 0
        .withSet(7, mcur[3]) // MPIE <- old MIE
        .withSet(11, mode.slice(1, 0)); // MPP <- current mode
    final mRet = mcur
        .withSet(3, mcur[7]) // MIE <- MPIE
        .withSet(7, Const(1, width: 1)) // MPIE <- 1
        .withSet(11, Const(!hasHypervisor && !hasUser ? 3 : 0, width: 2))
        // Use the OLD MPP: MRET to M preserves MPRV even as MPP is reset.
        .withSet(17, mux(mcur.slice(12, 11).eq(3), mcur[17], Const(0)));

    mepcBd.wrEn! <= trapToM;
    mepcBd.wrData! <= _trapPc!;
    mcauseBd.wrEn! <= trapToM;
    mcauseBd.wrData! <= _trapCauseVal!;
    mtvalBd.wrEn! <= trapToM;
    mtvalBd.wrData! <= _trapTval!;

    // mstatus.FS is NOT written here. A hardware write of mstatus in a cycle
    // with no trap and no xRET would echo `mcur`, the backdoor read, which is
    // one cycle behind. That echo would undo the SIE/SPIE update of a preceding
    // sret. FS is supplied on the READ path instead; see [_statusRead].
    if (!hasSupervisor) {
      final anyEvent = trapToM | retFromM;
      mstatusBd.wrEn! <= anyEvent;
      mstatusBd.wrData! <= mux(trapToM, mTrap, mRet);
    } else {
      // A trap delegated to VS-mode (vsTrap) saves to the vs* CSRs below, not the
      // HS s* CSRs, so exclude it from trapToS.
      final vsTrap = _trapToVS ?? Const(0);
      final trapToS = _trapActive! & ~_trapTargetIsM! & ~vsTrap;
      final retFromS = _returnActive! & ~_returnFromM!;

      final sepcBd = bd(CsrAddress.sepc.address);
      final scauseBd = bd(CsrAddress.scause.address);
      final stvalBd = bd(CsrAddress.stval.address);

      // The S status stack lives in mstatus, because sstatus is only a view of
      // it. mstatus bits: SIE=1, SPIE=5, SPP=8.
      final sTrap = mcur
          .withSet(1, Const(0, width: 1)) // SIE <- 0
          .withSet(5, mcur[1]) // SPIE <- old SIE
          .withSet(8, mode[0]); // SPP <- current mode (S=1/U=0)
      final sRet = mcur
          .withSet(1, mcur[5]) // SIE <- SPIE
          .withSet(5, Const(1, width: 1)) // SPIE <- 1
          .withSet(8, Const(0, width: 1)) // SPP <- U
          .withSet(17, Const(0)); // Every successful SRET returns below M.

      // One writer for the one register. A trap and an xRET never retire in the
      // same cycle, so the priority order here only breaks a tie that cannot
      // happen.
      final anyEvent = trapToM | retFromM | trapToS | retFromS;
      mstatusBd.wrEn! <= anyEvent;
      mstatusBd.wrData! <=
          mux(trapToM, mTrap, mux(retFromM, mRet, mux(trapToS, sTrap, sRet)));

      sepcBd.wrEn! <= trapToS;
      sepcBd.wrData! <= _trapPc!;
      scauseBd.wrEn! <= trapToS;
      scauseBd.wrData! <= _trapCauseVal!;
      stvalBd.wrEn! <= trapToS;
      stvalBd.wrData! <= _trapTval!;

      if (hasHypervisor) {
        // An SRET from HS-mode (the guest-entry case) clears hstatus.SPV (bit 7)
        // after the V-bit has captured it. Other bits preserved.
        final hstatusBd = bd(CsrAddress.hstatus.address);
        hstatusBd.wrEn! <= retFromS;
        hstatusBd.wrData! <= hstatusBd.rdData!.withSet(7, Const(0, width: 1));

        // Trap delegated to VS-mode: save VS state (vsepc/vscause/vstval) and
        // push the VS status stack (vsstatus: SPP<-mode, SPIE<-SIE, SIE<-0).
        final vsstatusBd = bd(CsrAddress.vsstatus.address);
        final vsepcBd = bd(CsrAddress.vsepc.address);
        final vscauseBd = bd(CsrAddress.vscause.address);
        final vstvalBd = bd(CsrAddress.vstval.address);
        final vcur = vsstatusBd.rdData!;
        vsstatusBd.wrEn! <= vsTrap;
        vsstatusBd.wrData! <=
            vcur
                .withSet(1, Const(0, width: 1)) // SIE <- 0
                .withSet(5, vcur[1]) // SPIE <- old SIE
                .withSet(8, mode[0]); // SPP <- current mode
        vsepcBd.wrEn! <= vsTrap;
        vsepcBd.wrData! <= _trapPc!;
        vscauseBd.wrEn! <= vsTrap;
        vscauseBd.wrData! <= _trapCauseVal!;
        vstvalBd.wrEn! <= vsTrap;
        vstvalBd.wrData! <= _trapTval!;
      }
    }
  }

  void setData(LogicValue address, LogicValue data) {
    assert(address.width == 12);

    _csrTop
        .getBackdoorPortsByAddr(0, _physAddr(address.toInt()))
        .wrEn!
        .inject(1);
    _csrTop
        .getBackdoorPortsByAddr(0, _physAddr(address.toInt()))
        .wrData!
        .inject(data);
  }

  LogicValue? getData(LogicValue address) {
    assert(address.width == 12);
    return _csrTop
        .getBackdoorPortsByAddr(0, _physAddr(address.toInt()))
        .rdData
        ?.value;
  }

  CsrBackdoorInterface getBackdoor(LogicValue address) {
    assert(address.width == 12);

    return _csrTop.getBackdoorPortsByAddr(0, _physAddr(address.toInt()));
  }

  // The supervisor CSR aliases: each S address and the M register that actually
  // holds its state. None of the three has a register of its own.
  Map<int, int> get _supervisorAliases => {
    CsrAddress.sstatus.address: CsrAddress.mstatus.address,
    CsrAddress.sie.address: CsrAddress.mie.address,
    CsrAddress.sip.address: CsrAddress.mip.address,
  };

  // The register that holds the state an architectural CSR address names. The
  // backdoor sees the WHOLE M register, not the S-visible subset.
  int _physAddr(int addr) =>
      (hasSupervisor && _supervisorAliases.containsKey(addr))
      ? _supervisorAliases[addr]!
      : addr;

  // What a read of an aliased S CSR returns, given the raw M register value.
  Logic _aliasReadData(int archAddr, Logic raw) {
    if (archAddr == CsrAddress.sstatus.address) {
      // sstatus is a view of mstatus, so it must show the same derived FS and
      // SD bits. The mask keeps both (bits 14:13 and bit XLEN-1).
      return _statusRead(raw) & _maskConst(_sstatusMask);
    }
    if (archAddr == CsrAddress.sie.address) return raw & _sInterruptMask;
    // sip: the PLIC line joins mip.SEIP before the supervisor mask.
    return _mipWithSei(raw) & _sInterruptMask;
  }

  // What a write through an aliased S CSR may change in the M register.
  Logic _aliasWriteMask(int archAddr) {
    if (archAddr == CsrAddress.sstatus.address) {
      return _maskConst(_sstatusMask);
    }
    if (archAddr == CsrAddress.sie.address) return _sInterruptMask;
    // sip.SEIP is READ-ONLY to supervisor: the PLIC owns that line, and the
    // software bit behind it belongs to M-mode. Everything else the supervisor
    // set delegates stays writable (Weir writes STIP for the SBI timer).
    return _sInterruptMask & ~_maskConst(1 << 9);
  }

  Logic get mvendorid =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mvendorid.address).rdData!;
  Logic get marchid =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.marchid.address).rdData!;
  Logic get mimpid =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mimpid.address).rdData!;
  Logic get mhartid =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mhartid.address).rdData!;
  Logic get misa =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.misa.address).rdData!;

  Logic get mstatus => output('mstatus');
  Logic get mie => output('mie');
  Logic get mip => output('mip');
  Logic get mtvec => output('mtvec');
  Logic get mscratch =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mscratch.address).rdData!;
  Logic get mepc => output('mepc');
  Logic get mcause =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mcause.address).rdData!;
  Logic get mtval =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mtval.address).rdData!;
  Logic get medeleg => output('medeleg');
  Logic get mideleg => output('mideleg');

  Logic? get stvec => hasSupervisor ? output('stvec') : null;
  Logic? get sstatus => hasSupervisor ? output('sstatus') : null;
  Logic? get sie => hasSupervisor ? output('sie') : null;
  Logic? get sip => hasSupervisor ? output('sip') : null;
  Logic? get hstatus => hasHypervisor ? output('hstatus') : null;
  Logic? get hedeleg => hasHypervisor ? output('hedeleg') : null;
  Logic? get vstvec => hasHypervisor ? output('vstvec') : null;
  Logic? get mstateen0Se0 => hasStateen ? output('mstateen0_se0') : null;
  Logic? get hstateen0Se0 =>
      (hasStateen && hasHypervisor) ? output('hstateen0_se0') : null;
  Logic get sepc => output('sepc');
  Logic get scause =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.scause.address).rdData!;
  Logic get stval =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.stval.address).rdData!;
  Logic? get satp => hasSupervisor ? output('satp') : null;

  Logic get rcachectl =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.rcachectl.address).rdData!;
  Logic get rcacheaddr =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.rcacheaddr.address).rdData!;
  Logic get rcachesize =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.rcachesize.address).rdData!;
  Logic get rpipelinectl => output('rpipelinectl');
  Logic get rmicrocodeaddr => output('rmicrocodeaddr');
  Logic get rmicrocodedata => output('rmicrocodedata');
}
