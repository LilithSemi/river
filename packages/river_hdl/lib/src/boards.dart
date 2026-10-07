import 'package:harbor/harbor.dart';

/// Board-level DDR definitions: the pad constraint table and part
/// configuration for each supported board.
///
/// A `dram` memory region names its board (`addr:size:dram:board`), and
/// genip merges that board's pad sites into the FPGA pin map and picks the
/// matching [HarborDdrConfig]. Pin map values are `SITE [IO_TYPE]
/// [ATTR=VAL...]`, the format [HarborFpgaTarget] renders into constraints.
class DdrBoard {
  /// The DRAM part/geometry configuration.
  final HarborDdrConfig config;

  /// Pad constraints, keyed by the controller's pad port names (vector
  /// ports use `port[index]` comp naming, matching synthesis output).
  ///
  /// The DQS entries here are the DLL-ON style: a single TRUE-DIFFERENTIAL pad
  /// (`sdram_dqs[*]` SSTL135D_I on the LDQS _p ball), so nextpnr derives the
  /// LDQSN _n rail and there is NO `sdram_dqs_n`. [pinsFor] rewrites these for
  /// the DLL-OFF build (the explicit pseudo-differential pair).
  final Map<String, String> pins;

  /// DLL-OFF DQS override: the EXPLICIT pseudo-differential `sdram_dqs_n[*]` _n
  /// pad sites (single-ended SSTL135_I). When DLL-off the controller drives an
  /// explicit complement ODDR (the hardware-proven 48 MHz write strobe, like
  /// CK#), so the _n ball needs its own constraint AND `sdram_dqs[*]` drops to
  /// single-ended SSTL135_I (see [pinsFor]). Empty for boards with no _n ball.
  final Map<String, String> dqsComplementPins;

  /// Extra fixed-level pins outside the controller's pad ports: the
  /// OrangeCrab fake-VTT network (see [gndPins]). Driven to all-1 by genip
  /// when non-empty. Empty for boards with no such network (Arty S7).
  final Map<String, String> vccioPins;

  /// Spare pins driven low to complete the OrangeCrab's fake-VTT network, as
  /// litex-boards does in gateware. Empty for boards without one (Arty S7).
  final Map<String, String> gndPins;

  const DdrBoard({
    required this.config,
    required this.pins,
    this.dqsComplementPins = const {},
    this.vccioPins = const {},
    this.gndPins = const {},
  });

  /// The pin/constraint table for a given DLL engagement. DLL-ON returns [pins]
  /// unchanged (the single SSTL135D_I diff DQS pad nextpnr derives _n from).
  /// DLL-OFF rewrites every `sdram_dqs[*]` from SSTL135D_I to single-ended
  /// SSTL135_I (keeping its site + extra attrs) and merges in
  /// [dqsComplementPins] (the explicit `sdram_dqs_n[*]` the PHY now drives),
  /// matching the explicit pseudo-differential DQS the controller builds DLL-off.
  Map<String, String> pinsFor({required bool dllOn}) {
    if (dllOn || dqsComplementPins.isEmpty) return pins;
    final out = <String, String>{};
    for (final e in pins.entries) {
      if (e.key.startsWith('sdram_dqs[')) {
        // Drop the differential IO-type to single-ended; keep site + attrs.
        out[e.key] = e.value.replaceFirst('SSTL135D_I', 'SSTL135_I');
      } else {
        out[e.key] = e.value;
      }
    }
    out.addAll(dqsComplementPins);
    return out;
  }

  /// Boards by name. `dram` memory regions must reference one of these.
  /// The OrangeCrab revisions differ materially: r0.1 moves CKE (D6) and
  /// RESET# (B1) and shuffles the address lines, so an r0.2 map on an r0.1
  /// board leaves the part's CKE/RESET# floating (eternally silent DRAM).
  static const byName = <String, DdrBoard>{
    'orangecrab': _orangeCrab,
    'orangecrab-r01': _orangeCrabR01,
    'arty-s7': _artyS7,
    'arty-s7-x8': _artyS7x8,
    'arty-s7-x8-hi': _artyS7x8hi,
  };

  /// Digilent Arty S7-50: Micron MT41K128M16 DDR3L (256MB, 16-bit), sites from
  /// the litex/migen `arty_s7` platform. Xilinx xc7s50-csga324. The Xilinx DDR3
  /// PHY drives an explicit pseudo-differential complement, so CK/DQS are
  /// single-ended SSTL135 on both _p and _n balls (dqs_n via [dqsComplementPins]);
  /// the litex true-diff DIFF_SSTL135 is for a hard OBUFDS pair this soft PHY does
  /// not build. 14 row lines (a[13:0]) => rowWidth 14 (part is 16K x 1K x 8). The
  /// XDC renderer emits only PACKAGE_PIN + IOSTANDARD, so migen's IN_TERM /
  /// SLEW attrs are dropped for now.
  static const _artyS7 = DdrBoard(
    config: HarborDdrConfig(
      type: HarborDdrType.ddr3l,
      size: 256 * 1024 * 1024,
      dataWidth: 16,
      frequency: 333333333,
      banks: 8,
      rowWidth: 14,
      colWidth: 10,
      casLatency: 6,
    ),
    pins: {
      'sdram_ck': 'R5 DIFF_SSTL135',
      'sdram_ck_n': 'T4 DIFF_SSTL135',
      'sdram_cke': 'T2 SSTL135',
      'sdram_cs_n': 'R3 SSTL135',
      'sdram_ras_n': 'U1 SSTL135',
      'sdram_cas_n': 'V3 SSTL135',
      'sdram_we_n': 'P7 SSTL135',
      'sdram_odt': 'P5 SSTL135',
      'sdram_reset_n': 'J6 SSTL135',
      'sdram_ba[0]': 'V5 SSTL135',
      'sdram_ba[1]': 'T1 SSTL135',
      'sdram_ba[2]': 'U3 SSTL135',
      'sdram_addr[0]': 'U2 SSTL135',
      'sdram_addr[1]': 'R4 SSTL135',
      'sdram_addr[2]': 'V2 SSTL135',
      'sdram_addr[3]': 'V4 SSTL135',
      'sdram_addr[4]': 'T3 SSTL135',
      'sdram_addr[5]': 'R7 SSTL135',
      'sdram_addr[6]': 'V6 SSTL135',
      'sdram_addr[7]': 'T6 SSTL135',
      'sdram_addr[8]': 'U7 SSTL135',
      'sdram_addr[9]': 'V7 SSTL135',
      'sdram_addr[10]': 'P6 SSTL135',
      'sdram_addr[11]': 'T5 SSTL135',
      'sdram_addr[12]': 'R6 SSTL135',
      'sdram_addr[13]': 'U6 SSTL135',
      // Lane 0 = DM0/DQS0 (K4/K1,L1) + DQ[0..7]; lane 1 = DM1/DQS1 (M3/N3,N2)
      // + DQ[8..15]. Sites in litex order.
      'sdram_dm[0]': 'K4 SSTL135',
      'sdram_dm[1]': 'M3 SSTL135',
      'sdram_dq[0]': 'K2 SSTL135',
      'sdram_dq[1]': 'K3 SSTL135',
      'sdram_dq[2]': 'L4 SSTL135',
      'sdram_dq[3]': 'M6 SSTL135',
      'sdram_dq[4]': 'K6 SSTL135',
      'sdram_dq[5]': 'M4 SSTL135',
      'sdram_dq[6]': 'L5 SSTL135',
      'sdram_dq[7]': 'L6 SSTL135',
      'sdram_dq[8]': 'N4 SSTL135',
      'sdram_dq[9]': 'R1 SSTL135',
      'sdram_dq[10]': 'N1 SSTL135',
      'sdram_dq[11]': 'N5 SSTL135',
      'sdram_dq[12]': 'M2 SSTL135',
      'sdram_dq[13]': 'P1 SSTL135',
      'sdram_dq[14]': 'M1 SSTL135',
      'sdram_dq[15]': 'P2 SSTL135',
      // DQS _p balls (K1/N3) AND the explicit _n complement balls (L1/N2). The
      // Xilinx DDR3 PHY always drives both rails, so both are constrained here in
      // `pins` rather than the dllOff-only dqsComplementPins (else the dllOn path
      // drops the _n pads and PnR fails "no IOSTANDARD").
      'sdram_dqs[0]': 'K1 SSTL135',
      'sdram_dqs[1]': 'N3 SSTL135',
      'sdram_dqs_n[0]': 'L1 SSTL135',
      'sdram_dqs_n[1]': 'N2 SSTL135',
    },
  );

  /// Arty S7-50 DDR3 as x8 (low byte-lane only). The MT41K128M16 is physically
  /// x16, but DDR3 byte lanes capture on independent per-byte DQS, so the low lane
  /// (DQ[7:0]/DQS0/DM0) behaves as a standalone x8 DDR3 of half the capacity
  /// (128 MB): same geometry, 1 byte/column. Working-DDR path while the x16
  /// high-lane write alignment (per-lane write-leveling) is under debug; the low
  /// lane reads and writes cleanly at cmdSlot=2/WRSHIFT=-1. The high-lane DRAM pins
  /// float. dataWidth=8 builds one byte lane (dmLanes=1), so only DQS0/DM0 drive.
  static const _artyS7x8 = DdrBoard(
    config: HarborDdrConfig(
      type: HarborDdrType.ddr3l,
      size: 128 * 1024 * 1024,
      dataWidth: 8,
      frequency: 333333333,
      banks: 8,
      rowWidth: 14,
      colWidth: 10,
      casLatency: 6,
    ),
    pins: {
      'sdram_ck': 'R5 DIFF_SSTL135',
      'sdram_ck_n': 'T4 DIFF_SSTL135',
      'sdram_cke': 'T2 SSTL135',
      'sdram_cs_n': 'R3 SSTL135',
      'sdram_ras_n': 'U1 SSTL135',
      'sdram_cas_n': 'V3 SSTL135',
      'sdram_we_n': 'P7 SSTL135',
      'sdram_odt': 'P5 SSTL135',
      'sdram_reset_n': 'J6 SSTL135',
      'sdram_ba[0]': 'V5 SSTL135',
      'sdram_ba[1]': 'T1 SSTL135',
      'sdram_ba[2]': 'U3 SSTL135',
      'sdram_addr[0]': 'U2 SSTL135',
      'sdram_addr[1]': 'R4 SSTL135',
      'sdram_addr[2]': 'V2 SSTL135',
      'sdram_addr[3]': 'V4 SSTL135',
      'sdram_addr[4]': 'T3 SSTL135',
      'sdram_addr[5]': 'R7 SSTL135',
      'sdram_addr[6]': 'V6 SSTL135',
      'sdram_addr[7]': 'T6 SSTL135',
      'sdram_addr[8]': 'U7 SSTL135',
      'sdram_addr[9]': 'V7 SSTL135',
      'sdram_addr[10]': 'P6 SSTL135',
      'sdram_addr[11]': 'T5 SSTL135',
      'sdram_addr[12]': 'R6 SSTL135',
      'sdram_addr[13]': 'U6 SSTL135',
      // Low byte lane only: DM0/DQS0 + DQ[0..7]; the high lane is omitted so those
      // DRAM balls float. With a single byte lane (dmLanes=1) the DM/DQS/DQS# ports
      // are scalar (sdram_dm, not sdram_dm[0]); only DQ stays an indexed vector.
      'sdram_dm': 'K4 SSTL135',
      'sdram_dq[0]': 'K2 SSTL135',
      'sdram_dq[1]': 'K3 SSTL135',
      'sdram_dq[2]': 'L4 SSTL135',
      'sdram_dq[3]': 'M6 SSTL135',
      'sdram_dq[4]': 'K6 SSTL135',
      'sdram_dq[5]': 'M4 SSTL135',
      'sdram_dq[6]': 'L5 SSTL135',
      'sdram_dq[7]': 'L6 SSTL135',
      'sdram_dqs': 'K1 SSTL135',
      'sdram_dqs_n': 'L1 SSTL135',
    },
  );

  /// Diagnostic: x8 on the high physical byte lane (DQ[15:8]/DQS1/DM1). Identical
  /// to [_artyS7x8] but the single logical lane maps to the upper-byte balls (litex
  /// arty_s7 lane-1 sites). Isolates the x16 lane1 write bug: if x8-on-lane1 works
  /// the lane1 nets are fine and the x16 failure is a dual-lane RTL bug; if it
  /// fails, lane1 is electrical.
  static const _artyS7x8hi = DdrBoard(
    config: HarborDdrConfig(
      type: HarborDdrType.ddr3l,
      size: 128 * 1024 * 1024,
      dataWidth: 8,
      frequency: 333333333,
      banks: 8,
      rowWidth: 14,
      colWidth: 10,
      casLatency: 6,
    ),
    pins: {
      'sdram_ck': 'R5 DIFF_SSTL135',
      'sdram_ck_n': 'T4 DIFF_SSTL135',
      'sdram_cke': 'T2 SSTL135',
      'sdram_cs_n': 'R3 SSTL135',
      'sdram_ras_n': 'U1 SSTL135',
      'sdram_cas_n': 'V3 SSTL135',
      'sdram_we_n': 'P7 SSTL135',
      'sdram_odt': 'P5 SSTL135',
      'sdram_reset_n': 'J6 SSTL135',
      'sdram_ba[0]': 'V5 SSTL135',
      'sdram_ba[1]': 'T1 SSTL135',
      'sdram_ba[2]': 'U3 SSTL135',
      'sdram_addr[0]': 'U2 SSTL135',
      'sdram_addr[1]': 'R4 SSTL135',
      'sdram_addr[2]': 'V2 SSTL135',
      'sdram_addr[3]': 'V4 SSTL135',
      'sdram_addr[4]': 'T3 SSTL135',
      'sdram_addr[5]': 'R7 SSTL135',
      'sdram_addr[6]': 'V6 SSTL135',
      'sdram_addr[7]': 'T6 SSTL135',
      'sdram_addr[8]': 'U7 SSTL135',
      'sdram_addr[9]': 'V7 SSTL135',
      'sdram_addr[10]': 'P6 SSTL135',
      'sdram_addr[11]': 'T5 SSTL135',
      'sdram_addr[12]': 'R6 SSTL135',
      'sdram_addr[13]': 'U6 SSTL135',
      // High byte lane: single logical lane maps to the upper-byte balls
      // (physical DQ[8..15]/DQS1/DM1). Low-byte balls float.
      'sdram_dm': 'M3 SSTL135',
      'sdram_dq[0]': 'N4 SSTL135',
      'sdram_dq[1]': 'R1 SSTL135',
      'sdram_dq[2]': 'N1 SSTL135',
      'sdram_dq[3]': 'N5 SSTL135',
      'sdram_dq[4]': 'M2 SSTL135',
      'sdram_dq[5]': 'P1 SSTL135',
      'sdram_dq[6]': 'M1 SSTL135',
      'sdram_dq[7]': 'P2 SSTL135',
      'sdram_dqs': 'N3 SSTL135',
      'sdram_dqs_n': 'N2 SSTL135',
    },
  );

  /// OrangeCrab r0.2: MT41K64M16 DDR3L, sites from the litex-boards gsd_orangecrab
  /// platform; CK#/DQS# complement balls from the prjtrellis LFE5U-25F/CSFBGA285
  /// pair database (J18/K18, B15/A16, G18/H17). CK# stays single-ended SSTL135
  /// (RTL drives the complement explicitly, since nextpnr does not build the B
  /// side of "D"-suffixed OUTPUT types). DQS is the exception: a true differential
  /// pad (SSTL135D_I on the LDQS _p ball B15/G18) whose LDQSN _n partner (A16/H17)
  /// nextpnr drives as the complement for a clean DQSBUFM.DQSI read strobe.
  static const _orangeCrab = DdrBoard(
    config: HarborDdrConfig.orangeCrab(),
    pins: {
      'sdram_ck': 'J18 SSTL135_I SLEWRATE=FAST',
      'sdram_ck_n': 'K18 SSTL135_I SLEWRATE=FAST',
      'sdram_cke': 'D18 SSTL135_I SLEWRATE=FAST',
      'sdram_cs_n': 'A12 SSTL135_I SLEWRATE=FAST',
      'sdram_ras_n': 'C12 SSTL135_I SLEWRATE=FAST',
      'sdram_cas_n': 'D13 SSTL135_I SLEWRATE=FAST',
      'sdram_we_n': 'B12 SSTL135_I SLEWRATE=FAST',
      'sdram_odt': 'C13 SSTL135_I SLEWRATE=FAST',
      'sdram_reset_n': 'L18 SSTL135_I SLEWRATE=FAST',
      'sdram_ba[0]': 'D6 SSTL135_I SLEWRATE=FAST',
      'sdram_ba[1]': 'B7 SSTL135_I SLEWRATE=FAST',
      'sdram_ba[2]': 'A6 SSTL135_I SLEWRATE=FAST',
      // 13 lines (a[0:12]): the MT41K64M16 is a 1Gb part (13 rows), matching
      // HarborDdrConfig.orangeCrab's rowWidth. litex-boards reserves 16 pad
      // sites for the bigger-part board variants (gsd_orangecrab.py:118-121,
      // the "a" Subsignal), but only the first 13 are wired for this part.
      // The rest float. Take the first 13 sites in that same order.
      'sdram_addr[0]': 'C4 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[1]': 'D2 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[2]': 'D3 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[3]': 'A3 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[4]': 'A4 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[5]': 'D4 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[6]': 'C3 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[7]': 'B2 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[8]': 'B1 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[9]': 'D1 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[10]': 'A7 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[11]': 'C2 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[12]': 'B6 SSTL135_I SLEWRATE=FAST',
      // DM sites in litex order so each lane's DM shares its lane's ECP5 DQS group:
      // D16 in LDQ20 with DQ[0..7]+DQS[0] (lane 0), G16 in LDQ32 with DQ[8..15]+
      // DQS[1] (lane 1). nextpnr enforces DQS-group membership via the DQSBUFM
      // path, so a swapped order fails packing with a DQS-group mismatch.
      'sdram_dm[0]': 'D16 SSTL135_I SLEWRATE=FAST',
      'sdram_dm[1]': 'G16 SSTL135_I SLEWRATE=FAST',
      'sdram_dq[0]': 'C17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[1]': 'D15 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[2]': 'B17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[3]': 'C16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[4]': 'A15 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[5]': 'B13 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[6]': 'A17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[7]': 'A13 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[8]': 'F17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[9]': 'F16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[10]': 'G15 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[11]': 'F15 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[12]': 'J16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[13]': 'C18 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[14]': 'H16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[15]': 'F18 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      // DQS is a true differential strobe: SSTL135D_I on the LDQS (_p) ball
      // (B15/G18, PIOA of DQS group 20/32) makes nextpnr-ecp5 drive/receive the
      // LDQSN (_n) partner (A16/H17, PIOB) as the complement, so DQSBUFM.DQSI sees
      // a clean differential read strobe. The _n ball is the implicit complement,
      // so it gets no separate constraint. Keep TERMINATION=75 on the strobe.
      'sdram_dqs[0]': 'B15 SSTL135D_I SLEWRATE=FAST TERMINATION=75',
      'sdram_dqs[1]': 'G18 SSTL135D_I SLEWRATE=FAST TERMINATION=75',
    },
    // DLL-OFF explicit DQS# complement: the LDQSN _n balls (A16/H17), single-
    // ended SSTL135_I, driven by the PHY's complement ODDR (the hardware-proven
    // 48 MHz write strobe). [pinsFor] adds these and drops sdram_dqs[*] to
    // SSTL135_I when DLL-off; DLL-on the single SSTL135D_I diff pad is used.
    dqsComplementPins: {
      'sdram_dqs_n[0]': 'A16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dqs_n[1]': 'H17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
    },
    // Fake-VTT network (no onboard VTT regulator): 6 spare pins sourcing
    // current (driven high by genip) and 2 sinking it (driven low), sites
    // from litex-boards gsd_orangecrab.py's `vccio`/`gnd` ddram Subsignals
    // (:140-141). r0.1 has no such network (absent from its _io_r0_1 list).
    vccioPins: {
      'ddr_vccio[0]': 'K16 SSTL135_II SLEWRATE=FAST',
      'ddr_vccio[1]': 'D17 SSTL135_II SLEWRATE=FAST',
      'ddr_vccio[2]': 'K15 SSTL135_II SLEWRATE=FAST',
      'ddr_vccio[3]': 'K17 SSTL135_II SLEWRATE=FAST',
      'ddr_vccio[4]': 'B18 SSTL135_II SLEWRATE=FAST',
      'ddr_vccio[5]': 'C6 SSTL135_II SLEWRATE=FAST',
    },
    gndPins: {
      'ddr_gnd[0]': 'L15 SSTL135_II SLEWRATE=FAST',
      'ddr_gnd[1]': 'L16 SSTL135_II SLEWRATE=FAST',
    },
  );

  /// OrangeCrab r0.1: same DRAM part and same DQ/DQS/CK/DM/command balls
  /// as r0.2, but CKE at D6, RESET# at B1, ba[0] at B6, and a 13-line
  /// reshuffled address bus (sites from the litex-boards gsd_orangecrab
  /// _io_r0_1 list). rowWidth drops to 13 to match the routed lines (a 1Gb
  /// part needs no more).
  static const _orangeCrabR01 = DdrBoard(
    config: HarborDdrConfig(
      type: HarborDdrType.ddr3,
      size: 128 * 1024 * 1024,
      dataWidth: 16,
      frequency: 400000000,
      banks: 8,
      rowWidth: 13,
      colWidth: 10,
      casLatency: 6,
    ),
    pins: {
      'sdram_ck': 'J18 SSTL135_I SLEWRATE=FAST',
      'sdram_ck_n': 'K18 SSTL135_I SLEWRATE=FAST',
      'sdram_cke': 'D6 SSTL135_I SLEWRATE=FAST',
      'sdram_cs_n': 'A12 SSTL135_I SLEWRATE=FAST',
      'sdram_ras_n': 'C12 SSTL135_I SLEWRATE=FAST',
      'sdram_cas_n': 'D13 SSTL135_I SLEWRATE=FAST',
      'sdram_we_n': 'B12 SSTL135_I SLEWRATE=FAST',
      'sdram_odt': 'C13 SSTL135_I SLEWRATE=FAST',
      'sdram_reset_n': 'B1 SSTL135_I SLEWRATE=FAST',
      'sdram_ba[0]': 'B6 SSTL135_I SLEWRATE=FAST',
      'sdram_ba[1]': 'B7 SSTL135_I SLEWRATE=FAST',
      'sdram_ba[2]': 'A6 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[0]': 'A4 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[1]': 'D2 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[2]': 'C3 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[3]': 'C7 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[4]': 'D3 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[5]': 'D4 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[6]': 'D1 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[7]': 'B2 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[8]': 'C1 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[9]': 'A2 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[10]': 'A7 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[11]': 'C2 SSTL135_I SLEWRATE=FAST',
      'sdram_addr[12]': 'C4 SSTL135_I SLEWRATE=FAST',
      // DM in litex order so each lane's DM shares its lane's DQS group
      // (D16=LDQ20/lane0, G16=LDQ32/lane1), same balls as r0.2.
      'sdram_dm[0]': 'D16 SSTL135_I SLEWRATE=FAST',
      'sdram_dm[1]': 'G16 SSTL135_I SLEWRATE=FAST',
      'sdram_dq[0]': 'C17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[1]': 'D15 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[2]': 'B17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[3]': 'C16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[4]': 'A15 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[5]': 'B13 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[6]': 'A17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[7]': 'A13 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[8]': 'F17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[9]': 'F16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[10]': 'G15 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[11]': 'F15 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[12]': 'J16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[13]': 'C18 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[14]': 'H16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dq[15]': 'F18 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      // TRUE DIFFERENTIAL DQS (see the r0.2 block): SSTL135D_I on the LDQS (_p)
      // ball pairs the LDQSN (_n) partner automatically, so no _n constraint.
      'sdram_dqs[0]': 'B15 SSTL135D_I SLEWRATE=FAST TERMINATION=75',
      'sdram_dqs[1]': 'G18 SSTL135D_I SLEWRATE=FAST TERMINATION=75',
    },
    // DLL-OFF explicit DQS# complement (same LDQSN _n balls as r0.2: A16/H17).
    dqsComplementPins: {
      'sdram_dqs_n[0]': 'A16 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
      'sdram_dqs_n[1]': 'H17 SSTL135_I SLEWRATE=FAST TERMINATION=OFF',
    },
  );

  /// The controller pad ports a `dram` region exposes at the SoC top.
  static const padPorts = [
    'sdram_ck',
    'sdram_ck_n',
    'sdram_cke',
    'sdram_cs_n',
    'sdram_ras_n',
    'sdram_cas_n',
    'sdram_we_n',
    'sdram_ba',
    'sdram_addr',
    'sdram_dm',
    'sdram_dq',
    // DQS is a TRUE DIFFERENTIAL pad (SSTL135D_I on the LDQS _p ball): the
    // LDQSN _n complement is generated by nextpnr, so there is no sdram_dqs_n
    // top-level port to expose.
    'sdram_dqs',
    'sdram_odt',
    'sdram_reset_n',
  ];
}

/// On-board SPI NOR flash pin table for a `flash:<board>` memory region. The
/// flash CLOCK is intentionally absent: on the ECP5 it is driven through the
/// USRMCLK macro (no I/O pad), so genip wires spi_clk into USRMCLK and only the
/// chip-select and data lines are real pads.
class FlashBoard {
  /// Pad constraints keyed by the controller's exposed pad port names (vector
  /// ports use `port[index]`, matching synthesis output).
  final Map<String, String> pins;

  const FlashBoard({required this.pins});

  static const byName = <String, FlashBoard>{
    'orangecrab': _orangeCrab,
    'orangecrab-r01': _orangeCrab, // identical quad-SPI pinout on both revs
    'arty-s7': _artyS7,
  };

  /// Digilent Arty S7-50 (xc7s50csga324) on-board Spansion S25FL128 (16MB) quad
  /// SPI config flash. The CCLK is driven through STARTUPE2 (USRCCLKO -> CCLK, no
  /// I/O pad), so only CS + DQ[0..3] are real pads. Balls from the Digilent
  /// Arty-S7-50 master XDC "Quad SPI Flash" section.
  /// VERIFY these against the board's master XDC before flashing hardware.
  static const _artyS7 = FlashBoard(
    pins: {
      'spi_cs_n': 'M13 LVCMOS33',
      'spi_io[0]': 'K17 LVCMOS33', // IO0 / MOSI
      'spi_io[1]': 'K18 LVCMOS33', // IO1 / MISO
      'spi_io[2]': 'L14 LVCMOS33', // IO2 / WP#
      'spi_io[3]': 'M15 LVCMOS33', // IO3 / HOLD#
    },
  );

  /// OrangeCrab GD25Q128 (16MB) quad SPI flash, from the litex-boards
  /// gsd_orangecrab platform (CS_N=U17, DQ=U18/T18/R18/N18, clock via USRMCLK).
  /// IO0/MOSI=U18, IO1/MISO=T18, IO2/WP=R18, IO3/HOLD=N18.
  static const _orangeCrab = FlashBoard(
    pins: {
      'spi_cs_n': 'U17 LVCMOS33',
      'spi_io[0]': 'U18 LVCMOS33',
      'spi_io[1]': 'T18 LVCMOS33',
      'spi_io[2]': 'R18 LVCMOS33',
      'spi_io[3]': 'N18 LVCMOS33',
    },
  );

  /// The pad ports exposed at the top for a board-qualified flash region (the
  /// clock is absorbed by USRMCLK, so it is not a pad).
  static const padPorts = ['spi_cs_n', 'spi_io'];
}
