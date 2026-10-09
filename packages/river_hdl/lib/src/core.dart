import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'data_port.dart';

import 'core/csr.dart';
import 'core/mmu.dart';
import 'core/misaligned_load.dart';
import 'core/pipeline.dart';
import 'inferred_rom.dart';

import 'compat.dart' show kMicroOpTable;
import 'microcode_rom.dart';

class RiverCore extends BridgeModule {
  final RiverCoreConfig config;

  late final HarborRegisterFile regs;
  late final DataPortInterface regWritePort;
  late final RiverPipeline pipeline;

  RiverCore(
    this.config, {
    Map<String, Logic> srcIrqs = const {},
    // Supervisor external interrupt-pending line from the interrupt controller,
    // the S-mode counterpart of [srcIrqs]. Drives mip.SEIP(9); null ties the bit
    // to 0. The SoC wires this from the PLIC context that belongs to this hart's
    // S-mode (see genip). Kept a separate port from [srcIrqs] because an S-mode
    // OS claims from its OWN context window, so the two lines are independent.
    Logic? supervisorExternalPending,
    // Machine timer / software interrupt-pending lines from the CLINT. Drive
    // mip.MTIP(7) and mip.MSIP(3) respectively; null ties the bit to 0. The SoC
    // wires these from the CLINT's timer_irq/sw_irq outputs (see genip).
    Logic? timerPending,
    Logic? swPending,
    Logic? timeIn,
    List<String> staticInstructions = const [],
    WishboneConfig? busConfig,
    HarborDeviceTarget? target,
    bool withDebug = false,
    // Number of hardware execute-breakpoint triggers (RISC-V mcontrol, type 2)
    // exposed to the Debug Module. 0 = no triggers (byte-identical to before).
    // Each trigger is tselect/tdata1/tdata2 and fires a cause-2 debug entry when
    // an enabled execute trigger's tdata2 matches the instruction PC.
    int debugTriggers = 0,
    // Expose plain bustap_ack/bustap_datmiso outputs mirroring the Wishbone
    // master's incoming ACK/read data for a logic analyzer. ACK is an input
    // here, so it must be mirrored to a plain output to stay hierarchy-legal.
    // Off in production.
    bool busTap = false,
    // Sticky user-mode excursion probe. Off by default and BYTE IDENTICAL when
    // off: nothing below elaborates. When on, seven sticky bits appear in the
    // reserved field of the dcsr READ path (they are not stored in dcsr, so a
    // debugger write cannot clobber them) and answer, over JTAG, whether this
    // core ever entered user mode and what put it there. See the probe block
    // below for the bit map.
    bool userProbe = false,
    // Test-only backdoor: when high, an architectural regWritePort write also
    // seeds the OoO physical regfile. Asserted only while frozen during seeding;
    // null leaves it tied off.
    Logic? prfSeedMode,
    // Test-only backdoor: the privilege the core holds coming out of reset.
    // Real RISC-V resets to machine; a unit test that exercises S/U behavior
    // (e.g. paged data translation) can pre-position the core in that mode
    // instead of running a boot-time mret. null keeps the machine-mode reset.
    int? resetPrivilege,
    super.name = 'river_core',
  }) : super('RiverCore') {
    final wbConfig =
        busConfig ??
        WishboneConfig(
          addressWidth: config.mxlen.size,
          dataWidth: config.mxlen.size,
          selWidth: config.mxlen.size ~/ 8,
        );

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    final clk = input('clk');
    final reset = input('reset');

    final microcode = MicrocodeRom(config.isa, encodings: kMicroOpTable);

    final pipelineEnable = Logic(name: 'pipelineEnable');
    final pc = Logic(name: 'pc', width: config.mxlen.size);
    final sp = Logic(name: 'sp', width: config.mxlen.size);
    final mode = Logic(name: 'mode', width: 3);
    // Virtualization (V) mode bit, only meaningful with H. Pushed to
    // {m,s}status.{MPV,SPV} and restored on MRET/SRET.
    final virt = config.hasHypervisor ? Logic(name: 'virt') : null;
    // Per-access "treat as guest" = virt | (HLV/HSV in flight). Drives the MMU's
    // VS/G-stage routing. Forward-declared; driven after the pipeline.
    final guestAccessWire = config.hasHypervisor
        ? Logic(name: 'guestAccess')
        : null;
    final interruptHold = Logic(name: 'interruptHold');
    final fence = Logic(name: 'fence');

    // Optional external debug (RISC-V Debug Module) halt/resume. Freezes the
    // core at an instruction boundary and latches its PC into dpc.
    Logic? debugHalted;
    Logic? debugDpc;
    // Debug control/status register (dcsr, CSR 0x7b0). Must be a real
    // readable/writable register (OpenOCD reads cause/priv and writes
    // ebreak/step bits during resume) or resume wedges.
    Logic? debugDcsr;
    // High when a committing ebreak should enter Debug Mode (dcsr.ebreak* set for
    // the current privilege) instead of taking a breakpoint trap.
    Logic? ebreakDebug;
    // Single-step in flight: set on resume when dcsr.step is high, cleared when
    // the one stepped instruction commits (which re-enters Debug Mode, cause 4).
    Logic? stepping;
    Logic? haltReqIn;
    Logic? resumeReqIn;
    // Abstract-command register access (driven by the Debug Module while halted).
    Logic? dbgGprRead; // read a GPR onto the regfile read port
    Logic? dbgGprWrite; // write a GPR through the regfile write port
    Logic? dbgGprIdx; // 5-bit GPR index
    Logic? dbgIsDpc; // regno == dpc (0x7b1)
    Logic? dbgIsDcsr; // regno == dcsr (0x7b0)
    Logic? dbgIsMisa; // regno == misa (0x301)
    Logic? dbgRegWdata;
    Logic? dbgIsGpr; // regno is a GPR (bit 12 set)
    Logic? dbgRegAddr12; // low 12 bits of the regno = the CSR address
    Logic? dbgCsrSel; // halted && the regno is a CSR (borrow the CSR read port)
    Logic? dbgCsrData; // CSR file read result for a debug CSR access
    // Hardware execute triggers (mcontrol, type 2). Present only when
    // debugTriggers > 0. tdata1[i]/tdata2[i] are the per-trigger config/match;
    // triggerMatch fires when an enabled execute trigger matches the current PC.
    final hasTriggers = withDebug && debugTriggers > 0;
    final tselectW = hasTriggers
        ? (debugTriggers <= 1 ? 1 : (debugTriggers - 1).bitLength)
        : 1;
    Logic? tselect;
    final List<Logic> tdata1 = [];
    final List<Logic> tdata2 = [];
    Logic? triggerMatch; // execute trigger matched the committing PC this cycle
    Logic? dbgTselWrite; // debugger writing tselect
    Logic? dbgTdata1Write; // debugger writing tdata1 (selected trigger)
    Logic? dbgTdata2Write; // debugger writing tdata2 (selected trigger)
    Logic? dbgTrigRdata; // read value for tselect/tdata1/tdata2/tinfo
    Logic? dbgIsTrigCsr; // regno is one of the trigger CSRs (0x7a0..0x7a4)
    // Sticky user-mode entry witnesses (userProbe only). Declared here and
    // driven from their own sequential block at the end of the constructor, so
    // the dcsr read path below can fold them in.
    Logic? probeUserFromMret; // an MRET restored MPP = user
    Logic? probeUserFromSret; // an SRET restored SPP = user
    Logic? probeUserFromTrap; // a trap targeted user mode
    if (withDebug) {
      createPort('debug_halt_req', PortDirection.input);
      createPort('debug_resume_req', PortDirection.input);
      createPort('debug_reg_read', PortDirection.input);
      createPort('debug_reg_write', PortDirection.input);
      createPort('debug_reg_addr', PortDirection.input, width: 16);
      createPort(
        'debug_reg_wdata',
        PortDirection.input,
        width: config.mxlen.size,
      );
      addOutput('debug_halted');
      addOutput('debug_dpc', width: config.mxlen.size);
      addOutput('debug_reg_rdata', width: config.mxlen.size);
      addOutput('debug_reg_ready');
      haltReqIn = input('debug_halt_req');
      resumeReqIn = input('debug_resume_req');
      debugHalted = Logic(name: 'debugHalted');
      debugDpc = Logic(name: 'debugDpc', width: config.mxlen.size);
      debugDcsr = Logic(name: 'debugDcsr', width: 32);
      if (userProbe) {
        probeUserFromMret = Logic(name: 'probeUserFromMret');
        probeUserFromSret = Logic(name: 'probeUserFromSret');
        probeUserFromTrap = Logic(name: 'probeUserFromTrap');
      }
      ebreakDebug = Logic(name: 'ebreakDebug');
      stepping = Logic(name: 'stepping');
      output('debug_halted') <= debugHalted;
      output('debug_dpc') <= debugDpc;

      final regAddr = input('debug_reg_addr');
      // GPR regnos are 0x1000..0x101f (bit 12 set); CSRs are < 0x1000.
      final isGpr = regAddr[12];
      dbgGprIdx = regAddr.getRange(0, 5);
      dbgIsDpc = regAddr.eq(0x7b1);
      dbgIsDcsr = regAddr.eq(0x7b0);
      // misa is a read-only constant (the configured ISA). Serve it directly so
      // a debugger can probe extensions over JTAG; else the abstract CSR read
      // falls through to the GPR port and reads 0.
      dbgIsMisa = regAddr.eq(0x301);
      dbgRegWdata = input('debug_reg_wdata');
      dbgGprRead = input('debug_reg_read') & isGpr;
      dbgGprWrite = input('debug_reg_write') & isGpr & debugHalted;
      // CSR abstract reads: while halted the pipeline is frozen, so the Debug
      // Module borrows the CSR read port. The regno IS the CSR address (regnos
      // < 0x1000), so present regAddr[11:0] and route the result back. Only the
      // read port is borrowed; CSR writes over abstract command are unimplemented.
      dbgIsGpr = isGpr;
      dbgRegAddr12 = regAddr.getRange(0, 12);
      if (config.hasCsrs) {
        dbgCsrSel = ~isGpr & debugHalted;
        dbgCsrData = Logic(name: 'dbgCsrData', width: config.mxlen.size);
      }
      // debug_reg_ready is driven below, once `regs` exists: it must honor the
      // regfile read latency (a registered BRAM read is 1+ cycles behind the
      // address), otherwise the Debug Module latches stale read data.

      // Hardware execute triggers (RISC-V trigger module, mcontrol type 2).
      // OpenOCD programs tdata1/tdata2 over the abstract command while halted;
      // an enabled execute trigger whose tdata2 matches the committing PC fires
      // a cause-2 debug entry BEFORE the matched instruction runs (dpc = pc).
      if (hasTriggers) {
        tselect = Logic(name: 'tselect', width: tselectW);
        for (var i = 0; i < debugTriggers; i++) {
          tdata1.add(Logic(name: 'tdata1_$i', width: 32));
          tdata2.add(Logic(name: 'tdata2_$i', width: config.mxlen.size));
        }
        final isTsel = dbgRegAddr12.eq(0x7a0);
        final isTd1 = dbgRegAddr12.eq(0x7a1);
        final isTd2 = dbgRegAddr12.eq(0x7a2);
        final isTinfo = dbgRegAddr12.eq(0x7a4);
        dbgIsTrigCsr = isTsel | isTd1 | isTd2 | isTinfo;
        final wr = input('debug_reg_write') & debugHalted;
        dbgTselWrite = wr & isTsel;
        dbgTdata1Write = wr & isTd1;
        dbgTdata2Write = wr & isTd2;
        // Read multiplexers over the selected trigger. tselect out of range
        // reads 0 so a debugger can count triggers (0..debugTriggers-1). Widen
        // tselect before the compare: debugTriggers may not fit in tselectW bits
        // (e.g. 4 needs 3 bits but tselectW is 2), which would truncate the bound
        // and force the reads to 0 (breaks OpenOCD trigger discovery).
        final selInRange = tselect.zeroExtend(32).lt(debugTriggers);
        Logic selTdata1 = Const(0, width: 32);
        Logic selTdata2 = Const(0, width: config.mxlen.size);
        for (var i = 0; i < debugTriggers; i++) {
          selTdata1 = mux(tselect.eq(i), tdata1[i], selTdata1);
          selTdata2 = mux(tselect.eq(i), tdata2[i], selTdata2);
        }
        selTdata1 = mux(selInRange, selTdata1, Const(0, width: 32));
        selTdata2 = mux(
          selInRange,
          selTdata2,
          Const(0, width: config.mxlen.size),
        );
        // tinfo: bit N set for supported trigger type N. Only mcontrol (2).
        dbgTrigRdata = mux(
          isTsel,
          tselect.zeroExtend(config.mxlen.size),
          mux(
            isTd1,
            selTdata1.zeroExtend(config.mxlen.size),
            mux(
              isTd2,
              selTdata2,
              Const(1 << 2, width: config.mxlen.size), // tinfo
            ),
          ),
        );
        // Combinational execute-match against the committing PC.
        Logic m = Const(0);
        for (var i = 0; i < debugTriggers; i++) {
          final t1 = tdata1[i];
          final typeOk = t1.getRange(28, 32).eq(2);
          final execute = t1[2];
          final actionDebug = t1.getRange(12, 16).eq(1);
          final modeEn =
              (t1[6] & mode.eq(PrivilegeMode.machine.id)) |
              (t1[4] & mode.eq(PrivilegeMode.supervisor.id)) |
              (t1[3] & mode.eq(PrivilegeMode.user.id));
          m = m | (typeOk & execute & actionDebug & modeEn & tdata2[i].eq(pc));
        }
        triggerMatch = m.named('triggerMatch');
      }
    }

    final pagingMode = Logic(
      name: 'pagingMode',
      width: config.mmu.pagingModes
          .map((m) => m.id)
          .fold(0, (a, b) => a > b ? a : b)
          .bitLength
          .clamp(1, 64),
    );

    final pageTableAddress = Logic(
      name: 'pageTableAddress',
      width: config.mxlen.size,
    );

    // satp.MODE (4 bits) and root PPN, forward-declared to feed the MMU (built
    // before the CSR file). Assigned from the CSR file's satp once it exists.
    final satpModeWire = Logic(name: 'satpModeWire', width: 4);
    final satpRootWire = Logic(name: 'satpRootWire', width: config.mxlen.size);

    // Hypervisor G-stage (hgatp) mode/root for two-stage translation, fed to the
    // MMU when the config has H. Driven from an hgatp shadow register below.
    final gModeWire = config.hasHypervisor
        ? Logic(name: 'gModeWire', width: 4)
        : null;
    final gRootWire = config.hasHypervisor
        ? Logic(name: 'gRootWire', width: config.mxlen.size)
        : null;

    final enableMxr = Logic(name: 'enableMxr');
    final enableSum = Logic(name: 'enableSum');
    final effectiveDataPriv = Logic(name: 'effectiveDataPriv', width: 3);
    // DTLBFC (rpipelinectl[3]): drives the MMU's flush-data-TLB-on-priv-change.
    // Forward-declared here, driven from the CSR file below (mirrors enableMxr).
    final dtlbFlushOnPriv = Logic(name: 'dtlbFlushOnPriv');

    // Pipeline uses DataPortInterfaces internally; bridge them to the MMU ports.

    final dualDispatch = config.issueWidth == IssueWidth.dual;

    // Fetch read: pipeline drives en/addr, MMU responds with data/done/valid
    final pipeFetchRead = DataPortInterface(
      config.mxlen.size,
      config.mxlen.size,
    );
    // Dual-dispatch: a second fetch port (lane 1). Both lanes arbitrate onto the
    // MMU's single ifetch port below (lane 0 priority), serialising on the shared
    // bus, but each lane keeps its own request/response interface so the
    // front-end can present a 2-instruction bundle to rename.
    final pipeFetchRead1 = dualDispatch
        ? DataPortInterface(config.mxlen.size, config.mxlen.size)
        : null;
    // Exec read: same pattern
    final pipeExecRead = DataPortInterface(
      config.mxlen.size,
      config.mxlen.size,
    );
    final l1 = config.l1cache;
    // Keep unsupported execution/translation profiles on the legacy path.
    // Scalar Sv39 checks translation and permission before physical cache hits.
    final physicalCaches =
        l1 != null &&
        !dualDispatch &&
        l1.d.lineSize <= 4096 &&
        (l1.i == null || l1.i!.lineSize <= 4096) &&
        config.mmu.hasPaging &&
        !config.hasHypervisor &&
        !config.speculativeFetch &&
        config.executionMode == ExecutionMode.inOrder &&
        config.mmu.pmp.entries == 0 &&
        !config.mmu.hasPageBasedMemoryTypes &&
        config.mmu.pagingModes.every(
          (m) =>
              m == RiscVPagingMode.bare ||
              (config.mxlen == RiscVMxlen.rv64 && m == RiscVPagingMode.sv39),
        ) &&
        wbConfig.dataWidth == config.mxlen.size &&
        wbConfig.addressWidth == config.mxlen.size &&
        wbConfig.effectiveSelWidth == config.mxlen.size ~/ 8;

    // Cached misaligned loads remain disabled, including on the physical path.
    // Do not advertise this path with unimplemented PMP/PBMT or H/OoO contexts.
    // A platform opts in by describing safe, full-beat-readable RAM in its PMAs.
    final enableMisalignedLoads =
        config.l1cache == null &&
        !config.hasHypervisor &&
        config.executionMode != ExecutionMode.outOfOrder &&
        config.mmu.pmp.entries == 0 &&
        !config.mmu.hasPageBasedMemoryTypes &&
        config.mmu.pagingModes.every(
          (m) =>
              m == RiscVPagingMode.bare ||
              (config.mxlen == RiscVMxlen.rv64 && m == RiscVPagingMode.sv39),
        ) &&
        wbConfig.dataWidth == config.mxlen.size &&
        wbConfig.addressWidth == config.mxlen.size &&
        wbConfig.effectiveSelWidth == config.mxlen.size ~/ 8 &&
        config.mmu.pma.regions.any(
          (r) =>
              r.memoryType == HarborPmaMemoryType.memory &&
              r.readable &&
              r.idempotent &&
              r.misalignedSupport &&
              r.accessWidths.contains(config.mxlen.size ~/ 8),
        );
    final loadMisaligned = Logic(name: 'loadMisaligned');
    final loadSize = Logic(name: 'loadSize', width: 3);
    final loadPageFault = Logic(name: 'loadPageFault');
    final mmuExecRead = enableMisalignedLoads
        ? DataPortInterface(config.mxlen.size, config.mxlen.size)
        : pipeExecRead;
    final loadUnit = enableMisalignedLoads
        ? MisalignedLoad(
            clk,
            reset,
            pipeExecRead.en,
            pipeExecRead.addr,
            loadSize,
            loadMisaligned,
            mmuExecRead.done,
            mmuExecRead.valid,
            mmuExecRead.data,
            loadPageFault,
          )
        : null;
    if (loadUnit != null) {
      mmuExecRead.en <= loadUnit.readEnable;
      mmuExecRead.addr <= loadUnit.readAddress;
      pipeExecRead.done <= loadUnit.done;
      pipeExecRead.valid <= loadUnit.valid;
      pipeExecRead.data <= loadUnit.data;
    }

    // Exec write: pipeline drives en/addr/data (with sized prefix), MMU responds done/valid
    final pipeExecWrite = DataPortInterface(
      config.mxlen.size + 7,
      config.mxlen.size,
    );

    // Bridge fetch → MMU ifetch
    // Bridge exec read/write → single dport
    final execWriteActive = pipeExecWrite.en;

    // swizzle layout: {size[6:0], value[xlen-1:0]} MSB-first
    // So value is bits [xlen-1:0] and size is bits [xlen+6:xlen]
    final writeValue = pipeExecWrite.data.getRange(0, config.mxlen.size);
    final writeSizePrefix = pipeExecWrite.data.getRange(
      config.mxlen.size,
      config.mxlen.size + 7,
    );
    final writeLog2Size = mux(
      writeSizePrefix[0],
      Const(0, width: 3),
      mux(
        writeSizePrefix[1],
        Const(1, width: 3),
        mux(
          writeSizePrefix[2],
          Const(2, width: 3),
          mux(writeSizePrefix[3], Const(3, width: 3), Const(2, width: 3)),
        ),
      ),
    );

    final dportEn = mux(execWriteActive, Const(1), mmuExecRead.en);
    final dportAddr = mux(
      execWriteActive,
      pipeExecWrite.addr,
      mmuExecRead.addr,
    );
    final dportWe = execWriteActive;
    final dportWdata = mux(
      execWriteActive,
      writeValue.zeroExtend(config.mxlen.size),
      Const(0, width: config.mxlen.size),
    );
    final dportSize = mux(
      execWriteActive,
      writeLog2Size,
      loadUnit == null
          ? (physicalCaches ? loadSize : Const(2, width: 3))
          : mux(
              loadUnit.restricted,
              Const((config.mxlen.size ~/ 8).bitLength - 1, width: 3),
              Const(2, width: 3),
            ),
    );

    // Wishbone responses from the external bus
    final wbAckExt = Logic(name: 'wbAckExt');
    final wbErrExt = Logic(name: 'wbErrExt');
    // OoO still needs fault addresses carried through the ROB and precise
    // store-queue retirement. Preserve its existing ERR behavior for now.
    final handleAccessFaults = config.executionMode == ExecutionMode.inOrder;
    final wbDatMisoExt = Logic(name: 'wbDatMisoExt', width: wbConfig.dataWidth);

    // Fetch arbiter (dual-dispatch): multiplex the two fetch lanes onto the
    // MMU's single ifetch port. Round-robin so both lanes make progress (a
    // FetchUnit keeps its request asserted while holding a delivered instruction,
    // so fixed priority would starve the other lane). A grant is held until the
    // in-flight fetch completes; the next grant prefers the lane not served last.
    final fetchActive = Logic(name: 'fetchActive');
    final fetchGrantP1 = Logic(name: 'fetchGrantP1');
    final lastGrantP1 = Logic(name: 'lastGrantP1');
    final bothReq = dualDispatch
        ? (pipeFetchRead.en & pipeFetchRead1!.en)
        : Const(0);
    final onlyP1 = dualDispatch
        ? (~pipeFetchRead.en & pipeFetchRead1!.en)
        : Const(0);
    final newGrantP1 = mux(bothReq, ~lastGrantP1, onlyP1);
    final grantP1Now = dualDispatch
        ? mux(fetchActive, fetchGrantP1, newGrantP1)
        : Const(0);
    final ifetchEnArb = dualDispatch
        ? mux(grantP1Now, pipeFetchRead1!.en, pipeFetchRead.en)
        : pipeFetchRead.en;
    final ifetchAddrArb = dualDispatch
        ? mux(grantP1Now, pipeFetchRead1!.addr, pipeFetchRead.addr)
        : pipeFetchRead.addr;

    // Legacy L1 wiring (for profiles not using physical caches below).
    // Optional L1 instruction cache between the fetch unit(s) and the MMU ifetch
    // port. Hits in one cycle; misses fill a line from the MMU (its miss port
    // drives the MMU ifetch instead of the arbiter). Dual-dispatch serves both
    // lanes the same cycle on a shared-line hit.
    // On creek (DDR behind the FPGA PHY) the L1 is a correctness lever: each miss
    // fills one paced word at a time, so the PHY only sees single reads it
    // captures correctly, never a back-to-back burst. The D-cache extends the
    // same pacing to data loads.
    final useICache = l1?.i != null && !physicalCaches;
    final useDCache = l1 != null && !physicalCaches;

    // Permission context for legacy L1 tags. Those caches are in FRONT of the MMU,
    // so a HIT never reaches the MMU and no permission check runs on it. Without
    // this tag a line filled by one privilege mode stayed usable by a mode the
    // page table forbids: user code read a supervisor-only page out of the
    // D-cache and executed a supervisor-only page out of the I-cache, and a
    // supervisor load with sstatus.SUM clear read a user page. The privilege
    // change itself flushes nothing here (the MMU DTLBFC does not reach the L1).
    //
    // Tagging each line with its context makes the offending access MISS, so it
    // goes to the MMU and faults. It costs one flop per line per context bit and
    // does not flush the cache on every trap, which whole-cache invalidation on
    // a privilege change would.
    //
    // Fetch uses actual privilege; data uses effective privilege and, for
    // non-H cores, SUM/MXR. Two privilege bits separate U (0), S (1) and M (3),
    // including translated S/U addresses from physical M addresses. Without
    // CSRs the permission controls are tied low.
    final privContext =
        (useICache || useDCache) && (config.hasSupervisor || config.hasUser);
    Logic? iCtx;
    Logic? dCtx;
    if (privContext) {
      final privTag = mode.slice(1, 0);
      iCtx = virt == null ? privTag : [virt, privTag].swizzle();
      // A data hit bypasses the MMU. A change to MPRV/MPP, SUM or MXR must
      // therefore miss under the old authorization, without a software fence.
      // H keeps its existing context until guest permission selection is wired.
      dCtx = [
        if (guestAccessWire != null) guestAccessWire,
        if (!config.hasHypervisor) ...[enableSum, enableMxr],
        effectiveDataPriv.slice(1, 0),
      ].swizzle();
    }

    // Significant low address bits BOTH L1 caches must tag on.
    //
    // The caches sit in FRONT of the MMU, so they are virtually indexed and
    // virtually tagged: with paging on they are shown a VIRTUAL address and only
    // a miss is translated. The tag must span the widest VIRTUAL address the
    // core can present, not the physical map. This used to be a flat 32, which
    // is the physical map width, so VA[63:32] was never compared and under Sv39
    // the linear map, vmalloc and kernel text aliased onto each other.
    //
    // 39 for Sv39 (VA[63:39] is a sign extension of VA[38], so VA[38:0] carries
    // every bit that distinguishes one canonical address from another). The
    // floor of 32 covers M-mode and satp=Bare, where the request is a physical
    // address on a <=4 GB map.
    final l1AddrBits = config.mmu.pagingModes
        .map((m) => m.virtualBits)
        .fold<int>(32, (a, b) => b > a ? b : a);

    final icMemDone = Logic(name: 'icMemDone');
    final icMemValid = Logic(name: 'icMemValid');
    final icMemFault = Logic(name: 'icMemFault');
    final icMemRdata = Logic(name: 'icMemRdata', width: config.mxlen.size);
    final icFlush = Logic(name: 'icFlush');
    // Driven from pipeline.fence below (forward ref); flushes the MMU fetch TLB.
    final mmuTlbFlush = Logic(name: 'mmuTlbFlush');

    HarborL1ICache? icache;
    if (useICache) {
      icache = HarborL1ICache(
        config: l1!.i!,
        xlen: config.mxlen.size,
        dualPort: dualDispatch,
        ctxBits: iCtx?.width ?? 0,
        reqAddrBits: l1AddrBits,
        // Maps the per-line data to a block RAM (DP16KD / RAMB36E1).
        target: target,
      );
      addSubModule(icache);
      icache.input('clk').srcConnection! <= clk;
      icache.input('reset').srcConnection! <= reset;
      icache.input('req_addr').srcConnection! <= pipeFetchRead.addr;
      icache.input('req_valid').srcConnection! <= pipeFetchRead.en;
      if (iCtx != null) icache.input('req_ctx').srcConnection! <= iCtx;
      icache.input('flush').srcConnection! <= icFlush;
      icache.input('mem_done').srcConnection! <= icMemDone;
      icache.input('mem_valid').srcConnection! <= icMemValid;
      icache.input('mem_fault').srcConnection! <= icMemFault;
      icache.input('mem_rdata').srcConnection! <= icMemRdata;
      if (dualDispatch) {
        icache.input('req_addr1').srcConnection! <= pipeFetchRead1!.addr;
        icache.input('req_valid1').srcConnection! <= pipeFetchRead1.en;
      }
    }
    final ifetchEnFinal = useICache ? icache!.memEn : ifetchEnArb;
    final ifetchAddrFinal = useICache ? icache!.memAddr : ifetchAddrArb;

    // L1 data cache. Instantiated before the MMU because it drives the MMU dport
    // (load fills and write-through stores); the response feeds back through the
    // dc* wires. Write-through, no-write-allocate: stores go straight to DRAM
    // and invalidate any resident line, so no dirty-eviction burst is launched
    // into the marginal PHY.
    final dcMemDone = Logic(name: 'dcMemDone');
    final dcMemValid = Logic(name: 'dcMemValid');
    final dcMemFault = Logic(name: 'dcMemFault');
    final dcMemRdata = Logic(name: 'dcMemRdata', width: config.mxlen.size);
    final dFlush = Logic(name: 'dFlush');
    HarborL1DCache? dcache;
    if (useDCache) {
      dcache = HarborL1DCache(
        config: l1.d,
        xlen: config.mxlen.size,
        ctxBits: dCtx?.width ?? 0,
        reqAddrBits: l1AddrBits,
        memFaultIn: dcMemFault,
        target: target,
      );
      addSubModule(dcache);
      dcache.input('clk').srcConnection! <= clk;
      dcache.input('reset').srcConnection! <= reset;
      dcache.input('req_addr').srcConnection! <= dportAddr;
      dcache.input('req_valid').srcConnection! <= dportEn;
      if (dCtx != null) dcache.input('req_ctx').srcConnection! <= dCtx;
      dcache.input('req_write').srcConnection! <= dportWe;
      dcache.input('req_data').srcConnection! <= writeValue;
      dcache.input('req_size').srcConnection! <= dportSize;
      dcache.input('flush').srcConnection! <= dFlush;
      dcache.input('mem_done').srcConnection! <= dcMemDone;
      dcache.input('mem_valid').srcConnection! <= dcMemValid;
      dcache.input('mem_rdata').srcConnection! <= dcMemRdata;
    }
    // Data-port request to the MMU: from the D-cache when present, else direct.
    final dportEnFinal = useDCache ? dcache!.memEn : dportEn;
    final dportAddrFinal = useDCache ? dcache!.memAddr : dportAddr;
    final dportWeFinal = useDCache ? dcache!.memWe : dportWe;
    final dportWdataFinal = useDCache ? dcache!.memWdata : dportWdata;
    final dportSizeFinal = useDCache ? dcache!.memSize : dportSize;

    // MMU.
    final mmu = RiverMmu(
      clk,
      reset,
      ifetchEnFinal,
      ifetchAddrFinal,
      dportEnFinal,
      dportAddrFinal,
      dportWeFinal,
      dportWdataFinal,
      dportSizeFinal,
      wbAckExt,
      wbDatMisoExt,
      mmuConfig: config.mmu,
      busConfig: wbConfig,
      restrictedRead: loadUnit?.restricted,
      wbErr: wbErrExt,
      satpMode: config.mmu.hasPaging ? satpModeWire : null,
      satpRoot: config.mmu.hasPaging ? satpRootWire : null,
      virtIn: config.hasHypervisor ? guestAccessWire : null,
      gMode: config.hasHypervisor ? gModeWire : null,
      gRoot: config.hasHypervisor ? gRootWire : null,
      privMode: config.mmu.hasPaging ? mode : null,
      dataPrivMode: config.mmu.hasPaging ? effectiveDataPriv : null,
      sum: config.mmu.hasPaging ? enableSum : null,
      mxr: config.mmu.hasPaging ? enableMxr : null,
      // Translate instruction fetches (below M-mode). The icache is VIRTUALLY
      // addressed, so its refill request carries a virtual address that the MMU
      // MUST translate; gating this off left the refill reading the untranslated
      // virtual address, which fetches garbage under any non-identity map (e.g.
      // Linux's swapper mapping virtual 0xffffffff8000xxxx -> physical
      // 0x8aaxxxxx). Fetch page-fault (ifetch_fault) reporting through the icache
      // is still a gap, but a valid mapping (the common case) now translates.
      translateFetch: config.mmu.hasPaging,
      tlbFlush: config.mmu.hasPaging ? mmuTlbFlush : null,
      dtlbFlushOnPrivChange: config.mmu.hasPaging ? dtlbFlushOnPriv : null,
      physicalL1: physicalCaches ? l1 : null,
      cacheTarget: target,
      cacheFlush: physicalCaches ? icFlush : null,
      userProbe: userProbe,
    );

    if (useICache) {
      // The icache owns the MMU ifetch port (its miss fills); fetch responses
      // come from the cache. flush on fence.i (driven from the pipeline below).
      icMemDone <= mmu.ifetchDone;
      icMemValid <= mmu.ifetchValid;
      icMemFault <= mmu.ifetchFault;
      icMemRdata <= mmu.ifetchRdata;
      // A faulting fetch is delivered as done AND not valid with respFault set, so
      // the FetchUnit raises an instruction page fault (see ifetchFault below).
      pipeFetchRead.done <= icache!.respValid | icache.respFault;
      pipeFetchRead.valid <= icache.respValid;
      pipeFetchRead.data <= icache.respData;
      if (dualDispatch) {
        pipeFetchRead1!.done <= icache.respValid1;
        pipeFetchRead1.valid <= icache.respValid1;
        pipeFetchRead1.data <= icache.respData1;
      }
    } else if (dualDispatch) {
      // Route the ifetch response to whichever lane currently holds the grant.
      pipeFetchRead.done <= mmu.ifetchDone & ~grantP1Now;
      pipeFetchRead.valid <= mmu.ifetchValid & ~grantP1Now;
      pipeFetchRead.data <= mmu.ifetchRdata;
      pipeFetchRead1!.done <= mmu.ifetchDone & grantP1Now;
      pipeFetchRead1.valid <= mmu.ifetchValid & grantP1Now;
      pipeFetchRead1.data <= mmu.ifetchRdata;
      Sequential(clk, [
        If(
          reset,
          then: [fetchActive < 0, fetchGrantP1 < 0, lastGrantP1 < 0],
          orElse: [
            If(
              ~fetchActive,
              then: [
                If(
                  pipeFetchRead.en | pipeFetchRead1.en,
                  then: [
                    fetchActive < 1,
                    fetchGrantP1 < newGrantP1,
                    lastGrantP1 < newGrantP1,
                  ],
                ),
              ],
              orElse: [
                If(mmu.ifetchDone, then: [fetchActive < 0]),
              ],
            ),
          ],
        ),
      ]);
    } else {
      pipeFetchRead.done <= mmu.ifetchDone;
      pipeFetchRead.valid <= mmu.ifetchValid;
      pipeFetchRead.data <= mmu.ifetchRdata;
    }

    if (useDCache) {
      // MMU dport response feeds the D-cache; the D-cache serves the pipeline
      // (a hit in one cycle, a miss after its paced fill, a store once memory
      // acknowledges the write-through).
      dcMemDone <= mmu.dportDone;
      dcMemValid <= mmu.dportValid;
      dcMemFault <= mmu.dportFault;
      dcMemRdata <= mmu.dportRdata;
      // A faulting access is delivered as done AND NOT valid, the same contract
      // the no-D-cache path below uses. Response metadata selects a page or
      // access fault. Previously, done and valid were BOTH driven from respValid,
      // making `done & ~valid` structurally impossible: the core could not report
      // a data page fault at all while the D-cache was in the path, and the
      // cache's fill/bypass FSM hung on the faulting access anyway. A NULL
      // pointer dereference froze the machine instead of trapping.
      pipeExecRead.done <=
          (dcache!.respValid | dcache.respFault) & ~execWriteActive;
      pipeExecRead.valid <= dcache.respValid & ~execWriteActive;
      pipeExecRead.data <= dcache.respData;
      pipeExecWrite.done <=
          (dcache.respValid | dcache.respFault) & execWriteActive;
      pipeExecWrite.valid <= dcache.respValid & execWriteActive;
    } else {
      mmuExecRead.done <= mmu.dportDone & ~execWriteActive;
      mmuExecRead.valid <= mmu.dportValid & ~execWriteActive;
      mmuExecRead.data <= mmu.dportRdata;

      pipeExecWrite.done <= mmu.dportDone & execWriteActive;
      pipeExecWrite.valid <= mmu.dportValid & execWriteActive;
    }

    // Expose Wishbone bus master as a proper interface
    final dataBusRef = addInterface(
      WishboneInterface(wbConfig),
      name: 'dataBus',
      role: PairRole.provider,
    );
    final wb = dataBusRef.internalInterface as WishboneInterface;

    wb.cyc <= mmu.wbCyc;
    wb.stb <= mmu.wbStb;
    wb.we <= mmu.wbWe;
    wb.adr <= mmu.wbAdr;
    wb.datMosi <= mmu.wbDatMosi;
    wb.sel <= mmu.wbSel;
    wbAckExt <= wb.ack;
    wbErrExt <= (handleAccessFaults ? (wb.err ?? Const(0)) : Const(0));
    wbDatMisoExt <= wb.datMiso;

    // Logic-analyzer bus taps: mirror the consumer-direction signals (ACK, read
    // data) to plain outputs for GPIO routing. These inputs cannot be read in
    // the parent without violating module hierarchy, so the core exposes them.
    if (busTap) {
      addOutput('bustap_ack') <= wb.ack;
      addOutput('bustap_datmiso', width: wbConfig.dataWidth) <= wb.datMiso;
      // Master-side control so a stuck transaction is visible: a hung load shows
      // cyc=stb=1, we=0, ack=0 held forever, with adr at the wedged address.
      addOutput('bustap_cyc') <= mmu.wbCyc;
      addOutput('bustap_stb') <= mmu.wbStb;
      addOutput('bustap_we') <= mmu.wbWe;
      addOutput('bustap_adr', width: wbConfig.addressWidth) <= mmu.wbAdr;
    }

    // Register file. Dual-commit (config.commitLanes > 1) adds a second write
    // port. Single-write-port storage can't take two writes/cycle, so the file
    // is split into one bank per write port; same-bank collisions are arbitrated
    // and back-pressured via the wr*_ready outputs.
    final numWritePorts = config.commitLanes;
    final dualCommit = numWritePorts > 1;
    String wrPort(int w, String s) =>
        numWritePorts == 1 ? 'wr_$s' : 'wr${w}_$s';

    final rs1Read = DataPortInterface(config.mxlen.size, 5);
    final rs2Read = DataPortInterface(config.mxlen.size, 5);
    final rdWrite = DataPortInterface(config.mxlen.size, 5);
    regWritePort = rdWrite;
    final rdWrite1 = dualCommit
        ? DataPortInterface(config.mxlen.size, 5)
        : null;

    regs = HarborRegisterFile(
      numEntries: 32,
      dataWidth: config.mxlen.size,
      // Dual-dispatch (4 read ports) is a follow-on; commit drives writes.
      numReadPorts: 2,
      numWritePorts: numWritePorts,
      numBanks: numWritePorts,
      writeBufferDepth: config.writeBufferDepth,
      target: target,
      forceReadLatency: config.regfileReadLatency,
      name: 'riscv_regfile',
    );
    addSubModule(regs);
    regs.input('clk').srcConnection! <= clk;
    regs.input('reset').srcConnection! <= reset;
    // While halted, the Debug Module borrows read/write port 0 to service
    // abstract register-access commands (the pipeline is frozen).
    regs.input('rd0_addr').srcConnection! <=
        (withDebug ? mux(dbgGprRead!, dbgGprIdx!, rs1Read.addr) : rs1Read.addr);
    regs.input('rd1_addr').srcConnection! <= rs2Read.addr;
    regs.input(wrPort(0, 'en')).srcConnection! <=
        (withDebug ? mux(dbgGprWrite!, Const(1), rdWrite.en) : rdWrite.en);
    regs.input(wrPort(0, 'addr')).srcConnection! <=
        (withDebug
            ? mux(dbgGprWrite!, dbgGprIdx!, rdWrite.addr)
            : rdWrite.addr);
    regs.input(wrPort(0, 'data')).srcConnection! <=
        (withDebug
            ? mux(dbgGprWrite!, dbgRegWdata!, rdWrite.data)
            : rdWrite.data);
    Logic? wr0Ready;
    Logic? wr1Ready;
    if (dualCommit) {
      regs.input(wrPort(1, 'en')).srcConnection! <= rdWrite1!.en;
      regs.input(wrPort(1, 'addr')).srcConnection! <= rdWrite1.addr;
      regs.input(wrPort(1, 'data')).srcConnection! <= rdWrite1.data;
      wr0Ready = regs.writeReady(0);
      wr1Ready = regs.writeReady(1);
      rdWrite1.done <= rdWrite1.en;
      rdWrite1.valid <= rdWrite1.en;
    }
    // Preserve the rohd_hcl semantics: read data is zero when the port is
    // disabled (and x0 reads zero, handled inside HarborRegisterFile).
    rs1Read.data <=
        mux(rs1Read.en, regs.rd0Data, Const(0, width: config.mxlen.size));
    // Abstract-command read result: dcsr, dpc, misa, a general CSR (borrowed
    // read port), or the GPR on read port 0. dcsr/dpc/misa are special-cased so
    // they serve even when the CSR file does not implement them as readable CSRs.
    if (withDebug) {
      // For a GPR access read port 0; for a non-special CSR read the borrowed
      // CSR port (dbgCsrData, null when the core has no CSR file).
      final gprOrCsr = dbgCsrData == null
          ? regs.rd0Data
          : mux(dbgIsGpr!, regs.rd0Data, dbgCsrData);
      // User-mode excursion probe, reported in dcsr's reserved field [26:20].
      // It is folded into the READ path only, never stored in debugDcsr, so a
      // debugger write to dcsr cannot clobber it and the existing write mask
      // (0x0FFFFE3F) needs no change. Bit map:
      //   [23:20] MMU probe: everUser, userWalk, latchMismatch, userFault
      //   [24]    an MRET restored MPP = user
      //   [25]    an SRET restored SPP = user
      //   [26]    a trap targeted user mode
      final dcsrRead = !userProbe
          ? debugDcsr!
          : (debugDcsr! |
                    (config.mmu.hasPaging
                        ? (mmu.probe.zeroExtend(32) << 20)
                        : Const(0, width: 32)) |
                    (probeUserFromMret!.zeroExtend(32) << 24) |
                    (probeUserFromSret!.zeroExtend(32) << 25) |
                    (probeUserFromTrap!.zeroExtend(32) << 26))
                .named('dcsrRead');
      final nonTrig = mux(
        dbgIsDcsr!,
        dcsrRead.zeroExtend(config.mxlen.size),
        mux(
          dbgIsMisa!,
          Const(config.isa.misaValue, width: config.mxlen.size),
          mux(dbgIsDpc!, debugDpc!, gprOrCsr),
        ),
      );
      // Trigger CSRs (tselect/tdata1/tdata2/tinfo) win when addressed.
      output('debug_reg_rdata') <=
          (hasTriggers ? mux(dbgIsTrigCsr!, dbgTrigRdata!, nonTrig) : nonTrig);
    }
    rs2Read.data <=
        mux(rs2Read.en, regs.rd1Data, Const(0, width: config.mxlen.size));
    // Read data is [regs.readLatency] cycles behind the address (0 for the
    // combinational/iCE40 negedge-EBR read, 1 for the ECP5 posedge-EBR read).
    // Delay done/valid by the same latency so the operand-read handshake latches
    // the data on the cycle it is valid. Writes are single-cycle, unaffected.
    Logic delayReadHandshake(Logic en, String name) {
      var s = en;
      for (var i = 0; i < regs.readLatency; i++) {
        final q = Logic(name: '${name}_q$i');
        Sequential(clk, [q < s]);
        s = q;
      }
      return s;
    }

    rs1Read.done <= delayReadHandshake(rs1Read.en, 'rs1RdDone');
    rs1Read.valid <= delayReadHandshake(rs1Read.en, 'rs1RdValid');
    rs2Read.done <= delayReadHandshake(rs2Read.en, 'rs2RdDone');
    rs2Read.valid <= delayReadHandshake(rs2Read.en, 'rs2RdValid');
    rdWrite.done <= rdWrite.en;
    rdWrite.valid <= rdWrite.en;

    // Floating-point register file (F/D). It lives here beside the integer file
    // so it sees the same device target and can use a BRAM backend instead of a
    // flop array. A 32x64 two-read-port flop file costs about 2048 flops plus
    // two 64-bit 32-to-1 read multiplexers, which is large and slow to place.
    // The exec unit gets the ports. A core with no FP operation gets neither.
    final hasFloat = microcode.execLookup.values.any(
      (op) => op.resources.any(
        (r) => r is RfResource && r.regfile is RiscVFloatRegFile,
      ),
    );
    DataPortInterface? fpRs1Port;
    DataPortInterface? fpRs2Port;
    DataPortInterface? fpRdPort;
    if (hasFloat) {
      final fp1 = DataPortInterface(64, 5);
      final fp2 = DataPortInterface(64, 5);
      final fpw = DataPortInterface(64, 5);
      final fpRegs = HarborRegisterFile(
        numEntries: 32,
        dataWidth: 64,
        // RISC-V has no hardwired-zero float register: f0/ft0 is a normal
        // storage entry, unlike integer x0.
        reservedZero: false,
        target: target,
        // The SAME knob the integer file gets. Without it the FP file always
        // built at latency 0 in simulation, while the shipping target gives it
        // latency 1 from the device default, so the hardware read latency of
        // the FP file was never exercised in a test.
        forceReadLatency: config.regfileReadLatency,
        name: 'fp_regfile',
      );
      // No addSubModule here. ROHD resolves the owning module by tracing
      // connectivity, and every FP port connects into the pipeline, so an
      // explicit core parent contradicts the resolved one. Hierarchy placement
      // does not change the synthesised result, and the file is still built
      // with the device target, which is the point of moving it here.
      fpRegs.input('clk').srcConnection! <= clk;
      fpRegs.input('reset').srcConnection! <= reset;
      fpRegs.input('rd0_addr').srcConnection! <= fp1.addr;
      fpRegs.input('rd1_addr').srcConnection! <= fp2.addr;
      fpRegs.input('wr_en').srcConnection! <= fpw.en;
      fpRegs.input('wr_addr').srcConnection! <= fpw.addr;
      fpRegs.input('wr_data').srcConnection! <= fpw.data;
      fp1.data <= fpRegs.rd0Data;
      fp2.data <= fpRegs.rd1Data;
      // Read data is [fpRegs.readLatency] cycles behind the address, the same
      // as the integer file, so delay the handshake by the same amount.
      Logic delayFpRead(Logic en, String name) {
        var d = en;
        for (var i = 0; i < fpRegs.readLatency; i++) {
          final q = Logic(name: '${name}_q$i');
          Sequential(clk, [q < d]);
          d = q;
        }
        return d;
      }

      fp1.done <= delayFpRead(fp1.en, 'fpRs1RdDone');
      fp1.valid <= delayFpRead(fp1.en, 'fpRs1RdValid');
      fp2.done <= delayFpRead(fp2.en, 'fpRs2RdDone');
      fp2.valid <= delayFpRead(fp2.en, 'fpRs2RdValid');
      fpw.done <= fpw.en;
      fpw.valid <= fpw.en;
      fpRs1Port = fp1;
      fpRs2Port = fp2;
      fpRdPort = fpw;
    }

    // The Debug Module borrows read port 0 to service abstract register-access
    // commands. Its ready must lag reg_read by the regfile read latency (the same
    // delay the operand read applies), otherwise the DM latches stale read data on
    // a registered-BRAM regfile (readLatency >= 1, e.g. the Xilinx/ECP5 builds).
    if (withDebug) {
      output('debug_reg_ready') <=
          delayReadHandshake(
            input('debug_reg_read') | input('debug_reg_write'),
            'dbgRegReady',
          );
    }

    // Interrupts.
    Logic externalPending = Const(0);
    for (final entry in srcIrqs.entries) {
      final sig = addInput(entry.key, entry.value);
      final anyFromThis = sig.or();
      externalPending = externalPending | anyFromThis;
    }
    // Supervisor external line -> mip.SEIP. Named `seiPending` at the module
    // boundary, the name the SoC and the CSR file both use for it.
    final seiPendingIn = supervisorExternalPending == null
        ? null
        : addInput('seiPending', supervisorExternalPending);
    // Per-cause CLINT lines: timer -> mip.MTIP, software -> mip.MSIP. Kept
    // distinct from externalPending (MEIP) so the SBI timer and IPIs reach the
    // right mcause, not the external-interrupt handler.
    final timerPendingIn = timerPending == null
        ? null
        : addInput('timerPending', timerPending);
    final swPendingIn = swPending == null
        ? null
        : addInput('swPending', swPending);
    final timeInIn = timeIn == null
        ? null
        : addInput('timeIn', timeIn, width: timeIn.width);

    // CSR file.
    final csrRead = DataPortInterface(config.mxlen.size, 12);
    final csrWrite = DataPortInterface(config.mxlen.size, 12);

    // Interface handed to the CSR file. Normally the pipeline's csrRead, but
    // while halted the Debug Module borrows the frozen read port: it presents
    // the debug regno (the CSR address) and routes the result back.
    final DataPortInterface csrReadCsr;
    if (dbgCsrData != null) {
      csrReadCsr = DataPortInterface(config.mxlen.size, 12);
      csrReadCsr.addr <= mux(dbgCsrSel!, dbgRegAddr12!, csrRead.addr);
      csrReadCsr.en <= mux(dbgCsrSel, Const(1), csrRead.en);
      // Feed the CSR read result back to the pipeline and to the debugger.
      csrRead.data <= csrReadCsr.data;
      csrRead.done <= csrReadCsr.done;
      csrRead.valid <= csrReadCsr.valid;
      dbgCsrData <= csrReadCsr.data;
    } else {
      csrReadCsr = csrRead;
    }

    // satp shadow register. The CsrTop backdoor read (csrs.satp) only reflects
    // the register during a write and reads X otherwise, so snapshot the
    // architectural satp write into a stable register the MMU walks against.
    // (satp has a full WARL mask, so the raw write data is the value.)
    final satpShadow = Logic(name: 'satpShadow', width: config.mxlen.size);
    if (config.mmu.hasPaging) {
      Sequential(clk, [
        If(
          reset,
          then: [satpShadow < 0],
          orElse: [
            If(
              csrWrite.en &
                  csrWrite.addr
                      .slice(11, 0)
                      .eq(Const(CsrAddress.satp.address, width: 12)) &
                  (virt == null ? Const(1) : ~virt),
              then: [satpShadow < csrWrite.data],
            ),
          ],
        ),
      ]);
    } else {
      satpShadow <= Const(0, width: config.mxlen.size);
    }

    // VS-stage page-table root for guest (virt=1) data accesses. Snapshotted
    // from HS-mode writes to vsatp, same shadow trick as satpShadow.
    final vsatpShadow = Logic(name: 'vsatpShadow', width: config.mxlen.size);
    if (config.hasHypervisor && config.mmu.hasPaging) {
      Sequential(clk, [
        If(
          reset,
          then: [vsatpShadow < 0],
          orElse: [
            If(
              csrWrite.en &
                  (csrWrite.addr
                          .slice(11, 0)
                          .eq(Const(CsrAddress.vsatp.address, width: 12)) |
                      (csrWrite.addr
                              .slice(11, 0)
                              .eq(Const(CsrAddress.satp.address, width: 12)) &
                          (virt ?? Const(0)))),
              then: [vsatpShadow < csrWrite.data],
            ),
          ],
        ),
      ]);
    } else {
      vsatpShadow <= Const(0, width: config.mxlen.size);
    }

    // G-stage root (hgatp), snapshotted from HS-mode writes. Same MODE/PPN
    // layout as satp. Feeds the MMU's two-stage walk when virt=1.
    final hgatpShadow = Logic(name: 'hgatpShadow', width: config.mxlen.size);
    if (config.hasHypervisor && config.mmu.hasPaging) {
      Sequential(clk, [
        If(
          reset,
          then: [hgatpShadow < 0],
          orElse: [
            If(
              csrWrite.en &
                  csrWrite.addr
                      .slice(11, 0)
                      .eq(Const(CsrAddress.hgatp.address, width: 12)),
              then: [hgatpShadow < csrWrite.data],
            ),
          ],
        ),
      ]);
    } else {
      hgatpShadow <= Const(0, width: config.mxlen.size);
    }

    // Trap save-state / xRET restore controls, driven from the pipeline's
    // retire-cycle outputs below (forward-declared so they can feed the CSR file
    // which is built before the pipeline).
    final xlen = config.mxlen.size;
    final csrTrapActive = Logic(name: 'csrTrapActive');
    final csrTrapTargetIsM = Logic(name: 'csrTrapTargetIsM');
    final csrTrapPc = Logic(name: 'csrTrapPc', width: xlen);
    final csrTrapCauseVal = Logic(name: 'csrTrapCauseVal', width: xlen);
    final csrTrapTval = Logic(name: 'csrTrapTval', width: xlen);
    final csrReturnActive = Logic(name: 'csrReturnActive');
    final csrReturnFromM = Logic(name: 'csrReturnFromM');
    // A trap delegated to VS-mode (virt stays 1, target vstvec, save to vs*).
    final csrTrapToVS = config.hasHypervisor
        ? Logic(name: 'csrTrapToVS')
        : null;
    // The retire strobe for minstret: one pulse per instruction that COMMITS.
    // Driven from the same `committing` gate the trap/xRET controls use, so a
    // multi-cycle microcoded instruction counts once.
    final csrRetire = config.hasCsrs ? Logic(name: 'csrRetire') : null;
    final csrFpFlags = Logic(name: 'csrFpFlags', width: 5);

    final csrs = config.hasCsrs
        ? RiscVCsrFile(
            clk,
            reset,
            mode,
            mxlen: config.mxlen,
            misa: config.isa.misaValue,
            mvendorid: config.vendorId,
            marchid: config.archId,
            mimpid: config.impId,
            mhartid: config.hartId,
            rpipelineCap: config.rpipelineCap,
            externalPending: externalPending,
            supervisorExternalPending: seiPendingIn,
            // An FP register-file write makes the FP context dirty. The CSR
            // file keeps a sticky flop and shows FS=Dirty on every mstatus and
            // sstatus read while it is set.
            fpDirty: fpRdPort?.en,
            enableFcsr: config.executionMode != ExecutionMode.outOfOrder,
            fpFlagsValid: csrRetire,
            fpFlags: csrFpFlags,
            retire: csrRetire,
            timerPending: timerPendingIn,
            swPending: swPendingIn,
            timeIn: timeInIn,
            hasSupervisor: config.hasSupervisor,
            hasUser: config.hasUser,
            hasHypervisor: config.hasHypervisor,
            hasStateen: config.hasStateen,
            hasPaging: config.mmu.hasPaging,
            hasMxr: config.mmu.hasMakeExecutableReadable,
            hasSum: config.mmu.hasSupervisorUserMemory,
            trapActive: csrTrapActive,
            trapTargetIsM: csrTrapTargetIsM,
            trapPc: csrTrapPc,
            trapCauseVal: csrTrapCauseVal,
            trapTval: csrTrapTval,
            returnActive: csrReturnActive,
            returnFromM: csrReturnFromM,
            virtInput: config.hasHypervisor ? virt : null,
            trapToVS: csrTrapToVS,
            csrRead: csrReadCsr,
            csrWrite: csrWrite,
          )
        : null;

    if (csrs != null && csrs.satp != null) {
      pagingMode <=
          (((csrs.satp! >>
                      Const(
                        config.mxlen.satpModeShift,
                        width: config.mxlen.size,
                      )) &
                  Const(config.mxlen.satpModeMask, width: config.mxlen.size)))
              .slice(pagingMode.width - 1, 0);
      pageTableAddress <=
          (csrs.satp! &
              Const(config.mxlen.satpPpnMask, width: config.mxlen.size));
    } else {
      pagingMode <= Const(0, width: pagingMode.width);
      pageTableAddress <= Const(0, width: config.mxlen.size);
    }

    // satp.MODE / root PPN for the MMU come from the stable shadow register.
    // In guest (virt=1) mode, data accesses translate through vsatp not HS satp.
    final effectiveSatp = guestAccessWire == null
        ? satpShadow
        : mux(guestAccessWire, vsatpShadow, satpShadow);
    satpModeWire <=
        ((effectiveSatp >>
                    Const(
                      config.mxlen.satpModeShift,
                      width: config.mxlen.size,
                    )) &
                Const(config.mxlen.satpModeMask, width: config.mxlen.size))
            .slice(3, 0);
    satpRootWire <=
        (effectiveSatp &
            Const(config.mxlen.satpPpnMask, width: config.mxlen.size));

    if (gModeWire != null) {
      gModeWire <=
          ((hgatpShadow >>
                      Const(
                        config.mxlen.satpModeShift,
                        width: config.mxlen.size,
                      )) &
                  Const(config.mxlen.satpModeMask, width: config.mxlen.size))
              .slice(3, 0);
      gRootWire! <=
          (hgatpShadow &
              Const(config.mxlen.satpPpnMask, width: config.mxlen.size));
    }

    // MPRV is an access override, not an actual-M-mode-only permission bit.
    // H deliberately retains read-only-zero MPRV pending MPV/VS integration.
    effectiveDataPriv <=
        (csrs == null || config.hasHypervisor
            ? mode
            : mux(
                csrs.mstatus[17],
                csrs.mstatus.slice(12, 11).zeroExtend(3),
                mode,
              ));
    if (csrs != null) {
      enableMxr <=
          ((csrs.mstatus >> 19) & Const(1, width: config.mxlen.size)).neq(0);
      enableSum <=
          ((csrs.mstatus >> 18) & Const(1, width: config.mxlen.size)).neq(0);
    } else {
      enableMxr <= Const(0);
      enableSum <= Const(0);
    }
    // DTLBFC bit (rpipelinectl[3]) -> MMU data-TLB priv-change flush.
    dtlbFlushOnPriv <= (csrs == null ? Const(0) : csrs.rpipelinectl[3]);

    // Microcode ROMs (optionally PATCHABLE at runtime via the rmicrocode* CSRs).
    // Parallel decode: the decode ROM packs `decodeLanes` pattern rows per word
    // (lane 0 in the low bits) so the dynamic decoder reads + compares that many
    // patterns per cycle, shortening its scan to ceil(patterns/lanes) cycles.
    // lanes==1 is the classic one-per-cycle ROM.
    final decodeLanes = config.microcodeDecodeLanes;
    final patternW = microcode.patternWidth;
    final decodeRowW = patternW * decodeLanes;
    final decodeWords = (microcode.map.length + decodeLanes - 1) ~/ decodeLanes;
    // Match the original count.bitLength convention (the RegisterFile/ROM index).
    final decodeIdxW = decodeWords.bitLength;
    // Pack: word w = pattern[w*lanes + l] << (l*patternW), padding the tail with
    // the last real pattern (a never-false extra: if the instruction matched it
    // the real lane matches first by priority, so no spurious hit).
    final rawPatterns = microcode.encodedPatterns;
    final packedPatterns = <BigInt>[
      for (var w = 0; w < decodeWords; w++)
        [
          for (var l = 0; l < decodeLanes; l++)
            rawPatterns[(w * decodeLanes + l).clamp(
                  0,
                  rawPatterns.length - 1,
                )] <<
                (l * patternW),
        ].reduce((a, b) => a | b),
    ];

    final microcodeDecodeRead = DataPortInterface(decodeRowW, decodeIdxW);
    final microcodeExecRead = DataPortInterface(
      microcode.mopWidth(config.mxlen),
      microcode.mopIndexWidth(config.mxlen),
    );

    final execRowW = microcode.mopWidth(config.mxlen);
    final execIdxW = microcode.mopIndexWidth(config.mxlen);

    // Runtime microcode update: a ROM row can be wider than XLEN, so the CPU
    // shifts the row in over rmicrocodedata (XLEN bits per push) and commits it
    // into the selected ROM. The rmicrocodectl strobes come from the csrWrite
    // write-pulse for that address, so each fires for one cycle and never
    // re-triggers. Built only when the core has CSRs and a microcode ROM.
    DataPortInterface? decodeWrite;
    DataPortInterface? execWrite;
    if (csrs != null && config.microcodeMode != MicrocodeMode.none) {
      final xlen = config.mxlen.size;
      final stagingW = decodeRowW > execRowW ? decodeRowW : execRowW;
      final staging = Logic(name: 'microcodeStaging', width: stagingW);

      final isCtl = csrWrite.addr.eq(
        Const(CsrAddress.rmicrocodectl.address, width: csrWrite.addr.width),
      );
      final pulse = csrWrite.en & isCtl;
      final push = pulse & csrWrite.data[0];
      final commit = pulse & csrWrite.data[1];
      final clear = pulse & csrWrite.data[2];

      final patchAddr = csrs.rmicrocodeaddr;
      final patchData = csrs.rmicrocodedata;
      // bit[XLEN-1] of the address selects the decode ROM (1) vs exec ROM (0).
      final targetDecode = patchAddr[xlen - 1];

      Sequential(clk, reset: reset, [
        If(
          clear,
          then: [staging < 0],
          orElse: [
            If(
              push,
              then: [
                staging < ((staging << xlen) | patchData.zeroExtend(stagingW)),
              ],
            ),
          ],
        ),
      ]);

      if (config.microcodeMode.onDecoder != MicrocodePipelineMode.none) {
        decodeWrite = DataPortInterface(decodeRowW, decodeIdxW);
        decodeWrite.en <= commit & targetDecode;
        decodeWrite.addr <= patchAddr.slice(decodeIdxW - 1, 0);
        decodeWrite.data <= staging.slice(decodeRowW - 1, 0);
      }
      if (config.microcodeMode.onExec != MicrocodePipelineMode.none) {
        execWrite = DataPortInterface(execRowW, execIdxW);
        execWrite.en <= commit & ~targetDecode;
        execWrite.addr <= patchAddr.slice(execIdxW - 1, 0);
        execWrite.data <= staging.slice(execRowW - 1, 0);
      }
    }

    if (config.microcodeMode.onDecoder != MicrocodePipelineMode.none) {
      // Decode pattern ROM (microcode.map.length x decodeRowW ~= 18k FF as a
      // resetValue RegisterFile). On ECP5 a DP16KD ROM (registered read),
      // elsewhere a flop ROM with a pipeline register so both paths have read
      // latency 1. done/valid lag `en` by 1 to match; the decoder holds its
      // address until `done`, so the registered read costs one fill cycle/probe.
      final useEbrRom =
          target is HarborFpgaTarget && target.vendor == HarborFpgaVendor.ecp5;
      final useXilinxRom =
          target is HarborFpgaTarget &&
          (target.vendor == HarborFpgaVendor.openXc7 ||
              target.vendor == HarborFpgaVendor.vivado);

      if (useEbrRom) {
        final rom = Ecp5InitRom(
          clk,
          contents: packedPatterns,
          width: decodeRowW,
          rdAddr: microcodeDecodeRead.addr,
          wrEn: decodeWrite?.en,
          wrAddr: decodeWrite?.addr,
          wrData: decodeWrite?.data,
          definitionName: 'RiverMicrocodeLookup',
        );
        microcodeDecodeRead.data <= rom.rdData;
      } else if (useXilinxRom) {
        // Xilinx: a behavioural BRAM-inferable ROM (synth_xilinx -> RAMB) so
        // the decode ROM does not explode into flops.
        final rom = InferredInitRom(
          clk,
          contents: packedPatterns,
          width: decodeRowW,
          rdAddr: microcodeDecodeRead.addr,
          wrEn: decodeWrite?.en,
          wrAddr: decodeWrite?.addr,
          wrData: decodeWrite?.data,
          definitionName: 'RiverMicrocodeLookup',
        );
        microcodeDecodeRead.data <= rom.rdData;
      } else {
        final decodeRaw = DataPortInterface(decodeRowW, decodeIdxW);
        decodeRaw.en <= microcodeDecodeRead.en;
        decodeRaw.addr <= microcodeDecodeRead.addr;
        RegisterFile(
          clk,
          reset,
          decodeWrite != null ? [wrapWriteForRegisterFile(decodeWrite)] : [],
          [wrapReadForRegisterFile(decodeRaw)],
          numEntries: decodeWords,
          resetValue: packedPatterns,
          definitionName: 'RiverMicrocodeLookup',
        );
        final decodeDataReg = Logic(
          name: 'microcodeDecodeDataReg',
          width: decodeRowW,
        );
        Sequential(clk, [decodeDataReg < decodeRaw.data]);
        microcodeDecodeRead.data <= decodeDataReg;
      }

      final decodeHsReg = Logic(name: 'microcodeDecodeHsReg');
      Sequential(clk, reset: reset, [decodeHsReg < microcodeDecodeRead.en]);
      microcodeDecodeRead.done <= microcodeDecodeRead.en & decodeHsReg;
      microcodeDecodeRead.valid <= microcodeDecodeRead.en & decodeHsReg;
    }

    if (config.microcodeMode.onExec != MicrocodePipelineMode.none) {
      final mops = microcode.encodedMops(config.mxlen);

      // Pipeline the exec ROM read: the addr -> ROM -> funct-decode + ALU-tree
      // path is the microcode Fmax bottleneck. Register the ROM data so
      // addr->ROM and ROM-data->ALU are separate stages, and delay the read
      // handshake to match (one extra read-latency cycle; the exec FSM already
      // stalls on done/valid). valid is gated by `en` so the registered
      // handshake does not leave a stale valid high after en deasserts.
      // The exec ROM is the largest memory in the core (mops.length x execRowW):
      // as a flop RegisterFile ~94k FF, 4x the whole LFE5U-25F. On ECP5 it MUST
      // be EBR (DP16KD, contents baked in via INITVAL); port B's registered read
      // IS the pipeline stage (1-cycle, matching the sim combinational-ROM +
      // execDataReg), the update-CSR write goes to port A. Sim has no DP16KD
      // model, so non-ECP5 targets keep the flop ROM (microcode via resetValue).
      final useEbrRom =
          target is HarborFpgaTarget && target.vendor == HarborFpgaVendor.ecp5;
      final useXilinxRom =
          target is HarborFpgaTarget &&
          (target.vendor == HarborFpgaVendor.openXc7 ||
              target.vendor == HarborFpgaVendor.vivado);

      if (useEbrRom) {
        final rom = Ecp5InitRom(
          clk,
          contents: mops,
          width: execRowW,
          rdAddr: microcodeExecRead.addr,
          wrEn: execWrite?.en,
          wrAddr: execWrite?.addr,
          wrData: execWrite?.data,
          definitionName: 'RiverMicrocodeOperations',
        );
        microcodeExecRead.data <= rom.rdData;
      } else if (useXilinxRom) {
        // Xilinx: BRAM-inferable ROM instead of the ~94k-FF flop RegisterFile.
        final rom = InferredInitRom(
          clk,
          contents: mops,
          width: execRowW,
          rdAddr: microcodeExecRead.addr,
          wrEn: execWrite?.en,
          wrAddr: execWrite?.addr,
          wrData: execWrite?.data,
          definitionName: 'RiverMicrocodeOperations',
        );
        microcodeExecRead.data <= rom.rdData;
      } else {
        final execRaw = DataPortInterface(execRowW, execIdxW);
        execRaw.en <= microcodeExecRead.en;
        execRaw.addr <= microcodeExecRead.addr;

        RegisterFile(
          clk,
          reset,
          execWrite != null ? [wrapWriteForRegisterFile(execWrite)] : [],
          [wrapReadForRegisterFile(execRaw)],
          numEntries: mops.length,
          resetValue: mops,
          definitionName: 'RiverMicrocodeOperations',
        );

        final execDataReg = Logic(
          name: 'microcodeExecDataReg',
          width: execRowW,
        );
        Sequential(clk, [execDataReg < execRaw.data]);
        microcodeExecRead.data <= execDataReg;
      }

      final execHsReg = Logic(name: 'microcodeExecHsReg');
      Sequential(clk, reset: reset, [execHsReg < microcodeExecRead.en]);
      microcodeExecRead.done <= microcodeExecRead.en & execHsReg;
      microcodeExecRead.valid <= microcodeExecRead.en & execHsReg;
    }

    // Multiple-outstanding fetch port (decoupled, latency-agnostic). When
    // fetchOutstanding > 1, fetch runs over a decoupled request/response port
    // the PipelinedFetchUnit drives, keeping several reads in flight (the
    // unified bus/icache is single-outstanding). Exposed at the core boundary so
    // the system can attach any fetch memory (fixed-latency BRAM/TCM or a
    // variable-latency DRAM/cache/AXI source) driving rsp_valid/req_ready; the
    // core makes no latency assumption.
    FetchReadInterface? fetchReadPort;
    if (config.fetchOutstanding > 1) {
      // Instructions are 32-bit, so the fetch port carries a 32-bit word with an
      // mxlen-wide address (one instruction per fetch, no 64-bit packing).
      final aw = config.mxlen.size;
      addOutput('fetchReq_valid');
      addOutput('fetchReq_addr', width: aw);
      createPort('fetchReq_ready', PortDirection.input);
      createPort('fetchRsp_valid', PortDirection.input);
      createPort('fetchRsp_data', PortDirection.input, width: 32);

      fetchReadPort = FetchReadInterface(32, aw);
      output('fetchReq_valid') <= fetchReadPort.reqValid;
      output('fetchReq_addr') <= fetchReadPort.reqAddr;
      fetchReadPort.reqReady <= input('fetchReq_ready');
      fetchReadPort.rspValid <= input('fetchRsp_valid');
      fetchReadPort.rspData <= input('fetchRsp_data');
    }

    // Backdoor prf seed: when prfSeedMode is asserted (frozen seed window), an
    // architectural regWritePort write also seeds the OoO physical regfile at
    // the same (arch == phys under the reset-identity rename map) index.
    final prfSeedModeIn = prfSeedMode == null
        ? null
        : addInput('prfSeedMode', prfSeedMode);

    // Select an asynchronous interrupt candidate. The executor accepts it at
    // a clean instruction boundary and uses the ordinary trap-retirement path.
    Logic? interruptTake;
    Logic? interruptCause;
    if (csrs != null &&
        !config.hasHypervisor &&
        config.executionMode != ExecutionMode.outOfOrder) {
      // All sources share mip/mie (including hardware OR software SEIP).
      // Source numbering does not determine the destination privilege.
      final pending = (csrs.mip & csrs.mie).named('enabledInterrupts');
      final delegated = config.hasSupervisor
          ? csrs.mideleg
          : Const(0, width: config.mxlen.size);
      final isM = mode.eq(Const(PrivilegeMode.machine.id, width: 3));
      final isS = mode.eq(Const(PrivilegeMode.supervisor.id, width: 3));
      final isU = mode.eq(Const(PrivilegeMode.user.id, width: 3));
      final mGlobal = ~isM | csrs.mstatus[3];
      final sGlobal = (isS & csrs.mstatus[1]) | isU;
      // Lowest priority first within each target. M-target interrupts must
      // outrank S-target interrupts, even if the M source has a lower cause.
      const order = [5, 1, 9, 7, 3, 11];
      Logic take = Const(0);
      Logic cause = Const(0, width: 6);
      for (final supervisor in [true, false]) {
        for (final bit in order) {
          final eligible =
              pending[bit] &
              (supervisor
                  ? delegated[bit] & sGlobal
                  : ~delegated[bit] & mGlobal);
          cause = mux(eligible, Const(bit, width: 6), cause);
          take |= eligible;
        }
      }
      // Keep the registered candidate. It is selection, not acceptance: exec
      // accepts it only at a clean instruction boundary. Revalidate against
      // current CSR/pending/privilege state, including priority, so a CSR write
      // or xRET cannot deliver a stale candidate. An accepted trap completes
      // through the existing exec/retirement path without further cancellation.
      final candidateValid = Logic(name: 'interruptTakeReg');
      final candidateCause = Logic(name: 'interruptCauseReg', width: 6);
      Sequential(clk, [
        If(
          reset,
          then: [candidateValid < 0, candidateCause < 0],
          orElse: [candidateValid < take, candidateCause < cause],
        ),
      ]);
      interruptTake = (candidateValid & take & candidateCause.eq(cause)).named(
        'interruptTake',
      );
      interruptCause = candidateCause.named('interruptCause');
    } else if (csrs != null) {
      // Preserve the existing H/OoO delivery path; guest interrupt targeting
      // and precise OoO acceptance require their own coordinated integration.
      final xlen = config.mxlen.size;
      final isM = mode.eq(Const(PrivilegeMode.machine.id, width: 3));
      final isS = mode.eq(Const(PrivilegeMode.supervisor.id, width: 3));
      final isU = mode.eq(Const(PrivilegeMode.user.id, width: 3));
      final mMie = csrs.mstatus[3]; // mstatus.MIE
      final sSie = (csrs.sstatus ?? csrs.mstatus)[1]; // sstatus.SIE
      final mGlobal = ((isM & mMie) | ~isM).named('mIntGlobal');
      final sGlobal = ((isS & sSie) | isU).named('sIntGlobal');
      final mPend = (csrs.mip & csrs.mie).named('mIntPend');
      var sPend = config.hasSupervisor
          ? (csrs.sip! & csrs.sie!).named('sIntPend')
          : Const(0, width: xlen);
      // mip.SEIP(9) is the OR of the hardware supervisor-external line and the
      // software-writable bit, per the privileged spec. The CSR file holds only
      // the software bit today, so the hardware line joins the take decision
      // here, still gated by sie.SEIE. This stays correct after the CSR file
      // folds the line into its own sip view: OR is idempotent.
      if (seiPendingIn != null && config.hasSupervisor) {
        sPend = sPend
            .withSet(9, sPend[9] | (seiPendingIn & csrs.sie![9]))
            .named('sIntPendHw');
      }
      // (bit, isSupervisor), listed lowest priority first so the folds below let
      // the highest priority win.
      const order = [
        (5, true), (1, true), (9, true), // STI, SSI, SEI
        (7, false), (3, false), (11, false), // MTI, MSI, MEI
      ];
      Logic take = Const(0);
      Logic cause = Const(0, width: 6);
      for (final entry in order) {
        final bit = entry.$1;
        final isSup = entry.$2;
        final t =
            ((isSup ? sPend[bit] : mPend[bit]) & (isSup ? sGlobal : mGlobal))
                .named('intTake_$bit');
        cause = mux(t, Const(bit, width: 6), cause);
        take = take | t;
      }
      // Register the interrupt-take decision. The mip/mie/mstatus/mode fold above
      // otherwise sits combinationally in series with the exec -> nextPc -> fetch
      // redirect (exec.dart:973 muxes the WHOLE exec output on interruptTake),
      // and its wide fanout congests the fabric. On the timing-marginal openXC7
      // delta build that combinational path costs ~7 MHz of core Fmax (measured:
      // 41 MHz interrupt-off vs 34 MHz interrupt-on), and openXC7 STA is
      // optimistic about the core clock, so that margin is load-bearing on
      // silicon (an async interrupt taken here intermittently wedged the fetch).
      // Delaying the take by one cycle is safe: the interrupt is async and
      // level-sensitive, and the readyExecution gate plus the post-redirect fetch
      // bubble let mstatus.MIE clear before the next instruction boundary, so a
      // just-taken interrupt cannot double-fire.
      final interruptTakeReg = Logic(name: 'interruptTakeReg');
      final interruptCauseReg = Logic(name: 'interruptCauseReg', width: 6);
      Sequential(clk, [
        If(
          reset,
          then: [interruptTakeReg < 0, interruptCauseReg < 0],
          orElse: [interruptTakeReg < take, interruptCauseReg < cause],
        ),
      ]);
      // Re-apply the global interrupt-enable COMBINATIONALLY. interruptTakeReg
      // reflects the enable state from one cycle ago; if software just cleared
      // SIE/MIE (csrrci sstatus/mstatus to enter a critical section) the stale
      // registered take must not fire a SPURIOUS interrupt into the now-disabled
      // section. The heavy mip&mie + priority fold stays registered (the timing
      // win); the global enable is a couple of mstatus bits, cheap and off the
      // critical path. The registered cause identifies the privilege: S-causes
      // are 1/5/9 (cause[1]=0), M-causes are 3/7/11 (cause[1]=1).
      final takeSup = (~interruptCauseReg[1]).named('intTakeSup');
      final curGlobal = mux(takeSup, sGlobal, mGlobal).named('curIntGlobal');
      interruptTake = (interruptTakeReg & curGlobal).named('interruptTake');
      interruptCause = interruptCauseReg.named('interruptCause');
    }

    loadPageFault <= mmu.dportFault;

    // Pipeline.
    pipeline = RiverPipeline(
      clk,
      reset,
      pipelineEnable,
      sp,
      pc,
      mode,
      config.hasCsrs ? csrRead : null,
      config.hasCsrs ? csrWrite : null,
      pipeFetchRead,
      pipeExecRead,
      pipeExecWrite,
      rs1Read,
      rs2Read,
      rdWrite,
      config.microcodeMode.onDecoder != MicrocodePipelineMode.none
          ? microcodeDecodeRead
          : null,
      config.microcodeMode.onExec != MicrocodePipelineMode.none
          ? microcodeExecRead
          : null,
      useOoO: config.executionMode == ExecutionMode.outOfOrder,
      useMixedDecoders:
          config.microcodeMode.onDecoder == MicrocodePipelineMode.inParallel,
      useMixedExecution:
          config.microcodeMode.onExec == MicrocodePipelineMode.inParallel,
      microcode: microcode,
      mxlen: config.mxlen,
      vlen: config.vlen,
      hasSupervisor: config.hasSupervisor,
      hasUser: config.hasUser,
      hasCompressed: config.extensions.any((e) => e.name == 'C'),
      frm: csrs?.frm,
      // Undeclared mstatus bits read as X, so only take these where the
      // supervisor fields exist.
      tsr: csrs != null && config.hasSupervisor ? csrs.mstatus[22] : null,
      tvm: csrs != null && config.hasSupervisor ? csrs.mstatus[20] : null,
      tw: csrs != null && config.hasSupervisor ? csrs.mstatus[21] : null,
      fpEnabled: csrs?.hasFcsr == true
          ? csrs!.mstatus.slice(14, 13).or()
          : null,
      mideleg: csrs?.mideleg,
      medeleg: csrs?.medeleg,
      mtvec: csrs?.mtvec,
      stvec: csrs?.stvec,
      interruptTake: interruptTake,
      interruptCause: interruptCause,
      fpRs1Port: fpRs1Port,
      fpRs2Port: fpRs2Port,
      fpRdPort: fpRdPort,
      mepc: csrs?.mepc,
      sepc: (csrs != null && config.hasSupervisor) ? csrs.sepc : null,
      virt: virt,
      mstateen0Se0: csrs?.mstateen0Se0,
      hstateen0Se0: csrs?.hstateen0Se0,
      memFaultGuest: config.hasHypervisor ? mmu.dportFaultGuest : null,
      enableMisalignedLoads: enableMisalignedLoads,
      exactMemoryReads: physicalCaches,
      loadFaultTval: loadUnit?.faultAddress,
      memAccessFault: !handleAccessFaults
          ? null
          : (useDCache
                ? dcache!.respFaultIsAccess
                : mux(
                    loadMisaligned,
                    loadUnit?.accessFault ?? Const(0),
                    mmu.dportDone & ~mmu.dportValid & ~mmu.dportFault,
                  )),
      ifetchAccessFault: !handleAccessFaults
          ? null
          : (useICache
                ? icache!.respFaultIsAccess
                : mmu.ifetchDone & ~mmu.ifetchValid & ~mmu.ifetchFault),
      specCtl: csrs?.rpipelinectl.getRange(0, 4),
      prfSeedEn: prfSeedModeIn == null ? null : (prfSeedModeIn & rdWrite.en),
      prfSeedAddr: prfSeedModeIn == null ? null : rdWrite.addr,
      prfSeedData: prfSeedModeIn == null ? null : rdWrite.data,
      ifetchFault: config.mmu.hasPaging
          ? (useICache ? icache!.respFault : mmu.ifetchFault)
          : null,
      rdWrite1: rdWrite1,
      wr0Ready: wr0Ready,
      wr1Ready: wr1Ready,
      speculative: config.speculativeFetch,
      dualDispatch: dualDispatch,
      prefetchFetch: config.prefetchFetch,
      prefetchDepth: config.prefetchDepth,
      fetchOutstanding: config.fetchOutstanding,
      fetchReadPort: fetchReadPort,
      branchPredictor: config.branchPredictor,
      loadStoreQueue: config.loadStoreQueue,
      robDepth: config.robDepth,
      storeQueueDepth: config.storeQueueDepth,
      loadQueueDepth: config.loadQueueDepth,
      memFetchRead1: pipeFetchRead1,
      staticInstructions: staticInstructions,
    );

    // Legacy L1 caches sit in FRONT of the MMU, so they are indexed and tagged by
    // VIRTUAL address. Every event that can re-point a virtual address at
    // different memory must drop their contents: fence.i, sfence.vma, AND a satp
    // write. The exec unit pulses `fence` for all three (see the WriteCsr steps,
    // which pulse it when the target CSR is satp), so this one net carries them
    // all and the caches need no separate satp port.
    //
    // The satp case is not redundant. Software is not obliged to follow a satp
    // write with an sfence.vma: River's satp is a plain read/write register, so
    // Linux reads back a full 16-bit ASID, enables its ASID allocator, and from
    // then on switches address spaces with the satp write ALONE. The MMU already
    // self-invalidates its TLBs on that write. While the L1s did not, they kept
    // the outgoing address space's lines and served them to the incoming one, so
    // a process fetched another process's instructions. On creek this could not
    // show (bare mode, VA == PA, one address space); under Sv39 it corrupted the
    // machine at random.
    // Physical L1s use the same flush signal conservatively. Translation and
    // permission checks still precede every physical-cache lookup.
    icFlush <= pipeline.fence;
    mmuTlbFlush <= pipeline.fence;
    loadMisaligned <= pipeline.output('misalignedLoad');
    loadSize <= pipeline.output('loadSize');
    if (useDCache) dFlush <= pipeline.fence;

    // An access is guest-translated when the core is virtualized OR the current
    // access is an HLV/HSV (memGuest). Drives the MMU's VS/G-stage routing.
    if (guestAccessWire != null) {
      guestAccessWire <= virt! | pipeline.memGuest;
    }

    // Drive the CSR file's trap/return controls from the pipeline retire-cycle
    // outputs. `committing` matches the PC-latch gate so each event fires once.
    if (csrs != null) {
      // One-shot commit: pipelineEnable is 1 only on the first done cycle.
      final committing = ~interruptHold & pipeline.done & pipelineEnable;
      // An ebreak commits as a breakpoint trap (cause 3). If dcsr.ebreak* is set
      // for the current privilege, redirect it to Debug Mode: suppress the
      // architectural trap and let the halt FSM latch dpc/cause.
      Logic trapSuppress = Const(0);
      if (withDebug) {
        final ebreakForMode =
            (mode.eq(Const(PrivilegeMode.machine.id, width: 3)) &
                debugDcsr![15]) |
            (mode.eq(Const(PrivilegeMode.supervisor.id, width: 3)) &
                debugDcsr[13]) |
            (mode.eq(Const(PrivilegeMode.user.id, width: 3)) & debugDcsr[12]);
        ebreakDebug! <=
            committing &
                pipeline.trap &
                pipeline.trapCause.eq(Const(3, width: 6)) &
                ebreakForMode;
        trapSuppress = ebreakDebug;
      }
      csrTrapActive <= committing & pipeline.trap & ~trapSuppress;
      csrTrapTargetIsM <=
          pipeline.nextMode.eq(Const(PrivilegeMode.machine.id, width: 3));
      csrTrapPc <= pipeline.trapEpc;
      // mcause = (interrupt << XLEN-1) | cause. trapCause carries only the low
      // cause code (also used for delegation); the interrupt bit rides the
      // separate trapInterrupt signal.
      csrTrapCauseVal <=
          (pipeline.trapInterrupt.zeroExtend(xlen) << (xlen - 1)) |
              pipeline.trapCause.zeroExtend(xlen);
      csrTrapTval <= pipeline.trapTval;
      csrFpFlags <= pipeline.fpFlags;
      csrReturnActive <= committing & pipeline.isReturn;
      csrReturnFromM <= pipeline.returnLevel.eq(Const(3, width: 3));
      // minstret counts instructions that RETIRE. An instruction that takes a
      // trap, or a cycle in which an asynchronous interrupt is taken, does not
      // retire: the instruction runs again after the handler returns.
      csrRetire! <= committing & ~pipeline.trap;
      if (csrTrapToVS != null) {
        // exec already routed this trap to S (medeleg-delegated); upgrade to VS
        // when virtualized and hedeleg further delegates this cause.
        csrTrapToVS <=
            committing &
                pipeline.trap &
                virt! &
                pipeline.nextMode.eq(
                  Const(PrivilegeMode.supervisor.id, width: 3),
                ) &
                csrs.hedeleg![pipeline.trapCause];
      }
    } else {
      csrTrapActive <= Const(0);
      csrTrapTargetIsM <= Const(0);
      csrTrapPc <= Const(0, width: xlen);
      csrTrapCauseVal <= Const(0, width: xlen);
      csrTrapTval <= Const(0, width: xlen);
      csrReturnActive <= Const(0);
      csrReturnFromM <= Const(0);
    }

    // xRET PC/mode restore values (read combinationally from the CSR backdoor).
    final retPc = csrs == null
        ? pipeline.nextPc
        : mux(
            csrReturnFromM,
            csrs.mepc,
            config.hasSupervisor ? csrs.sepc : Const(0, width: xlen),
          );
    final retMode = csrs == null
        ? pipeline.nextMode
        : mux(
            csrReturnFromM,
            // MPP = mstatus[12:11]
            csrs.mstatus.slice(12, 11).zeroExtend(3),
            // SPP = sstatus[8] ? supervisor : user
            config.hasSupervisor
                ? mux(
                    csrs.sstatus![8],
                    Const(PrivilegeMode.supervisor.id, width: 3),
                    Const(PrivilegeMode.user.id, width: 3),
                  )
                : Const(PrivilegeMode.machine.id, width: 3),
          );

    // V-bit restore on xRET: MRET enters virt iff MPP!=M and mstatus.MPV; an
    // HS-mode SRET (virt=0) enters the guest iff hstatus.SPV (a guest-mode SRET
    // keeps virt=1). Trap entry clears virt.
    final retVirt = (csrs == null || !config.hasHypervisor)
        ? Const(0)
        : mux(
            csrReturnFromM,
            retMode.neq(Const(PrivilegeMode.machine.id, width: 3)) &
                csrs.mstatus[39],
            mux(virt!, Const(1), csrs.hstatus![7]),
          );

    // VS-delegated trap vector (vstvec base, direct mode). The trap stays in
    // VS-mode (virt=1) and saves to vs* (handled in the CSR file).
    final vsTrapPc = (csrTrapToVS == null)
        ? Const(0, width: xlen)
        : (csrs!.vstvec! & ~Const(0x3, width: xlen));

    // The PC the committing instruction advances to (xRET restores from *epc,
    // everything else takes the pipeline's next PC). Used as dpc for single-step.
    final committedNextPc = mux(
      pipeline.isReturn,
      retPc,
      (csrTrapToVS == null
          ? pipeline.nextPc
          : mux(csrTrapToVS, vsTrapPc, pipeline.nextPc)),
    );

    // dcsr.prv: the privilege the hart held when it entered Debug Mode. The
    // RISC-V debug spec requires it; River never wrote it, so it read its reset
    // value (3, machine) whatever the core was doing. mode[1:0] is already the
    // spec encoding (M=3, S=1, U=0).
    final dcsrPrv = withDebug
        ? mode.getRange(0, 2).zeroExtend(32).named('dcsrPrv')
        : Const(0, width: 32);

    // Core state machine. The normal (non-halted) advance body, captured so
    // debug-halt can gate it.
    final coreBody = <Conditional>[
      If(
        interruptHold & externalPending,
        then: [interruptHold < 0, pipelineEnable < 1, fence < 0],
      ),
      If(
        ~interruptHold,
        then: [
          // Commit exactly once: pipeline.done can stay asserted for several
          // drain cycles, but pipelineEnable is 1 only on the first done cycle.
          // Critical for xRET/trap where the commit mutates CSR state (mstatus
          // pop); a second fire would read the popped value and corrupt the mode.
          If(
            pipeline.done & pipelineEnable,
            then: [
              // On xRET, restore PC/mode from {m,s}epc/{m,s}status; the CSR
              // file pops the status stack in parallel. Otherwise advance
              // normally (doTrap already redirected nextPc to tvec).
              If(
                pipeline.isReturn,
                then: [
                  pc < retPc,
                  mode < retMode,
                  if (virt != null) virt < retVirt,
                ],
                orElse: [
                  // A trap delegated to VS-mode targets vstvec and STAYS
                  // virtualized; all other traps go to HS/M and clear virt.
                  pc <
                      (csrTrapToVS == null
                          ? pipeline.nextPc
                          : mux(csrTrapToVS, vsTrapPc, pipeline.nextPc)),
                  mode < pipeline.nextMode,
                  if (virt != null)
                    virt < mux(pipeline.trap, csrTrapToVS ?? Const(0), virt),
                ],
              ),
              sp < pipeline.nextSp,
              interruptHold < pipeline.interruptHold,
              fence < pipeline.fence,
              // Lockstep commits once then drops enable to force a re-fetch.
              // Speculative fetch keeps the pipeline enabled and self-sequences,
              // so the commit fires every `done` cycle (distinct instructions).
              if (!config.speculativeFetch) pipelineEnable < 0,
              // Single-step: this commit is the one stepped instruction; re-enter
              // Debug Mode at the next PC (cause 4) and freeze the pipeline.
              if (withDebug)
                If(
                  stepping!,
                  then: [
                    debugHalted! < 1,
                    pipelineEnable < 0,
                    debugDpc! < committedNextPc,
                    debugDcsr! <
                        (debugDcsr! & Const(0xFFFFFE3C, width: 32)) |
                            (Const(4 << 6, width: 32) | dcsrPrv),
                    stepping! < Const(0),
                  ],
                ),
            ],
          ),
          // Re-enable the pipeline once `done` drops (the next fetch is
          // underway); do not re-enable during the drain cycles.
          If(~pipeline.done, then: [pipelineEnable < 1, fence < 0]),
        ],
        orElse: [pipelineEnable < 0, fence < 0],
      ),
    ];

    Sequential(clk, [
      If(
        reset,
        then: [
          pipelineEnable < 0,
          pc < config.resetVector,
          sp < 0,
          // RISC-V resets to machine mode (PrivilegeMode.machine == 3). Tests
          // may override this to pre-position the core in S/U (resetPrivilege).
          mode < (resetPrivilege ?? PrivilegeMode.machine.id),
          if (virt != null) virt < 0,
          fence < 0,
          interruptHold < 0,
          if (withDebug) debugHalted! < 0,
          if (withDebug) stepping! < Const(0),
          // Trigger reset: type=2 (mcontrol), no control bits, no match addr.
          if (hasTriggers) tselect! < Const(0, width: tselectW),
          if (hasTriggers)
            for (var i = 0; i < debugTriggers; i++) ...[
              tdata1[i] < Const(2 << 28, width: 32),
              tdata2[i] < Const(0, width: config.mxlen.size),
            ],
          if (withDebug) debugDpc! < config.resetVector,
          // dcsr reset: debugver=4 (0.13.2), prv=3 (machine), cause=0.
          if (withDebug) debugDcsr! < Const(0x40000003, width: 32),
        ],
        orElse: withDebug
            ? [
                // While halted, freeze the pipeline and hold the PC; resume on
                // the debugger's request. Otherwise enter debug mode at the
                // next instruction boundary on haltreq, latching dpc.
                If(
                  debugHalted!,
                  then: [
                    pipelineEnable < 0,
                    // A debugger may rewrite dpc to redirect where we resume.
                    If(
                      input('debug_reg_write') & dbgIsDpc!,
                      then: [debugDpc! < dbgRegWdata],
                    ),
                    // A debugger may write dcsr (ebreak/step/prv bits). debugver
                    // (31:28) is read-only and cause (8:6) is hardware-set, so
                    // force the former and preserve the latter on every write.
                    If(
                      input('debug_reg_write') & dbgIsDcsr!,
                      then: [
                        debugDcsr! <
                            (dbgRegWdata!.getRange(0, 32) &
                                    Const(0x0FFFFE3F, width: 32)) |
                                Const(0x40000000, width: 32) |
                                (debugDcsr & Const(0x000001C0, width: 32)),
                      ],
                    ),
                    // A debugger programs the hardware triggers (tselect picks
                    // one; tdata1 is the mcontrol config, type forced to 2;
                    // tdata2 is the match address).
                    if (hasTriggers) ...[
                      If(
                        dbgTselWrite!,
                        then: [tselect! < dbgRegWdata!.getRange(0, tselectW)],
                      ),
                      If(
                        dbgTdata1Write!,
                        then: [
                          for (var i = 0; i < debugTriggers; i++)
                            If(
                              tselect!.eq(i),
                              then: [
                                tdata1[i] <
                                    (dbgRegWdata!.getRange(0, 32) &
                                            Const(0x0FFFFFFF, width: 32)) |
                                        Const(2 << 28, width: 32),
                              ],
                            ),
                        ],
                      ),
                      If(
                        dbgTdata2Write!,
                        then: [
                          for (var i = 0; i < debugTriggers; i++)
                            If(
                              tselect!.eq(i),
                              then: [tdata2[i] < dbgRegWdata!],
                            ),
                        ],
                      ),
                    ],
                    If(
                      resumeReqIn!,
                      then: [
                        debugHalted < 0,
                        pc < debugDpc,
                        // Arm single-step for this resume if dcsr.step is set.
                        stepping! < debugDcsr![2],
                      ],
                    ),
                  ],
                  orElse: [
                    If(
                      haltReqIn!,
                      then: [
                        debugHalted < 1,
                        pipelineEnable < 0,
                        debugDpc < pc,
                        // Halt cause = 3 (haltreq); keep the other dcsr bits.
                        debugDcsr <
                            (debugDcsr & Const(0xFFFFFE3C, width: 32)) |
                                (Const(3 << 6, width: 32) | dcsrPrv),
                      ],
                      orElse: [
                        // A hardware execute trigger fires BEFORE its matched
                        // instruction runs: freeze at pc, cause = 2 (trigger).
                        // The ternary keeps debugTriggers==0 byte-identical.
                        hasTriggers
                            ? If(
                                triggerMatch!,
                                then: [
                                  debugHalted < 1,
                                  pipelineEnable < 0,
                                  debugDpc < pc,
                                  debugDcsr <
                                      (debugDcsr &
                                              Const(0xFFFFFE3C, width: 32)) |
                                          (Const(2 << 6, width: 32) | dcsrPrv),
                                ],
                                orElse: [
                                  If(
                                    ebreakDebug!,
                                    then: [
                                      debugHalted < 1,
                                      pipelineEnable < 0,
                                      debugDpc < pipeline.trapEpc,
                                      debugDcsr <
                                          (debugDcsr &
                                                  Const(
                                                    0xFFFFFE3C,
                                                    width: 32,
                                                  )) |
                                              (Const(1 << 6, width: 32) |
                                                  dcsrPrv),
                                    ],
                                    orElse: coreBody,
                                  ),
                                ],
                              )
                            : If(
                                ebreakDebug!,
                                then: [
                                  // ebreak entered Debug Mode: freeze at the
                                  // ebreak, latch pc into dpc, cause = 1.
                                  debugHalted < 1,
                                  pipelineEnable < 0,
                                  debugDpc < pipeline.trapEpc,
                                  debugDcsr <
                                      (debugDcsr &
                                              Const(0xFFFFFE3C, width: 32)) |
                                          (Const(1 << 6, width: 32) | dcsrPrv),
                                ],
                                orElse: coreBody,
                              ),
                      ],
                    ),
                  ],
                ),
              ]
            : coreBody,
      ),
    ]);

    // Sticky witnesses for HOW the core entered user mode, so the probe gives a
    // diagnosis rather than a yes or no. Each sets once and never clears.
    // A separate sequential block: it adds no input to the core state machine's
    // condition cone, so it cannot perturb the timing of what it measures.
    if (userProbe && withDebug) {
      final fromMret = probeUserFromMret!;
      final fromSret = probeUserFromSret!;
      final fromTrap = probeUserFromTrap!;
      final userId = Const(PrivilegeMode.user.id, width: 3);
      final committingNow = (~interruptHold & pipeline.done & pipelineEnable)
          .named('probeCommitting');
      final retToUser = (committingNow & pipeline.isReturn & retMode.eq(userId))
          .named('probeRetToUser');
      Sequential(clk, [
        If(
          reset,
          then: [fromMret < 0, fromSret < 0, fromTrap < 0],
          orElse: [
            If(retToUser & csrReturnFromM, then: [fromMret < 1]),
            If(retToUser & ~csrReturnFromM, then: [fromSret < 1]),
            If(
              committingNow & ~pipeline.isReturn & pipeline.nextMode.eq(userId),
              then: [fromTrap < 1],
            ),
          ],
        ),
      ]);
    }

    // Expose the V-bit for observability (no behavioral effect until VS-mode /
    // two-stage translation consume it).
    if (virt != null) {
      addOutput('virt') <= virt;
    }
  }
}
