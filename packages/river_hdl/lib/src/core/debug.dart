import 'package:rohd/rohd.dart';

/// RISC-V external debug for the River HDL sim: a JTAG TAP, a Debug Transport
/// Module (DTM), and a Debug Module (DM) fused into one [Module] so an external
/// debugger (OpenOCD `remote_bitbang`, driving Heimdall) can attach to the RTL.
///
/// The whole block lives in the system clock domain. `tck` is sampled and
/// rising-edge detected, so one bitbang TCK pulse advances the TAP by exactly
/// one step and there is no JTAG-to-core clock-domain crossing to reason about.
/// This mirrors the emulator's software path (`SoftJtagDtm` + `SoftDebugModule`)
/// bit for bit, so both report the same DMI behaviour to OpenOCD.
///
/// JTAG: IR width 5, IDCODE=0x01 (reset default), DTMCS=0x10, DMI=0x11,
/// BYPASS=0x1F. DMI DR is `abits + 34` = 41 bits `{addr[6:0], data[31:0],
/// op[1:0]}`.
///
/// DMI register map (RISC-V Debug Spec, matches the emulator, NOT Harbor's
/// older `HarborDebugModule` which mis-maps dmstatus): dmstatus=0x11,
/// dmcontrol=0x10, data0=0x04, data1=0x05, abstractcs=0x16, command=0x17,
/// sbcs=0x38, sbaddress0=0x39, sbdata0=0x3c, sbdata1=0x3d.
///
/// Memory inspection uses System Bus Access (SBA): the DM is a tiny bus master
/// exposing a single-outstanding request/ack memory port (`sba_*`). The hart is
/// untouched by SBA, so this works whether the core is halted or running.
class RiverDebugModule extends Module {
  /// Machine xlen (32 or 64). Drives SBA data width and the abstract register
  /// data path.
  final int xlen;

  /// JTAG IDCODE presented over the IDCODE instruction.
  final int idcode;

  /// IR width (RISC-V convention is 5).
  final int irWidth;

  static const int _abits = 7;
  static const int _dmiWidth = _abits + 34; // 41

  // JTAG instruction opcodes.
  static const int _irIdcode = 0x01;
  static const int _irDtmcs = 0x10;
  static const int _irDmi = 0x11;

  /// JTAG data out to the debugger.
  Logic get tdo => output('tdo');

  /// Direct DMI reads are combinational and sampled at the request edge.
  /// Each asserted request clock is one transaction; there is no queued
  /// transport response or backpressure. Abstract commands still use busy.
  Logic get dmiRdata => output('dmi_rdata');

  // Core control (driven from dmcontrol; consumed in Phase 1+).
  Logic get haltReq => output('halt_req');
  Logic get resumeReq => output('resume_req');
  Logic get ndmreset => output('ndmreset');

  /// High while a multi-cycle DM FSM (abstract command or system-bus access)
  /// is in flight. A bit-banged simulation testbench can drain these to
  /// completion instead of advancing one core clock per JTAG bit.
  Logic get dmBusy => output('dm_busy');

  // Abstract-command register port to the hart (Phase 2).
  Logic get regRead => output('reg_read');
  Logic get regWrite => output('reg_write');
  Logic get regAddr => output('reg_addr');
  Logic get regWdata => output('reg_wdata');

  // System bus access memory port.
  Logic get sbaReq => output('sba_req');
  Logic get sbaWe => output('sba_we');
  Logic get sbaAddr => output('sba_addr');
  Logic get sbaWdata => output('sba_wdata');
  Logic get sbaSize => output('sba_size');

  RiverDebugModule(
    Logic clk,
    Logic reset,
    Logic tck,
    Logic tms,
    Logic tdi,
    Logic trstN, {
    Logic? hartHalted,
    Logic? regRdata,
    Logic? regReady,
    Logic? sbaRdata,
    Logic? sbaAck,
    this.xlen = 64,
    bool directDmi = false,
    Logic? dmiRequest,
    Logic? dmiWrite,
    Logic? dmiAddress,
    Logic? dmiWriteData,
    this.idcode = 0x10000001,
    this.irWidth = 5,
    super.name = 'river_debug',
  }) : super(definitionName: 'RiverDebugModule') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    // Transport ownership is fixed at elaboration; no runtime handover.
    if (!directDmi) {
      tck = addInput('tck', tck);
      tms = addInput('tms', tms);
      tdi = addInput('tdi', tdi);
      trstN = addInput('trst_n', trstN);
    } else {
      if (dmiRequest == null ||
          dmiWrite == null ||
          dmiAddress == null ||
          dmiWriteData == null) {
        throw ArgumentError('Direct DMI requires all request signals');
      }
      dmiRequest = addInput('dmi_request', dmiRequest);
      dmiWrite = addInput('dmi_write', dmiWrite);
      dmiAddress = addInput('dmi_address', dmiAddress, width: 7);
      dmiWriteData = addInput('dmi_wdata', dmiWriteData, width: 32);
      addOutput('dmi_rdata', width: 32);
    }

    final hartHaltedIn = hartHalted == null
        ? Const(0)
        : addInput('hart_halted', hartHalted);
    final regRdataIn = regRdata == null
        ? Const(0, width: xlen)
        : addInput('reg_rdata', regRdata, width: xlen);
    final regReadyIn = regReady == null
        ? Const(1)
        : addInput('reg_ready', regReady);
    final sbaRdataIn = sbaRdata == null
        ? Const(0, width: xlen)
        : addInput('sba_rdata', sbaRdata, width: xlen);
    final sbaAckIn = sbaAck == null ? Const(0) : addInput('sba_ack', sbaAck);

    if (!directDmi) addOutput('tdo');
    addOutput('halt_req');
    addOutput('resume_req');
    addOutput('ndmreset');
    addOutput('reg_read');
    addOutput('reg_write');
    addOutput('reg_addr', width: 16);
    addOutput('reg_wdata', width: xlen);
    addOutput('sba_req');
    addOutput('sba_we');
    addOutput('sba_addr', width: xlen);
    addOutput('sba_wdata', width: xlen);
    addOutput('sba_size', width: 3);
    addOutput('dm_busy');

    // TAP state encoding (matches the emulator's TapState order).
    const sTlr = 0;
    const sRti = 1;
    const sSelDr = 2;
    const sCapDr = 3;
    const sShDr = 4;
    const sEx1Dr = 5;
    const sPauseDr = 6;
    const sEx2Dr = 7;
    const sUpdDr = 8;
    const sSelIr = 9;
    const sCapIr = 10;
    const sShIr = 11;
    const sEx1Ir = 12;
    const sPauseIr = 13;
    const sEx2Ir = 14;
    const sUpdIr = 15;

    final tapState = Logic(name: 'tap_state', width: 4);
    final tapNext = Logic(name: 'tap_next', width: 4);
    final irReg = Logic(name: 'ir_reg', width: irWidth);
    final irShift = Logic(name: 'ir_shift', width: irWidth);
    final dr = Logic(name: 'dr', width: _dmiWidth);
    final drLen = Logic(name: 'dr_len', width: 7);
    final tckPrev = Logic(name: 'tck_prev');

    // Latched result of the previous DMI transaction (captured next scan).
    final dmiData = Logic(name: 'dmi_data', width: 32);
    final dmiAddr = Logic(name: 'dmi_addr', width: _abits);
    final dmiStatus = Logic(name: 'dmi_status', width: 2);

    // Debug Module registers.
    final dmactive = Logic(name: 'dmactive');
    final data0 = Logic(name: 'data0', width: 32);
    final data1 = Logic(name: 'data1', width: 32);
    final cmderr = Logic(name: 'cmderr', width: 3);
    final sbaddress = Logic(name: 'sbaddress', width: xlen);
    final sbdata0 = Logic(name: 'sbdata0', width: 32);
    final sbdata1 = Logic(name: 'sbdata1', width: 32);
    final sbAccessSize = Logic(name: 'sb_access_size', width: 3);
    final sbAutoincr = Logic(name: 'sb_autoincr');
    final sbReadOnAddr = Logic(name: 'sb_read_on_addr');
    final sbReadOnData = Logic(name: 'sb_read_on_data');
    final sbError = Logic(name: 'sb_error', width: 3);

    // SBA bus-master FSM.
    const sbIdle = 0;
    const sbReqState = 1;
    final sbState = Logic(name: 'sb_state', width: 2);
    final sbWeReg = Logic(name: 'sb_we_reg');
    final sbAddrReg = Logic(name: 'sb_addr_reg', width: xlen);
    final sbWdataReg = Logic(name: 'sb_wdata_reg', width: xlen);
    final sbBusy = Logic(name: 'sb_busy');

    // Abstract-command register port latches.
    final regReadReg = Logic(name: 'reg_read_reg');
    final regWriteReg = Logic(name: 'reg_write_reg');
    final regAddrReg = Logic(name: 'reg_addr_reg', width: 16);
    final regWdataReg = Logic(name: 'reg_wdata_reg', width: xlen);
    final cmdPending = Logic(name: 'cmd_pending');
    final cmdActive = Logic(name: 'cmd_active');
    final cmdIs64 = Logic(name: 'cmd_is64');
    final cmdWrite = Logic(name: 'cmd_write');
    final haltReqReg = Logic(name: 'halt_req_reg');
    final commandBusy = cmdPending | cmdActive;
    final resumeAck = Logic(name: 'resume_ack');
    final resumePending = Logic(name: 'resume_pending');
    // dmcontrol.ndmreset (bit 1): holds the rest of the system (the hart) in
    // reset while set, leaving the Debug Module itself alive. The SoC reset tree
    // ORs this into the core reset; the DM is reset only by the external reset.
    final ndmresetReg = Logic(name: 'ndmreset_reg');

    final tckRise = tck & ~tckPrev;

    // TAP next-state combinational logic.
    CaseItem fsm(int from, int hi, int lo) => CaseItem(Const(from, width: 4), [
      If(
        tms,
        then: [tapNext < Const(hi, width: 4)],
        orElse: [tapNext < Const(lo, width: 4)],
      ),
    ]);
    Combinational([
      tapNext < Const(sTlr, width: 4),
      Case(tapState, [
        fsm(sTlr, sTlr, sRti),
        fsm(sRti, sSelDr, sRti),
        fsm(sSelDr, sSelIr, sCapDr),
        fsm(sCapDr, sEx1Dr, sShDr),
        fsm(sShDr, sEx1Dr, sShDr),
        fsm(sEx1Dr, sUpdDr, sPauseDr),
        fsm(sPauseDr, sEx2Dr, sPauseDr),
        fsm(sEx2Dr, sUpdDr, sShDr),
        fsm(sUpdDr, sSelDr, sRti),
        fsm(sSelIr, sTlr, sCapIr),
        fsm(sCapIr, sEx1Ir, sShIr),
        fsm(sShIr, sEx1Ir, sShIr),
        fsm(sEx1Ir, sUpdIr, sPauseIr),
        fsm(sPauseIr, sEx2Ir, sPauseIr),
        fsm(sEx2Ir, sUpdIr, sShIr),
        fsm(sUpdIr, sSelDr, sRti),
      ]),
    ]);

    // TDO is combinational: the LSB of whichever shift register is active, i.e.
    // the bit about to be shifted out. Per IEEE 1149.1 the host samples TDO
    // while TCK is low (before the rising edge that shifts), which is exactly
    // how OpenOCD's remote_bitbang reads it. (A registered-on-rising-edge TDO
    // presents the bit one step late for that convention.)
    if (!directDmi) {
      output('tdo') <=
          mux(
            tapState.eq(sShIr),
            irShift[0],
            mux(tapState.eq(sShDr), dr[0], Const(0)),
          );
    }

    // dtmcs read word: version=1, abits=7, dmistat, idle hint.
    final dtmcsVal =
        Const(0x1071, width: 32) | (dmiStatus.zeroExtend(32) << 10);

    // dmstatus: version=2 (0.13.2), authenticated, all/anyhalted or
    // all/anyrunning, all/anyresumeack.
    final dmstatusVal =
        Const(2, width: 32) |
        Const(1 << 7, width: 32) |
        mux(
          resumeAck,
          Const((1 << 17) | (1 << 16), width: 32),
          Const(0, width: 32),
        ) |
        mux(
          hartHaltedIn,
          Const((1 << 9) | (1 << 8), width: 32),
          Const((1 << 11) | (1 << 10), width: 32),
        );

    // An accepted DMI access can be waiting for the SBA FSM to consume it.
    // Include this start slot in busy: direct DMI can poll on the next edge.
    final sbStart = Logic(name: 'sb_start');
    final sbStartWe = Logic(name: 'sb_start_we');
    final sbStartAddr = Logic(name: 'sb_start_addr', width: xlen);
    final sbStartWdata = Logic(name: 'sb_start_wdata', width: xlen);

    // sbcs read word: sbversion=1, sbaccess size, sbasize=xlen, busy, error,
    // the supported access-size flags.
    final sbcsVal =
        Const(1 << 29, width: 32) |
        (sbAccessSize.zeroExtend(32) << 17) |
        Const(xlen << 5, width: 32) |
        ((sbBusy | sbStart).zeroExtend(32) << 21) |
        (sbError.zeroExtend(32) << 12) |
        (sbAutoincr.zeroExtend(32) << 16) |
        (sbReadOnAddr.zeroExtend(32) << 20) |
        (sbReadOnData.zeroExtend(32) << 15) |
        Const(0xF, width: 32); // sbaccess 8/16/32/64 supported

    // DMI read value selected by the address shifted into dr.
    final dmiReadAddr = directDmi ? dmiAddress! : dr.getRange(34, 41);
    final dmiReadVal = Logic(name: 'dmi_read_val', width: 32);
    Combinational([
      dmiReadVal < Const(0, width: 32),
      Case(dmiReadAddr, [
        CaseItem(Const(0x11, width: 7), [dmiReadVal < dmstatusVal]),
        CaseItem(Const(0x10, width: 7), [
          dmiReadVal <
              (dmactive.zeroExtend(32) | (ndmresetReg.zeroExtend(32) << 1)),
        ]),
        CaseItem(Const(0x16, width: 7), [
          dmiReadVal <
              (Const(0x2, width: 32) |
                  (cmderr.zeroExtend(32) << 8) |
                  ((cmdPending | cmdActive).zeroExtend(32) << 12)),
        ]),
        CaseItem(Const(0x04, width: 7), [dmiReadVal < data0]),
        CaseItem(Const(0x05, width: 7), [dmiReadVal < data1]),
        CaseItem(Const(0x38, width: 7), [dmiReadVal < sbcsVal]),
        CaseItem(Const(0x39, width: 7), [
          dmiReadVal < sbaddress.getRange(0, 32),
        ]),
        CaseItem(Const(0x3c, width: 7), [dmiReadVal < sbdata0]),
        CaseItem(Const(0x3d, width: 7), [dmiReadVal < sbdata1]),
      ]),
    ]);

    // Fields of a DMI scan once shifted into dr.
    final scanOp = directDmi
        ? mux(dmiWrite!, Const(2, width: 2), Const(1, width: 2))
        : dr.getRange(0, 2);
    final scanData = directDmi ? dmiWriteData! : dr.getRange(2, 34);
    final scanAddr = dmiReadAddr;
    if (directDmi) dmiRdata <= dmiReadVal;
    List<Conditional> writeData(Logic target) => [
      If(
        commandBusy,
        then: [
          If(cmderr.eq(0), then: [cmderr < Const(1, width: 3)]),
        ],
        orElse: [target < scanData],
      ),
    ];

    // Bus-master combinational outputs.
    output('sba_req') <= sbState.eq(sbReqState);
    // Busy while an abstract command or a system-bus access is mid-flight.
    output('dm_busy') <= cmdPending | cmdActive | sbStart | ~sbState.eq(sbIdle);
    output('sba_we') <= sbWeReg;
    output('sba_addr') <= sbAddrReg;
    output('sba_wdata') <= sbWdataReg;
    output('sba_size') <= sbAccessSize;
    output('reg_read') <= regReadReg;
    output('reg_write') <= regWriteReg;
    output('reg_addr') <= regAddrReg;
    output('reg_wdata') <= regWdataReg;
    output('halt_req') <= haltReqReg;
    output('ndmreset') <= ndmresetReg;

    Sequential(clk, [
      If(
        reset,
        then: [
          if (!directDmi) ...[
            tapState < Const(sTlr, width: 4),
            irReg < Const(_irIdcode, width: irWidth),
            irShift < Const(0, width: irWidth),
            dr < Const(0, width: _dmiWidth),
            drLen < Const(1, width: 7),
            tckPrev < Const(0),
            dmiData < Const(0, width: 32),
            dmiAddr < Const(0, width: _abits),
            dmiStatus < Const(0, width: 2),
          ],
          dmactive < Const(0),
          data0 < Const(0, width: 32),
          data1 < Const(0, width: 32),
          cmderr < Const(0, width: 3),
          sbaddress < Const(0, width: xlen),
          sbdata0 < Const(0, width: 32),
          sbdata1 < Const(0, width: 32),
          sbAccessSize < Const(xlen == 64 ? 3 : 2, width: 3),
          sbAutoincr < Const(0),
          sbReadOnAddr < Const(0),
          sbReadOnData < Const(0),
          sbError < Const(0, width: 3),
          sbState < Const(sbIdle, width: 2),
          sbWeReg < Const(0),
          sbAddrReg < Const(0, width: xlen),
          sbWdataReg < Const(0, width: xlen),
          sbBusy < Const(0),
          output('resume_req') < Const(0),
          regReadReg < Const(0),
          regWriteReg < Const(0),
          regAddrReg < Const(0, width: 16),
          regWdataReg < Const(0, width: xlen),
          cmdPending < Const(0),
          cmdActive < Const(0),
          cmdIs64 < Const(0),
          cmdWrite < Const(0),
          haltReqReg < Const(0),
          resumeAck < 0,
          resumePending < 0,
          ndmresetReg < Const(0),
          sbStart < Const(0),
          sbStartWe < Const(0),
          sbStartAddr < Const(0, width: xlen),
          sbStartWdata < Const(0, width: xlen),
        ],
        orElse: [
          if (!directDmi) tckPrev < tck,
          output('resume_req') < Const(0),
          // Acknowledge completion, not request receipt; retain the result
          // through a subsequent halt (including a quick single-step halt).
          If(
            resumePending & ~hartHaltedIn,
            then: [resumeAck < 1, resumePending < 0],
          ),

          // Defaults for the per-cycle start pulse (overridden in the tap step).
          sbStart < Const(0),
          sbStartWe < Const(0),
          sbStartAddr < sbaddress,
          sbStartWdata < sbdata0.zeroExtend(xlen),

          // ---- TAP step (one per rising TCK) ----
          If(
            directDmi ? dmiRequest! : tckRise,
            then: [
              if (!directDmi) ...[
                // Shift the active register while in a shift state.
                If(
                  tapState.eq(sShIr),
                  then: [
                    irShift <
                        ((tdi.zeroExtend(irWidth) <<
                                Const(irWidth - 1, width: irWidth)) |
                            (irShift >>> 1)),
                  ],
                ),
                If(
                  tapState.eq(sShDr),
                  then: [
                    dr <
                        ((tdi.zeroExtend(_dmiWidth) << (drLen - 1)) |
                            (dr >>> 1)),
                  ],
                ),

                // Entering-state actions, keyed on tapNext.
                If(
                  tapNext.eq(sTlr),
                  then: [irReg < Const(_irIdcode, width: irWidth)],
                ),
                If(
                  tapNext.eq(sCapIr),
                  then: [irShift < Const(0x01, width: irWidth)],
                ),
                If(tapNext.eq(sUpdIr), then: [irReg < irShift]),

                // Capture-DR loads the DR per the current instruction.
                If(
                  tapNext.eq(sCapDr),
                  then: [
                    If(
                      irReg.eq(_irIdcode),
                      then: [
                        dr < Const(idcode & 0xFFFFFFFF, width: _dmiWidth),
                        drLen < Const(32, width: 7),
                      ],
                      orElse: [
                        If(
                          irReg.eq(_irDtmcs),
                          then: [
                            dr < dtmcsVal.zeroExtend(_dmiWidth),
                            drLen < Const(32, width: 7),
                          ],
                          orElse: [
                            If(
                              irReg.eq(_irDmi),
                              then: [
                                dr < [dmiAddr, dmiData, dmiStatus].swizzle(),
                                drLen < Const(_dmiWidth, width: 7),
                              ],
                              orElse: [
                                dr < Const(0, width: _dmiWidth),
                                drLen < Const(1, width: 7),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ],
              // Both frontends execute the same single-edge DM transaction.
              If(
                directDmi ? Const(1) : tapNext.eq(sUpdDr),
                then: [
                  If(
                    directDmi ? Const(1) : irReg.eq(_irDmi),
                    then: [
                      if (!directDmi) ...[
                        dmiAddr < scanAddr,
                        dmiStatus < Const(0, width: 2),
                      ],
                      // Read.
                      If(
                        scanOp.eq(1),
                        then: [
                          if (!directDmi) dmiData < dmiReadVal,
                          If(
                            (scanAddr.eq(0x04) | scanAddr.eq(0x05)) &
                                commandBusy &
                                cmderr.eq(0),
                            then: [cmderr < Const(1, width: 3)],
                          ),
                          // sbdata0 read with sbreadondata kicks another access.
                          If(
                            scanAddr.eq(0x3c) & sbReadOnData,
                            then: [sbStart < Const(1), sbStartWe < Const(0)],
                          ),
                        ],
                      ),
                      // Write.
                      If(
                        scanOp.eq(2),
                        then: [
                          Case(scanAddr, [
                            CaseItem(Const(0x10, width: 7), [
                              dmactive < scanData[0],
                              ndmresetReg < scanData[1],
                              If(
                                ~commandBusy,
                                then: [
                                  haltReqReg < scanData[31],
                                  If(
                                    scanData[30] & ~scanData[31],
                                    then: [
                                      resumeAck < 0,
                                      resumePending < hartHaltedIn,
                                      output('resume_req') < hartHaltedIn,
                                    ],
                                  ),
                                ],
                              ),
                            ]),
                            CaseItem(Const(0x04, width: 7), writeData(data0)),
                            CaseItem(Const(0x05, width: 7), writeData(data1)),
                            CaseItem(Const(0x16, width: 7), [
                              If(
                                ~commandBusy,
                                then: [
                                  cmderr < (cmderr & ~scanData.getRange(8, 11)),
                                ],
                              ),
                            ]),
                            CaseItem(Const(0x17, width: 7), [
                              // A command cannot replace an in-flight request;
                              // preserve the first error until explicit W1C.
                              If(
                                cmderr.eq(0),
                                then: [
                                  If(
                                    commandBusy,
                                    then: [cmderr < Const(1, width: 3)],
                                    orElse: [
                                      If(
                                        scanData.getRange(24, 32).eq(0),
                                        then: [
                                          If(
                                            scanData[17],
                                            then: [
                                              // The core lends its register port only while halted.
                                              If(
                                                hartHaltedIn,
                                                then: [
                                                  cmdPending < Const(1),
                                                  cmdWrite < scanData[16],
                                                  cmdIs64 <
                                                      scanData
                                                          .getRange(20, 23)
                                                          .eq(3),
                                                  regAddrReg <
                                                      scanData.getRange(0, 16),
                                                ],
                                                orElse: [
                                                  cmderr < Const(4, width: 3),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ],
                                        orElse: [
                                          cmderr <
                                              Const(
                                                2,
                                                width: 3,
                                              ), // unsupported cmdtype
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ]),
                            CaseItem(Const(0x38, width: 7), [
                              sbAccessSize < scanData.getRange(17, 20),
                              sbAutoincr < scanData[16],
                              sbReadOnAddr < scanData[20],
                              sbReadOnData < scanData[15],
                              sbError < (sbError & ~scanData.getRange(12, 15)),
                            ]),
                            CaseItem(Const(0x39, width: 7), [
                              sbaddress < scanData.zeroExtend(xlen),
                              If(
                                sbReadOnAddr,
                                then: [
                                  sbStart < Const(1),
                                  sbStartWe < Const(0),
                                  sbStartAddr < scanData.zeroExtend(xlen),
                                ],
                              ),
                            ]),
                            CaseItem(Const(0x3c, width: 7), [
                              sbdata0 < scanData,
                              sbStart < Const(1),
                              sbStartWe < Const(1),
                              sbStartWdata < scanData.zeroExtend(xlen),
                            ]),
                            CaseItem(Const(0x3d, width: 7), [
                              sbdata1 < scanData,
                            ]),
                          ]),
                        ],
                      ),
                    ],
                  ),
                  // DTMCS affects only the JTAG transport, not the DM FSMs.
                  if (!directDmi)
                    If(
                      irReg.eq(_irDtmcs),
                      then: [
                        If(
                          scanData[16] | scanData[17],
                          then: [dmiStatus < Const(0, width: 2)],
                        ),
                      ],
                    ),
                ],
              ),

              if (!directDmi) tapState < tapNext,
            ],
          ),

          // ---- SBA bus-master FSM (one per system clock) ----
          Case(sbState, [
            CaseItem(Const(sbIdle, width: 2), [
              If(
                sbStart,
                then: [
                  sbState < Const(sbReqState, width: 2),
                  sbBusy < Const(1),
                  sbWeReg < sbStartWe,
                  sbAddrReg < sbStartAddr,
                  sbWdataReg < sbStartWdata,
                ],
              ),
            ]),
            CaseItem(Const(sbReqState, width: 2), [
              If(
                sbaAckIn,
                then: [
                  sbState < Const(sbIdle, width: 2),
                  sbBusy < Const(0),
                  If(
                    ~sbWeReg,
                    then: [
                      sbdata0 < sbaRdataIn.getRange(0, 32),
                      if (xlen == 64) sbdata1 < sbaRdataIn.getRange(32, 64),
                    ],
                  ),
                  If(
                    sbAutoincr,
                    then: [
                      sbaddress < (sbAddrReg + sbBytes(sbAccessSize, xlen)),
                    ],
                  ),
                ],
              ),
            ]),
          ]),

          // ---- Abstract register-access FSM (Phase 2 hook) ----
          // A command first asserts the request (cmdActive), then completes once
          // the core reports ready. This guarantees the request pulse is visible
          // even when the core's regfile is zero-latency (ready always high).
          If(
            cmdActive,
            then: [
              If(
                regReadyIn,
                then: [
                  cmdActive < Const(0),
                  regReadReg < Const(0),
                  regWriteReg < Const(0),
                  // Only a read pulls the result back into data0/data1.
                  If(
                    ~cmdWrite,
                    then: [
                      data0 < regRdataIn.getRange(0, 32),
                      if (xlen == 64) data1 < regRdataIn.getRange(32, 64),
                    ],
                  ),
                ],
              ),
            ],
            orElse: [
              If(
                cmdPending,
                then: [
                  cmdPending < Const(0),
                  cmdActive < Const(1),
                  regReadReg < ~cmdWrite,
                  regWriteReg < cmdWrite,
                  regWdataReg <
                      (xlen == 64
                          ? mux(
                              cmdIs64,
                              [data1, data0].swizzle(),
                              data0.zeroExtend(xlen),
                            )
                          : data0.zeroExtend(xlen)),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}

/// Bytes-per-access from the sbaccess size field (0->1, 1->2, 2->4, 3->8).
Logic sbBytes(Logic size, int xlen) =>
    (Const(1, width: xlen) << size.zeroExtend(xlen));
