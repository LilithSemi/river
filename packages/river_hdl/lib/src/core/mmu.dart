import 'package:river/river.dart';
import 'package:rohd/rohd.dart';

/// River MMU with Wishbone bus master downstream.
///
/// Upstream: ifetch (en/addr → done/valid/rdata) and dport (en/addr/we/wdata/size → done/valid/rdata)
/// Downstream: Wishbone master (CYC/STB/WE/ADR/DAT_MOSI/SEL → ACK/DAT_MISO)
///
/// Internally: priority arbiter (dport > ifetch), Wishbone master FSM.
class RiverMmu extends Module {
  final HarborMmuConfig mmuConfig;
  final WishboneConfig busConfig;

  // Upstream response outputs
  Logic get ifetchDone => output('ifetch_done');
  Logic get ifetchValid => output('ifetch_valid');
  Logic get ifetchRdata => output('ifetch_rdata');
  Logic get dportDone => output('dport_done');
  Logic get dportValid => output('dport_valid');
  Logic get dportRdata => output('dport_rdata');
  Logic get dportFault => output('dport_fault');
  Logic get dportFaultGuest => output('dport_fault_guest');
  Logic get ifetchFault => output('ifetch_fault');

  /// Sticky user-mode excursion probe, present only when `userProbe` is set.
  /// See the probe block in the constructor for the bit map.
  Logic get probe => output('probe');
  // Downstream bus master outputs
  Logic get wbCyc => output('dataBus_CYC');
  Logic get wbStb => output('dataBus_STB');
  Logic get wbWe => output('dataBus_WE');
  Logic get wbAdr => output('dataBus_ADR');
  Logic get wbDatMosi => output('dataBus_DAT_MOSI');
  Logic get wbSel => output('dataBus_SEL');

  RiverMmu(
    Logic clk,
    Logic reset,
    Logic ifetchEn,
    Logic ifetchAddr,
    Logic dportEn,
    Logic dportAddr,
    Logic dportWe,
    Logic dportWdata,
    Logic dportSize,
    Logic wbAck,
    Logic wbDatMiso, {
    required this.mmuConfig,
    required this.busConfig,
    Logic? wbErr,
    Logic? satpMode,
    Logic? satpRoot,
    // Hypervisor two-stage: when [virtIn]=1 and [gMode]!=0, the (VS-stage)
    // page-table walk addresses, every PTE pointer and the final leaf, are
    // themselves G-translated through the hgatp table ([gMode]/[gRoot]) before
    // the host bus access. satpMode/satpRoot already carry vsatp when virt=1.
    Logic? virtIn,
    Logic? gMode,
    Logic? gRoot,
    Logic? privMode, // current effective privilege (for U-bit/SUM checks)
    Logic? sum, // mstatus.SUM (supervisor may access user pages)
    Logic? mxr, // mstatus.MXR (loads may read execute-only pages)
    // When true, instruction fetches below machine mode are translated through
    // the page table (X-permission + U-bit fetch rule, faulting to ifetch_fault).
    // Defaults off until the fetch consumer wires ifetch_fault to cause 12.
    bool translateFetch = false,
    // Pulsed when the core executes sfence.vma (or fence.i, which over-flushes
    // harmlessly): invalidates the single-entry fetch TLB so a page-table edit
    // that does not change satp is observed by the next fetch.
    Logic? tlbFlush,
    // Sticky user-mode excursion probe (see the `probe` output). Off by
    // default: when false NOTHING below elaborates, so the emitted RTL is byte
    // identical to a build that never had the option. Turn it on only to answer
    // "does this core ever enter user mode" on real hardware.
    bool userProbe = false,
    // DTLBFC (rpipelinectl[3]): when high, also flush the data TLB on every
    // privilege-mode change (satp changes already flush). Closes the data-TLB
    // residue channel across context switches for paranoid configs.
    Logic? dtlbFlushOnPrivChange,
    super.name = 'river_mmu',
  }) {
    final xlen = mmuConfig.mxlen.size;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    ifetchEn = addInput('ifetch_en', ifetchEn);
    ifetchAddr = addInput('ifetch_addr', ifetchAddr, width: xlen);
    dportEn = addInput('dport_en', dportEn);
    dportAddr = addInput('dport_addr', dportAddr, width: xlen);
    dportWe = addInput('dport_we', dportWe);
    dportWdata = addInput('dport_wdata', dportWdata, width: xlen);
    dportSize = addInput('dport_size', dportSize, width: 3);
    wbAck = addInput('dataBus_ACK', wbAck);
    wbErr = addInput('dataBus_ERR', wbErr ?? Const(0));
    wbDatMiso = addInput(
      'dataBus_DAT_MISO',
      wbDatMiso,
      width: busConfig.dataWidth,
    );

    // satp.MODE (0=bare, 8=Sv39, 9=Sv48) and root PPN. When wired and MODE!=0,
    // data accesses are translated by walking the page table over the bus.
    final hasPaging = satpMode != null && satpRoot != null;
    satpMode = hasPaging ? addInput('satp_mode', satpMode, width: 4) : null;
    satpRoot = hasPaging ? addInput('satp_root', satpRoot, width: xlen) : null;

    // Two-stage (hypervisor G-stage) wiring is present only when all three are
    // provided AND single-stage paging exists to build on.
    final hasTwoStage =
        hasPaging && virtIn != null && gMode != null && gRoot != null;
    virtIn = hasTwoStage ? addInput('virt', virtIn) : null;
    gMode = hasTwoStage ? addInput('g_mode', gMode, width: 4) : null;
    gRoot = hasTwoStage ? addInput('g_root', gRoot, width: xlen) : null;

    // Privilege/permission inputs for leaf checks (U-bit, SUM, MXR). When not
    // wired, the leaf check falls back to R/W only (the pre-existing behavior).
    final priv = privMode == null ? null : addInput('priv', privMode, width: 3);
    final sumIn = sum == null ? null : addInput('sum', sum);
    final mxrIn = mxr == null ? null : addInput('mxr', mxr);
    final tlbFlushIn = tlbFlush == null
        ? Const(0)
        : addInput('tlbFlush', tlbFlush);
    final dtlbFlushOnPrivIn = dtlbFlushOnPrivChange == null
        ? Const(0)
        : addInput('dtlbFlushOnPriv', dtlbFlushOnPrivChange);

    addOutput('ifetch_done');
    addOutput('ifetch_valid');
    addOutput('ifetch_rdata', width: xlen);
    addOutput('dport_done');
    addOutput('dport_valid');
    addOutput('dport_rdata', width: xlen);
    addOutput('dport_fault');
    // 1 when the dport fault occurred in the G-stage (second-stage) walk, so the
    // consumer can raise a *guest* page-fault cause (20/21/23) vs the regular
    // VS-stage cause (12/13/15).
    addOutput('dport_fault_guest');
    // Asserted with ifetch_done & ~ifetch_valid when an instruction-fetch walk
    // faults (invalid PTE, no X permission, or a U-bit violation). Lets the
    // fetch consumer raise an instruction page fault (cause 12).
    addOutput('ifetch_fault');
    addOutput('dataBus_CYC');
    addOutput('dataBus_STB');
    addOutput('dataBus_WE');
    addOutput('dataBus_ADR', width: busConfig.addressWidth);
    addOutput('dataBus_DAT_MOSI', width: busConfig.dataWidth);
    addOutput('dataBus_SEL', width: busConfig.effectiveSelWidth);

    // Internal registers
    final arbState = Logic(name: 'arbState', width: 2);
    final busActive = Logic(name: 'busActive');
    // Set for one cycle after a transaction completes so arbitration pauses,
    // letting the requester (e.g. the fetch unit redirecting to a straddle's
    // second word) present its next address before the next grant. Without it
    // the arbiter would re-grant the stale address the moment the bus frees.
    final justCompleted = Logic(name: 'justCompleted');

    final ifDoneR = Logic(name: 'ifDoneR');
    final ifValidR = Logic(name: 'ifValidR');
    final ifRdataR = Logic(name: 'ifRdataR', width: xlen);
    final dpDoneR = Logic(name: 'dpDoneR');
    final dpValidR = Logic(name: 'dpValidR');
    final dpRdataR = Logic(name: 'dpRdataR', width: xlen);
    // Asserted with dpDone & ~dpValid when a page-table walk faults (invalid PTE
    // or leaf-permission violation). Lets the dport consumer raise a *page*
    // fault rather than the generic access fault.
    final dpFaultR = Logic(name: 'dpFaultR');
    final dpFaultGuestR = Logic(name: 'dpFaultGuestR');
    // Asserted when a walk faults for an instruction fetch (routes the fault to
    // ifetch_fault instead of dport_fault).
    final ifFaultR = Logic(name: 'ifFaultR');
    final cycR = Logic(name: 'cycR');
    final stbR = Logic(name: 'stbR');
    final weR = Logic(name: 'weR');
    final adrR = Logic(name: 'adrR', width: busConfig.addressWidth);
    final datMosiR = Logic(name: 'datMosiR', width: busConfig.dataWidth);
    final selR = Logic(name: 'selR', width: busConfig.effectiveSelWidth);

    final selW = busConfig.effectiveSelWidth;

    // Page-table-walk state (only used when hasPaging). `walking` = the bus is
    // fetching PTEs (vs the final translated access); walkLevel counts down from
    // levels-1; the original dport request is held in req*.
    final walking = Logic(name: 'walking');
    final walkLevel = Logic(name: 'walkLevel', width: 3);
    final reqAddr = Logic(name: 'reqAddr', width: xlen);
    final reqWe = Logic(name: 'reqWe');
    final reqWdata = Logic(name: 'reqWdata', width: xlen);
    final reqSize = Logic(name: 'reqSize', width: 3);
    // Privilege state LATCHED with the walk request. The leaf permission check
    // at the end of a walk must judge the access by the privilege the requester
    // held when the MMU accepted the request, not by the privilege in effect
    // many cycles later when the leaf comes back. A trap or an xRET between the
    // two moved the mode under the walk, and the U-bit rule then denied a
    // supervisor page to the new (user) mode: a valid, executable page raised an
    // instruction page fault. SUM and MXR move with the same commit, so latch
    // them together.
    final reqPriv = Logic(name: 'reqPriv', width: 3);
    final reqSum = Logic(name: 'reqSum');
    final reqMxr = Logic(name: 'reqMxr');
    // Each bus access of the walk is its own Wishbone transaction (cyc/stb drop
    // between accesses, mirroring the single-access path). walkArmed = an access
    // address is queued; walkAddr = that address; armed accesses are launched by
    // a dedicated branch once the bus has gone idle.
    final walkArmed = Logic(name: 'walkArmed');
    final walkAddr = Logic(name: 'walkAddr', width: busConfig.addressWidth);
    // 1 while the active walk is for an instruction fetch (access type = instr),
    // so leaf-permission checks use the X bit and the fetch U-bit rule, and a
    // fault/result routes to the ifetch ports rather than the dport ports.
    final isFetchWalk = Logic(name: 'isFetchWalk');
    // Svadu hardware A/D update: after a leaf read whose A (or, for a write, D)
    // bit needs setting, the walk writes the updated PTE back to memory (an extra
    // bus transaction) before the translated access. `adWrite` is 1 while that
    // writeback is in flight; `adTransPa` stashes the translated PA to resume.
    final adWrite = Logic(name: 'adWrite');
    final adTransPa = Logic(name: 'adTransPa', width: busConfig.addressWidth);

    // Single-entry instruction-fetch TLB. Caches the last walked fetch
    // translation so the lockstep front-end (which re-presents the same
    // instruction each cycle) does not re-walk per fetch and starve the data
    // port. `ftlbPte` holds the leaf so the permission check re-runs per access
    // (priv may change). Invalidated on satp change.
    final ftlbValid = Logic(name: 'ftlbValid');
    final ftlbVpn = Logic(name: 'ftlbVpn', width: xlen - 12);
    final ftlbPte = Logic(name: 'ftlbPte', width: xlen);
    // Leaf level of the cached fetch translation, so a hit composes the physical
    // address with the right superpage offset.
    final ftlbLevel = Logic(name: 'ftlbLevel', width: 3);
    // Single-entry data TLB (mirrors the fetch TLB). `dtlbPte` holds the leaf so
    // R/W/U re-checks per access. Single-stage only: guest (two-stage) accesses
    // always walk (the cached leaf would be guest-physical). Flushed with ftlb.
    final dtlbValid = Logic(name: 'dtlbValid');
    final dtlbVpn = Logic(name: 'dtlbVpn', width: xlen - 12);
    final dtlbPte = Logic(name: 'dtlbPte', width: xlen);
    // Leaf level of the cached data translation (see ftlbLevel).
    final dtlbLevel = Logic(name: 'dtlbLevel', width: 3);
    final satpShadowMode = Logic(name: 'satpShadowMode', width: 4);
    final satpShadowRoot = Logic(name: 'satpShadowRoot', width: xlen);
    // Shadow of the privilege mode, to detect a context switch for DTLBFC.
    final privShadow = Logic(name: 'privShadow', width: 3);
    final privChanged = priv == null
        ? Const(0)
        : priv.neq(privShadow).named('privChanged');

    // G-stage (hypervisor second-stage) walk state. Under two-stage, every
    // VS-stage bus address (`walkAddr`) is guest-physical and must be G-walked
    // through hgatp before launch. `gTranslated` marks `walkAddr` as already
    // host-physical (launch directly). `gWalking`/`gWalkLevel`/`gWalkArmed`/
    // `gWalkAddr` mirror the VS-walk state for the inner G walk; `gReqAddr` holds
    // the guest-physical being translated; `gSave*` preserve the VS access's
    // we/data/sel across the G sub-walk so the final store re-launches.
    final gWalking = Logic(name: 'gWalking');
    final gWalkLevel = Logic(name: 'gWalkLevel', width: 3);
    final gWalkArmed = Logic(name: 'gWalkArmed');
    final gWalkAddr = Logic(name: 'gWalkAddr', width: busConfig.addressWidth);
    final gReqAddr = Logic(name: 'gReqAddr', width: xlen);
    final gTranslated = Logic(name: 'gTranslated');
    final gSaveWe = Logic(name: 'gSaveWe');
    final gSaveData = Logic(name: 'gSaveData', width: xlen);
    final gSaveSel = Logic(name: 'gSaveSel', width: selW);

    // VPN[level] (9 bits): bits [12 + 9*level +: 9]. Each level's field is a
    // fixed slice (L0=[20:12], L1=[29:21], L2=[38:30], L3=[47:39]), so select
    // with a small 4:1 mux instead of a 64-bit variable barrel shift (big LUT
    // saving).
    Logic vpnOf(Logic addr, Logic level) {
      Logic field(int lvl) => addr.slice(12 + 9 * lvl + 8, 12 + 9 * lvl);
      return mux(
        level.eq(0),
        field(0),
        mux(level.eq(1), field(1), mux(level.eq(2), field(2), field(3))),
      );
    }

    // PTE fields (Sv39/Sv48, 8-byte PTE in the low bus word): V=bit0, R=bit1,
    // X=bit3, PPN=bits 53:10. Next page-table base = PPN<<12.
    Logic pteLeaf(Logic pte) => pte[1] | pte[3];
    // Page-fault conditions (V=bit0, R=bit1, W=bit2). A PTE is invalid if V=0
    // or the reserved encoding W&&!R. At a leaf, the access is denied if a write
    // (reqWe) hits a non-writable page or a read hits a non-readable one.
    Logic pteInvalid(Logic pte) => ~pte[0] | (~pte[1] & pte[2]);
    // Leaf permission fault: the requested access must be allowed by the PTE.
    // A fetch (isFetch) needs the X bit; a write needs W; a read needs R, or X
    // when MXR lets a load read an execute-only page. The U bit must also fit the
    // privilege: a user access needs U=1, and a supervisor access to a user page
    // needs SUM, except a supervisor FETCH from a user page is never allowed
    // (SUM does not cover instruction fetch). M-mode and unwired priv fall back
    // to the R/W/X check only.
    // [atPriv]/[atSum]/[atMxr] name the privilege state the access was MADE at.
    // A TLB hit is checked at the cycle the request is granted, so it leaves
    // them null and the live inputs apply. A walk finishes cycles later, so it
    // passes the values latched with the request.
    Logic leafPermFault(
      Logic pte,
      Logic isFetch,
      Logic we, {
      Logic? atPriv,
      Logic? atSum,
      Logic? atMxr,
    }) {
      final mxrEff = atMxr ?? mxrIn ?? Const(0);
      final dataPerm = mux(
        we,
        pte[2], // write -> W
        pte[1] | (mxrEff & pte[3]), // read -> R | (MXR & X)
      );
      final permOk = mux(isFetch, pte[3], dataPerm); // fetch -> X
      final privEff = atPriv ?? priv;
      if (privEff == null) return ~permOk;
      final isUser = privEff.eq(Const(PrivilegeMode.user.id, width: 3));
      final isSup = privEff.eq(Const(PrivilegeMode.supervisor.id, width: 3));
      final u = pte[4];
      // SUM only relaxes supervisor data access to user pages, not fetches.
      final supUserOk = (atSum ?? sumIn ?? Const(0)) & ~isFetch;
      final uFault = (isUser & ~u) | (isSup & u & ~supUserOk);
      return ~permOk | uFault;
    }

    Logic pteNextBase(Logic pte) => (pte.slice(53, 10) << 12).zeroExtend(xlen);
    // Translated physical address for a leaf at `level`. A leaf above level 0 is
    // a superpage, so the low VPN fields come from the virtual address, not the
    // PTE PPN: level 1 (2MB) keeps vaddr[20:0], level 2 (1GB) vaddr[29:0], level
    // 3 (512GB, Sv48) vaddr[38:0]. Taking only vaddr[11:0] for every level would
    // alias all sub-pages of a superpage to its base.
    Logic leafPa(Logic pte, Logic vaddr, Logic level) {
      final ppn = pte.slice(53, 10); // 44-bit PPN
      // {ppn[43:hi], vaddr[lo:0]}: hi is the first PPN bit kept from the PTE, lo
      // is the top virtual bit taken from vaddr. Each pairing sums to 56 bits.
      Logic compose(int hi, int lo) =>
          [ppn.slice(43, hi), vaddr.slice(lo, 0)].swizzle().zeroExtend(xlen);
      return mux(
        level.eq(0),
        compose(0, 11),
        mux(
          level.eq(1),
          compose(9, 20),
          mux(level.eq(2), compose(18, 29), compose(27, 38)),
        ),
      );
    }

    // First-level (root) PTE byte address.
    Logic ptePtr(Logic base, Logic vpn) => base + (vpn.zeroExtend(xlen) << 3);
    final fullSel = Const((1 << selW) - 1, width: selW);
    // Byte-enable mask for a log2-sized access, unshifted (lane 0); the lane
    // shift happens at the bus boundary. Mask covers (1 << size) bytes:
    // byte=0b1, half=0b11, word=0b1111.
    Logic sizeSel(Logic log2Size) => mux(
      log2Size.eq(0),
      Const(0x1, width: selW),
      mux(
        log2Size.eq(1),
        Const(0x3, width: selW),
        mux(log2Size.eq(2), Const(0xF, width: selW), fullSel),
      ),
    );
    // Levels-1 start index: Sv48 (MODE 9) = 3, else (Sv39) = 2. When the MMU has
    // no Sv48, satp.MODE can never be 9, so pin startLevel to 2 and drop the
    // satpMode==9 compare + Sv48 level (shrinks Sv39-only cores).
    final hasSv48 = mmuConfig.pagingModes.contains(RiscVPagingMode.sv48);
    final startLevel = (hasPaging && hasSv48)
        ? mux(satpMode!.eq(9), Const(3, width: 3), Const(2, width: 3))
        : Const(2, width: 3);
    final rootBase = hasPaging
        ? (satpRoot! << 12).zeroExtend(xlen)
        : Const(0, width: xlen);
    final pagingOn = hasPaging ? satpMode!.neq(0) : Const(0);
    // Fetch is translated only when paging is on AND below machine mode (MPRV
    // only affects loads/stores, never fetch). When priv is unwired, fall back
    // to pagingOn. Also bypassed in virtualized mode: a guest fetch needs
    // two-stage (VS + G) translation, which the fetch path does not do yet.
    final fetchPagingOn = priv == null
        ? pagingOn
        : (pagingOn &
              priv.neq(Const(PrivilegeMode.machine.id, width: 3)) &
              (virtIn == null ? Const(1) : ~virtIn));

    // Data (load/store) translation is ALSO off in machine mode. River does not
    // implement mstatus.MPRV, so the effective data privilege is just the
    // current privilege: an M-mode load/store is always physical. Without this
    // gate, once supervisor enables paging (satp.MODE != 0) an M-mode access
    // (e.g. the SBI firmware restoring its own stack in a trap handler) would be
    // walked through the SUPERVISOR page tables - its physical address is not a
    // valid supervisor VA, so the walk faults or the bus access never returns
    // and the core hangs. The one M-mode exception is an explicit virtualized
    // access (HLV/HSV): those carry [virtIn] and must translate through the
    // guest tables regardless of the current privilege, so OR virtIn back in.
    final dataPagingOn = priv == null
        ? pagingOn
        : (pagingOn &
              (priv.neq(Const(PrivilegeMode.machine.id, width: 3)) |
                  (virtIn ?? Const(0))));

    // Fetch-TLB lookup for the requested fetch address.
    final satpChanged = hasPaging
        ? (satpMode!.neq(satpShadowMode) | satpRoot!.neq(satpShadowRoot))
        : Const(0);
    // Gated on hasPaging: leafPa/leafPermFault assume an Sv39/Sv48 (64-bit) PTE
    // layout, so they must not elaborate for non-paging (e.g. RV32) configs.
    final ftlbHit = hasPaging
        ? (ftlbValid &
              ~satpChanged &
              ifetchAddr.slice(xlen - 1, 12).eq(ftlbVpn))
        : Const(0);
    // Re-run the fetch permission check on the cached leaf (priv may have moved)
    // and compute the translated physical address from the cached PTE.
    final ftlbPermFault = hasPaging
        ? leafPermFault(ftlbPte, Const(1), Const(0))
        : Const(0);
    final ftlbPa = hasPaging
        ? leafPa(ftlbPte, ifetchAddr, ftlbLevel)
        : Const(0, width: xlen);

    // G-stage derived signals. twoStage = guest mode with a non-bare G-stage.
    // gRootBase/gStartLevel = hgatp root and top level. NOTE: the Sv39x4 "+2
    // bits at the root index" widening is not applied yet, fine while
    // guest-physical addresses stay in the low 2^(9*levels+12) range.
    final twoStage = hasTwoStage ? (virtIn! & gMode!.neq(0)) : Const(0);
    final gRootBase = hasTwoStage
        ? (gRoot! << 12).zeroExtend(xlen)
        : Const(0, width: xlen);
    final gStartLevel = hasTwoStage
        ? mux(gMode!.eq(9), Const(3, width: 3), Const(2, width: 3))
        : Const(2, width: 3);

    // Data-TLB lookup for the requested data address. Disabled under two-stage
    // (guest) translation: the cached leaf would be guest-physical, so always
    // walk in that case. Mirrors the fetch-TLB combinational lookup above.
    final dtlbUsable = hasTwoStage ? ~twoStage : Const(1);
    final dtlbHit = hasPaging
        ? (dtlbValid &
              ~satpChanged &
              dtlbUsable &
              // A write to a page cached not-yet-dirty (D=0, bit 7) must re-walk
              // so the Svadu writeback sets the D bit; reads always hit (A is
              // already set on the cached leaf).
              ~(dportWe & ~dtlbPte[7]) &
              dportAddr.slice(xlen - 1, 12).eq(dtlbVpn))
        : Const(0);
    final dtlbPermFault = hasPaging
        ? leafPermFault(dtlbPte, Const(0), dportWe)
        : Const(0);
    // Svadu hardware A/D update (single-stage only; two-stage A/D is deferred).
    // After a leaf read, set A (bit 6) and, for a write, D (bit 7); if the bit
    // was not already set, write the updated PTE back before the access.
    final adABit = Const(1, width: xlen) << 6;
    final adDBit = Const(1, width: xlen) << 7;
    final pteWithAd = hasPaging
        ? wbDatMiso | adABit | mux(reqWe, adDBit, Const(0, width: xlen))
        : Const(0, width: xlen);
    final adDoWrite = hasPaging
        ? ((~wbDatMiso[6] | (reqWe & ~wbDatMiso[7])) & dtlbUsable)
        : Const(0);
    final dtlbPa = hasPaging
        ? leafPa(dtlbPte, dportAddr, dtlbLevel)
        : Const(0, width: xlen);

    // A transfer ends on ONE acknowledge. Every branch below that consumes an
    // ACK is qualified by cycR, the registered CYC the MMU is driving, so an
    // acknowledge that arrives when the MMU owns no transaction is ignored.
    // Without this, a slave that held ACK for a second cycle (after the MMU had
    // already dropped CYC) was read as the NEXT page-table entry: the walk
    // descended a level on a PTE it had already consumed, read a table entry
    // that belongs to no part of the translation, found it empty, and raised an
    // instruction page fault on a valid executable page. The Harbor register
    // slice pulses ACK for one cycle, so the shipped fabric never did this, but
    // the FSM must not depend on that. cycR and stbR are always written
    // together, so cycR alone names a live transaction and costs one AND term.
    // ERR is terminal even for slaves that assert ACK and ERR together.
    final ackLive = (cycR & wbAck & ~wbErr).named('ackLive');
    final errLive = (cycR & wbErr).named('errLive');

    Sequential(clk, [
      If(
        reset,
        then: [
          arbState < 0,
          busActive < 0,
          justCompleted < 0,
          ifDoneR < 0,
          ifValidR < 0,
          ifRdataR < 0,
          dpDoneR < 0,
          dpValidR < 0,
          dpRdataR < 0,
          dpFaultR < 0,
          dpFaultGuestR < 0,
          ifFaultR < 0,
          isFetchWalk < 0,
          adWrite < 0,
          adTransPa < 0,
          ftlbValid < 0,
          ftlbVpn < 0,
          dtlbValid < 0,
          dtlbVpn < 0,
          dtlbPte < 0,
          ftlbPte < 0,
          ftlbLevel < 0,
          dtlbLevel < 0,
          satpShadowMode < 0,
          satpShadowRoot < 0,
          privShadow < 0,
          cycR < 0,
          stbR < 0,
          weR < 0,
          adrR < 0,
          datMosiR < 0,
          selR < 0,
          walking < 0,
          walkArmed < 0,
          walkAddr < 0,
          walkLevel < 0,
          reqAddr < 0,
          reqWe < 0,
          reqWdata < 0,
          reqSize < 0,
          reqPriv < 0,
          reqSum < 0,
          reqMxr < 0,
          if (hasTwoStage) ...[
            gWalking < 0,
            gWalkArmed < 0,
            gWalkAddr < 0,
            gWalkLevel < 0,
            gReqAddr < 0,
            gTranslated < 0,
            gSaveWe < 0,
            gSaveData < 0,
            gSaveSel < 0,
          ],
        ],
        orElse: [
          ifDoneR < 0,
          ifValidR < 0,
          dpDoneR < 0,
          dpValidR < 0,
          dpFaultR < 0,
          dpFaultGuestR < 0,
          ifFaultR < 0,
          justCompleted < 0,
          privShadow < (priv ?? Const(0, width: 3)),
          // Track satp so the fetch-TLB self-invalidates when it changes, and
          // flush it on sfence.vma (tlbFlushIn).
          if (hasPaging) ...[
            satpShadowMode < satpMode!,
            satpShadowRoot < satpRoot!,
            If(satpChanged | tlbFlushIn, then: [ftlbValid < 0, dtlbValid < 0]),
            // DTLBFC: also drop the data TLB on a privilege-mode change (satp
            // changes already flushed above) so a cached translation never
            // survives a context switch on a paranoid config.
            If(dtlbFlushOnPrivIn & privChanged, then: [dtlbValid < 0]),
          ],

          If.block([
            // A physical bus error terminates the ORIGINAL access, including
            // errors reading PTEs or writing A/D bits. Leave the page/guest
            // fault flags clear: done & !valid & !fault denotes an access fault.
            Iff(busActive & errLive, [
              cycR < 0,
              stbR < 0,
              busActive < 0,
              justCompleted < 1,
              dpDoneR < arbState.eq(1),
              ifDoneR < arbState.eq(2),
              dpRdataR < 0,
              ifRdataR < 0,
              arbState < 0,
              if (hasPaging) ...[
                walking < 0,
                walkArmed < 0,
                adWrite < 0,
                ftlbValid < 0,
                dtlbValid < 0,
              ],
              if (hasTwoStage) ...[
                gWalking < 0,
                gWalkArmed < 0,
                gTranslated < 0,
              ],
            ]),
            // G-stage (second-stage) PTE returned. (checked first: during a
            // G sub-walk both gWalking and walking may be set). Resolves the
            // host-physical address for the pending VS access, then resumes it.
            if (hasTwoStage)
              Iff(busActive & ackLive & gWalking, [
                cycR < 0,
                stbR < 0,
                If.block([
                  // Invalid G-PTE -> guest page fault.
                  Iff(pteInvalid(wbDatMiso), [
                    gWalking < 0,
                    gWalkArmed < 0,
                    walking < 0,
                    walkArmed < 0,
                    busActive < 0,
                    justCompleted < 1,
                    dpDoneR < 1,
                    dpValidR < 0,
                    dpFaultR < 1,
                    dpFaultGuestR < 1,
                    arbState < 0,
                  ]),
                  // G leaf. Every G-stage leaf page must be user-accessible
                  // (PTE.U=bit4), a non-U G-leaf is a guest page fault. When
                  // OK, walkAddr is now host-physical; re-arm the VS access
                  // (gTranslated=1 makes the launch fire directly) and restore
                  // its original write controls.
                  Iff(pteLeaf(wbDatMiso), [
                    If(
                      ~wbDatMiso[4],
                      then: [
                        gWalking < 0,
                        gWalkArmed < 0,
                        walking < 0,
                        walkArmed < 0,
                        busActive < 0,
                        justCompleted < 1,
                        dpDoneR < 1,
                        dpValidR < 0,
                        dpFaultR < 1,
                        dpFaultGuestR < 1,
                        arbState < 0,
                      ],
                      orElse: [
                        gWalking < 0,
                        gTranslated < 1,
                        walkArmed < 1,
                        walkAddr < leafPa(wbDatMiso, gReqAddr, gWalkLevel),
                        weR < gSaveWe,
                        datMosiR < gSaveData,
                        selR < gSaveSel,
                      ],
                    ),
                  ]),
                  // No leaf at the last level -> guest page fault.
                  Iff(~gWalkLevel.or(), [
                    gWalking < 0,
                    gWalkArmed < 0,
                    walking < 0,
                    walkArmed < 0,
                    busActive < 0,
                    justCompleted < 1,
                    dpDoneR < 1,
                    dpValidR < 0,
                    dpFaultR < 1,
                    dpFaultGuestR < 1,
                    arbState < 0,
                  ]),
                  // Pointer G-PTE -> descend.
                  Iff(Const(1), [
                    gWalkLevel < (gWalkLevel - 1),
                    gWalkArmed < 1,
                    gWalkAddr <
                        ptePtr(
                          pteNextBase(wbDatMiso),
                          vpnOf(gReqAddr, gWalkLevel - 1),
                        ),
                  ]),
                ]),
              ]),

            // Page-table walk: a PTE just came back.
            if (hasPaging)
              Iff(busActive & ackLive & walking & ~(hasTwoStage ? gWalking : Const(0)), [
                // End this PTE's transaction.
                cycR < 0,
                stbR < 0,
                If.block([
                  // Invalid PTE (V=0 or reserved W&&!R) -> page fault.
                  Iff(pteInvalid(wbDatMiso), [
                    walking < 0,
                    walkArmed < 0,
                    busActive < 0,
                    justCompleted < 1,
                    dpDoneR < ~isFetchWalk,
                    dpValidR < 0,
                    dpFaultR < ~isFetchWalk,
                    ifDoneR < isFetchWalk,
                    ifValidR < 0,
                    ifFaultR < isFetchWalk,
                    arbState < 0,
                  ]),
                  // Leaf PTE.
                  Iff(pteLeaf(wbDatMiso), [
                    If(
                      leafPermFault(
                        wbDatMiso,
                        isFetchWalk,
                        reqWe,
                        atPriv: priv == null ? null : reqPriv,
                        atSum: sumIn == null ? null : reqSum,
                        atMxr: mxrIn == null ? null : reqMxr,
                      ),
                      then: [
                        // Permission violation -> page fault.
                        walking < 0,
                        walkArmed < 0,
                        busActive < 0,
                        justCompleted < 1,
                        dpDoneR < ~isFetchWalk,
                        dpValidR < 0,
                        dpFaultR < ~isFetchWalk,
                        ifDoneR < isFetchWalk,
                        ifValidR < 0,
                        ifFaultR < isFetchWalk,
                        arbState < 0,
                      ],
                      orElse: [
                        // Arm the final translated access (guest-physical when
                        // two-stage: gTranslated<0 makes it G-translate first).
                        // Cache the walked leaf so a same-page re-access skips
                        // the walk (4KB leaves only). Fetch leaf -> ftlb, data
                        // leaf -> dtlb (single-stage only, dtlbUsable gates out
                        // guest leaves). Cache the A/D-updated leaf so a hit
                        // reflects the post-Svadu state.
                        If(
                          isFetchWalk,
                          then: [
                            ftlbValid < 1,
                            ftlbVpn < reqAddr.slice(xlen - 1, 12),
                            ftlbPte < pteWithAd,
                            ftlbLevel < walkLevel,
                          ],
                          orElse: [
                            If(
                              dtlbUsable,
                              then: [
                                dtlbValid < 1,
                                dtlbVpn < reqAddr.slice(xlen - 1, 12),
                                dtlbPte < pteWithAd,
                                dtlbLevel < walkLevel,
                              ],
                            ),
                          ],
                        ),
                        walking < 0,
                        If(
                          adDoWrite,
                          then: [
                            // Svadu: write the updated PTE (A, and D on a write)
                            // back to its address (walkAddr still holds the PTE
                            // pointer), then resume with the translated access.
                            adWrite < 1,
                            adTransPa < leafPa(wbDatMiso, reqAddr, walkLevel),
                            walkArmed < 1,
                            weR < 1,
                            datMosiR < pteWithAd,
                            selR < fullSel,
                          ],
                          orElse: [
                            // A/D already set: arm the translated access directly.
                            walkArmed < 1,
                            walkAddr < leafPa(wbDatMiso, reqAddr, walkLevel),
                            weR < reqWe,
                            datMosiR < reqWdata,
                            // A fetch reads a full word; a dport uses its size.
                            selR < mux(isFetchWalk, fullSel, sizeSel(reqSize)),
                            if (hasTwoStage) gTranslated < 0,
                          ],
                        ),
                      ],
                    ),
                  ]),
                  // Non-leaf at the last level (no leaf found) -> page fault.
                  Iff(~walkLevel.or(), [
                    walking < 0,
                    walkArmed < 0,
                    busActive < 0,
                    justCompleted < 1,
                    dpDoneR < ~isFetchWalk,
                    dpValidR < 0,
                    dpFaultR < ~isFetchWalk,
                    ifDoneR < isFetchWalk,
                    ifValidR < 0,
                    ifFaultR < isFetchWalk,
                    arbState < 0,
                  ]),
                  // Pointer PTE, descend to the next level.
                  Iff(Const(1), [
                    walkLevel < (walkLevel - 1),
                    walkArmed < 1,
                    walkAddr <
                        ptePtr(
                          pteNextBase(wbDatMiso),
                          vpnOf(reqAddr, walkLevel - 1),
                        ),
                    weR < 0,
                    datMosiR < 0,
                    selR < fullSel,
                    if (hasTwoStage) gTranslated < 0,
                  ]),
                ]),
              ]),

            // Svadu A/D PTE writeback completed: resume with the access.
            if (hasPaging)
              Iff(busActive & ackLive & adWrite, [
                cycR < 0,
                stbR < 0,
                adWrite < 0,
                walkArmed < 1,
                walkAddr < adTransPa,
                weR < reqWe,
                datMosiR < reqWdata,
                selR < mux(isFetchWalk, fullSel, sizeSel(reqSize)),
                if (hasTwoStage) gTranslated < 0,
              ]),

            // ACK received, complete the (non-walk) transaction.
            if (hasPaging)
              Iff(busActive & ackLive & ~walking & ~adWrite, [
                cycR < 0,
                stbR < 0,
                busActive < 0,
                justCompleted < 1,
                If(
                  arbState.eq(1),
                  then: [
                    // Wishbone byte-lane convention: a sub-word load reads an
                    // aligned word with the addressed byte in its lane, so shift
                    // it back to lane 0 (mirrors the write path's lane shift);
                    // else e.g. `lbu` at byte offset 5 reads the wrong byte.
                    // Ifetch stays unshifted (the fetch unit extracts its own).
                    dpRdataR <
                        (wbDatMiso >>
                            [
                              adrR.getRange(
                                0,
                                (busConfig.effectiveSelWidth - 1).bitLength,
                              ),
                              Const(0, width: 3),
                            ].swizzle()),
                    dpDoneR < 1,
                    dpValidR < 1,
                  ],
                ),
                If(
                  arbState.eq(2),
                  then: [ifRdataR < wbDatMiso, ifDoneR < 1, ifValidR < 1],
                ),
                arbState < 0,
              ])
            else
              Iff(busActive & ackLive, [
                cycR < 0,
                stbR < 0,
                busActive < 0,
                justCompleted < 1,
                If(
                  arbState.eq(1),
                  then: [
                    // Wishbone byte-lane convention: a sub-word load reads an
                    // aligned word with the addressed byte in its lane, so shift
                    // it back to lane 0 (mirrors the write path's lane shift);
                    // else e.g. `lbu` at byte offset 5 reads the wrong byte.
                    // Ifetch stays unshifted (the fetch unit extracts its own).
                    dpRdataR <
                        (wbDatMiso >>
                            [
                              adrR.getRange(
                                0,
                                (busConfig.effectiveSelWidth - 1).bitLength,
                              ),
                              Const(0, width: 3),
                            ].swizzle()),
                    dpDoneR < 1,
                    dpValidR < 1,
                  ],
                ),
                If(
                  arbState.eq(2),
                  then: [ifRdataR < wbDatMiso, ifDoneR < 1, ifValidR < 1],
                ),
                arbState < 0,
              ]),

            // Launch an armed walk access once the bus is idle.
            // With two-stage active, the armed (guest-physical) address is first
            // diverted through a G-stage sub-walk; once gTranslated, it launches.
            if (hasPaging && hasTwoStage)
              Iff(busActive & walkArmed & ~cycR, [
                walkArmed < 0,
                If(
                  twoStage & ~gTranslated,
                  then: [
                    gSaveWe < weR,
                    gSaveData < datMosiR,
                    gSaveSel < selR,
                    gWalking < 1,
                    gWalkLevel < gStartLevel,
                    gReqAddr < walkAddr,
                    gWalkArmed < 1,
                    gWalkAddr < ptePtr(gRootBase, vpnOf(walkAddr, gStartLevel)),
                    weR < 0,
                    datMosiR < 0,
                    selR < fullSel,
                  ],
                  orElse: [cycR < 1, stbR < 1, adrR < walkAddr],
                ),
              ])
            else if (hasPaging)
              Iff(busActive & walkArmed & ~cycR, [
                walkArmed < 0,
                cycR < 1,
                stbR < 1,
                adrR < walkAddr,
              ]),

            // Launch an armed G-stage (second-stage) walk access.
            if (hasTwoStage)
              Iff(busActive & gWalkArmed & ~cycR, [
                gWalkArmed < 0,
                cycR < 1,
                stbR < 1,
                adrR < gWalkAddr,
                weR < 0,
                datMosiR < 0,
                selR < fullSel,
              ]),

            // Bus active, waiting
            Iff(busActive, []),

            // Idle, arbitrate (dport > ifetch); pause one cycle after a
            // completion so the requester can update its address first.
            Iff(~busActive & ~justCompleted & dportEn, [
              arbState < 1,
              busActive < 1,
              isFetchWalk < 0,
              if (hasPaging)
                If(
                  dataPagingOn,
                  then: [
                    If(
                      dtlbHit,
                      then: [
                        // Data-TLB hit: skip the walk. Re-check the permission on
                        // the cached leaf (priv/we may differ from when cached).
                        walking < 0,
                        If(
                          dtlbPermFault,
                          then: [
                            // Permission violation -> page fault.
                            busActive < 0,
                            justCompleted < 1,
                            dpDoneR < 1,
                            dpValidR < 0,
                            dpFaultR < 1,
                            arbState < 0,
                          ],
                          orElse: [
                            // Direct translated access at the cached PA.
                            cycR < 1,
                            stbR < 1,
                            adrR < dtlbPa,
                            weR < dportWe,
                            datMosiR < dportWdata,
                            selR < sizeSel(dportSize),
                          ],
                        ),
                      ],
                      orElse: [
                        // TLB miss: start the page-table walk. Latch the request
                        // and arm the root PTE fetch (launched next cycle).
                        walking < 1,
                        walkLevel < startLevel,
                        reqAddr < dportAddr,
                        reqWe < dportWe,
                        reqWdata < dportWdata,
                        reqSize < dportSize,
                        // Freeze the privilege state this access was made at,
                        // so the leaf check at the end of the walk judges the
                        // requester and not whoever is running by then.
                        reqPriv < (priv ?? Const(0, width: 3)),
                        reqSum < (sumIn ?? Const(0)),
                        reqMxr < (mxrIn ?? Const(0)),
                        walkArmed < 1,
                        walkAddr <
                            ptePtr(rootBase, vpnOf(dportAddr, startLevel)),
                        weR < 0,
                        datMosiR < 0,
                        selR < fullSel,
                        // The VS root pointer is guest-physical under two-stage.
                        if (hasTwoStage) gTranslated < 0,
                      ],
                    ),
                  ],
                  orElse: [
                    walking < 0,
                    cycR < 1,
                    stbR < 1,
                    adrR < dportAddr,
                    weR < dportWe,
                    datMosiR < dportWdata,
                    selR < sizeSel(dportSize),
                  ],
                )
              else ...[
                cycR < 1,
                stbR < 1,
                adrR < dportAddr,
                weR < dportWe,
                datMosiR < dportWdata,
                selR < sizeSel(dportSize),
              ],
            ]),

            Iff(~busActive & ~justCompleted & ~dportEn & ifetchEn, [
              arbState < 2,
              busActive < 1,
              if (hasPaging && translateFetch)
                If(
                  fetchPagingOn,
                  then: [
                    If(
                      ftlbHit,
                      then: [
                        // Fetch-TLB hit: skip the walk. Re-check the fetch
                        // permission on the cached leaf (priv may have changed).
                        If(
                          ftlbPermFault,
                          then: [
                            // Not fetchable now -> instruction page fault.
                            isFetchWalk < 0,
                            walking < 0,
                            busActive < 0,
                            justCompleted < 1,
                            ifDoneR < 1,
                            ifValidR < 0,
                            ifFaultR < 1,
                            arbState < 0,
                          ],
                          orElse: [
                            // Direct fetch at the cached physical address.
                            isFetchWalk < 0,
                            walking < 0,
                            cycR < 1,
                            stbR < 1,
                            adrR < ftlbPa,
                            weR < 0,
                            datMosiR < 0,
                            selR < fullSel,
                          ],
                        ),
                      ],
                      orElse: [
                        // TLB miss: walk the page table for ifetchAddr as an
                        // instruction access. isFetchWalk routes the X-permission
                        // check, the fault, and the result to the ifetch ports,
                        // and the leaf is cached for subsequent re-fetches.
                        isFetchWalk < 1,
                        walking < 1,
                        walkLevel < startLevel,
                        reqAddr < ifetchAddr,
                        reqWe < 0,
                        reqWdata < 0,
                        reqSize < Const(3, width: 3),
                        // See the data port above: the fetch is judged by the
                        // privilege it was requested at.
                        reqPriv < (priv ?? Const(0, width: 3)),
                        reqSum < (sumIn ?? Const(0)),
                        reqMxr < (mxrIn ?? Const(0)),
                        walkArmed < 1,
                        walkAddr <
                            ptePtr(rootBase, vpnOf(ifetchAddr, startLevel)),
                        weR < 0,
                        datMosiR < 0,
                        selR < fullSel,
                        if (hasTwoStage) gTranslated < 0,
                      ],
                    ),
                  ],
                  orElse: [
                    isFetchWalk < 0,
                    walking < 0,
                    cycR < 1,
                    stbR < 1,
                    adrR < ifetchAddr,
                    weR < 0,
                    datMosiR < 0,
                    selR < fullSel,
                  ],
                )
              else ...[
                cycR < 1,
                stbR < 1,
                adrR < ifetchAddr,
                weR < 0,
                datMosiR < 0,
                selR < fullSel,
              ],
            ]),
          ]),
        ],
      ),
    ]);

    // Sticky user-mode excursion probe.
    //
    // A privilege excursion into user mode is invisible after the fact: any
    // trap taken later is taken FROM supervisor, so sstatus.SPP reads 1 and the
    // excursion leaves no trace. It has to be caught while it happens. These
    // four bits set once and never clear, so a debugger can read them long
    // afterwards and learn what the core did.
    //
    //   bit 0  everUser       the core was in user mode at all
    //   bit 1  userWalk       it was in user mode while a page-table walk ran
    //   bit 2  latchMismatch  a walk accepted in user mode returned its leaf
    //                         while the core was no longer in user mode. This
    //                         is the EXACT condition under which the
    //                         grant-time privilege latch judges an access
    //                         differently from the live-privilege check it
    //                         replaced.
    //   bit 3  userFault      such a walk actually raised a page fault
    //
    // It is a SEPARATE sequential block on purpose: it adds no input to the
    // walk FSM's condition cone, so it cannot slow down the logic it measures.
    if (userProbe && hasPaging && priv != null) {
      final userId = Const(PrivilegeMode.user.id, width: 3);
      final everUser = Logic(name: 'probeEverUser');
      final userWalk = Logic(name: 'probeUserWalk');
      final latchMismatch = Logic(name: 'probeLatchMismatch');
      final userFault = Logic(name: 'probeUserFault');

      final leafNow = (busActive & ackLive & walking & pteLeaf(wbDatMiso))
          .named('probeLeafNow');
      final acceptedInUser = (leafNow & reqPriv.eq(userId)).named(
        'probeAcceptedInUser',
      );

      addOutput('probe', width: 4);
      Sequential(clk, [
        If(
          reset,
          then: [everUser < 0, userWalk < 0, latchMismatch < 0, userFault < 0],
          orElse: [
            If(priv.eq(userId), then: [everUser < 1]),
            If(priv.eq(userId) & walking, then: [userWalk < 1]),
            If(acceptedInUser & priv.neq(userId), then: [latchMismatch < 1]),
            If(
              acceptedInUser &
                  leafPermFault(
                    wbDatMiso,
                    isFetchWalk,
                    reqWe,
                    atPriv: reqPriv,
                    atSum: reqSum,
                    atMxr: reqMxr,
                  ),
              then: [userFault < 1],
            ),
          ],
        ),
      ]);
      output('probe') <=
          [userFault, latchMismatch, userWalk, everUser].swizzle();
    }

    // Drive outputs from registers
    ifetchDone <= ifDoneR;
    ifetchValid <= ifValidR;
    ifetchRdata <= ifRdataR;
    dportDone <= dpDoneR;
    dportValid <= dpValidR;
    dportRdata <= dpRdataR;
    dportFault <= dpFaultR;
    ifetchFault <= ifFaultR;
    dportFaultGuest <= dpFaultGuestR;
    wbCyc <= cycR;
    wbStb <= stbR;
    wbWe <= weR;
    // Wishbone byte-lane convention at the bus boundary. The FSM tracks exact
    // byte addresses, lane-0 write data, and an unshifted size mask in selR; the
    // bus carries a word-aligned address with the byte position in SEL and the
    // data shifted into its lane. Walk accesses are word-aligned with fullSel,
    // so this is the identity for them.
    final laneBits = (busConfig.effectiveSelWidth - 1).bitLength;
    final busLane = adrR.getRange(0, laneBits).named('busLane');
    wbAdr <=
        [
          adrR.getRange(laneBits, busConfig.addressWidth),
          Const(0, width: laneBits),
        ].swizzle();
    wbDatMosi <= datMosiR << [busLane, Const(0, width: 3)].swizzle();
    wbSel <= selR << busLane;
  }
}
