import 'dart:io';
import 'dart:typed_data';

import 'package:rohd/rohd.dart' show Logic, Sequential, Const;
import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart' as adl;
import 'package:river_maskrom/river_maskrom.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'boards.dart';
import 'core.dart';
import 'core/debug_subsystem.dart';
import 'usb_dfu_subsystem.dart';

/// How the USB DFU subsystem is integrated.
enum UsbDfuMode {
  /// Hardware RAM-sink integration: a second bus master ([UsbDfuRamSink]) DMAs
  /// the downloaded firmware into an on-chip SRAM through a [HarborCdcFifo] and
  /// a [RiverWishboneArbiter]. The maskrom polls image_ready and jumps. Heavy.
  hardware,

  /// Lean software/CAR integration: only the PHY + [UsbEp0Engine] + a small
  /// MMIO slave ([RiverDfuSubsystemSw]). The maskrom reads received bytes over
  /// MMIO and stores them into Cache-as-RAM itself. No RAM-sink, no CDC FIFO,
  /// no arbiter, no second master, no SRAM region. Light.
  software,
}

/// Structured `key=val,...` params carried by a [Device] spec (e.g.
/// `dram:0x...:arty-s7-x8:ddr3fast=true,clockfreq=200000000`). Every field is
/// nullable: null means "not set", so genip falls back to the board default then
/// a literal default.
class DeviceParams {
  // --- DDR controller tuning (`dram` devices) ---

  /// Expose the CPU read-training MMIO window (HarborDdrController.trainableRead).
  final bool? trainable;

  /// ddr3v2 training mode: `train=runtime` exposes the knob-ABI window so the
  /// FSBL sweep engine drives calibration; `train=hw` (default) keeps the
  /// controller's internal cal FSM. Distinct from the legacy [trainable].
  final bool? runtimeTrain;

  /// ddr3Fast command CK edge (0..3), forwarded to the Xilinx PHY.
  final int? cmdSlot;

  /// ddr3Fast write-launch window slide (may be negative).
  final int? wrShift;

  /// ddr3Fast sub-tick DDR write beat rotation (null derives from CWL).
  final int? wrBeat;

  /// Static/initial read tap (the per-DQ read-eye centering knob).
  final int? readTap;

  /// Read-capture window slack in cycles.
  final int? readSlack;

  /// DRAM read-retry / read-voting depth (0 disables).
  final int? readRetry;

  /// ddr3Fast runtime read-window tap reset (reg12 default).
  final int? window;

  /// Hardware write-verify-retry on every array write.
  final bool? writeVerify;

  /// Hardware MPR read-calibration: the sequencer sweeps each byte lane's read
  /// window x IDELAY tap against the DRAM MPR pattern and locks the eye before
  /// the bus opens (ddr3Fast only). Kills the per-boot read coin-flip.
  final bool? readLevel;

  /// Post-read-cal cadence self-test: bus opens only after a varied-cadence read
  /// verify passes (ddr3Fast + readlevel only). Kills the read cadence coin-flip.
  final bool? selfTest;

  /// Expose the DDR controller's dbg_la LA-probe bundle ([3:0]=stateCode,
  /// [4]=rd_cal_active, [5]=phy.rdValid) to top pins so a logic analyzer can
  /// watch the sequencer FSM + read completion live (bus-independent). The 6
  /// dbg_la[*] pins must be assigned via --pin.
  final bool? laprobe;

  /// Diagnostic MR3.MPR mode (every read returns the part MPR pattern).
  final bool? mpr;

  /// Real-speed DDR3-667 ISERDESE2 datapath (else the DLL-off IDDR read path).
  /// Per controller: two dram devices may differ.
  final bool? ddr3Fast;

  /// Use the new silicon-proven [HarborDdr3] stack (Ddr3Controller + Ddr3Phy,
  /// with proper calibration + bank anticipate) instead of the legacy
  /// HarborDdrController + DdrSequencer/DdrPhyXilinx. Implies ddr3Fast.
  final bool? ddr3v2;

  /// DDR3 controller-logic gearing (ddr3v2 only). 1 (absent) = the controller
  /// runs on CK/4 (byte-identical to today). 2 = the CK/8 gearbox controller:
  /// the DDR MMCM emits CLKOUT5 as CK/8, HarborDdr3 interposes the fabric 2:1
  /// gearbox, and the congestion-limited command scheduler gets timing margin
  /// on a dense open-tools part while DDR CK stays at full speed.
  final int? ctrlGear;

  /// Open the ddr3Fast read window from the DRAM's read strobe (DQS as data) so
  /// each read self-frames, instead of a fixed CL tap that mis-frames under the
  /// i+d cadence. ddr3Fast only.
  final bool? dqsGate;

  /// LiteDRAM read margin: extra CK added to the programmed DRAM CAS latency
  /// (MR0) so the read burst lands one memory-clock phase INTO the ISERDESE2
  /// word, not at the CLKDIV edge where setup/hold is marginal and the i+d read
  /// cadence tips it over. LiteDRAM s7ddrphy notes "Artix-7 requires read data
  /// one memory-clock phase into the ISERDESE2 word for reliable read leveling"
  /// (originally CL+1 in MR0). The DRAM drives read data [readClExtra] CK later,
  /// clTicks/MR0 track it, and the FSBL read sweep re-centres. ddr3Fast only.
  final int? readClExtra;

  /// DRAM clock-domain (CDC) frequency in Hz. Above the oscillator PLLs the
  /// `ddr` domain to a higher DLL-off / DLL-on rate than the core drives.
  final int? clockFreq;

  /// Separate oscillator (Hz) sourcing the DDR3 clock tree. When set genip mints
  /// the top-level `ddr_osc` pin (site via `--pin ddr_osc=<pad>`).
  final int? oscFreq;

  // --- usb-dfu device ---

  /// DFU integration style: `hardware` (RAM-sink DMA + 2nd master) or `software`
  /// (lean MMIO slave, maskrom stores into Cache-as-RAM).
  final String? mode;

  // --- flash-firmware device ---

  /// External firmware binary bundled into flash (takes precedence over program).
  final String? path;

  /// Built-in firmware program baked into flash (e.g. `hexdump`).
  final String? program;

  // --- spi/sdio device ---

  /// Board connector this device's pads bind to (e.g. `iface=pmod@ja`). Resolved
  /// against the selected [HarborBoard]'s `interfaces` catalog, so the SoC need
  /// not hand-enter the connector's pin sites. Used by the `spi` device.
  final String? iface;

  /// An SD/MMC card is wired to this SPI controller (CS0, SPI mode). genip then
  /// has Harbor emit an `mmc-spi-slot` device-tree child so Linux binds the
  /// in-tree `mmc_spi` driver and exposes a mountable block device.
  final bool? sdcard;

  /// Number of hardware execute-breakpoint triggers on a `debug-jtag` device.
  /// 0/absent = none (byte-identical to before). OpenOCD programs these over
  /// JTAG so it can breakpoint even hot, I-cached code without patching it.
  final int? triggers;

  /// debug-jtag `userprobe=true`: build the sticky user-mode excursion probe
  /// and report it in dcsr's reserved field. Off by default and byte identical
  /// when off. A diagnostic build option, not a production one.
  final bool? userProbe;

  /// Give this `spi` device an integrated DMA engine: a second fabric master
  /// that streams SD bytes straight to memory (no per-byte CPU poll). absent/
  /// false = byte-identical slave-only PIO. Firmware finds it via the device's
  /// `dma` device-tree/ACPI property.
  final bool? dma;

  /// Put the DMA master on the PRIMARY fabric channel (shared crossbar with the
  /// core) instead of its own `dma` channel. The separate channel lifts the
  /// wide DMA leg off the primary crossbar, but on a small device it adds a
  /// second crossbar plus a converge arbiter that becomes the routing hotspot;
  /// sharing is the topology that provably closes on xc7s50. Costs DMA/CPU
  /// fabric contention. absent/false = the separate `dma` channel.
  final bool? dmaShared;

  /// Sample the SDIO read DAT lines on the SD clock FALLING edge (half a period
  /// later) instead of the rising edge. Gives the card-to-host round-trip more
  /// settle time, the fix for marginal read capture at speed on a real board.
  /// It is also a runtime CTRL[8] bit, so this only sets the reset default.
  /// absent/false = rising-edge sample (the standard host default).
  final bool? sampleFall;

  /// Pin count of a `gpio` device. Absent uses a small default, because every
  /// pin costs three registers plus its own interrupt logic.
  final int? pins;

  const DeviceParams({
    this.trainable,
    this.runtimeTrain,
    this.cmdSlot,
    this.wrShift,
    this.wrBeat,
    this.readTap,
    this.readSlack,
    this.readRetry,
    this.window,
    this.writeVerify,
    this.readLevel,
    this.selfTest,
    this.laprobe,
    this.mpr,
    this.ddr3Fast,
    this.ddr3v2,
    this.ctrlGear,
    this.dqsGate,
    this.readClExtra,
    this.clockFreq,
    this.oscFreq,
    this.mode,
    this.path,
    this.program,
    this.iface,
    this.sdcard,
    this.triggers,
    this.userProbe,
    this.dma,
    this.dmaShared,
    this.sampleFall,
    this.pins,
  });

  /// Accepted param keys (case-insensitive), for error messages.
  static const _keys = [
    'trainable',
    'train',
    'cmdslot',
    'wrshift',
    'wrbeat',
    'readtap',
    'readslack',
    'readretry',
    'window',
    'writeverify',
    'readlevel',
    'selftest',
    'laprobe',
    'mpr',
    'ddr3fast',
    'ddr3v2',
    'ctrlgear',
    'dqsgate',
    'readclextra',
    'clockfreq',
    'oscfreq',
    'mode',
    'path',
    'program',
    'iface',
    'sdcard',
    'triggers',
    'userprobe',
    'dma',
    'dmashared',
    'samplefall',
    'pins',
  ];

  static bool _parseBool(String v) {
    switch (v.toLowerCase()) {
      case 'true':
      case '1':
        return true;
      case 'false':
      case '0':
        return false;
      default:
        throw FormatException(
          'Device param bool must be true/false/1/0, got: $v',
        );
    }
  }

  /// Parses `key=val,key=val,...` into a [DeviceParams]. Keys are
  /// case-insensitive. Unknown keys throw. Int values use [int.parse] so
  /// negatives (e.g. `wrshift=-1`) work. Split on the FIRST `=`, so a path may
  /// contain `=`.
  static DeviceParams parse(String s) {
    bool? trainable;
    bool? runtimeTrain;
    int? cmdSlot;
    int? wrShift;
    int? wrBeat;
    int? readTap;
    int? readSlack;
    int? readRetry;
    int? window;
    bool? writeVerify;
    bool? readLevel;
    bool? selfTest;
    bool? laprobe;
    bool? mpr;
    bool? ddr3Fast;
    bool? ddr3v2;
    int? ctrlGear;
    bool? dqsGate;
    int? readClExtra;
    int? clockFreq;
    int? oscFreq;
    String? mode;
    String? path;
    String? program;
    String? iface;
    bool? sdcard;
    int? triggers;
    bool? userProbe;
    int? pins;
    bool? dma;
    bool? dmaShared;
    bool? sampleFall;
    for (final pair in s.split(',')) {
      final eq = pair.indexOf('=');
      if (eq < 0) {
        throw FormatException('Device param must be key=val, got: $pair');
      }
      final key = pair.substring(0, eq).trim().toLowerCase();
      final val = pair.substring(eq + 1).trim();
      switch (key) {
        case 'trainable':
          trainable = _parseBool(val);
        case 'train':
          if (val != 'hw' && val != 'runtime') {
            throw FormatException('train must be hw|runtime, got: $val');
          }
          runtimeTrain = val == 'runtime';
        case 'cmdslot':
          cmdSlot = int.parse(val);
        case 'wrshift':
          wrShift = int.parse(val);
        case 'wrbeat':
          wrBeat = int.parse(val);
        case 'readtap':
          readTap = int.parse(val);
        case 'readslack':
          readSlack = int.parse(val);
        case 'readretry':
          readRetry = int.parse(val);
        case 'window':
          window = int.parse(val);
        case 'writeverify':
          writeVerify = _parseBool(val);
        case 'readlevel':
          readLevel = _parseBool(val);
        case 'selftest':
          selfTest = _parseBool(val);
        case 'laprobe':
          laprobe = _parseBool(val);
        case 'mpr':
          mpr = _parseBool(val);
        case 'ddr3fast':
          ddr3Fast = _parseBool(val);
        case 'ddr3v2':
          ddr3v2 = _parseBool(val);
        case 'ctrlgear':
          ctrlGear = int.parse(val);
          if (ctrlGear != 1 && ctrlGear != 2) {
            throw FormatException('ctrlgear must be 1 or 2, got: $val');
          }
        case 'dqsgate':
          dqsGate = _parseBool(val);
        case 'readclextra':
          readClExtra = int.parse(val);
        case 'clockfreq':
          clockFreq = int.parse(val);
        case 'oscfreq':
          oscFreq = int.parse(val);
        case 'mode':
          if (val != 'hardware' && val != 'software') {
            throw FormatException(
              'Device param mode must be hardware/software, got: $val',
            );
          }
          mode = val;
        case 'path':
          path = val;
        case 'program':
          program = val;
        case 'iface':
          iface = val;
        case 'sdcard':
          sdcard = _parseBool(val);
        case 'triggers':
          triggers = int.parse(val);
        case 'userprobe':
          userProbe = _parseBool(val);
        case 'pins':
          pins = int.parse(val);
        case 'dma':
          dma = _parseBool(val);
        case 'dmashared':
          dmaShared = _parseBool(val);
        case 'samplefall':
          sampleFall = _parseBool(val);
        default:
          throw FormatException(
            'Unknown device param "$key"; accepted: ${_keys.join(', ')}',
          );
      }
    }
    return DeviceParams(
      trainable: trainable,
      runtimeTrain: runtimeTrain,
      cmdSlot: cmdSlot,
      wrShift: wrShift,
      wrBeat: wrBeat,
      readTap: readTap,
      readSlack: readSlack,
      readRetry: readRetry,
      window: window,
      writeVerify: writeVerify,
      readLevel: readLevel,
      selfTest: selfTest,
      laprobe: laprobe,
      mpr: mpr,
      ddr3Fast: ddr3Fast,
      ddr3v2: ddr3v2,
      ctrlGear: ctrlGear,
      dqsGate: dqsGate,
      readClExtra: readClExtra,
      clockFreq: clockFreq,
      oscFreq: oscFreq,
      mode: mode,
      path: path,
      program: program,
      iface: iface,
      sdcard: sdcard,
      triggers: triggers,
      userProbe: userProbe,
      dma: dma,
      dmaShared: dmaShared,
      sampleFall: sampleFall,
      pins: pins,
    );
  }
}

/// Deprecated alias, retained while [MemoryRegion.ddrParams] still uses this name.
typedef DdrRegionParams = DeviceParams;

/// Target-aware flash partition layout. Pure, so the DT `fixed-partitions` node
/// and xipboot's jump target computed from it stay in agreement across call
/// sites. An FPGA reserves slot 0 for the config bitstream (master-SPI self-boot
/// from flash); an ASIC has no fabric to configure, so the FSBL is the reset
/// payload at offset 0.
({int fsblOffset, int firmwareOffset, List<HarborFlashPartition> partitions})
flashLayout(Object? target, int flashSize) {
  // The uncompressed 7-series bitstream size is FIXED per device (the full
  // configuration memory), design-independent. Round the reserved slot up to
  // 1 MiB so the FSBL clears it.
  const bitstreamBytes = <String, int>{'xc7s50': 2192012};
  final isFpga = target is HarborFpgaTarget;
  final bitSlot = isFpga
      ? (((bitstreamBytes[target.device] ?? 0x300000) + 0xfffff) & ~0xfffff)
      : 0;
  final fsblOffset = bitSlot;
  const fsblSize = 0x100000; // 1 MiB, generous for the XIP FSBL
  final firmwareOffset = fsblOffset + fsblSize;
  return (
    fsblOffset: fsblOffset,
    firmwareOffset: firmwareOffset,
    partitions: [
      if (isFpga)
        HarborFlashPartition(label: 'fpga-bitstream', offset: 0, size: bitSlot),
      HarborFlashPartition(
        label: 'river-fsbl',
        offset: fsblOffset,
        size: fsblSize,
      ),
      HarborFlashPartition(
        label: 'river-firmware',
        offset: firmwareOffset,
        size: flashSize - firmwareOffset,
      ),
    ],
  );
}

class MemoryRegion {
  final int address;
  final int size;
  final String type;

  /// Board name for off-chip memory (`dram` regions): selects the DDR part
  /// configuration and pad constraint table from [DdrBoard.byName].
  final String? board;

  /// Per-region DDR tuning knobs (`dram` regions only). Null when the spec
  /// carried no params field. Each set field overrides the board default.
  final DdrRegionParams? ddrParams;

  const MemoryRegion({
    required this.address,
    required this.size,
    required this.type,
    this.board,
    this.ddrParams,
  });

  static MemoryRegion parse(String spec) {
    final parts = spec.split(':');
    if (parts.length < 3 || parts.length > 5) {
      throw FormatException(
        'Memory format: addr:size:type[:board][:key=val,...], got: $spec',
      );
    }
    // parts[3..] may carry a board name (no '=') and/or a params field (has
    // '='), in either combination up to two extra fields.
    String? board;
    DdrRegionParams? ddrParams;
    for (final extra in parts.skip(3)) {
      if (extra.contains('=')) {
        ddrParams = DdrRegionParams.parse(extra);
      } else {
        board = extra;
      }
    }
    final region = MemoryRegion(
      address: int.parse(parts[0]),
      size: _parseSize(parts[1]),
      type: parts[2],
      board: board,
      ddrParams: ddrParams,
    );
    if (region.type == 'dram' && region.board != null) {
      final board = DdrBoard.byName[region.board];
      if (board == null) {
        throw ArgumentError(
          'Unknown dram board "${region.board}"; '
          'known: ${DdrBoard.byName.keys.join(', ')}',
        );
      }
      if (board.config.size != region.size) {
        throw ArgumentError(
          'dram size ${region.size} does not match the ${region.board} '
          'part (${board.config.size} bytes)',
        );
      }
    }
    return region;
  }

  /// The DDR board definition, when this is a board-qualified `dram` region.
  /// Board-less `dram` keeps the legacy on-chip placeholder.
  DdrBoard? get ddrBoard => type == 'dram' ? DdrBoard.byName[board] : null;

  /// The flash board definition, when this is a board-qualified `flash` region.
  FlashBoard? get flashBoard =>
      type == 'flash' && board != null ? FlashBoard.byName[board] : null;
}

class DeviceEntry {
  final String name;
  final String type;
  final int address;
  final String? compatible;

  /// Trailing `key=val` tuning params carried over from the unified device, so
  /// peripheral construction can read them (e.g. the `spi` device's `sdcard`).
  final DeviceParams? params;

  const DeviceEntry({
    required this.name,
    required this.type,
    required this.address,
    this.compatible,
    this.params,
  });

  /// Parses `[name=]type:addr[:compat]`.
  ///
  /// Examples:
  /// - `uart:0x10000000`, name defaults to type
  /// - `myuart=uart:0x10000000:ns16550a`, explicit name
  static DeviceEntry parse(String spec) {
    String? name;
    var rest = spec;
    final eq = spec.indexOf('=');
    if (eq > 0 && spec.indexOf(':') > eq) {
      name = spec.substring(0, eq);
      rest = spec.substring(eq + 1);
    }
    final parts = rest.split(':');
    if (parts.length < 2) {
      throw FormatException(
        'Device format: [name=]type:addr[:compat], got: $spec',
      );
    }
    return DeviceEntry(
      name: name ?? parts[0],
      type: parts[0],
      address: int.parse(parts[1]),
      compatible: parts.length > 2 ? parts[2] : null,
    );
  }

  static const _defaultCompat = {
    'uart': 'ns16550a',
    'clint': 'riscv,clint0',
    'plic': 'riscv,plic0',
    'sram': 'river,sram',
    'flash': 'river,flash',
    'psram': 'river,psram',
    'dram': 'river,dram',
    'gpio': 'river,gpio',
  };

  static const _defaultSizes = {
    'clint': 0x10000,
    'plic': 0x4000000,
    'uart': 0x1000,
    'gpio': 0x1000,
  };

  String get effectiveCompat =>
      compatible ?? _defaultCompat[type] ?? 'river,$type';
  int get effectiveSize => _defaultSizes[type] ?? 0x1000;
}

/// A unified addressed thing in the SoC, replacing the old separate
/// [MemoryRegion] and [DeviceEntry]. One of:
/// - a sized memory-backed region (`sram`/`flash`/`dram`): needs addr + size,
///   may carry a `board` and (dram) tuning params.
/// - a fixed-function MMIO peripheral (`uart`/`clint`/`plic`/`gpio`): needs an
///   addr, size defaults from the peripheral class.
/// - a pseudo-device that drives an integration (`usb-dfu`, `debug-jtag`,
///   `flash-firmware`): `buildSoC` detects these and wires the subsystem.
class Device {
  final String name;
  final String type;

  /// Bus base address. Null for addressless devices (`debug-jtag`). For
  /// `flash-firmware` this is the flash byte offset, not an absolute address.
  final int? address;

  /// Address-window size. Null uses the type's class default (fixed
  /// peripherals). Required for the memory-backed types.
  final int? size;

  /// Board name (`dram`/`flash`): selects the DdrBoard/FlashBoard config + pads.
  final String? board;

  /// Devicetree `compatible` override (currently inert, kept for the
  /// `uart:addr:compat` back-compat form).
  final String? compatible;

  /// Trailing `key=val,...` tuning params.
  final DeviceParams? params;

  const Device({
    required this.name,
    required this.type,
    this.address,
    this.size,
    this.board,
    this.compatible,
    this.params,
  });

  /// Memory-backed types: they require a user-chosen size and address.
  static const _memBacked = {'sram', 'flash', 'psram', 'dram'};

  /// Class-default window sizes for fixed MMIO peripherals.
  static const _defaultSizes = {
    'clint': 0x10000,
    'plic': 0x4000000,
    'uart': 0x1000,
    'gpio': 0x1000,
    'usb-dfu': 0x1000,
  };

  static final _numberRe = RegExp(r'^0[xX][0-9a-fA-F]+$|^[0-9]+$');

  static bool _looksLikeSize(String s) {
    final u = s.toUpperCase();
    return (u.endsWith('K') || u.endsWith('M') || u.endsWith('G')) &&
        _numberRe.hasMatch(u.substring(0, u.length - 1));
  }

  /// Parses `[name=]type[:addr][:size][:board|compat][:key=val,...]`.
  ///
  /// The colon parts after the type are classified by shape, not position.
  /// A `key=val` blob is params. A size-suffixed number is size. A bare number
  /// is address (first) then size. A known board name is board. Anything else
  /// is compatible. Examples:
  /// - `uart:0x10000000:ns16550a` (addr + compat, the legacy device form)
  /// - `sram:0x08000000:64K` (addr + size, a legacy memory region)
  /// - `dram:0x80000000:128M:arty-s7-x8:ddr3fast=true` (addr+size+board+params)
  /// - `debug-jtag` (type only, addressless)
  /// - `usb-dfu:0x0C000000:mode=software`
  /// - `flash-firmware:0x100000:path=weir.bin` (addr field is the flash offset)
  static Device parse(String spec) {
    String? name;
    var rest = spec;
    final eq = spec.indexOf('=');
    final colon = spec.indexOf(':');
    // `name=` prefix only when the first '=' precedes the first ':'. A later
    // '=' belongs to a params blob (`type:...:key=val`).
    if (eq > 0 && (colon < 0 || colon > eq)) {
      name = spec.substring(0, eq);
      rest = spec.substring(eq + 1);
    }
    final parts = rest.split(':');
    final type = parts[0];
    int? address;
    int? size;
    String? board;
    String? compatible;
    DeviceParams? params;
    for (final tok in parts.skip(1)) {
      if (tok.contains('=')) {
        params = DeviceParams.parse(tok);
      } else if (_looksLikeSize(tok)) {
        size = _parseSize(tok);
      } else if (_numberRe.hasMatch(tok)) {
        if (address == null) {
          address = int.parse(tok);
        } else {
          size ??= _parseSize(tok);
        }
      } else if (type == 'dram' || type == 'flash') {
        // A plain word on a board-qualified region is the board name. An unknown
        // one is caught by _validate rather than silently becoming compat.
        board = tok;
      } else {
        compatible = tok;
      }
    }
    final dev = Device(
      name: name ?? type,
      type: type,
      address: address,
      size: size,
      board: board,
      compatible: compatible,
      params: params,
    );
    _validate(dev, spec);
    return dev;
  }

  static void _validate(Device d, String spec) {
    if (_memBacked.contains(d.type)) {
      if (d.address == null || d.size == null) {
        throw FormatException(
          'Device "${d.type}" needs an address and size '
          '(type:addr:size[:board][:key=val,...]), got: $spec',
        );
      }
    }
    if (d.type == 'dram' && d.board != null) {
      final b = DdrBoard.byName[d.board];
      if (b == null) {
        throw ArgumentError(
          'Unknown dram board "${d.board}"; '
          'known: ${DdrBoard.byName.keys.join(', ')}',
        );
      }
      if (b.config.size != d.size) {
        throw ArgumentError(
          'dram size ${d.size} does not match the ${d.board} '
          'part (${b.config.size} bytes)',
        );
      }
    }
  }

  /// The DDR board definition, when this is a board-qualified `dram` device.
  DdrBoard? get ddrBoard => type == 'dram' ? DdrBoard.byName[board] : null;

  /// The flash board definition, when this is a board-qualified `flash` device.
  FlashBoard? get flashBoard =>
      type == 'flash' && board != null ? FlashBoard.byName[board] : null;

  /// The bus window size: the explicit [size] or the peripheral class default.
  int get effectiveSize => size ?? _defaultSizes[type] ?? 0x1000;

  /// True when this device is a sized, memory-backed region (`sram`/`flash`/
  /// `dram`) rather than an MMIO peripheral or a pseudo-device.
  bool get isMemoryBacked => _memBacked.contains(type);
}

/// Target for RTL generation, either FPGA or ASIC.
///
/// FPGA format: `ecp5:lfe5u-45f:CABGA381` or `ice40:up5k:sg48`
/// ASIC format: `sky130:hd` or `gf180mcu:3v3`
// TODO: replace with the harbor target class
sealed class Target {
  const Target();

  static Target parse(String spec) {
    final parts = spec.split(':');
    // Verilator simulation target: `verilator`, optionally `verilator:trace`.
    // It has no device or package, so it is handled before the
    // vendor:device:package arity check below.
    if (parts[0] == 'verilator' || parts[0] == 'sim') {
      // `verilator[:trace][:threads=N]`. threads is the run-time thread count
      // of the Verilated model; omit it for the single-threaded default.
      var simThreads = 1;
      for (final p in parts) {
        if (p.startsWith('threads=')) {
          simThreads = int.parse(p.substring('threads='.length));
        }
      }
      return SimTarget(trace: parts.contains('trace'), threads: simThreads);
    }
    if (parts.length < 2) {
      throw FormatException(
        'Target format: vendor:device[:package], got: $spec',
      );
    }
    switch (parts[0]) {
      case 'ecp5':
      case 'ice40':
      case 'spartan7':
        if (parts.length != 3) {
          throw FormatException(
            'FPGA target format: vendor:device:package, got: $spec',
          );
        }
        return FpgaTarget(
          vendor: parts[0],
          device: parts[1],
          package: parts[2],
        );
      case 'sky130':
        return AsicTarget(
          pdk: 'sky130',
          variant: parts.length > 1 ? parts[1] : 'hd',
        );
      case 'gf180mcu':
        return AsicTarget(
          pdk: 'gf180mcu',
          variant: parts.length > 1 ? parts[1] : '3v3',
        );
      default:
        throw UnsupportedError('Unknown target vendor: ${parts[0]}');
    }
  }

  HarborDeviceTarget toHarborTarget({
    required String topCell,
    required int frequency,
    Map<String, String> pins = const {},
    Map<String, String> extraConstraints = const {},
    String? pdkRoot,
  });
}

// TODO: replace with the harbor target class
class FpgaTarget extends Target {
  final String vendor;
  final String device;
  final String package;

  const FpgaTarget({
    required this.vendor,
    required this.device,
    required this.package,
  });

  @override
  HarborDeviceTarget toHarborTarget({
    required String topCell,
    required int frequency,
    Map<String, String> pins = const {},
    Map<String, String> extraConstraints = const {},
    String? pdkRoot,
  }) {
    switch (vendor) {
      case 'ecp5':
        return HarborFpgaTarget.ecp5(
          device: device,
          package: package,
          frequency: frequency,
          pinMap: pins,
          extraConstraints: extraConstraints,
        );
      case 'ice40':
        return HarborFpgaTarget.ice40(
          device: device,
          package: package,
          frequency: frequency,
          pinMap: pins,
          extraConstraints: extraConstraints,
        );
      case 'spartan7':
        // Xilinx Spartan-7 via the open-source openXC7 flow (yosys
        // synth_xilinx + nextpnr-xilinx + prjxray), the only Xilinx flow that
        // runs natively on this aarch64 box (x86 Vivado/qemu is unavailable).
        return HarborFpgaTarget.spartan7(
          device: device,
          package: package,
          frequency: frequency,
          pinMap: pins,
          extraConstraints: extraConstraints,
          useOpenXc7: true,
        );
      default:
        throw UnsupportedError('Unknown FPGA vendor: $vendor');
    }
  }
}

/// Verilator simulation target. Selected with `--target verilator` (or
/// `verilator:trace`). It maps to Harbor's [HarborSimTarget], which drives the
/// Verilator build emission in `HarborSoC.generateAll` (the C++ harness
/// `sim/main.cpp`, the Verilator `Makefile`, and the remote_bitbang OpenOCD
/// config). Un-Verilatable vendor IP (the DDR PHY, config-JTAG primitives)
/// swaps to a behavioral body under this target, and the debug TAP is exposed
/// as real top-level pins for the harness to bit-bang, so no config-JTAG tunnel.
class SimTarget extends Target {
  /// Emit FST waveform tracing (opt-in; a large run-time cost).
  final bool trace;

  /// Verilator `--trace-depth`, ignored when [trace] is false.
  final int traceDepth;

  /// Optimisation level for Verilator and the generated C++.
  final int optLevel;

  /// Extra Verilator warnings to suppress on top of Harbor's defaults.
  final List<String> extraWarningsOff;

  /// Run-time thread count of the Verilated model (`--threads`). 1 keeps the
  /// single-threaded model; above 1 partitions the sim across host threads.
  final int threads;

  const SimTarget({
    this.trace = false,
    this.traceDepth = 99,
    this.optLevel = 3,
    this.extraWarningsOff = const [],
    this.threads = 1,
  });

  @override
  HarborDeviceTarget toHarborTarget({
    required String topCell,
    required int frequency,
    // Verilator has no pins, constraints, or PDK; those are ignored.
    Map<String, String> pins = const {},
    Map<String, String> extraConstraints = const {},
    String? pdkRoot,
  }) => HarborSimTarget(
    topCell: topCell,
    frequency: frequency,
    trace: trace,
    traceDepth: traceDepth,
    optLevel: optLevel,
    extraWarningsOff: extraWarningsOff,
    threads: threads,
  );
}

// TODO: replace with the harbor target class
class AsicTarget extends Target {
  final String pdk;
  final String variant;

  const AsicTarget({required this.pdk, required this.variant});

  PdkProvider _createProvider(String pdkRoot) {
    switch (pdk) {
      case 'sky130':
        final sky130Variant =
            {
              'hd': Sky130Variant.hd,
              'hs': Sky130Variant.hs,
              'ms': Sky130Variant.ms,
              'ls': Sky130Variant.ls,
              'lp': Sky130Variant.lp,
              'hdll': Sky130Variant.hdll,
            }[variant] ??
            Sky130Variant.hd;
        return Sky130Provider(pdkRoot: pdkRoot, variant: sky130Variant);
      case 'gf180mcu':
        final voltage = variant == '5v0'
            ? Gf180mcuVoltage.v5_0
            : Gf180mcuVoltage.v3_3;
        return Gf180mcuProvider(pdkRoot: pdkRoot, voltage: voltage);
      default:
        throw UnsupportedError('Unknown PDK: $pdk');
    }
  }

  @override
  HarborDeviceTarget toHarborTarget({
    required String topCell,
    required int frequency,
    Map<String, String> pins = const {},
    Map<String, String> extraConstraints = const {},
    String? pdkRoot,
  }) {
    if (pdkRoot == null) {
      throw ArgumentError('ASIC target requires --pdk-root');
    }
    return HarborAsicTarget(
      provider: _createProvider(pdkRoot),
      topCell: topCell,
      frequency: frequency,
    );
  }
}

/// Pin assignment: maps an external signal name to a device port and FPGA pin.
///
/// Format: `external_name=device@port:fpga_pin`
///
/// Example: `--pin uart_tx=uart@tx:B6`
class PinAssignment {
  /// External signal name (used in constraint file and SoC top-level port).
  final String externalName;

  /// Device name (as given in --device).
  final String deviceName;

  /// Port name on the device.
  final String portName;

  /// FPGA physical pin (e.g., `B6`, `A9`).
  final String fpgaPin;

  const PinAssignment({
    required this.externalName,
    required this.deviceName,
    required this.portName,
    required this.fpgaPin,
  });

  /// Parses `external_name=device@port:fpga_pin`.
  static PinAssignment parse(String spec) {
    final eq = spec.indexOf('=');
    if (eq < 0) {
      throw FormatException('Pin format: name=device@port:pin, got: $spec');
    }
    final externalName = spec.substring(0, eq);
    final rest = spec.substring(eq + 1);

    final at = rest.indexOf('@');
    if (at < 0) {
      // Simple format: name=pin (for clk, etc.)
      return PinAssignment(
        externalName: externalName,
        deviceName: '',
        portName: '',
        fpgaPin: rest,
      );
    }

    final deviceName = rest.substring(0, at);
    final afterAt = rest.substring(at + 1);
    final colon = afterAt.indexOf(':');
    if (colon < 0) {
      throw FormatException('Pin format: name=device@port:pin, got: $spec');
    }
    return PinAssignment(
      externalName: externalName,
      deviceName: deviceName,
      portName: afterAt.substring(0, colon),
      fpgaPin: afterAt.substring(colon + 1),
    );
  }

  bool get isDevicePin => deviceName.isNotEmpty;
}

class RiverGenIpConfig {
  final String name;
  final List<String> cores;
  final String interconnect;
  final int clockFrequency;
  final int oscFrequency;

  /// The unified `--device` list: every addressed thing in the SoC (memory-backed
  /// regions, MMIO peripherals, and the usb-dfu/debug-jtag/flash-firmware
  /// pseudo-devices). [memories] and [mmioDevices] are typed views over this.
  final List<Device> devices;
  final Target? target;

  /// Optional board name (`--board arty-s7-50`): pulls the FPGA target identity
  /// (when [target] is unset) and the board's standard pin catalog (clk/uart/...)
  /// from the Harbor [HarborBoard.byName] registry, so a build need not hand-enter
  /// the target and boilerplate `--pin`s. Explicit `--pin` still overrides.
  final String? boardName;

  final List<PinAssignment> pins;
  final String? maskromPath;
  final String? pdkRoot;

  /// Bakes a built-in boot program directly into an on-chip boot ROM at
  /// [bootRomBase] and boots from it. This is the "skip cache-as-RAM" path
  /// for SRAM-class systems: the program runs straight from the boot ROM and
  /// uses the data RAM directly, with no copy/training bootstrap.
  ///
  /// Programs: `hello` ([RiverHelloWorld] bring-up smoke test), `monitor`
  /// ([RiverSerialMonitor], loads payloads into RAM over the UART), and
  /// `hexdump` ([RiverFlashHexdump], dumps two flash windows over the UART
  /// straight from ROM, a SILENT-bring-up probe with no flash/maskrom
  /// dependency).
  final String? bootProgram;

  /// When false, restrict the core to bare (no-paging) mode (machine-mode
  /// bring-up). Defaults to the full-MMU build.
  final bool enableMmu;

  /// Address of the on-chip boot ROM (maskrom / boot demo).
  static const int bootRomBase = 0x00010000;

  /// Diagnostic: the baked `ddrtest` writes/reads ONLY the first DRAM word
  /// (isolates a broken read path from BL8-line DM-mask clobber).
  final bool ddrSingleWord;

  const RiverGenIpConfig({
    required this.name,
    required this.cores,
    this.interconnect = 'wishbone',
    this.clockFrequency = 48000000,
    this.oscFrequency = 12000000,
    this.devices = const [],
    this.target,
    this.boardName,
    this.pins = const [],
    this.maskromPath,
    this.pdkRoot,
    this.bootProgram,
    this.enableMmu = true,
    this.ddrSingleWord = false,
  });

  // --- Typed views over the unified [devices] list ---

  /// Types that are not addPeripheral MMIO slaves: the memory-backed regions and
  /// the pseudo-devices that drive a subsystem integration instead.
  static const _pseudoTypes = {'usb-dfu', 'debug-jtag', 'flash-firmware'};

  /// The memory-backed regions (`sram`/`flash`/`dram`), preserving `--device`
  /// order, as [MemoryRegion] value objects so the memory build loop and the
  /// region getters read them unchanged.
  List<MemoryRegion> get memories => [
    for (final d in devices)
      if (d.isMemoryBacked)
        MemoryRegion(
          address: d.address!,
          size: d.size!,
          type: d.type,
          board: d.board,
          ddrParams: d.params,
        ),
  ];

  /// The fixed-function MMIO peripherals (`uart`/`clint`/`plic`/`gpio`/...): every
  /// device that is neither memory-backed nor a pseudo-device. This is what the
  /// peripheral loop, PLIC source count, and pin binding iterate.
  List<DeviceEntry> get mmioDevices => [
    for (final d in devices)
      if (!d.isMemoryBacked && !_pseudoTypes.contains(d.type))
        DeviceEntry(
          name: d.name,
          type: d.type,
          address: d.address!,
          compatible: d.compatible,
          params: d.params,
        ),
  ];

  Device? _firstDeviceOfType(String type) {
    for (final d in devices) {
      if (d.type == type) return d;
    }
    return null;
  }

  // --- usb-dfu (derived from a `usb-dfu` device) ---

  /// True when a `usb-dfu` device is present: integrate the USB DFU subsystem.
  bool get usbDfu => _firstDeviceOfType('usb-dfu') != null;

  /// DFU integration style, from the `usb-dfu` device's `mode` param (default
  /// [UsbDfuMode.hardware], the heavy RAM-sink path).
  UsbDfuMode get usbDfuMode =>
      _firstDeviceOfType('usb-dfu')?.params?.mode == 'software'
      ? UsbDfuMode.software
      : UsbDfuMode.hardware;

  /// MMIO base of the DFU status/control block: the `usb-dfu` device address, or
  /// the default free window clear of flash/clint/plic/uart/sram.
  int get dfuStatusBase => _firstDeviceOfType('usb-dfu')?.address ?? 0x0C000000;

  /// CONTROL register (write 1 -> usb_enable). Word offset 1.
  int get dfuControlAddr => dfuStatusBase + 0x04;

  /// STATUS register (bit0 = image_ready). Word offset 0.
  int get dfuStatusAddr => dfuStatusBase + 0x00;

  /// ENTRY register (RAM entry address). Word offset 2.
  int get dfuEntryAddr => dfuStatusBase + 0x08;

  /// RXDATA register (captured download byte) in [UsbDfuMode.software].
  int get dfuRxDataAddr => dfuStatusBase + 0x08;

  // --- debug-jtag (derived from a `debug-jtag` device) ---

  /// True when a `debug-jtag` device is present: wire the JTAG debug subsystem
  /// (TAP+DTM+DM+SBA) as a second fabric master and build the core with debug.
  bool get enableDebug => _firstDeviceOfType('debug-jtag') != null;

  /// Number of hardware execute-breakpoint triggers requested on the debug-jtag
  /// device (`debug-jtag:triggers=N`). 0 when absent.
  int get debugTriggers =>
      _firstDeviceOfType('debug-jtag')?.params?.triggers ?? 0;

  /// Sticky user-mode excursion probe requested on the debug-jtag device
  /// (`debug-jtag:userprobe=true`). False when absent.
  bool get userModeProbe =>
      _firstDeviceOfType('debug-jtag')?.params?.userProbe ?? false;

  // --- flash-firmware (derived from a `flash-firmware` device) ---

  /// Built-in firmware program baked into flash (the device `program` param).
  String? get flashFirmware =>
      _firstDeviceOfType('flash-firmware')?.params?.program;

  /// External firmware binary bundled into flash (the device `path` param). Takes
  /// precedence over [flashFirmware].
  String? get flashFirmwarePath =>
      _firstDeviceOfType('flash-firmware')?.params?.path;

  /// Byte offset into the SPI flash where the bundled firmware lives (the
  /// `flash-firmware` device address). Default 1 MiB, clear of the bitstream.
  int get flashFirmwareOffset =>
      _firstDeviceOfType('flash-firmware')?.address ?? 0x100000;

  // --- DDR clock/datapath (derived from the `dram` devices) ---
  // Whole-SoC aggregates: the single-controller RTL stays byte-identical to the
  // old global flags.

  /// True when ANY `dram` device selects the ISERDESE2 datapath.
  bool get ddr3Fast => devices.any(
    (d) =>
        d.type == 'dram' &&
        ((d.params?.ddr3Fast ?? false) || (d.params?.ddr3v2 ?? false)),
  );

  /// DRAM clock-domain (CDC) frequency: the first `dram` device that sets one.
  int? get ddrClockFrequency {
    for (final d in devices) {
      if (d.type == 'dram' && d.params?.clockFreq != null) {
        return d.params!.clockFreq;
      }
    }
    return null;
  }

  /// Separate DDR3 oscillator (mints the shared `ddr_osc` pin): the first `dram`
  /// device that sets one.
  int? get ddrOscFrequency {
    for (final d in devices) {
      if (d.type == 'dram' && d.params?.oscFreq != null) {
        return d.params!.oscFreq;
      }
    }
    return null;
  }

  /// The clock-tree params (`ddr3fast`/`clockfreq`/`oscfreq`) mint ONE shared
  /// `ddr_osc` pin and one DDR3 MMCM tree, so every `dram` controller shares them.
  /// Two disagreeing `dram` devices would silently get the first one's clock, so
  /// throw instead. Per-region data-eye tuning (cmdslot/wrshift/readtap/trainable)
  /// may still differ. Independent per-controller trees are future work.
  void _validateDdrClockAgreement() {
    final drams = [
      for (final d in devices)
        if (d.type == 'dram') d,
    ];
    if (drams.length < 2) return;
    bool differ<T>(T Function(Device) sel) => drams.map(sel).toSet().length > 1;
    if (differ((d) => d.params?.ddr3Fast ?? false) ||
        differ((d) => d.params?.clockFreq) ||
        differ((d) => d.params?.oscFreq)) {
      throw ArgumentError(
        'Multiple dram devices must agree on the shared-clock-tree params '
        '(ddr3fast/clockfreq/oscfreq): they mint one shared ddr_osc pin and one '
        'DDR3 clock tree. Per-controller data-eye tuning (cmdslot/wrshift/readtap/'
        'trainable/readretry/window/etc) may still differ; independent '
        'per-controller clock trees are not yet supported.',
      );
    }
  }

  /// The first `flash` memory region (the SPI NOR XIP window), or null.
  MemoryRegion? get flashRegion {
    for (final mem in memories) {
      if (mem.type == 'flash') return mem;
    }
    return null;
  }

  /// The first `sram` region (the bundled-firmware copy target), or null.
  MemoryRegion? get sramRegion => dfuRamRegion;

  /// The SRAM region the DFU image is downloaded into (= the RAM-sink loadBase
  /// and the maskrom jump target). Picks the first `sram` region.
  MemoryRegion? get dfuRamRegion {
    for (final mem in memories) {
      if (mem.type == 'sram') return mem;
    }
    return null;
  }

  static const _coreModels = {
    'rc1-n': RiverCoreConfigV1.nano,
    'rc1-mi': RiverCoreConfigV1.micro,
    'rc1-s': RiverCoreConfigV1.small,
    'rc1-m': RiverCoreConfigV1.macro,
    // River Core V1 Full: the full ISA with the F/D FPU. This is the core the
    // Delta SoC family carries, so a stock rv64gc/lp64d NixOS runs.
    'rc1-f': RiverCoreConfigV1.full,
  };

  RiscVMxlen get mxlen {
    final primaryCore = cores.first;
    switch (primaryCore) {
      case 'rc1-n':
      case 'rc1-mi':
        return RiscVMxlen.rv32;
      default:
        return RiscVMxlen.rv64;
    }
  }

  RiverCoreConfig buildCoreConfig(
    HarborClockConfig clock,
    String coreModel, {
    int hartId = 0,
  }) {
    // When [enableMmu] is false, restrict the core to bare (no-paging) mode so
    // `HarborMmuConfig.hasPaging` is false: the core/MMU gate off the entire
    // Sv39 page-table-walk datapath + satp/SUM/MXR hookups, leaving only the
    // bare bus arbiter. Used for machine-mode bring-up bitstreams.
    final pagingOn = enableMmu && mxlen == RiscVMxlen.rv64;
    final mmu = HarborMmuConfig(
      mxlen: mxlen,
      pagingModes: pagingOn
          ? const [RiscVPagingMode.bare, RiscVPagingMode.sv39]
          : const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
      hasSupervisorUserMemory: pagingOn,
      hasMakeExecutableReadable: pagingOn,
    );

    final factory = _coreModels[coreModel];
    if (factory == null) {
      throw UnsupportedError('Unknown core model: $coreModel');
    }

    return factory(
      hartId: hartId,
      mmu: mmu,
      interrupts: [],
      clock: clock,
      resetVector:
          (maskromPath != null ||
              bootProgram != null ||
              usbDfu ||
              flashFirmware != null ||
              flashFirmwarePath != null)
          ? bootRomBase
          : (memories.isNotEmpty ? memories.first.address : 0),
    );
  }

  WishboneConfig buildBusConfig() => WishboneConfig(
    addressWidth: mxlen.size,
    dataWidth: mxlen.size,
    selWidth: mxlen.size ~/ 8,
  );

  /// The resolved Harbor board, when `--board` names one.
  HarborBoard? get board =>
      boardName != null ? HarborBoard.get(boardName!) : null;

  /// The effective FPGA/ASIC target: the explicit `--target`, else one
  /// synthesised from the `--board` identity (so the board can stand in for
  /// `--target`). The synthesised target routes through the same [FpgaTarget]
  /// path as `--target`, so the generated RTL is identical.
  Target? get effectiveTarget {
    if (target != null) return target;
    final b = board;
    if (b == null) return null;
    final vendor = switch (b.vendor) {
      HarborFpgaVendor.ice40 => 'ice40',
      HarborFpgaVendor.ecp5 => 'ecp5',
      HarborFpgaVendor.vivado => 'spartan7',
      HarborFpgaVendor.openXc7 => 'spartan7',
    };
    return FpgaTarget(vendor: vendor, device: b.device, package: b.package);
  }

  /// A board catalog entry turned into a [PinAssignment]. A key shaped like
  /// `<device>_<port>` whose `<device>` matches an MMIO device binds to that
  /// device port (like `--pin uart_tx=uart@tx:<site>`). Anything else is a simple
  /// pin (constraint only, e.g. `clk`, `ddr_osc`). The value is the catalog
  /// `"SITE [IO_TYPE] [ATTR]"` string.
  PinAssignment _boardPinAssignment(String signal, String site) {
    final us = signal.indexOf('_');
    if (us > 0) {
      final devName = signal.substring(0, us);
      final port = signal.substring(us + 1);
      if (mmioDevices.any((d) => d.name == devName)) {
        return PinAssignment(
          externalName: signal,
          deviceName: devName,
          portName: port,
          fpgaPin: site,
        );
      }
    }
    return PinAssignment(
      externalName: signal,
      deviceName: '',
      portName: '',
      fpgaPin: site,
    );
  }

  /// The user `--pin` assignments plus the board catalog pins for any signal the
  /// user did not already assign (explicit `--pin` wins). Board device-convention
  /// entries become device bindings, the rest are simple constraint pins.
  List<PinAssignment> get effectivePins {
    final b = board;
    final catalog = b == null
        ? pins
        : [
            for (final e in b.pins.entries)
              if (!{for (final p in pins) p.externalName}.contains(e.key))
                _boardPinAssignment(e.key, e.value),
            ...pins,
          ];
    return [...catalog, ..._ifacePins];
  }

  /// SPI role -> the HarborSpiController pad each connector role drives. The
  /// board connector bakes the wiring convention (e.g. Digilent Pmod-SPI), so
  /// this is a fixed role vocabulary the `spi` device consumes.
  static const _spiIfaceRoleToPort = {
    'cs': 'spi_cs_n',
    'mosi': 'spi_mosi',
    'miso': 'spi_miso',
    'sck': 'spi_clk',
  };

  /// Device-bound pin assignments synthesised from a device's `iface=<name>`.
  /// Each `spi` device with an interface binds its four pads to the named board
  /// connector's `cs`/`mosi`/`miso`/`sck` sites. The external pin name is
  /// prefixed with the device name so it never collides with the config-flash
  /// SPI pads (which also expose `spi_cs_n`).
  List<PinAssignment> get _ifacePins {
    final out = <PinAssignment>[];
    for (final dev in devices) {
      final ifaceName = dev.params?.iface;
      if (ifaceName == null) continue;
      if (dev.type != 'spi') {
        throw ArgumentError(
          'iface= is only supported on `spi` devices, not "${dev.type}"',
        );
      }
      final b = board;
      if (b == null) {
        throw ArgumentError(
          'device "${dev.name}" has iface=$ifaceName but no --board is set to '
          'resolve the connector; add board=<name> to the SoC',
        );
      }
      final conn = b.interfaces[ifaceName];
      if (conn == null) {
        throw ArgumentError(
          'board "${b.name}" has no interface "$ifaceName"; '
          'known: ${b.interfaces.keys.join(', ')}',
        );
      }
      _spiIfaceRoleToPort.forEach((role, port) {
        final site = conn[role];
        if (site == null) {
          throw ArgumentError(
            'interface "$ifaceName" on board "${b.name}" is missing the SPI '
            'role "$role" (need cs/mosi/miso/sck)',
          );
        }
        out.add(
          PinAssignment(
            externalName: '${dev.name}_$role',
            deviceName: dev.name,
            portName: port,
            fpgaPin: site,
          ),
        );
      });
    }
    return out;
  }

  Map<String, String> get fpgaPinMap => {
    for (final p in effectivePins) p.externalName: p.fpgaPin,
    // Board-qualified dram/flash regions bring their whole pad constraint table.
    // DQS constraints are DLL-aware ([DdrBoard.pinsFor]). DLL-ON: the single
    // SSTL135D_I diff pad (nextpnr derives _n). DLL-OFF: the explicit
    // pseudo-differential pair (sdram_dqs[*] SSTL135_I + sdram_dqs_n[*]), matching
    // the complement ODDR the PHY drives. dllOn = DDR CK rate > ~60 MHz.
    for (final mem in memories)
      if (mem.ddrBoard != null)
        ...mem.ddrBoard!.pinsFor(
          dllOn:
              (ddrClockFrequency != null && ddrClockFrequency! > oscFrequency)
              ? ddrClockFrequency! > 60000000
              : oscFrequency > 60000000,
        ),
    for (final mem in memories)
      if (mem.flashBoard != null) ...mem.flashBoard!.pins,
  };

  HarborDeviceTarget? buildTarget() => effectiveTarget?.toHarborTarget(
    topCell: name,
    // The `clk` pin is the external oscillator, so its LPF FREQUENCY constraint
    // must be the oscillator frequency, NOT the post-PLL system frequency. A wrong
    // input frequency makes nextpnr derive the PLL VCO for the wrong band (e.g.
    // 24 MHz in -> VCO 300 MHz, out of range), so the PLL never locks and the
    // silicon stays in reset.
    frequency: oscFrequency,
    pins: fpgaPinMap,
    extraConstraints: _ddrClockBelConstraints,
    pdkRoot: pdkRoot,
  );

  /// openXC7 clock-BEL placement constraints for the ddr3Fast DDR3 PHY.
  ///
  /// All DDR clocks (CK / CLKDIV / idelayref / ck90) ride plain GLOBAL BUFGs and
  /// the read ISERDESE2 CLK shares the CK BUFG net, with zero regional BUFH/BUFHCE
  /// (matching the HW-verified UberDDR3 oracle). A global BUFG reaches any region's
  /// HCLK leaf, so there is no region to mis-bind, so NO constraints are emitted.
  Map<String, String> get _ddrClockBelConstraints => const {};

  /// Builds the bundled flash firmware image for the primary core, for emitting
  /// as a standalone `firmware.bin` (flashed at [flashFirmwareOffset]).
  Future<Uint8List> buildFlashFirmwareImage() async {
    final coreClock = HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(clockFrequency),
    );
    final primaryConfig = buildCoreConfig(coreClock, cores.first);
    return buildFlashFirmware(primaryConfig);
  }

  Future<HarborSoC> buildSoC() async {
    _validateDdrClockAgreement();
    // Single-oscillator Xilinx DDR3-fast (e.g. the Arty S7, one 100 MHz R2 osc):
    // a second MMCM on the raw clock pin cannot share the pin's one dedicated
    // clock-capable route on openXC7, so the core MMCM never clocks and the core
    // never leaves reset. Fold the core clock onto a spare CLKOUT of the DDR3
    // MMCM instead (one MMCM on the pin). A separate `ddr_osc` pin has no
    // contention and keeps its own core MMCM.
    // Under Verilator there is no Xilinx MMCM/PLL to build the DDR3 clock tree
    // (BUFG/PLLE2_ADV have no sim model), and the behavioral DRAM runs off the
    // plain bus clock, so never hang the core clock off a DDR tree in sim: fall
    // back to the behavioral clock generation like a boardless SoC.
    final useDdr3TreeCoreClk =
        ddr3Fast && ddrOscFrequency == null && effectiveTarget is! SimTarget;
    // DDR controller gearing (shared tree): the CK/8 gearbox controller when any
    // ddr3v2 DRAM sets ctrlgear=2. One tree serves every controller, so they use
    // one gearRatio (the per-device HarborDdr3 controllerGearRatio matches it).
    final ddrGearRatio = memories
        .where((m) => m.ddrParams?.ddr3v2 ?? false)
        .map((m) => m.ddrParams?.ctrlGear ?? 1)
        .fold<int>(1, (a, b) => b > a ? b : a);
    final xilinxDdr3Tree = useDdr3TreeCoreClk
        ? XilinxDdr3TreeSpec(
            sourceHz: oscFrequency,
            ddrCkHz: ddrClockFrequency ?? 333333333,
            coreClkHz: clockFrequency,
            dqsPhaseDeg: 180.0,
            ddrGearRatio: ddrGearRatio,
          )
        : null;
    final coreClock = HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(clockFrequency),
    );

    final coreConfigs = cores.indexed
        .map((e) => buildCoreConfig(coreClock, e.$2, hartId: e.$1))
        .toList();
    final busConfig = buildBusConfig();
    final target = buildTarget();

    // The PLIC context plan: one context per privilege level that claims
    // interrupts, machine first then supervisor, hart by hart. A hart without
    // the S extension gets only its machine context.
    //
    // This ONE list decides three things that must agree: how many contexts the
    // PLIC is built with, which core input each `ext_irq_<N>` drives, and the
    // `interrupts-extended` pairs in the device tree. Deriving them separately
    // is how the sources came to dangle in the first place.
    final interruptContexts = <HarborInterruptContext>[
      for (final c in coreConfigs) ...[
        HarborInterruptContext.machine(c.hartId),
        if (c.hasSupervisor) HarborInterruptContext.supervisor(c.hartId),
      ],
    ];

    // The clk90 DDR controller (DLL-off, CK = system clock) shares the single SoC
    // clock domain: no separate DRAM clock, CDC bridge, or train-control MMIO. The
    // matching GenIpConfig knobs are retained as accepted-but-ignored no-ops.

    // A board-backed DRAM region runs its DQS PHY on the `ddr` clock domain while
    // the core/fabric runs on the divided `sys` clock. The `ddr` domain is the raw
    // osc (48 MHz CK, DLL-off) by default, or a PLL output at --ddr-clock-freq
    // (e.g. 144 MHz CK, DLL-on) when set above the osc. The controller bridges its
    // slow `bus` face with an internal HarborWishboneCdcBridge (asyncClock). The
    // PHY halves `ddr_clk` to the sclk fabric the DQS x2 datapath runs on.
    final hasDdrBoard = memories.any((m) => m.ddrBoard != null);
    // ddr3Fast provides its OWN clocking (the DDR3 MMCM tree built inline below),
    // so it does NOT use the ECP5-style shared `ddr`/`sys` PLL domain. The core
    // rides a standalone `sys` domain and the DDR controller runs on the tree's
    // ctrl83 (asyncClock), so the ECP5 DDR clock plumbing is gated off here.
    final ecp5DdrDomain = hasDdrBoard && !ddr3Fast;

    final soc = HarborSoC(
      name: name,
      compatible: 'lilith,${name.replaceAll('_', '-')}',
      busConfig: busConfig,
      acpiOemId: 'LILSMI',
      acpiOemTableId: 'RIVER',
      interruptContexts: interruptContexts,
      // An FPGA target normally resets only at configuration (power-on). A
      // `reset_n=<pad>` pin (e.g. a board RESET button) adds an active-low
      // external reset ORed into that POR, so a press restarts the SoC. The
      // pad is constrained by the generic pin loop; here we just enable the port.
      externalReset: pins.any((p) => p.externalName == 'reset_n'),
      cpus: coreConfigs
          .map(
            (coreConfig) => HarborCpu(
              hartId: coreConfig.hartId,
              isa: coreConfig.isa.implementsString,
              clockFrequency: clockFrequency,
              // The CLINT ticks mtime once per bus clock, so the timer's
              // timebase equals the SoC clock.
              timebaseFrequency: clockFrequency,
              mmu: coreConfig.mmu.hasPaging ? 'riscv,sv39' : null,
            ),
          )
          .toList(),
      target: target,
      xilinxDdr3Tree: xilinxDdr3Tree,
      clocks: [
        // System/bus domain: PLL from the osc down to the core clock. This is
        // [defaultClock], so every master/peripheral lands here by default. When
        // a DDR board is present the `sys` domain instead rides the DDR PLL's
        // CLKOS (the `ddr` entry below is the CLKOP primary, since nextpnr only
        // routes the dedicated ECLK network from CLKOP), sharing one EHXPLLL. So a
        // standalone sys domain is only added when there is NO DDR board.
        if (!ecp5DdrDomain)
          HarborClockConfig(
            name: 'sys',
            rate: HarborFixedClockRate(clockFrequency),
            sourceFrequency: oscFrequency,
            // Single-oscillator Xilinx DDR3-fast: run the core off the DDR MMCM's
            // spare core CLKOUT instead of a second MMCM contending for the pin.
            providedByDdr3Tree: useDdr3TreeCoreClk,
          ),
        // USB full-speed domain: the RAW oscillator, passed straight through
        // (isPrimary). The 48 MHz osc is already the SoC `clk`, handed to the USB
        // engine while the core runs on the PLL-divided `sys`. Only when USB DFU
        // is integrated.
        if (usbDfu)
          HarborClockConfig(
            name: 'usb',
            rate: HarborFixedClockRate(oscFrequency),
            isPrimary: true,
          ),
        // DDR domain. Two cases, keyed on --ddr-clock-freq (ddrClockFrequency):
        //   - unset or <= osc: the RAW osc (48 MHz), DLL-OFF at the osc rate (the
        //     proven bring-up path), no DRAM DLL lock.
        //   - above the osc (e.g. 144 MHz): an EHXPLLL CLKOP from the osc, so the
        //     DRAM CK runs faster than the core. At 144 MHz the DRAM DLL locks and
        //     the DQSBUFM DLL-on read scheme works, CDC bridging the slow `sys` bus
        //     face. 48 -> 144 is a clean ECP5 target (VCO 576 MHz, in band).
        // Only when a board-backed DRAM region is present.
        if (ecp5DdrDomain)
          (ddrClockFrequency != null && ddrClockFrequency! > oscFrequency)
              // DLL-ON: the DDR CK is the CLKOP primary (its eclk needs the
              // dedicated ECLK network) and the core/sys clock rides CLKOS off the
              // same VCO. VCO = ddrCk*CLKOP_DIV (576) must be an integer multiple
              // of the core clock. The CLKOS_CPHASE fix in
              // createDomainWithSecondary makes this single PLL lock on silicon.
              ? HarborClockConfig(
                  name: 'ddr',
                  rate: HarborFixedClockRate(ddrClockFrequency!),
                  sourceFrequency: oscFrequency,
                  coClkosSecondary: (name: 'sys', frequency: clockFrequency),
                )
              // DLL-OFF: the DDR CK is a real PLL CLKOP with the core/sys clock on
              // CLKOS off the same PLL. Default CK = osc (48->48). Setting
              // --ddr-clock-freq below the osc (e.g. 24 MHz) halves the CK, which
              // doubles the absolute DLL-off read eye so the marginal DQS jitter is
              // a smaller eye fraction. The ECP5 ECLK network only routes from a
              // PLL CLKOP, not a raw osc pad. Sharing one PLL for ddr+sys leaves
              // the 2nd EHXPLLL for the DQS clk90.
              : HarborClockConfig(
                  name: 'ddr',
                  rate: HarborFixedClockRate(
                    (ddrClockFrequency != null &&
                            ddrClockFrequency! < oscFrequency)
                        ? ddrClockFrequency!
                        : oscFrequency,
                  ),
                  sourceFrequency: oscFrequency,
                  coClkosSecondary: (name: 'sys', frequency: clockFrequency),
                ),
      ],
    );

    // The CLINT (if present) drives each hart's machine timer/software interrupt
    // lines. The core is built before the peripherals, so make a net per hart
    // now, feed it to the core, and connect the CLINT output to it after the
    // peripheral loop below.
    final hasClint = mmioDevices.any((d) => d.type == 'clint');
    final coreTimerNets = <Logic>[];
    final coreSwNets = <Logic>[];
    final coreTimeNets = <Logic>[];

    // The PLIC (if present) drives each hart's machine EXTERNAL interrupt line
    // (mip.MEIP). Same shape as the CLINT nets above: make a net per hart now,
    // feed it to the core, and connect the PLIC `ext_irq_<hart>` output to it
    // after the peripheral loop below. Without this the core has no external
    // interrupt input at all, so a device interrupt can never reach software.
    final hasPlic = mmioDevices.any((d) => d.type == 'plic');
    final coreExtNets = <Logic>[];
    // The supervisor-external counterpart (mip.SEIP), one per hart that has the
    // S extension. An S-mode OS claims from its OWN PLIC context, so this is a
    // second line and not a copy of the machine one.
    final coreSeiNets = <int, Logic>{};

    RiverCore? debugCore;
    var hartIndex = 0;
    for (final coreConfig in coreConfigs) {
      Logic? timerNet;
      Logic? swNet;
      Logic? timeNet;
      if (hasClint) {
        timerNet = Logic(name: 'core${hartIndex}_timer_pending');
        swNet = Logic(name: 'core${hartIndex}_sw_pending');
        // The 64-bit CLINT mtime, fed to the core's `time` CSR (rdtime).
        timeNet = Logic(name: 'core${hartIndex}_time', width: 64);
        coreTimerNets.add(timerNet);
        coreSwNets.add(swNet);
        coreTimeNets.add(timeNet);
      }
      Logic? extNet;
      Logic? seiNet;
      if (hasPlic) {
        extNet = Logic(name: 'core${hartIndex}_ext_pending');
        coreExtNets.add(extNet);
        if (coreConfig.hasSupervisor) {
          seiNet = Logic(name: 'core${hartIndex}_sei_pending');
          coreSeiNets[coreConfig.hartId] = seiNet;
        }
      }
      final core = RiverCore(
        coreConfig,
        busConfig: busConfig,
        target: target,
        withDebug: enableDebug,
        debugTriggers: enableDebug ? debugTriggers : 0,
        userProbe: enableDebug && userModeProbe,
        srcIrqs: extNet == null ? const {} : {'extPending': extNet},
        supervisorExternalPending: seiNet,
        timerPending: timerNet,
        swPending: swNet,
        timeIn: timeNet,
      );
      soc.addMaster(core, busInterfaceName: 'dataBus');
      debugCore ??= core;
      hartIndex++;
    }

    // Boot ROM. The hello-world demo bakes the application directly into the
    // ROM (skip cache-as-RAM: the core runs from ROM and uses SRAM directly).
    // Otherwise a maskrom path requests the copy/training bootstrap.
    if (bootProgram != null) {
      final primaryConfig = coreConfigs.first;
      final bootBin = await _buildBootProgram(primaryConfig);
      soc.addPeripheral(
        HarborMaskRom(
          baseAddress: primaryConfig.resetVector,
          initialData: _bytesToWords(bootBin, busConfig.dataWidth ~/ 8),
          dataWidth: busConfig.dataWidth,
          busAddressWidth: busConfig.addressWidth,
          busDataWidth: busConfig.dataWidth,
        ),
      );
    } else if (maskromPath != null ||
        usbDfu ||
        flashFirmware != null ||
        flashFirmwarePath != null) {
      // A maskrom path (copy/training bootstrap), USB DFU mode (arm USB, wait
      // for a host download into SRAM, jump to it), or a bundled flash firmware
      // (copy from a flash offset into SRAM, jump to it) all bake a RiverMaskrom
      // into the boot ROM.
      final primaryConfig = coreConfigs.first;
      final maskromBin = await _buildMaskrom(primaryConfig, busConfig);
      soc.addPeripheral(
        HarborMaskRom(
          baseAddress: primaryConfig.resetVector,
          initialData: _bytesToWords(maskromBin, busConfig.dataWidth ~/ 8),
          dataWidth: busConfig.dataWidth,
          busAddressWidth: busConfig.addressWidth,
          busDataWidth: busConfig.dataWidth,
        ),
      );
    }

    for (var i = 0; i < memories.length; i++) {
      final mem = memories[i];
      final board = mem.ddrBoard;
      if (board != null && ddr3Fast) {
        // Verilator: HarborDdr3 builds a behavioral DRAM (_HarborSimDram) on the
        // bus/sys clock, loaded at runtime via +dram_image=<hex>. It has no DDR3
        // clock tree (PLLE2/BUFG, which have no sim model) and no PHY pads, so
        // skip all of that FPGA plumbing and just add it as a bus slave. The
        // clock/period values are ignored by the behavioral body.
        if (target is HarborSimTarget && (mem.ddrParams?.ddr3v2 ?? false)) {
          final ddr = HarborDdr3(
            config: board.config,
            baseAddress: mem.address,
            clockHz: clockFrequency,
            busAddressWidth: busConfig.addressWidth,
            busDataWidth: busConfig.dataWidth,
            target: target,
            ckPeriodPs: 1250,
            runtimeTrainable: false,
            simExternalMem: true,
            name: '${mem.type}_$i',
          );
          soc.addPeripheral(ddr);
          // The behavioral DRAM is a host-side C++ mmap model, so route its
          // wishbone memory bus to the top for the model to drive, the same
          // split-port exposure the SDIO card model uses.
          for (final p in const [
            'mem_stb',
            'mem_we',
            'mem_adr',
            'mem_dat_w',
            'mem_sel',
            'mem_ack',
            'mem_dat_r',
          ]) {
            soc.exposePin(ddr, p, externalName: '${ddr.name}_$p');
          }
          continue;
        }
        // Real-speed DDR3-667 (Xilinx ISERDESE2).
        // Build the DDR3 clock tree from the board oscillator: an MMCM (ZHOLD +
        // BUFG feedback, the only openXC7-lockable form) fans one VCO into ck333
        // (DDR CK / ISERDESE2 CLK), ctrl83 (CK/4, controller + ISERDESE2 CLKDIV),
        // a ~200 MHz IDELAYCTRL reference, and ck333@90 (write launch), each on
        // its own BUFG. The controller runs on ctrl83 (asyncClock CDC to the slow
        // sys core/bus). This is the UberDDR3 / LiteDRAM open-tools read
        // arrangement (no BUFR/BUFIO/PHASER).
        // Tree source: with --ddr-osc-freq, a separate `ddr_osc` pin (the Arty S7
        // 100 MHz R2 osc), leaving the core/UART on the 12 MHz `clk`. Otherwise
        // the main `clk` osc.
        final Logic ddrTreeSource;
        final int ddrTreeSourceHz;
        if (ddrOscFrequency != null) {
          soc.createPort('ddr_osc', PortDirection.input);
          ddrTreeSource = soc.input('ddr_osc');
          ddrTreeSourceHz = ddrOscFrequency!;
        } else {
          ddrTreeSource = soc.input('clk');
          ddrTreeSourceHz = oscFrequency;
        }
        // DDR3 CK target. With the 100 MHz osc the oracle PLLE2 solves CK 400 MHz
        // (DDR3-800), controller 100 MHz, IDELAYCTRL ref 200 MHz exact. Default to
        // 400 MHz on the 100 MHz path so the solver lands the exact oracle
        // dividers. Keep 333 for the legacy 12 MHz path.
        final ck333Hz =
            ddrClockFrequency ??
            (ddrOscFrequency == 100000000 ? 400000000 : 333333333);
        const idelayRefHz = 200000000;
        // DQS launch phase (CLKOUT4). Default 180 = the UberDDR3 Arty HR-bank
        // oracle: DQS on 180-deg CK while DQ/DM ride ck90 centers the DQS edge in
        // the DQ eye and edge-frames the write off CK (tDQSS).
        const dqsPhaseDeg = 180.0;
        // When the SoC already built the DDR3 clock tree in its clock generation
        // (single-oscillator core-clock-off-spare-CLKOUT path), reuse it so the
        // core and the DDR clocks share ONE MMCM. Otherwise build it here (the
        // separate `ddr_osc` pin case has no clock-pin contention).
        // DDR controller gearing for THIS dram device (ddr3v2 only). Must match
        // whatever the shared SoC tree was built with.
        final ddrGear = (mem.ddrParams?.ddr3v2 ?? false)
            ? (mem.ddrParams?.ctrlGear ?? 1)
            : 1;
        final tree =
            soc.xilinxDdr3Clocks ??
            buildXilinxDdr3ClockTree(
              soc,
              source: ddrTreeSource,
              sourceHz: ddrTreeSourceHz,
              ddrCkHz: ck333Hz,
              idelayRefHz: idelayRefHz,
              dqsPhaseDeg: dqsPhaseDeg,
              ddrGearRatio: ddrGear,
              name: 'ddr3clk',
            );
        // Controller clock = ctrl83 (CK/4). All DRAM us/ns timing counters derive
        // from this rate. The sequencer is told CK = ctrl83 * 4 (ckCyclesPerTick=4)
        // so the CK-relative JEDEC latencies + MR CL/CWL compute against the true
        // DDR CK.
        final ctrlHz = tree.controllerMhz.round() * 1000000;
        // DDR3 speed-bin CL/CWL from the REALISED CK period (UberDDR3 JEDEC table,
        // ddr3_controller.v CL_generator/CWL_generator):
        //   tCK >= 3000 ps (DDR3-667) -> CL=5, CWL=5
        //   2500..3000 ps (DDR3-800)  -> CL=6, CWL=5
        //   1875..2500 ps             -> CL=7, CWL=6 ...
        // Deriving from the realised period keeps MR CL/CWL correct whatever the
        // tree solves. On the 100 MHz path hard-match the HW-verified oracle
        // (CL=5, CWL=5): it runs the DDR3-667 MR latencies on the faster 400 MHz CK
        // (read data arrives 1 nCK early, conservative + proven). The legacy 12 MHz
        // path keeps deriving from the realised period.
        final tCkPs = (1.0e6 / tree.ddrCkMhz);
        final int ddr3Cl;
        final int ddr3Cwl;
        if (ddrOscFrequency == 100000000) {
          ddr3Cl = 5;
          ddr3Cwl = 5;
        } else {
          ddr3Cl = tCkPs >= 3000 ? 5 : (tCkPs >= 2500 ? 6 : 7);
          ddr3Cwl = tCkPs >= 2500 ? 5 : (tCkPs >= 1875 ? 6 : 7);
        }
        final ddr3CwlEff = ddr3Cwl;
        // --- new silicon-proven Ddr3Controller stack (ddr3v2) ---
        if (mem.ddrParams?.ddr3v2 ?? false) {
          final ddr = HarborDdr3(
            config: board.config,
            baseAddress: mem.address,
            clockHz: ctrlHz,
            busAddressWidth: busConfig.addressWidth,
            busDataWidth: busConfig.dataWidth,
            target: target,
            // Match the DDR3 CK the tree actually solves (set clockfreq=
            // 300000000 on the device for the proven 300 MHz x16 point).
            ckPeriodPs: (1e6 / tree.ddrCkMhz).round(),
            // ctrlgear=2: run the controller LOGIC on the tree's CK/8 clock
            // (controllerClkPeriodPs = CK*4*gear -> the AC-timing counts are
            // CK/8-correct, T6) and interpose the fabric gearbox.
            controllerGearRatio: ddrGear,
            // Strictly-ordered (non-posted) DRAM writes: a write is not ACKed to
            // the fabric until it has crossed and committed. This buys two things,
            // BOTH HW-proven necessary on the timing-marginal Arty S7 DDR:
            //   1. Cross-master coherency: a later read by ANY master (CPU or SDIO
            //      ADMA) sees the write. Posted writes ACK early and leave a stale
            //      hole that QEMU + the functional ROHD sim never reproduce.
            //   2. ADMA pacing: each ADMA card-read block-write waits for its
            //      commit, which throttles the sustained read to a rate the
            //      marginal DDR survives. Posted writes remove that pacing; the
            //      unthrottled ADMA over-stresses the DDR and the board RESETS
            //      mid-read (HW-verified 2026-08-15: a posted build resets at the
            //      boot-file read where this non-posted build loads the kernel).
            // Costs CPU write throughput (~220-cycle commit per store), which the
            // real fix (a fast, non-marginal DDR route, or per-master posted so
            // only the ADMA is paced) would recover. See project #68.
            postedWrites: false,
            // train=runtime exposes the knob-ABI window for the FSBL engine.
            runtimeTrainable: mem.ddrParams?.runtimeTrain ?? false,
            name: '${mem.type}_$i',
          );
          soc.addPeripheral(ddr);
          if (mem.ddrParams?.runtimeTrain ?? false) {
            // The knob-ABI window is a second bus slave carved from the top page
            // of the DRAM aperture (usableSize excludes it). Map it explicitly.
            soc.addPeripheralSlave(
              ddr,
              'train',
              BusAddressRange(ddr.trainBase, HarborDdr3.trainWindowSize),
            );
          }
          // Under Verilator, HarborDdr3 builds a behavioral DRAM (_HarborSimDram,
          // loadable via +dram_image) with only the bus + clk/reset, and NO DDR3
          // PHY: no ddr_clk/ck_fast inputs and no physical pads. So the whole PHY
          // wiring and pad exposure below is FPGA/ASIC only. The bus side and
          // clk/reset are auto-wired by addPeripheral for both.
          if (target is! HarborSimTarget) {
            // gearRatio 1: single clock (ddr_clk = CK/4). gearRatio 2: the
            // controller runs on CK/8 (tree.controllerClk = CLKOUT5) and the
            // SERDES/PHY + gearbox on CK/4 (tree.controller) via ddr_serdes_clk.
            ddr.input('ddr_clk').srcConnection! <= tree.controllerClk;
            if (ddrGear > 1) {
              ddr.input('ddr_serdes_clk').srcConnection! <= tree.controller;
            }
            final sysDomainForDdr = soc.clockDomain('sys');
            if (sysDomainForDdr == null) {
              throw StateError(
                'ddr3v2 needs the sys clock domain for ddr_reset',
              );
            }
            ddr.input('ddr_reset').srcConnection! <= sysDomainForDdr.reset;
            ddr.input('ddr_ck_fast').srcConnection! <= tree.ddrCk;
            ddr.input('ddr_ck90_fast').srcConnection! <= tree.ddrCk90;
            ddr.input('ddr_ck_dqs_fast').srcConnection! <= tree.ddrCkDqs;
            ddr.input('ddr_idelay_ref').srcConnection! <= tree.idelayRef;
            final padPorts = [...DdrBoard.padPorts, 'sdram_dqs_n'];
            for (final pad in padPorts) {
              soc.exposePin(ddr, pad, externalName: pad);
            }
          }
          continue;
        }
        final ddr = HarborDdrController(
          config: board.config,
          baseAddress: mem.address,
          clockHz: ctrlHz,
          busAddressWidth: busConfig.addressWidth,
          busDataWidth: busConfig.dataWidth,
          target: target,
          // Sequencer/PHY on ctrl83, bus face on the slow sys clock (CDC).
          asyncClock: true,
          // The real-speed ISERDESE2 DW8 read gearbox.
          ddr3Fast: true,
          // Open the read window from the DRAM's read strobe (DQS as data) so each
          // read self-frames instead of a fixed CL tap (region `dqsgate` param).
          dqsGatedRead: mem.ddrParams?.dqsGate ?? false,
          ddr3FastCkMhz: tree.ddrCkMhz,
          ddr3FastIdelayRefMhz: tree.idelayRefMhz,
          // LiteDRAM one-memory-clock-phase read margin: the DRAM drives read
          // data readClExtra CK later so the burst lands INTO the ISERDESE2 word
          // (not at the marginal CLKDIV edge). CWL/writes untouched.
          ddr3FastCl: ddr3Cl + (mem.ddrParams?.readClExtra ?? 0),
          ddr3FastCwl: ddr3CwlEff,
          // ddr3Fast write/command timing. Effective value = region param, else
          // board default, else the global default. cmdSlot/wrShift/window fall
          // back to 0/0/5. wrBeat falls back to null (the PHY then derives it
          // from CWL).
          cmdSlot: mem.ddrParams?.cmdSlot ?? board.cmdSlot ?? 0,
          writeShift: mem.ddrParams?.wrShift ?? board.wrShift ?? 0,
          wrBeatOffset: mem.ddrParams?.wrBeat ?? board.wrBeat,
          windowTapReset: mem.ddrParams?.window ?? board.window ?? 5,
          // Per-lane IDELAY(VAR_LOAD) + BITSLIP leveling MMIO for the ddrlevelx
          // firmware (defaults on for the DDR read-path boot programs). Region
          // param / board default win over the boot-program default set.
          trainableRead:
              mem.ddrParams?.trainable ??
              board.trainable ??
              const {
                'ddrtest',
                'ddrprobe',
                'ddrlevel',
                'ddrlevelx',
                'ddreye',
                'ddrdiag',
              }.contains(bootProgram),
          readSlack: mem.ddrParams?.readSlack ?? board.readSlack ?? 1,
          readTaps: mem.ddrParams?.readTap ?? board.readTap ?? 40,
          readRetryTries: mem.ddrParams?.readRetry ?? board.readRetry ?? 0,
          // Bring-up diagnostic: leave MR3.MPR set so every read returns the part
          // MPR pattern (0xFFFF0000) with no write dependency, decoupling a broken
          // write from a broken init/read. From the dram region `mpr` param
          // (defaults off), on both the ddr3Fast and ECP5 paths.
          mprDebug: mem.ddrParams?.mpr ?? false,
          // Marginal-write boards (openXC7 Arty x8) carry writeVerify in their
          // DdrBoard so a plain build is correct with no extra flag. A region
          // param can still force it on/off.
          writeVerify: mem.ddrParams?.writeVerify ?? board.writeVerify,
          // Hardware MPR read-calibration before the bus opens (openXC7 ddr3Fast
          // read eye drifts per boot). Board default, region param can override.
          readLevel: mem.ddrParams?.readLevel ?? board.readLevel,
          selfTest: mem.ddrParams?.selfTest ?? board.selfTest,
          // Write-leveling / write-DQS actuator on the ddr3Fast (Xilinx) path.
          // This was MISSING from this controller call (only the legacy/ECP5 call
          // below had it), so writeLevel silently defaulted to false and the whole
          // Xilinx WL + write-beat block never built. Same DLL-on-band gate as the
          // ECP5 call. Needed for the runtime write-beat override at rated CK.
          writeLevel:
              (ddrClockFrequency != null &&
                  ddrClockFrequency! > oscFrequency) &&
              (mem.ddrParams?.trainable ??
                  board.trainable ??
                  const {
                    'ddrtest',
                    'ddrprobe',
                    'ddrlevel',
                    'ddreye',
                    'ddrdiag',
                  }.contains(bootProgram)),
          name: '${mem.type}_$i',
        );
        soc.addPeripheral(ddr);
        // Wire the DDR domain: controller/CLKDIV = ctrl83, plus the three tree
        // clocks into the PHY (ck333, ck333@90, 200 MHz IDELAYCTRL ref).
        ddr.input('ddr_clk').srcConnection! <= tree.controller;
        // ddr_reset: the sys clock domain reset (an FPGA target uses an internal
        // power-on reset, no external `reset` pin). The controller stretches the
        // IDELAYCTRL RST internally, so this only needs a valid domain reset for
        // the sequencer/PHY. The `sys` domain is always present on ddr3Fast.
        final sysDomainForDdr = soc.clockDomain('sys');
        if (sysDomainForDdr == null) {
          throw StateError('ddr3Fast needs the sys clock domain for ddr_reset');
        }
        ddr.input('ddr_reset').srcConnection! <= sysDomainForDdr.reset;
        ddr.input('ddr_ck_fast').srcConnection! <= tree.ddrCk;
        ddr.input('ddr_ck90_fast').srcConnection! <= tree.ddrCk90;
        // 180-deg DQS launch clock (CLKOUT4): DQS edge centered in the DQ eye +
        // edge-framed to CK (tDQSS), the UberDDR3 Arty HR-bank oracle scheme.
        ddr.input('ddr_ck_dqs_fast').srcConnection! <= tree.ddrCkDqs;
        ddr.input('ddr_idelay_ref').srcConnection! <= tree.idelayRef;
        // DDR3 pads (single-ended SSTL135 _p + explicit _n complement, like the
        // ECP5 DLL-off path). The Xilinx PHY drives both DQS rails.
        final padPorts = [...DdrBoard.padPorts, 'sdram_dqs_n'];
        for (final pad in padPorts) {
          soc.exposePin(ddr, pad, externalName: pad);
        }
      } else if (board != null) {
        // DQS-strobed (DQSBUFM) DDR3 PHY. The ECP5 read path captures DQ with the
        // DRAM's own DQS strobe (DQSBUFM DQSR90 + IDDRX2DQA), so the DQ IOLOGIC is
        // x2-geared. An ECP5 DQ pad's input and output IOLOGIC must share gearing,
        // so the write is x2 too. The x2 gearbox needs a half-rate fabric clock:
        // the PHY derives eclk (CK rate = 48 MHz) and sclk (eclk/2 = 24 MHz) from
        // the `ddr` domain. The asyncClock controller keeps its `bus` slave face
        // on the slow `sys` fabric (24 MHz) and runs the sequencer/PHY on the
        // 48 MHz `ddr_clk`, bridged by an internal HarborWishboneCdcBridge. CK
        // stays 48 MHz. The controller also owns the 64->32 downsizer.
        //
        // The DDR CK rate = the `ddr` clock domain rate: the raw osc (DLL-off) by
        // default, or the PLL'd --ddr-clock-freq when set above the osc (DLL-on).
        // All DRAM timing counters and the DLL-on/off init choice derive from this
        // CK rate. Any explicit --ddr-clock-freq is the real CK. Only an unset
        // frequency falls back to the raw osc. A sub-osc CK (e.g. 24 MHz) widens
        // the DLL-off read eye.
        final ddrCkHz = ddrClockFrequency ?? oscFrequency;
        // DLL engagement (CK > ~60 MHz). DLL-OFF takes the x1 IDDRX1F/ODDRX1F
        // read/write datapath whose write->read turnaround eats beat0's rise
        // sample. readCrossPair recovers it via the cross-cycle sliding pair.
        // readSlack=1 is the proven full-cycle window for the x1 read.
        final ddrCkDllOn = ddrCkHz > 60000000;
        final ddr = HarborDdrController(
          config: board.config,
          baseAddress: mem.address,
          // Sequencer/PHY clock = the `ddr` domain CK rate (osc for DLL-off, the
          // PLL'd rate for DLL-on). The PHY halves it to the sclk fabric. All
          // DRAM timing counters derive from this CK rate.
          clockHz: ddrCkHz,
          busAddressWidth: busConfig.addressWidth,
          busDataWidth: busConfig.dataWidth,
          // ECP5 board target so the controller builds the Lattice DQS PHY.
          target: target,
          // Second (faster) DRAM clock domain: bus face on `sys`, sequencer/PHY
          // on `ddr_clk`, bridged by the controller's internal CDC.
          asyncClock: true,
          // Runtime-trainable DQS read: anchors beat0 on the DQSBUFM DATAVALID
          // burst (the cold-read fix) and exposes the train-control MMIO window
          // (the controller auto-extends its decoded span by trainCtrlSize).
          // Resolves region param, then board default, then default ON for the
          // DDR3 read-path boot programs. The set MUST include every program that
          // touches the train-control window, else its accesses are unmapped and
          // hang on the first STATUS read.
          trainableRead:
              mem.ddrParams?.trainable ??
              board.trainable ??
              const {
                'ddrtest',
                'ddrprobe',
                'ddrlevel',
                'ddrlevelx',
                'ddreye',
                'ddrdiag',
              }.contains(bootProgram),
          // JEDEC DDR3 write-leveling FSM (MR1 A7=1, sweep the write DQS delay
          // until the CK-vs-DQS feedback flips, exit WL): trains tDQSS so the BL8
          // deposit lands aligned. DLL-ON only. DLL-OFF used the fixed litedram
          // tie-off and worked. Enabling WL there parks the pointer at a mistrained
          // tap and garbages every write. So gate WL (and the DYNDELAY write-trim)
          // on the DLL-on band. ddreye/ddrdiag MUST be in the set too: without the
          // WL FSM the trainable sequencer never completes DLL-on init and hangs.
          writeLevel:
              (ddrClockFrequency != null &&
                  ddrClockFrequency! > oscFrequency) &&
              (mem.ddrParams?.trainable ??
                  board.trainable ??
                  const {
                    'ddrtest',
                    'ddrprobe',
                    'ddrlevel',
                    'ddreye',
                    'ddrdiag',
                  }.contains(bootProgram)),
          // Firmware DQSBUFM DYNDELAY[7:0] write-trim (reg8): a per-byte-lane
          // dynamic DQS-delay sweep to trim the fixed below-strobe-pad write skew
          // that floats the first-cycle DQ bits. DLL-on only (same reason as WL).
          writeTrimTrainable:
              (ddrClockFrequency != null &&
                  ddrClockFrequency! > oscFrequency) &&
              (mem.ddrParams?.trainable ??
                  board.trainable ??
                  const {
                    'ddrtest',
                    'ddrprobe',
                    'ddrlevel',
                    'ddreye',
                    'ddrdiag',
                  }.contains(bootProgram)),
          mprDebug: mem.ddrParams?.mpr ?? false,
          // Read-eye knobs (bench sweep axes), from the dram region
          // `read-tap`/`read-slack` params or board defaults:
          //   readTaps  = per-DQ static DELAYG delay (the eye-centering knob).
          //   readSlack = full-cycle read-window slide. DLL-on keeps 2 (proven x2).
          //               DLL-off uses the region read-slack (default 1).
          readTaps: mem.ddrParams?.readTap ?? board.readTap ?? 40,
          readSlack: ddrCkDllOn
              ? 2
              : (mem.ddrParams?.readSlack ?? board.readSlack ?? 1),
          // x1 read deserialize assembly. With the write-side DQS fix (DQS on the
          // 50%-duty CLKOS2, both write beats centered), the read uses HEAD
          // same-cycle MODE 0 {q1,q0}. No effect on the DLL-on x2 path.
          readPairMode: 0,
          readRetryTries: mem.ddrParams?.readRetry ?? board.readRetry ?? 0,
          name: '${mem.type}_$i',
        );
        // The fabric-facing `bus` slave auto-clocks on `sys` (24 MHz): this is the
        // peripheral the SoC decoder maps at mem.address. The internal CDC's fast
        // master side + sequencer + PHY run on the `ddr` 48 MHz domain wired below.
        // The PHY divides it to the 24 MHz sclk for the DQS x2 datapath.
        soc.addPeripheral(ddr);
        final ddrDomain = soc.clockDomain('ddr');
        if (ddrDomain == null) {
          throw StateError(
            'board-backed DRAM present but the "ddr" clock domain is missing',
          );
        }
        ddr.input('ddr_clk').srcConnection! <= ddrDomain.clk;
        ddr.input('ddr_reset').srcConnection! <= ddrDomain.reset;
        // The pads keep their port names so the board's constraint table (sdram_*)
        // lines up with the netlist. DLL-OFF: the controller adds an explicit
        // sdram_dqs_n complement port, so expose it too. DLL-ON: the single
        // SSTL135D_I diff DQS pad has no _n port (nextpnr derives _n).
        final ddrDllOn = ddrCkHz > 60000000;
        final padPorts = [...DdrBoard.padPorts, if (!ddrDllOn) 'sdram_dqs_n'];
        for (final pad in padPorts) {
          soc.exposePin(ddr, pad, externalName: pad);
        }
        // LA probe: expose the DDR controller's 6-bit dbg_la bundle
        // ([3:0]=stateCode [4]=rd_cal_active [5]=phy.rdValid) as top pins so a
        // logic analyzer can watch the read-cal FSM + read completion live
        // (bus-independent). Gated on the dram `laprobe=true` param; the
        // dbg_la[*] pads come from --pin.
        if (mem.ddrParams?.laprobe ?? false) {
          soc.exposePin(ddr, 'dbg_la', externalName: 'dbg_la');
        }
      } else if (mem.type == 'flash') {
        // Real SPI NOR flash with XIP: the CPU fetches firmware directly from the
        // part, no on-chip copy. 16MB maps to the W25Q128 (the OrangeCrab/
        // iCEBreaker part). Other sizes get a generic quad-read config sized to
        // the region.
        // Target-aware partition map (fpga-bitstream on FPGA + river-fsbl +
        // river-firmware): the FSBL reads its firmware offset from this and
        // Linux exposes each as /dev/mtdN.
        final flashParts = flashLayout(target, mem.size).partitions;
        final spiConfig = mem.size == 16 * 1024 * 1024
            ? HarborSpiFlashConfig.w25q128(partitions: flashParts)
            : HarborSpiFlashConfig(
                size: mem.size,
                mode: HarborSpiFlashMode.quad,
                readCommand: 0x6B,
                addressBytes: mem.size > 16 * 1024 * 1024 ? 4 : 3,
                dummyCycles: 8,
                partitions: flashParts,
              );
        // The config-flash clock has no I/O pad on either family: route it
        // through the ECP5 USRMCLK macro or the Xilinx STARTUPE2 (USRCCLKO ->
        // CCLK) inside the controller, so there is no spi_clk port.
        final isEcp5 =
            target is HarborFpgaTarget &&
            target.vendor == HarborFpgaVendor.ecp5;
        final isXilinx =
            target is HarborFpgaTarget &&
            (target.vendor == HarborFpgaVendor.openXc7 ||
                target.vendor == HarborFpgaVendor.vivado);
        final flash = HarborSpiFlashController(
          config: spiConfig,
          baseAddress: mem.address,
          busAddressWidth: busConfig.addressWidth,
          busDataWidth: busConfig.dataWidth,
          useUsrmclk: isEcp5,
          useStartupe2: isXilinx,
          // Standalone FPGA builds have no external pad ring, so the controller
          // owns the bidirectional IO pad (one inout spi_io + internal tristate).
          ownPads: isEcp5 || isXilinx,
          name: '${mem.type}_$i',
        );
        soc.addPeripheral(flash);
        // Expose the SPI pads. The clock is absent on ECP5 (USRMCLK). Quad/dual
        // flash exposes split tristate IO (spi_io_out/oe/in). Standard mode is
        // spi_mosi/spi_miso.
        // FPGA targets own the pad (single inout spi_io); otherwise expose the
        // split tristate for an external pad ring / shared-bus mux.
        final flashOwnsPads = isEcp5 || isXilinx;
        final dataPins = spiConfig.mode == HarborSpiFlashMode.standard
            ? const ['spi_cs_n', 'spi_mosi', 'spi_miso']
            : flashOwnsPads
            ? const ['spi_cs_n', 'spi_io']
            : const ['spi_cs_n', 'spi_io_out', 'spi_io_oe', 'spi_io_in'];
        final spiPins = [if (!isEcp5 && !isXilinx) 'spi_clk', ...dataPins];
        // Prefix when more than one SPI device shares the pinout (multiple flash,
        // or flash alongside PSRAM) so spi_clk/spi_cs_n/spi_io do not collide.
        final spiCount = memories
            .where((m) => m.type == 'flash' || m.type == 'psram')
            .length;
        final prefix = spiCount > 1 ? '${mem.type}_' : '';
        for (final pin in spiPins) {
          soc.exposePin(flash, pin, externalName: '$prefix$pin');
        }
      } else if (mem.type == 'psram') {
        // External QSPI PSRAM (APS6404 / LY68L6400): a bus slave serving RAM over
        // SPI, sized to the region. Quad mode by default (the Tiny Tapeout QSPI
        // Pmod). Like flash it exposes split-tristate SPI pads. On the TT Pmod
        // flash and PSRAM share one physical bus (separate CS), wired in the
        // hand-maintained SoC top, not here. Genip exposes each device's pins
        // independently.
        final psram = HarborPsramController(
          config: HarborPsramConfig(size: mem.size, mode: HarborPsramMode.quad),
          baseAddress: mem.address,
          busAddressWidth: busConfig.addressWidth,
          busDataWidth: busConfig.dataWidth,
          name: '${mem.type}_$i',
        );
        soc.addPeripheral(psram);
        // Prefix when more than one SPI device shares the pinout (see flash).
        final spiCount = memories
            .where((m) => m.type == 'flash' || m.type == 'psram')
            .length;
        final prefix = spiCount > 1 ? '${mem.type}_' : '';
        // Quad PSRAM exposes split tristate IO (spi_io_out/oe/in) so the pad ring
        // (or the hand-written shared-QSPI SoC top) resolves the bidirectional
        // lines. Standard mode is spi_mosi/spi_miso.
        final ioPins = psram.config.mode == HarborPsramMode.quad
            ? const ['spi_io_out', 'spi_io_oe', 'spi_io_in']
            : const ['spi_mosi', 'spi_miso'];
        for (final pin in ['spi_clk', 'spi_cs_n', ...ioPins]) {
          soc.exposePin(psram, pin, externalName: '$prefix$pin');
        }
      } else {
        soc.addPeripheral(
          HarborSram(
            baseAddress: mem.address,
            size: mem.size,
            dataWidth: busConfig.dataWidth,
            busAddressWidth: busConfig.addressWidth,
            target: target,
            name: '${mem.type}_$i',
          ),
        );
      }
    }

    final peripheralsByName = <String, BridgeModule>{};
    for (final dev in mmioDevices) {
      final peripheral = _createPeripheral(
        dev,
        busConfig,
        target: target,
        plicContexts: interruptContexts.length,
      );
      if (peripheral != null) {
        soc.addPeripheral(peripheral);
        peripheralsByName[dev.name] = peripheral;
      }
    }

    // Wire the CLINT's per-hart timer_irq/sw_irq outputs into each core's
    // machine timer/software interrupt-pending lines (mip.MTIP / mip.MSIP), the
    // same output-drives-input idiom the debug subsystem uses below. Without
    // this the CLINT outputs dangle and a Linux/SBI timer never fires.
    if (hasClint && coreTimerNets.isNotEmpty) {
      final clintDev = mmioDevices.firstWhere((d) => d.type == 'clint');
      final clint = peripheralsByName[clintDev.name]!;
      for (var h = 0; h < coreTimerNets.length; h++) {
        coreTimerNets[h] <= clint.output('timer_irq_$h');
        coreSwNets[h] <= clint.output('sw_irq_$h');
        coreTimeNets[h] <= clint.output('mtime_val');
      }
    }

    // A DMA-capable SPI controller is BOTH a slave (its registers, added above)
    // and a bus master (its `dma` interface streams SD bytes to memory). Attach
    // that master to the fabric arbiter alongside the core. Its leg is pipelined
    // because the SPI sits out at an I/O pad: a registered bus to the arbiter
    // keeps the placer from stretching a die-crossing combinational route
    // through the core's decode region (routing-congestion relief). The DMA is
    // throughput-bound, so the two extra latency cycles do not matter.
    for (final dev in mmioDevices) {
      if ((dev.type == 'spi' || dev.type == 'sdio') &&
          (dev.params?.dma ?? false)) {
        soc.addMaster(
          peripheralsByName[dev.name]!,
          busInterfaceName: 'dma',
          pipeline: true,
          // Put the DMA master on its OWN fabric channel, physically off the
          // primary arbiter. Its wide 64-bit leg was the delta xc7s50 routing
          // hotspot (it smeared the crossbar's arbitration mux through the
          // core's decode region); on its own channel it meets the CPU fabric
          // only at a converge arbiter in front of DRAM. Also the Linux
          // topology: DMA traffic never stalls the CPU's primary fabric.
          // With dmashared, the separate channel plus its converge arbiter is
          // itself the routing hotspot on a small device, so share the primary
          // crossbar instead (the topology that provably closes on xc7s50).
          channel: (dev.params?.dmaShared ?? false) ? 'primary' : 'dma',
        );
      }
    }

    // Expose the SDIO controller's SD pads. CMD/DAT are bidirectional (ownPads
    // inout, driven through IOBUFs inside the controller); clk is an output and
    // card-detect an input. Board pins bind to these by external name.
    for (final dev in mmioDevices) {
      if (dev.type == 'sdio') {
        final sdio = peripheralsByName[dev.name]!;
        final pads = target is HarborSimTarget
            // Verilator (ownPads=false): the split out/oe/in ports, so the C++
            // SD-card sim model reads the host's cmd/dat drive and injects the
            // card's response/data on the `_in` lines.
            ? const [
                'sd_clk',
                'sd_cd',
                'sd_cmd_out',
                'sd_cmd_oe',
                'sd_cmd_in',
                'sd_dat_out',
                'sd_dat_oe',
                'sd_dat_in',
              ]
            // FPGA/ASIC (ownPads=true): one scalar inout pad per DAT lane
            // (sd_dat0..3) plus cmd/clk/cd.
            : const [
                'sd_clk',
                'sd_cmd',
                'sd_cd',
                'sd_dat0',
                'sd_dat1',
                'sd_dat2',
                'sd_dat3',
              ];
        for (final pad in pads) {
          soc.exposePin(sdio, pad, externalName: '${dev.name}_$pad');
        }
      }
    }

    // Under Verilator the UART has no board pin, so its serial lines are not
    // exposed by --pin. Expose tx/rx as real top-level ports so the harness's
    // host-side UART sink (HarborUart.simModels, gated on topPort('tx')) can
    // decode the transmit line to stdout, the same way the JTAG pins are raised
    // for the remote_bitbang server. Mirrors the console a board gives us.
    if (target is HarborSimTarget) {
      for (final dev in mmioDevices) {
        if (dev.type != 'uart') continue;
        final uart = peripheralsByName[dev.name]!;
        for (final line in const ['tx', 'rx']) {
          soc.exposePin(uart, line, externalName: '${dev.name}_$line');
        }
      }
    }

    // GPIO pin bundles. They are real chip pads, so raise all three to the top
    // even without a --pin flag: an unexposed `gpio_in` is a floating module
    // input, which is an X in simulation and an unconstrained net in synthesis.
    for (final dev in mmioDevices) {
      if (dev.type != 'gpio') continue;
      final gpio = peripheralsByName[dev.name]!;
      for (final port in const ['gpio_in', 'gpio_out', 'gpio_dir']) {
        soc.exposePin(gpio, port, externalName: '${dev.name}_$port');
      }
    }

    // Expose peripheral pins referenced by --pin flags (and the board catalog).
    for (final pin in effectivePins) {
      if (!pin.isDevicePin) continue;
      final peri = peripheralsByName[pin.deviceName];
      if (peri == null) {
        throw ArgumentError(
          'Pin "${pin.externalName}": unknown device "${pin.deviceName}"',
        );
      }
      soc.exposePin(peri, pin.portName, externalName: pin.externalName);
    }

    // Build the fabric. When a DMA-capable device placed a master on the 'dma'
    // channel (see addMaster above), keep that channel separate: it reaches only
    // memory (dram) and converges with the primary channel at an arbiter in
    // front of DRAM. This lifts the DMA's wide master off the primary crossbar
    // (delta xc7s50 congestion relief) and is the Linux-throughput topology.
    // Without a DMA channel this is byte-identical to the historic single fabric.
    void finishFabric() {
      // Wire every peripheral interrupt output into the PLIC, and the PLIC's
      // per-hart output into the core. Done here, after the DFU and debug
      // subsystems have added their peripherals, so the numbering the device
      // tree and the ACPI tables report covers the final peripheral list.
      //
      // The numbers come from `HarborSoC.interruptAssignments`, the same
      // allocator the device tree, ACPI and SVD generators read. Hardware and
      // tables therefore cannot disagree.
      if (hasPlic) {
        final routing = HarborInterruptRouting.forSoC(soc);
        if (routing != null) {
          routing.connectSoCSources(soc);
          // Each context output goes to the core input for the cause it drives.
          // The list is the same one the device tree turns into
          // `interrupts-extended`, so a context an OS is told to claim from is
          // the context actually wired to that hart's interrupt line.
          final driven = <Logic>{};
          for (final (ctx, entry) in soc.interruptContexts.indexed) {
            if (ctx >= routing.numHarts) break;
            final line = entry.cause == 9
                ? coreSeiNets[entry.hartId]
                : (entry.hartId < coreExtNets.length
                      ? coreExtNets[entry.hartId]
                      : null);
            if (line == null) continue;
            line <= routing.hartInterrupt(ctx);
            driven.add(line);
          }
          // Anything the plan did not reach is tied low rather than left
          // floating. A floating core interrupt input is an X in simulation and
          // an unconstrained net in synthesis.
          for (final net in [...coreExtNets, ...coreSeiNets.values]) {
            if (!driven.contains(net)) net <= Const(0);
          }
        }
      }

      final hasDmaChannel = mmioDevices.any(
        (dev) =>
            (dev.type == 'spi' || dev.type == 'sdio') &&
            (dev.params?.dma ?? false) &&
            !(dev.params?.dmaShared ?? false),
      );
      if (!hasDmaChannel) {
        soc.buildFabric(pipeline: true);
        return;
      }
      // The DMA channel reaches main memory only. DRAM is main memory on every
      // board that has it, so prefer it and keep those SoCs byte identical. A
      // DRAM-less SoC (an SRAM or PSRAM part) still needs the DMA to reach ITS
      // main memory, so fall back to those. An empty set makes Harbor throw
      // `channel "dma" reaches no slave` from deep inside the fabric builder,
      // far from the cause, so name the real problem here instead.
      var dmaSlaves = {
        for (final p in soc.peripherals)
          if (p.name.startsWith('dram')) p.name,
      };
      if (dmaSlaves.isEmpty) {
        dmaSlaves = {
          for (final p in soc.peripherals)
            if (p.name.startsWith('sram') || p.name.startsWith('psram')) p.name,
        };
      }
      if (dmaSlaves.isEmpty) {
        throw ArgumentError(
          'A DMA-capable device needs a memory region for the DMA channel to '
          'reach. Add a dram, sram or psram device, or set dmashared=true to '
          'put the DMA master on the primary channel.',
        );
      }
      soc.buildFabric(
        pipeline: true,
        channelSlaves: {
          'primary': {for (final p in soc.peripherals) p.name},
          'dma': dmaSlaves,
        },
      );
    }

    if (usbDfu && usbDfuMode == UsbDfuMode.hardware) {
      if (enableDebug) {
        // The hardware DFU path uses a fixed 2-master arbiter (core + DFU
        // RAM-sink). The debug JTAG SBA would be a third master it cannot route.
        // Make it an explicit error rather than silently dropping JTAG.
        throw ArgumentError(
          'debug-jtag is not supported with hardware usb-dfu (the 2-master '
          'arbitrated fabric has no slot for the debug SBA master); use '
          'usb-dfu:...:mode=software or drop debug-jtag',
        );
      }
      _integrateUsbDfu(soc, busConfig, target);
    } else if (usbDfu && usbDfuMode == UsbDfuMode.software) {
      _integrateUsbDfuSoftware(soc, busConfig, target);
      if (enableDebug) _integrateDebugJtag(soc, busConfig, debugCore!, target);
      finishFabric();
    } else {
      if (enableDebug) _integrateDebugJtag(soc, busConfig, debugCore!, target);
      finishFabric();
    }

    return soc;
  }

  /// Wire the JTAG debug subsystem as a second fabric master: connect its
  /// core-facing control ports to the [core]'s `withDebug` ports and expose the
  /// JTAG pins (tck/tms/tdi/tdo/trst_n) as top-level SoC pads.
  void _integrateDebugJtag(
    HarborSoC soc,
    WishboneConfig busConfig,
    RiverCore core,
    HarborDeviceTarget? target,
  ) {
    final xlen = busConfig.dataWidth;
    final dbg = RiverDebugSubsystem(busConfig, xlen: xlen, target: target);
    soc.addMaster(dbg, busInterfaceName: 'bus');

    // Under Verilator the TAP is not tunnelled through a config-JTAG
    // primitive, so its pins are real top-level ports for the generated
    // remote_bitbang server to bit-bang. Names must match the harness that
    // HarborSimTarget.generateMain emits.
    if (target is HarborSimTarget) {
      for (final pin in const [
        'jtag_tck',
        'jtag_tms',
        'jtag_tdi',
        'jtag_trst',
        'jtag_tdo',
      ]) {
        soc.exposePin(dbg, pin, externalName: pin);
      }
    }

    // To the core.
    core.input('debug_halt_req').srcConnection! <= dbg.output('halt_req');
    core.input('debug_resume_req').srcConnection! <= dbg.output('resume_req');
    core.input('debug_reg_read').srcConnection! <= dbg.output('reg_read');
    core.input('debug_reg_write').srcConnection! <= dbg.output('reg_write');
    core.input('debug_reg_addr').srcConnection! <= dbg.output('reg_addr');
    core.input('debug_reg_wdata').srcConnection! <= dbg.output('reg_wdata');
    // From the core.
    dbg.input('hart_halted').srcConnection! <= core.output('debug_halted');
    dbg.input('reg_rdata').srcConnection! <= core.output('debug_reg_rdata');
    dbg.input('reg_ready').srcConnection! <= core.output('debug_reg_ready');

    // No top-level JTAG pads: the TAP comes off the FPGA config JTAG (ECP5
    // JTAGG or Xilinx BSCANE2 on USER1, selected by target) inside the
    // subsystem. OpenOCD reaches it over the config TAP with
    // `riscv use_bscan_tunnel`.
  }

  /// Integrates the USB DFU subsystem into [soc]: instantiates the subsystem
  /// (engine + RAM sink + line tristate, dual clock domain) as a SECOND bus
  /// master, the [RiverDfuStatus] control/status slave as a peripheral, exposes
  /// the USB + button pads, and builds a two-master Wishbone fabric (core +
  /// DFU sink) through a [RiverWishboneArbiter] into a single decoder.
  void _integrateUsbDfu(
    HarborSoC soc,
    WishboneConfig busConfig,
    HarborDeviceTarget? target,
  ) {
    final ram = dfuRamRegion;
    if (ram == null) {
      throw ArgumentError(
        '--usb-dfu requires an SRAM region (-m sram:...) for the download '
        'target; none found.',
      );
    }

    // The control/status slave the maskrom polls.
    final status = RiverDfuStatus(
      baseAddress: dfuStatusBase,
      busAddressWidth: busConfig.addressWidth,
      busDataWidth: busConfig.dataWidth,
    );
    soc.addPeripheral(status); // bus (sys) domain, auto-clocked.

    // The DFU subsystem (engine + sink + pads). Its bus master runs on `sys`
    // (auto-wired via addMaster). The 48 MHz USB side is wired manually.
    final dfu = RiverDfuSubsystem(
      loadBase: ram.address,
      busAddressWidth: busConfig.addressWidth,
      busDataWidth: busConfig.dataWidth,
    );
    soc.addMaster(dfu, busInterfaceName: 'bus'); // clk/reset <- sys domain.

    // Hand the raw 48 MHz osc (the `usb` primary clock domain) to the USB side.
    final usbDomain = soc.clockDomain('usb');
    if (usbDomain == null) {
      throw StateError('usb-dfu enabled but the "usb" clock domain is missing');
    }
    dfu.input('usb_clk').srcConnection! <= usbDomain.clk;
    dfu.input('usb_reset').srcConnection! <= usbDomain.reset;

    // Status wiring between the subsystem and the slave (all bus domain).
    status.input('image_ready').srcConnection! <= dfu.output('image_ready');
    status.input('entry_addr').srcConnection! <= dfu.output('entry_addr');
    status.input('bytes_written').srcConnection! <= dfu.output('bytes_written');
    dfu.input('usb_enable').srcConnection! <= status.output('usb_enable');

    // Expose the USB line pads + pull-up + button to the SoC top.
    soc.exposePin(dfu, 'usb_dp', externalName: 'usb_dp');
    soc.exposePin(dfu, 'usb_dm', externalName: 'usb_dm');
    soc.exposePin(dfu, 'usb_pullup', externalName: 'usb_pullup');

    // Two-master fabric: arbitrate [core, dfu] onto one decoder. buildFabric's
    // per-master decoders would multiply-drive the slaves, so build it here.
    _buildArbitratedWishboneFabric(soc, busConfig);
  }

  /// Integrates the LEAN, software-driven USB DFU subsystem
  /// ([RiverDfuSubsystemSw]) into [soc]. Unlike [_integrateUsbDfu], this adds a
  /// single MMIO SLAVE (no second master, no arbiter, no RAM-sink, no CDC
  /// FIFO), so the stock single-master [HarborSoC.buildFabric] handles routing.
  /// The maskrom reads received bytes over MMIO and stores them into CAR.
  void _integrateUsbDfuSoftware(
    HarborSoC soc,
    WishboneConfig busConfig,
    HarborDeviceTarget? target,
  ) {
    final dfu = RiverDfuSubsystemSw(
      baseAddress: dfuStatusBase,
      busAddressWidth: busConfig.addressWidth,
      busDataWidth: busConfig.dataWidth,
    );
    // Add as a peripheral (bus/sys-domain slave, auto-clocked).
    soc.addPeripheral(dfu);

    // Hand the raw 48 MHz osc (the `usb` primary clock domain) to the USB side.
    final usbDomain = soc.clockDomain('usb');
    if (usbDomain == null) {
      throw StateError('usb-dfu enabled but the "usb" clock domain is missing');
    }
    dfu.input('usb_clk').srcConnection! <= usbDomain.clk;
    dfu.input('usb_reset').srcConnection! <= usbDomain.reset;

    // Expose the USB line pads + pull-up to the SoC top.
    soc.exposePin(dfu, 'usb_dp', externalName: 'usb_dp');
    soc.exposePin(dfu, 'usb_dm', externalName: 'usb_dm');
    soc.exposePin(dfu, 'usb_pullup', externalName: 'usb_pullup');
  }

  /// Builds a Wishbone fabric for exactly two masters (the River core and the
  /// DFU RAM-sink) sharing the peripheral set, by merging them through a
  /// [RiverWishboneArbiter] into a single [WishboneDecoder].
  void _buildArbitratedWishboneFabric(HarborSoC soc, WishboneConfig busConfig) {
    final errors = soc.validate();
    if (errors.isNotEmpty) {
      throw StateError(
        'Validation errors in ${soc.name}:\n${errors.join("\n")}',
      );
    }

    final masters = soc.masters;
    if (masters.length != 2) {
      throw StateError(
        'USB DFU fabric expects exactly 2 masters (core + dfu), got '
        '${masters.length}',
      );
    }
    final core = masters[0];
    final dfu = masters[1];

    final peripherals = soc.peripherals;
    final mappings = <HarborAddressMapping>[];
    for (var i = 0; i < peripherals.length; i++) {
      final p = peripherals[i] as HarborDeviceTreeNodeProvider;
      mappings.add(HarborAddressMapping(range: p.dtNode.reg, slaveIndex: i));
    }

    // Arbiter: merge the two masters' provider interfaces into one slave.
    final (clk, reset) = soc.defaultClock;
    final arbiter = RiverWishboneArbiter(busConfig);
    soc.addSubModule(arbiter);
    arbiter.input('clk').srcConnection! <= clk;
    arbiter.input('reset').srcConnection! <= reset;
    connectInterfaces(core.interface('dataBus'), arbiter.interface('m0'));
    connectInterfaces(dfu.interface('bus'), arbiter.interface('m1'));

    // Decoder: route the merged master to every peripheral slave.
    final decoder = WishboneDecoder(busConfig, mappings);
    soc.addSubModule(decoder);
    connectInterfaces(arbiter.interface('slave'), decoder.interface('master'));
    for (var i = 0; i < peripherals.length; i++) {
      connectInterfaces(
        decoder.interface('slave_$i'),
        peripherals[i].interface('bus'),
      );
    }
  }

  BridgeModule? _createPeripheral(
    DeviceEntry dev,
    WishboneConfig busConfig, {
    HarborDeviceTarget? target,
    // Number of PLIC contexts, from the SoC's one context plan. See buildSoC.
    int plicContexts = 1,
  }) {
    switch (dev.type) {
      case 'uart':
        return HarborUart(
          baseAddress: dev.address,
          clockFrequency: clockFrequency,
          busAddressWidth: busConfig.addressWidth,
          busDataWidth: busConfig.dataWidth,
        );
      case 'clint':
        return HarborClint(
          baseAddress: dev.address,
          busAddressWidth: busConfig.addressWidth,
          busDataWidth: busConfig.dataWidth,
        );
      case 'plic':
        // Size the PLIC to the SoC's actual interrupt sources, not the 32-source
        // default. One source per interrupt-generating peripheral (the CLINT goes
        // direct to the hart), so the device count +1 (reserved source 0) is a
        // safe upper bound. Priority/claim logic scales with source count, a real
        // LUT win on small SoCs.
        return HarborPlic(
          baseAddress: dev.address,
          busAddressWidth: busConfig.addressWidth,
          busDataWidth: busConfig.dataWidth,
          sources: mmioDevices.length + 1,
          // One context per privilege level that claims: M and S per hart. An
          // S-mode OS needs its own enable/threshold/claim block, which is what
          // the Linux PLIC driver looks for.
          contexts: plicContexts,
        );
      case 'spi':
        // Generic SPI master. Pads (spi_clk/spi_mosi/spi_miso/spi_cs_n) are
        // exposed and bound to a board connector via `iface=` (see [_ifacePins]).
        return HarborSpiController(
          baseAddress: dev.address,
          busAddressWidth: busConfig.addressWidth,
          busDataWidth: busConfig.dataWidth,
          sdCard: dev.params?.sdcard ?? false,
          // Optional integrated DMA master (fast SD block reads). Its master
          // interface is wired to the fabric via addMaster below; the address
          // width matches the fabric so it can reach all of memory.
          dma: dev.params?.dma ?? false,
          dmaAddressWidth: busConfig.addressWidth,
          name: dev.name,
        );
      case 'gpio':
        // General-purpose I/O with per-pin interrupts. The three pin bundles are
        // exposed as top-level ports below, so a board binds them with
        // `--pin name=<dev>@gpio_in:<pad>` style indexed pads.
        return HarborGpio(
          baseAddress: dev.address,
          // Small default: each pin costs an output, a direction, an enable, a
          // status and an edge bit, so a wide default is real area for nothing.
          pinCount: dev.params?.pins ?? 8,
          busAddressWidth: busConfig.addressWidth,
          busDataWidth: busConfig.dataWidth,
          name: dev.name,
        );
      case 'sdio':
        // Native SD/SDIO host. `ownPads` gives one bidirectional pad per CMD/DAT
        // line (IOBUF), and `fabricDma` (from the `dma` param) exposes the ADMA
        // engine as a Wishbone master wired to the fabric via addMaster below.
        // 4-bit native SD: 4x the throughput of the 1-bit SPI path (the reason
        // to use SDIO). DAT0..3 + CMD + CLK + CD map to the full PmodSD pinout.
        return HarborSdioController(
          baseAddress: dev.address,
          config: HarborSdioConfig(
            maxBusWidth: HarborSdioBusWidth.four,
            // Reset default for the read-data sample edge. A real board with a
            // marginal read-capture window (a long card round-trip at speed)
            // sets samplefall=1 so the read DAT is sampled on the falling edge.
            sampleReadOnFall: dev.params?.sampleFall ?? false,
          ),
          // FPGA/ASIC collapse CMD/DAT to bidirectional IOBUF pads; under
          // Verilator keep the split out/oe/in ports so the C++ SD-card sim
          // model can drive the response/data lines cleanly (inout pads are
          // fiddly to drive from a host model), matching the ROHD SD oracle.
          ownPads: target is! HarborSimTarget,
          fabricDma: dev.params?.dma ?? false,
          dmaAddressWidth: busConfig.addressWidth,
          dmaDataWidth: busConfig.dataWidth,
          busAddressWidth: busConfig.addressWidth,
          busDataWidth: busConfig.dataWidth,
          // On a posted-write DDR fabric an ADMA card-read's block writes are
          // ACKed before they commit to DRAM, so raising data-done when the RX
          // FIFO drains lets the CPU read the buffer while the last writes are
          // still in flight (stale data -> the Arty S7 sustained-read reset).
          // Fence the writes with a read-back so data-done means durable. Only
          // when this SoC has both the ADMA and a real DDR memory; SRAM-only
          // SoCs keep the byte-identical straight-through completion.
          readBackBarrier:
              (dev.params?.dma ?? false) &&
              memories.any((m) => m.ddrBoard != null),
          // Drop CYC after EVERY DDR write beat (not every 16) on a DDR SoC. The
          // ADMA otherwise holds CYC across a burst; the DRAM CDC bridge wedges
          // on back-to-back held-CYC transactions on silicon (it needs CYC to
          // drop between transactions, the same hazard l1_cache guards the CPU
          // against). One beat per bus grant gives the CDC that guarantee.
          dmaBurstBeats:
              (dev.params?.dma ?? false) &&
                  memories.any((m) => m.ddrBoard != null)
              ? 1
              : 16,
          name: dev.name,
        );
      default:
        // A device type the parser accepts but no case builds would otherwise
        // vanish silently: no RTL, no device-tree node, no bus window, and no
        // message. That is the same class of fault as an interrupt source that
        // is declared but never wired, so name it here instead.
        throw ArgumentError(
          'Device "${dev.name}": type "${dev.type}" has no peripheral '
          'implementation in genip. Supported MMIO types are '
          'uart, clint, plic, gpio, spi and sdio.',
        );
    }
  }

  Future<Uint8List> _buildMaskrom(
    RiverCoreConfig coreConfig,
    WishboneConfig busConfig,
  ) async {
    final firstMem = memories.isNotEmpty ? memories.first : null;
    // When USB DFU is integrated, the maskrom arms USB, waits for the host to
    // download an image into SRAM, then jumps to the reported entry address.
    final dfuConfig = usbDfu
        ? RiverDfuConfig(
            controlAddr: dfuControlAddr,
            statusAddr: dfuStatusAddr,
            entryAddr: dfuEntryAddr,
          )
        : null;
    // Bundled flash firmware: copy from flash[firmwareOffset] into SRAM and jump
    // there. flashSource is the firmware OFFSET (not flash base 0, the bitstream),
    // copyDest is SRAM, copySize is the firmware byte length. The `dramexec` boot
    // program consumes --flash-firmware-path itself (copies it into DRAM and jumps
    // there), so skip the flash->SRAM bundling for it and let the external binary
    // reach the dramexec case below.
    if ((flashFirmware != null || flashFirmwarePath != null) &&
        bootProgram != 'dramexec') {
      final flash = flashRegion ?? firstMem;
      final sram = sramRegion;
      if (flash == null || sram == null) {
        throw StateError(
          'flash-firmware bundle needs both a flash and an sram region',
        );
      }
      // An external binary (e.g. the Weir FSBL) takes precedence over a built-in
      // firmware program: the maskrom copies its raw bytes into SRAM and jumps.
      final firmware = flashFirmwarePath != null
          ? await File(flashFirmwarePath!).readAsBytes()
          : await buildFlashFirmware(coreConfig);
      final rom = RiverMaskrom(
        RiverMaskromConfig(
          isa: coreConfig.isa,
          resetVector: coreConfig.resetVector,
          flashSource: flash.address + flashFirmwareOffset,
          copyDest: sram.address,
          // Round up to a word so the maskrom's word copy covers the tail byte.
          copySize: (firmware.length + 3) & ~3,
          stackTop: sram.address + sram.size,
        ),
      );
      await rom.build();
      return Uint8List.fromList(rom.generateBinary());
    }
    // In DFU mode the stack lives in writable SRAM (the download target),
    // not the read-only flash that `memories.first` usually is.
    final stackMem = usbDfu ? (dfuRamRegion ?? firstMem) : firstMem;
    final rom = RiverMaskrom(
      RiverMaskromConfig(
        isa: coreConfig.isa,
        resetVector: coreConfig.resetVector,
        flashSource: firstMem?.address ?? 0,
        copyDest: firstMem?.address ?? 0,
        copySize: 4,
        stackTop: (stackMem?.address ?? 0) + (stackMem?.size ?? 0x1000),
        dfu: dfuConfig,
      ),
    );
    await rom.build();
    return Uint8List.fromList(rom.generateBinary());
  }

  /// Builds the bundled flash firmware ([flashFirmware]) against the first UART
  /// and the flash region. Returns the raw bytes to be flashed at
  /// [flashFirmwareOffset] (and which the maskrom copies into SRAM).
  Future<Uint8List> buildFlashFirmware(RiverCoreConfig coreConfig) async {
    final uart = mmioDevices.firstWhere(
      (d) => d.type == 'uart',
      orElse: () => throw StateError('flash firmware needs a uart device'),
    );
    final flash = flashRegion;
    if (flash == null) {
      throw StateError('flash firmware needs a flash region');
    }
    switch (flashFirmware) {
      case 'hexdump':
        final fw = RiverFlashHexdump(
          isa: coreConfig.isa,
          uartBase: uart.address,
          flashBase: flash.address,
          clockHz: clockFrequency,
        );
        await fw.build();
        return Uint8List.fromList(fw.generateBinary());
      default:
        throw UnsupportedError('Unknown flash firmware: $flashFirmware');
    }
  }

  /// Builds the selected built-in boot program for the boot ROM, against the
  /// first UART and the first RAM region.
  ///
  /// `hello` ([RiverHelloWorld]) streams a banner after round-tripping it
  /// through RAM. `monitor` ([RiverSerialMonitor]) additionally loads
  /// checksummed payloads into RAM over the UART and jumps to them.
  Future<Uint8List> _buildBootProgram(RiverCoreConfig coreConfig) async {
    final uart = mmioDevices.firstWhere(
      (d) => d.type == 'uart',
      orElse: () => throw StateError('boot program needs a uart device'),
    );
    if (memories.isEmpty) {
      throw StateError('boot program needs a RAM region');
    }
    // The boot program scratchpads through writable RAM, so ramBase must be a RAM
    // region, NOT flash. `memories.first` is the read-only flash region in the
    // usual (flash, sram, dram) ordering. Storing there drops the bytes and the
    // program streams garbage. Prefer SRAM, fall back to any non-flash region.
    final ram = memories.firstWhere(
      (m) => m.type == 'sram',
      orElse: () => memories.firstWhere(
        (m) => m.type != 'flash',
        orElse: () => throw StateError(
          'boot program needs a writable RAM region (sram or dram)',
        ),
      ),
    );
    final adl.Module program;
    switch (bootProgram) {
      case 'hello':
        program = RiverHelloWorld(
          isa: coreConfig.isa,
          uartBase: uart.address,
          ramBase: ram.address,
          clockHz: clockFrequency,
          // Stream the banner continuously so bring-up can dial in the UART
          // baud without racing a one-shot that fires the instant the FPGA
          // configures (before a terminal is attached).
          loop: true,
        );
      case 'trapwfi':
        // Silicon proof for the creek dynamic-microcode MRET + WFI fixes: runs
        // straight from the boot ROM (romBase = resetVector), no RAM copy, and
        // streams CREEK/M/R/W/OK markers. No "R" => MRET still loops. No "W"/"OK"
        // => WFI still wedges.
        program = RiverTrapWfiTest(
          isa: coreConfig.isa,
          uartBase: uart.address,
          romBase: coreConfig.resetVector,
          clockHz: clockFrequency,
        );
      case 'monitor':
        program = RiverSerialMonitor(
          isa: coreConfig.isa,
          uartBase: uart.address,
          ramBase: ram.address,
          clockHz: clockFrequency,
        );
      case 'ddrtest':
        // Isolates the DDR array from the FSBL/main: the maskrom runs the proven
        // RiverDdrTest (8-offset word sweep + byte ops) straight from ROM against
        // the dram region and prints "DDR OK" or "DDR ER". No FSBL, no flash copy.
        final dram = memories.firstWhere(
          (m) => m.type == 'dram',
          orElse: () =>
              throw StateError('ddrtest boot program needs a dram region'),
        );
        program = RiverDdrTest(
          isa: coreConfig.isa,
          uartBase: uart.address,
          dramBase: dram.address,
          // Train-control MMIO sits just above the DRAM array (board-relative,
          // NOT a fixed 128M offset which lands inside a 256M array).
          trainCtrlBase: dram.address + dram.size,
          clockHz: clockFrequency,
          // Loop the verdict: FPGA reconfig glitches the first UART bytes on
          // hardware, so a one-shot print is unreadable. Streaming repeats
          // gives a clean read once the line settles.
          loopForever: true,
          singleWord: ddrSingleWord,
        );
      case 'ddrprobe':
        // Diagnostic hex dump: printer self-test (0x12345678) then two passes
        // writing distinct patterns and dumping the readbacks. Tracks-pattern =
        // writes land but read suspect. Identical junk both passes = writes never
        // reach the array.
        final dram = memories.firstWhere(
          (m) => m.type == 'dram',
          orElse: () =>
              throw StateError('ddrprobe boot program needs a dram region'),
        );
        program = RiverDdrProbe(
          isa: coreConfig.isa,
          uartBase: uart.address,
          dramBase: dram.address,
          clockHz: clockFrequency,
        );
      case 'ddrlevel':
        // DDR3 READ-vs-WRITE discriminator (no scope). Programs the trainable-read
        // MMIO block and runs two sub-tests across RDSLACK 0..4 x READCLKSEL 0..7,
        // judged by data. Test A (RDADDR) reads four distinct rows/banks with no
        // writes: DISTINCT = read captures array, ALLSAME = read-side bug. Test B
        // (WRCHG) writes then re-reads A0: CHANGES = writes modify the cell,
        // NOCHANGE = writes never land. Needs trainableRead (genip auto-enables it
        // plus writeLevel here).
        final dram = memories.firstWhere(
          (m) => m.type == 'dram',
          orElse: () =>
              throw StateError('ddrlevel boot program needs a dram region'),
        );
        program = RiverDdrLevel(
          isa: coreConfig.isa,
          uartBase: uart.address,
          dramBase: dram.address,
          // The train-control window sits immediately above the DRAM array.
          trainCtrlBase: dram.address + dram.size,
          clockHz: clockFrequency,
        );
      case 'ddrlevelx':
        // Xilinx (Arty S7) ISERDESE2 read-leveling. Walks the per-lane IDELAY
        // tap (reg10 LD/CE/INC) to center each DQ eye against a written pattern,
        // then searches the fabric BITSLIP (reg11) for the beat rotation that
        // reads it clean, reporting LVLX L=<lane> TAP/LO/HI + LVLX SLIP over the
        // UART. Drives the train-control MMIO exposed by the Xilinx DDR PHY when
        // the read path is trainable (genip auto-enables trainableRead here).
        final dram = memories.firstWhere(
          (m) => m.type == 'dram',
          orElse: () =>
              throw StateError('ddrlevelx boot program needs a dram region'),
        );
        program = RiverDdrLevelXilinx(
          isa: coreConfig.isa,
          uartBase: uart.address,
          dramBase: dram.address,
          // The train-control window sits immediately above the DRAM array.
          trainCtrlBase: dram.address + dram.size,
          clockHz: clockFrequency,
          // dram region `mpr` param => run MPR read-eye centering (write-
          // independent 0101 target). Real build => park the baked center + run
          // the A/B/C write-store test with the clean read.
          mprMode: dram.ddrParams?.mpr ?? false,
        );
      case 'ddrdiag':
        // DDR train-control ADDRESS diagnostic (no scope). Prints the train-control
        // STATUS address as a full 64-bit value (CTLADDR=<hi> <lo>) to check
        // whether the upper 32 bits are sign-extended, then brackets a control
        // WRITE (TRYWR/WROK) and READ (TRYRD/RDOK=) so a missing OK marker
        // pinpoints which access never acks. Needs the train-control window
        // (genip auto-enables trainableRead here).
        final dram = memories.firstWhere(
          (m) => m.type == 'dram',
          orElse: () =>
              throw StateError('ddrdiag boot program needs a dram region'),
        );
        program = RiverDdrDiag(
          isa: coreConfig.isa,
          uartBase: uart.address,
          dramBase: dram.address,
          // The train-control window sits immediately above the DRAM array.
          trainCtrlBase: dram.address + dram.size,
          clockHz: clockFrequency,
        );
      case 'ddreye':
        // DDR3 read-leveling EYE SWEEP. Sweeps RDTAP {0,8,..,120} x READCLKSEL 0..7
        // x RDSLACK 0..4 (640 combos), writing + reading the C0DE pattern each,
        // printing INTERESTING lines (EYE ... [MATCH]) and a looped summary
        // (EYEBEST / EYEDV) so a UART read finds the read eye (or proves DATAVALID
        // never fires, a deeper analog read-strobe issue). Needs the train-control
        // window + writeLevel (genip auto-enables both here).
        final dram = memories.firstWhere(
          (m) => m.type == 'dram',
          orElse: () =>
              throw StateError('ddreye boot program needs a dram region'),
        );
        program = RiverDdrEyeSweep(
          isa: coreConfig.isa,
          uartBase: uart.address,
          dramBase: dram.address,
          // The train-control window sits immediately above the DRAM array.
          trainCtrlBase: dram.address + dram.size,
          clockHz: clockFrequency,
        );
      case 'ddrverify':
        // Minimal DDR probe: prints the STATUS reg (DLL lock / valid flags), then
        // a write->readback loop + a retention check. Unambiguous output where the
        // eye diagnostics are degraded. Needs the train-control window for STATUS
        // (genip builds it here via the board default trainable).
        final dram = memories.firstWhere(
          (m) => m.type == 'dram',
          orElse: () =>
              throw StateError('ddrverify boot program needs a dram region'),
        );
        program = RiverDdrVerify(
          isa: coreConfig.isa,
          uartBase: uart.address,
          dramBase: dram.address,
          trainCtrlBase: dram.address + dram.size,
          clockHz: clockFrequency,
        );
      case 'dramexec':
        // Proves the core can FETCH+EXECUTE from DRAM, not just load/store: prints
        // "DEXEC", copies a PIC banner stub into DRAM, then jalrs to it. Banner
        // streams = I-fetch from DRAM works. Dead after "DEXEC" = the core cannot
        // fetch from DRAM.
        final dram = memories.firstWhere(
          (m) => m.type == 'dram',
          orElse: () =>
              throw StateError('dramexec boot program needs a dram region'),
        );
        // The DRAM payload: an external binary via --flash-firmware-path (e.g. a
        // Weir linked at the dram base), or the built-in PIC "DRAM EXEC OK" banner
        // stub when none is given. RiverDramExec copies to dram.address and jalrs
        // there, so the payload must be linked at dram.address.
        final List<int> dxBytes;
        if (flashFirmwarePath != null) {
          dxBytes = await File(flashFirmwarePath!).readAsBytes();
        } else {
          final dxStub = RiverHelloWorld(
            isa: coreConfig.isa,
            uartBase: uart.address,
            ramBase: dram.address + 0x10000,
            clockHz: clockFrequency,
            message: 'DRAM EXEC OK\r\n',
            loop: true,
          );
          await dxStub.build();
          dxBytes = dxStub.generateBinary();
        }
        program = RiverDramExec(
          isa: coreConfig.isa,
          uartBase: uart.address,
          dramBase: dram.address,
          clockHz: clockFrequency,
          stubBytes: dxBytes,
        );
      case 'dramping':
        // Like dramexec, but the DRAM stub prints from immediates with pacing
        // (no DRAM data buffer, no UART saturation). Clean [PING] lines = fetch
        // from DRAM is sound. Garbled = fetch itself is marginal.
        final dram = memories.firstWhere(
          (m) => m.type == 'dram',
          orElse: () =>
              throw StateError('dramping boot program needs a dram region'),
        );
        final dpStub = RiverDramPing(
          isa: coreConfig.isa,
          uartBase: uart.address,
        );
        await dpStub.build();
        program = RiverDramExec(
          isa: coreConfig.isa,
          uartBase: uart.address,
          dramBase: dram.address,
          clockHz: clockFrequency,
          stubBytes: dpStub.generateBinary(),
        );
      case 'dramstress':
      case 'dramstress64':
      case 'dramstresshi':
        // Reproduces the Weir bss-memset hang in isolation: a stub that runs FROM
        // DRAM while streaming heavy stores TO DRAM (fetch-under-write contention
        // through the MMU arbiter + downsizer + CDC). Steady dots = sound. Dots
        // stop/garble = the core wandered mid-sweep. `dramstress64` uses 64-bit
        // `sd` (both downsizer lanes) vs `sw`.
        final dram = memories.firstWhere(
          (m) => m.type == 'dram',
          orElse: () =>
              throw StateError('dramstress boot program needs a dram region'),
        );
        final dsStub = RiverDramWriteStress(
          isa: coreConfig.isa,
          uartBase: uart.address,
          dramBase: dram.address,
          useSd: bootProgram != 'dramstress', // 64-bit for 64 + hi
          // dramstress: sw from a PAGE-MISALIGNED base (0x95d0, == Weir bss_start
          //   low bits) to reproduce the Weir +1MiB hang outside Weir.
          // dramstresshi: 96MB up. dramstress64: aligned sd.
          writeOffset: switch (bootProgram) {
            'dramstresshi' => 0x6000000,
            'dramstress' => 0x95d0,
            _ => 0x100000,
          },
        );
        await dsStub.build();
        program = RiverDramExec(
          isa: coreConfig.isa,
          uartBase: uart.address,
          dramBase: dram.address,
          clockHz: clockFrequency,
          stubBytes: dsStub.generateBinary(),
        );
      case 'hexdump':
        // Silent bring-up probe: hex-dump two flash windows straight from ROM, no
        // flash-write or maskrom-copy dependency. Region A is the bitstream
        // preamble (offset 0), region B the firmware slot at 0x100000. Both read
        // by lbu XIP from the flash region base.
        final flash = flashRegion;
        if (flash == null) {
          throw StateError('hexdump boot program needs a flash region');
        }
        program = RiverFlashHexdump(
          isa: coreConfig.isa,
          uartBase: uart.address,
          flashBase: flash.address,
          clockHz: clockFrequency,
          regions: [
            HexdumpRegion(
              base: flash.address,
              length: 512,
              header: 'FLASH @0:',
            ),
            HexdumpRegion(
              base: flash.address + 0x100000,
              length: 64,
              header: 'FLASH @100000:',
            ),
          ],
        );
      case 'bundleselftest':
        // SILENT-bundle diagnostic: mirror the maskrom flash->SRAM copy+jump
        // from ROM with checkpoints, so one boot localizes which boundary breaks
        // (flash read / copy / jump). Needs flash + sram and the firmware length.
        final flash = flashRegion;
        final sram = sramRegion;
        if (flash == null || sram == null) {
          throw StateError(
            'bundleselftest boot program needs both a flash and an sram region',
          );
        }
        // Build the SAME hexdump firmware the bundle flashes, just to learn its
        // length (the copy word count). Independent of the --flash-firmware
        // option, so the probe works as a plain --boot-program.
        final fw = RiverFlashHexdump(
          isa: coreConfig.isa,
          uartBase: uart.address,
          flashBase: flash.address,
          clockHz: clockFrequency,
        );
        await fw.build();
        final firmware = fw.generateBinary();
        program = RiverBundleSelfTest(
          isa: coreConfig.isa,
          uartBase: uart.address,
          flashSource: flash.address + flashFirmwareOffset,
          copyDest: sram.address,
          copyWords: (firmware.length + 3) >> 2,
          clockHz: clockFrequency,
        );
      case 'xipboot':
        // creek "maskrom -> FSBL in XIP -> Weir in DDR" boot with NO SRAM: run
        // from the BRAM boot ROM (reset vector), warm up the flash XIP controller
        // (the Xilinx STARTUPE2/CCLK path is not fetch-ready at the first
        // cold-reset cycle), then jump to the FSBL executing IN PLACE from flash.
        // The FSBL lives at the `river-fsbl` partition offset: on an FPGA that is
        // ABOVE the config bitstream (slot 0 holds the bitstream for master-SPI
        // self-boot), on an ASIC it is flash base. Main Weir sits above the FSBL
        // and the FSBL copies it into DRAM. Same layout the DT partitions carry.
        final flash = flashRegion;
        if (flash == null) {
          throw StateError('xipboot boot program needs a flash region');
        }
        // Use the HARBOR target (buildTarget()), not the genip `target` field:
        // flashLayout keys FPGA-vs-ASIC on `is HarborFpgaTarget`, and the field
        // is genip's own Target type, so it would wrongly fall to the ASIC
        // offset 0 and xipboot would jump into the bitstream slot instead of the
        // relocated FSBL. Matches the flash/DT site (buildSoC uses buildTarget()).
        final fsblOffset = flashLayout(buildTarget(), flash.size).fsblOffset;
        final stackMem = memories.firstWhere(
          (m) => m.type != 'flash',
          orElse: () => flash,
        );
        // Boot banner, e.g. "River maskrom (RC1.f, Delta V1), jumping to FSBL
        // in flash". The core id "rc1-f" reads as "RC1.f" (uppercase the RC1
        // stem, keep the variant suffix) and the SoC name "delta_v1" reads as
        // "Delta V1" (title-case each underscore-word).
        final coreParts = cores.first.split('-');
        final coreName = [
          coreParts.first.toUpperCase(),
          ...coreParts.skip(1),
        ].join('.');
        final socDisplay = name
            .split('_')
            .map(
              (w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}',
            )
            .join(' ');
        final banner =
            'River maskrom ($coreName, $socDisplay), jumping to FSBL in flash\r\n';
        program = RiverMaskrom(
          RiverMaskromConfig(
            isa: coreConfig.isa,
            resetVector: coreConfig.resetVector,
            flashSource: flash.address + fsblOffset,
            copyDest: flash.address + fsblOffset, // jump target = FSBL entry
            copySize: 256, // warmup read window
            stackTop: stackMem.address + stackMem.size,
            bootMode: RiverBootMode.xipLaunch,
            bootMessage: banner,
            uartBase: uart.address,
            uartDivisor: (clockFrequency ~/ 115200).clamp(1, 0xffff),
          ),
        );
      default:
        throw UnsupportedError('Unknown boot program: $bootProgram');
    }
    await program.build();
    return Uint8List.fromList(program.generateBinary());
  }

  static List<int> _bytesToWords(Uint8List bytes, int bytesPerWord) {
    final words = <int>[];
    for (var i = 0; i < bytes.length; i += bytesPerWord) {
      var word = 0;
      for (var b = 0; b < bytesPerWord && (i + b) < bytes.length; b++) {
        word |= bytes[i + b] << (b * 8);
      }
      words.add(word);
    }
    return words;
  }
}

int _parseSize(String s) {
  final upper = s.toUpperCase();
  if (upper.endsWith('G')) {
    return int.parse(upper.substring(0, upper.length - 1)) * 1024 * 1024 * 1024;
  }
  if (upper.endsWith('M')) {
    return int.parse(upper.substring(0, upper.length - 1)) * 1024 * 1024;
  }
  if (upper.endsWith('K')) {
    return int.parse(upper.substring(0, upper.length - 1)) * 1024;
  }
  return int.parse(s);
}
