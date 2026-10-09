import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
// river.dart re-exports harbor (HarborUsbCore, HarborUsbDfu, UsbDfuRamSink,
// UsbDfuSinkInterface, HarborCdcSync, HarborCdcHandshake, Wishbone*,
// BusSlavePort, HarborDeviceTreeNode(Provider), BusAddressRange, etc.).
import 'package:river/river.dart';

/// [BridgeModule] wrapper that merges the two SoC masters (River core + DFU
/// RAM-sink writeback master) onto a single decoder master. Exposes two CONSUMER
/// master ports (`m0`, `m1`) the upstream masters connect into and one PROVIDER
/// `slave` port into the decoder. Single bus clock domain (12 MHz `bus_clk` /
/// `bus_reset`); the USB crossing already happened in [UsbDfuRamSink]'s CDC FIFO.
class RiverWishboneArbiter extends BridgeModule {
  RiverWishboneArbiter(WishboneConfig config, {String? name})
    : super('RiverWishboneArbiter', name: name ?? 'wb_arbiter2') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // Two upstream masters: this module is the CONSUMER (it receives the
    // master's CYC/ADR/... and drives ACK/DAT_MISO back), so the upstream
    // PROVIDER interfaces connect down into these.
    final m0Ref = addInterface(
      WishboneInterface(config),
      name: 'm0',
      role: PairRole.consumer,
    );
    final m1Ref = addInterface(
      WishboneInterface(config),
      name: 'm1',
      role: PairRole.consumer,
    );
    // Downstream merged slave: this module is the PROVIDER, driving the decoder.
    final slaveRef = addInterface(
      WishboneInterface(config),
      name: 'slave',
      role: PairRole.provider,
    );

    final m0 = m0Ref.internalInterface as WishboneInterface;
    final m1 = m1Ref.internalInterface as WishboneInterface;
    final s = slaveRef.internalInterface as WishboneInterface;

    // Arbitration is inline (not via the raw WishboneArbiter Module): the slave
    // response signals (ACK/DAT_MISO) driven in by the parent decoder must be
    // consumed within this module's boundary; nesting the raw arbiter would tap
    // them across the module edge, which ROHD forbids.
    //
    // Grant policy: registered CYC-held round-robin. The grant only changes while
    // no transfer is in flight, so a burst is never torn mid-transaction.
    final clk = input('clk');
    final reset = input('reset');

    // grantM1: 0 -> master 0 (core) is granted, 1 -> master 1 (DFU sink).
    final grantM1 = Logic(name: 'grant_m1');
    // last: who was served last, for round-robin fairness.
    final last = Logic(name: 'last_grant');

    final m0Req = m0.cyc;
    final m1Req = m1.cyc;
    final grantedCyc = mux(grantM1, m1Req, m0Req); // current grantee's CYC
    final busIdle = ~grantedCyc;

    Sequential(clk, [
      If(
        reset,
        then: [grantM1 < Const(0), last < Const(0)],
        orElse: [
          // Re-arbitrate only when the bus is idle (no granted transfer running).
          If(
            busIdle,
            then: [
              // Round-robin: prefer the master that was NOT served last.
              If(
                last & m0Req,
                then: [grantM1 < Const(0), last < Const(0)],
                orElse: [
                  If(
                    ~last & m1Req,
                    then: [grantM1 < Const(1), last < Const(1)],
                    orElse: [
                      // Otherwise keep whichever single master is requesting.
                      If(m0Req, then: [grantM1 < Const(0), last < Const(0)]),
                      If(
                        m1Req & ~m0Req,
                        then: [grantM1 < Const(1), last < Const(1)],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    // Forward the granted master to the slave.
    s.cyc <= mux(grantM1, m1.cyc, m0.cyc);
    s.stb <= mux(grantM1, m1.stb, m0.stb);
    s.we <= mux(grantM1, m1.we, m0.we);
    s.adr <= mux(grantM1, m1.adr, m0.adr);
    s.datMosi <= mux(grantM1, m1.datMosi, m0.datMosi);
    s.sel <= mux(grantM1, m1.sel, m0.sel);

    // Route the slave response back: ACK gated per master, DAT_MISO broadcast.
    m0.ack <= s.ack & ~grantM1;
    m1.ack <= s.ack & grantM1;
    m0.datMiso <= s.datMiso;
    m1.datMiso <= s.datMiso;
  }
}

/// Small Wishbone SLAVE status/control block the maskrom polls to drive a USB
/// DFU download into RAM. Single-cycle registered ACK, bus (12 MHz) domain.
///
/// Word-mapped registers (word offset within [baseAddress]):
///   0x00  STATUS   (R)  bit0 = image_ready (sticky from the RAM sink).
///   0x04  CONTROL  (R/W) bit0 = usb_enable: write 1 to assert the USB pull-up
///                       enable so the host enumerates. Reads back latched value.
///   0x08  ENTRY    (R)  RAM entry address the image landed at (= sink loadBase).
///   0x0C  BYTES    (R)  image bytes written so far (debug).
///
/// Status inputs come from [UsbDfuRamSink]'s bus-domain outputs; usb_enable is
/// the only writable bit, surfaced as an output to gate the USB pull-up.
class RiverDfuStatus extends BridgeModule with HarborDeviceTreeNodeProvider {
  final int baseAddress;
  final int busAddressWidth;
  final int busDataWidth;

  /// The control bit the CPU writes to enable USB (drives the pull-up enable).
  Logic get usbEnable => output('usb_enable');

  late final BusSlavePort bus;

  RiverDfuStatus({
    required this.baseAddress,
    this.busAddressWidth = 32,
    this.busDataWidth = 32,
    String? name,
  }) : super('RiverDfuStatus', name: name ?? 'dfu_status') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // Bus-domain status inputs from the RAM sink.
    createPort('image_ready', PortDirection.input);
    createPort('entry_addr', PortDirection.input, width: busAddressWidth);
    createPort('bytes_written', PortDirection.input, width: 32);

    addOutput('usb_enable');

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: BusProtocol.wishbone,
      addressWidth: busAddressWidth,
      dataWidth: busDataWidth,
    );

    final clk = input('clk');
    final reset = input('reset');

    final imageReadyIn = input('image_ready');
    final entryAddrIn = input('entry_addr');
    final bytesWrittenIn = input('bytes_written');

    // Sticky image_ready: once the sink pulses/holds it, latch it so the
    // maskrom poll cannot miss a transient.
    final imageReadySticky = Logic(name: 'image_ready_sticky');
    // usb_enable control bit (R/W).
    final usbEnableReg = Logic(name: 'usb_enable_reg');
    // Registered ACK: one cycle per strobe.
    final ackReg = Logic(name: 'dfu_status_ack');

    final stb = bus.stb;
    final we = bus.we;
    // Word offset (drop the in-word byte bits). A 32-bit bus has a 4-byte word;
    // the register select is addr bits above the byte offset.
    final wordSel = bus.addr.getRange(2, 4); // bits [3:2] -> 0..3

    Sequential(clk, [
      If(
        reset,
        then: [
          imageReadySticky < Const(0),
          usbEnableReg < Const(0),
          ackReg < Const(0),
        ],
        orElse: [
          // Latch image_ready forever once seen.
          If(imageReadyIn, then: [imageReadySticky < Const(1)]),

          // ACK is a single-cycle pulse on an unacked strobe.
          ackReg < (stb & ~ackReg),

          // Register write: CONTROL (word offset 1, byte addr 0x04).
          If(
            stb & we & ~ackReg & wordSel.eq(Const(1, width: 2)),
            then: [usbEnableReg < bus.dataIn.getRange(0, 1)],
          ),
        ],
      ),
    ]);

    bus.ack <= ackReg;
    output('usb_enable') <= usbEnableReg;

    // Read mux: select the addressed register, zero-extended to the bus width.
    final statusWord = imageReadySticky
        .zeroExtend(busDataWidth)
        .named('status_word');
    final controlWord = usbEnableReg
        .zeroExtend(busDataWidth)
        .named('control_word');
    final entryWord = entryAddrIn.zeroExtend(busDataWidth).named('entry_word');
    final bytesWord = bytesWrittenIn
        .zeroExtend(busDataWidth)
        .named('bytes_word');

    bus.dataOut <=
        mux(
          wordSel.eq(Const(0, width: 2)),
          statusWord,
          mux(
            wordSel.eq(Const(1, width: 2)),
            controlWord,
            mux(wordSel.eq(Const(2, width: 2)), entryWord, bytesWord),
          ),
        );
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['river,dfu-status'],
    reg: BusAddressRange(baseAddress, 0x1000),
  );
}

/// The USB DFU subsystem: ch9 core + DFU class device + RAM-sink writeback
/// master + line tristate pads, so the SoC sees one bus master and a few
/// pads.
///
/// Dual clock domain. `usb_clk`/`usb_reset` is the raw 48 MHz osc (already
/// the SoC `clk`). It runs [HarborUsbCore], [HarborUsbDfu] and the USB side
/// of [UsbDfuRamSink]. `bus_clk`/`bus_reset` is the 12 MHz core/bus domain
/// (the sink's Wishbone master and CDC FIFO bus side). The FIFO inside the
/// sink bridges the two.
///
/// Exposed ports: a provider Wishbone `bus` (the RAM sink's master), the
/// `usb_dp`/`usb_dm` inOut pads (core dp_out/dm_out + oe tristate, pad fed
/// back to the core), `usb_pullup` (D+ enable, gated by `usb_enable`), the
/// status outputs image_ready/entry_addr/bytes_written, and a `usb_enable`
/// input for the [RiverDfuStatus] slave.
class RiverDfuSubsystem extends BridgeModule {
  final int loadBase;

  /// Size of the writable region starting at [loadBase] the sink will
  /// accept bytes into (the target SRAM region's size).
  final int regionBytes;
  final int busAddressWidth;
  final int busDataWidth;

  RiverDfuSubsystem({
    this.loadBase = 0x80000000,
    required this.regionBytes,
    this.busAddressWidth = 32,
    this.busDataWidth = 32,
    String? name,
  }) : super('RiverDfuSubsystem', name: name ?? 'usb_dfu') {
    // Bus-domain clock/reset (12 MHz). Named clk/reset so addMaster
    // auto-wires them from the bus domain. The 48 MHz usb_clk/usb_reset are
    // wired manually.
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);

    // USB line pads (bidirectional) + pull-up enable + the user button.
    createPort('usb_dp', PortDirection.inOut);
    createPort('usb_dm', PortDirection.inOut);
    addOutput('usb_pullup');

    // Control/status bridge to the RiverDfuStatus slave (bus domain).
    createPort('usb_enable', PortDirection.input);
    addOutput('image_ready');
    addOutput('entry_addr', width: busAddressWidth);
    addOutput('bytes_written', width: 32);

    final usbClk = input('usb_clk');
    final usbReset = input('usb_reset');
    final busClk = input('clk');
    final busReset = input('reset');

    // ch9 core + DFU class device (48 MHz USB domain). No flash sink is
    // ever wired up, so the descriptor set only advertises alt 0 (RAM): a
    // host can then never select the alt setting nothing would service.
    final core = HarborUsbCore(
      descriptors: HarborUsbDfu.dfuDescriptors(includeFlashAlt: false),
      name: 'usb_core',
    );
    addSubModule(core);
    core.input('clk').srcConnection! <= usbClk;
    core.input('reset').srcConnection! <= usbReset;

    final dfu = HarborUsbDfu(name: 'usb_dfu');
    addSubModule(dfu);
    dfu.input('clk').srcConnection! <= usbClk;
    dfu.input('reset').srcConnection! <= usbReset;
    connectInterfaces(core.interface('func'), dfu.interface('usb'));

    // RAM writeback sink (dual domain, Wishbone master).
    final ramSink = UsbDfuRamSink(
      loadBase: loadBase,
      regionBytes: regionBytes,
      busAddressWidth: busAddressWidth,
      busDataWidth: busDataWidth,
      // Depth-8 is plenty: the sink's own ready back-pressure means the
      // device never outruns the bus drain, so a deep FIFO buys nothing but
      // local cells.
      fifoDepth: 8,
      name: 'ram_sink',
    );
    addSubModule(ramSink);
    ramSink.input('usb_clk').srcConnection! <= usbClk;
    ramSink.input('usb_reset').srcConnection! <= usbReset;
    ramSink.input('bus_clk').srcConnection! <= busClk;
    ramSink.input('bus_reset').srcConnection! <= busReset;
    connectInterfaces(dfu.interface('sink'), ramSink.interface('dfu'));

    // Status outputs (bus domain) to the slave.
    output('image_ready') <= ramSink.output('image_ready');
    output('entry_addr') <= ramSink.output('entry_addr');
    output('bytes_written') <= ramSink.output('bytes_written');

    // USB line tristate pads: drive when oe is high, else high-Z, and feed the
    // pad value back into the core's dp/dm inputs.
    final dpPad = inOut('usb_dp');
    final dmPad = inOut('usb_dm');
    final oe = core.output('oe');
    final dpDrive = TriStateBuffer(core.output('dp_out'), enable: oe);
    final dmDrive = TriStateBuffer(core.output('dm_out'), enable: oe);
    dpPad <= dpDrive.out;
    dmPad <= dmDrive.out;
    core.input('dp').srcConnection! <= dpPad;
    core.input('dm').srcConnection! <= dmPad;

    // Pull-up enable, gated by the CPU-written usb_enable so the device only
    // connects once the maskrom has armed DFU mode.
    output('usb_pullup') <= core.output('usb_pullup') & input('usb_enable');

    // Expose the RAM-sink Wishbone master as this subsystem's `bus`.
    pullUpInterface(ramSink.interface('bus'), newIntfName: 'bus');
  }
}

/// Implements [UsbDfuSinkInterface]'s consumer side for the lean software
/// path: a single-entry CDC toggle handshake moves each byte, and the end
/// marker, into the bus domain for [RiverDfuSubsystemSw]'s register file.
///
/// Public so a test can drive `dfu` directly, the way Harbor's own sink
/// tests drive [UsbDfuRamSink].
///
/// Reset boundary: usbReset/busReset are independent, and either can pulse
/// alone. Only the bus side ever forces anything: it watches a synced copy
/// of usbReset and, for a few cycles after that (or its own reset) clears,
/// treats it like `clear` below. Forcing the USB side's producerToggle
/// instead would round-trip it through its own reset value, which the bus
/// domain cannot tell apart from a real byte landing.
class RiverDfuSwSink extends BridgeModule {
  RiverDfuSwSink({String? name})
    : super('RiverDfuSwSink', name: name ?? 'usb_dfu_sw_sink') {
    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);
    createPort('bus_clk', PortDirection.input);
    createPort('bus_reset', PortDirection.input);
    // Bus-domain W1P: the CPU has read the current byte (or the dnload_done
    // status) and releases the next one.
    createPort('advance', PortDirection.input);

    final dfuRef = addInterface(
      UsbDfuSinkInterface(),
      name: 'dfu',
      role: PairRole.consumer,
    );
    final dfu = dfuRef.internalInterface!;

    // Bus-domain register-file taps, read by RiverDfuSubsystemSw.
    addOutput('rx_data', width: 8);
    addOutput('rx_valid');
    addOutput('dnload_done');
    addOutput('bytes_count', width: 32);
    // Sticky: the device issued `clear` (CLRSTATUS, ABORT, a fresh
    // download, or a seen usb-only reset). W1C via `clear_ack` below.
    addOutput('cleared');
    createPort('clear_ack', PortDirection.input);

    final usbClk = input('usb_clk');
    final usbReset = input('usb_reset');
    final busClk = input('bus_clk');
    final busReset = input('bus_reset');
    final advance = input('advance');
    final clearAck = input('clear_ack');

    // consumerToggle (bus domain): flips each time the CPU acks a byte.
    final consumerToggle = Logic(name: 'consumer_toggle');

    // Synchronize the consumer toggle into the USB domain so the device
    // knows its last byte was consumed and may release the next.
    final consSyncUsb = HarborCdcSync(stages: 2, name: 'cons_sync');
    addSubModule(consSyncUsb);
    consSyncUsb.input('async_in').srcConnection! <= consumerToggle;
    consSyncUsb.input('dst_clk').srcConnection! <= usbClk;
    consSyncUsb.input('dst_reset').srcConnection! <= usbReset;
    final consumerInUsb = consSyncUsb.output('sync_out');

    // USB-domain producer side: latch the byte (or the end marker) and flip
    // the producer toggle. ready: the device may push the next byte/marker
    // only once the prior one has been consumed, i.e. producer and
    // (synchronized) consumer toggles match. This is the depth-1
    // back-pressure that replaces a deep FIFO.
    final producerToggle = Logic(name: 'producer_toggle');
    final byteHold = Logic(name: 'byte_hold', width: 8);
    final endHold = Logic(name: 'end_hold');
    // xfer_end has no backpressure of its own: the device drives it off the
    // zero-length DNLOAD's SETUP, not gated on ready the way a data byte
    // is. Latch it if ready is still low from an earlier unacked byte, and
    // hand it over the moment ready returns.
    final endPendingUsb = Logic(name: 'end_pending_usb_q');

    // Reset-boundary recovery, bus side only. See the class comment.
    final usbResetBusSync = HarborCdcSync(name: 'usb_reset_bus_sync');
    addSubModule(usbResetBusSync);
    usbResetBusSync.input('async_in').srcConnection! <= usbReset;
    usbResetBusSync.input('dst_clk').srcConnection! <= busClk;
    usbResetBusSync.input('dst_reset').srcConnection! <= busReset;
    final usbResetSeenBus = usbResetBusSync.output('sync_out');
    final busRecoverCount = Logic(name: 'bus_recover_count_q', width: 2);
    final busRecovering = Logic(name: 'bus_recovering_q');
    Sequential(busClk, [
      If(
        busReset | usbResetSeenBus,
        then: [busRecoverCount < Const(0, width: 2), busRecovering < Const(1)],
        orElse: [
          If(
            busRecovering & busRecoverCount.lt(Const(3, width: 2)),
            then: [busRecoverCount < busRecoverCount + Const(1, width: 2)],
            orElse: [busRecovering < Const(0)],
          ),
        ],
      ),
    ]);

    // Whether busReset has been seen anywhere in the current recovery
    // episode: a power-on or bus-only reset, not a usb-only reset seen
    // at runtime. `cleared` (below) only latches for the latter; a plain
    // reset must read back 0, not look like an aborted download. Spans
    // the raw trigger AND busRecovering's own settle tail: busRecovering
    // itself (a register) still reads stale on the episode's first
    // cycle, and resetting this the instant the raw signals clear would
    // drop it a few cycles before busRecovering (and the `cleared` check
    // below) are actually done with it.
    final recoveryActive = (busRecovering | busReset | usbResetSeenBus)
        .named('recovery_active');
    final recoveryJointWithBusReset = Logic(
      name: 'recovery_joint_with_bus_reset_q',
    );
    Sequential(busClk, [
      If(
        recoveryActive,
        then: [
          If(busReset, then: [recoveryJointWithBusReset < Const(1)]),
        ],
        orElse: [recoveryJointWithBusReset < Const(0)],
      ),
    ]);

    // Sync busRecovering back into the USB domain and hold `ready` low
    // while it is set. Both toggles can briefly read as "matched" right
    // after a reset purely because they reset to the same fixed value,
    // not because the bus side has actually converged yet. Without this,
    // the device could see that transient match, push a byte, and have it
    // lost while the bus side is still forcing prodSeen to track the
    // producer in lockstep (see the busClk Sequential below).
    final busRecoveringUsbSync = HarborCdcSync(name: 'bus_recovering_usb_sync');
    addSubModule(busRecoveringUsbSync);
    busRecoveringUsbSync.input('async_in').srcConnection! <= busRecovering;
    busRecoveringUsbSync.input('dst_clk').srcConnection! <= usbClk;
    busRecoveringUsbSync.input('dst_reset').srcConnection! <= usbReset;
    final busRecoveringSeenUsb = busRecoveringUsbSync.output('sync_out');
    final sinkReady =
        (producerToggle.eq(consumerInUsb) & ~busRecoveringSeenUsb).named(
          'sw_sink_ready',
        );

    // clear: a fresh image or CLRSTATUS/ABORT. Crossed the same way as a
    // byte. The bus domain drops whatever it was holding and forces
    // consumerToggle to match the current producer toggle (below), so
    // ready (producer == consumer) comes back high immediately instead of
    // staying wedged on a byte or end marker this clear just discarded.
    final clearToggleUsb = Logic(name: 'clear_toggle_usb_q');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [clearToggleUsb < Const(0)],
        orElse: [
          If(dfu.clear, then: [clearToggleUsb < ~clearToggleUsb]),
        ],
      ),
    ]);
    final clearSync = HarborCdcSync(name: 'clear_sync');
    addSubModule(clearSync);
    clearSync.input('async_in').srcConnection! <= clearToggleUsb;
    clearSync.input('dst_clk').srcConnection! <= busClk;
    clearSync.input('dst_reset').srcConnection! <= busReset;
    final clearTogglePrevBus = Logic(name: 'clear_toggle_prev_bus_q');
    Sequential(busClk, [
      If(
        busReset,
        then: [clearTogglePrevBus < Const(0)],
        orElse: [clearTogglePrevBus < clearSync.output('sync_out')],
      ),
    ]);
    final clearPulseBus = (clearSync.output('sync_out') ^ clearTogglePrevBus)
        .named('clear_pulse_bus');

    Sequential(usbClk, [
      If(
        usbReset,
        then: [
          producerToggle < Const(0),
          byteHold < Const(0, width: 8),
          endHold < Const(0),
          endPendingUsb < Const(0),
        ],
        orElse: [
          If(dfu.end & ~sinkReady, then: [endPendingUsb < Const(1)]),
          // Capture a byte, or a pending or fresh end marker, only once
          // ready is high.
          If(
            sinkReady & (dfu.valid | dfu.end | endPendingUsb),
            then: [
              byteHold < dfu.data,
              endHold < dfu.end | endPendingUsb,
              producerToggle < ~producerToggle,
              endPendingUsb < Const(0),
            ],
          ),
          // `clear` can land while an end marker is still latched here. A
          // USB bus reset snaps the device straight to dfuIDLE without
          // ever touching this sink, and a DNLOAD from there raises
          // `clear`. An unexpected request during manifest also reaches
          // dfuERROR, and CLRSTATUS from there raises `clear` too. Either
          // way, drop the stale latch or it lands in the next image.
          If(dfu.clear, then: [endPendingUsb < Const(0)]),
        ],
      ),
    ]);

    dfu.ready <= sinkReady;
    dfu.error <= Const(0, width: 4);

    // Synchronize the producer toggle into the bus domain.
    final prodSyncBus = HarborCdcSync(stages: 2, name: 'prod_sync');
    addSubModule(prodSyncBus);
    prodSyncBus.input('async_in').srcConnection! <= producerToggle;
    prodSyncBus.input('dst_clk').srcConnection! <= busClk;
    prodSyncBus.input('dst_reset').srcConnection! <= busReset;
    final producerInBus = prodSyncBus.output('sync_out');

    // Bus-domain capture + register-file state.
    final rxData = Logic(name: 'rx_data_reg', width: 8);
    final rxValid = Logic(name: 'rx_valid_reg');
    final dnloadDoneSticky = Logic(name: 'dnload_done_sticky');
    final bytesCount = Logic(name: 'bytes_count_reg', width: 32);
    // True from the cycle the end marker is captured until the CPU's next
    // advance. Tells that advance to ack `dfu.done` too, not just a normal
    // byte.
    final pendingIsEnd = Logic(name: 'pending_is_end');
    // Last seen producer toggle (bus domain) to detect a fresh byte edge.
    final prodSeen = Logic(name: 'prod_seen');
    final doneAckToggleBus = Logic(name: 'done_ack_toggle_bus_q');
    final clearAckToggleBus = Logic(name: 'clear_ack_toggle_bus_q');
    final clearedSticky = Logic(name: 'cleared_sticky');

    // done/clearDone cross as toggles, instantiated here (ahead of the
    // reset branch below that reads their own synced echo back) so a
    // bus-only reset can re-arm each from what the (unreset) USB side
    // already observes, instead of a bare 0.
    final doneAckSync = HarborCdcSync(name: 'done_ack_sync');
    addSubModule(doneAckSync);
    doneAckSync.input('async_in').srcConnection! <= doneAckToggleBus;
    doneAckSync.input('dst_clk').srcConnection! <= usbClk;
    doneAckSync.input('dst_reset').srcConnection! <= usbReset;

    final clearAckSync = HarborCdcSync(name: 'clear_ack_sync');
    addSubModule(clearAckSync);
    clearAckSync.input('async_in').srcConnection! <= clearAckToggleBus;
    clearAckSync.input('dst_clk').srcConnection! <= usbClk;
    clearAckSync.input('dst_reset').srcConnection! <= usbReset;

    // A new byte is present when the synchronized producer toggle differs
    // from what we last captured.
    final newByte = producerInBus.neq(prodSeen).named('sw_new_byte');

    Sequential(busClk, [
      If(
        busReset,
        then: [
          consumerToggle < Const(0),
          rxData < Const(0, width: 8),
          rxValid < Const(0),
          dnloadDoneSticky < Const(0),
          bytesCount < Const(0, width: 32),
          pendingIsEnd < Const(0),
          prodSeen < Const(0),
          // Re-arm from the already-synced echo, not a bare 0. The
          // (unreset) USB side holds the matching "previous" sample for
          // each, and seeding anything else would look like a phantom
          // done/clearDone the moment the sync catches up. A real clear
          // in flight at this exact instant is still dropped either way,
          // same as UsbDfuRamSink's documented bus_reset/clear policy.
          // HarborUsbDfu's own clear watchdog recovers it.
          doneAckToggleBus < doneAckSync.output('sync_out'),
          clearAckToggleBus < clearAckSync.output('sync_out'),
          clearedSticky < Const(0),
        ],
        orElse: [
          If(
            busRecovering,
            then: [
              // A seen usb-only reset is treated like `clear`: drop
              // whatever byte/end marker was pending. `cleared` only
              // latches when busReset was never part of this episode, a
              // genuine usb-only reset seen at runtime, not a plain
              // power-on or bus-only reset (recoveryJointWithBusReset).
              rxValid < Const(0),
              pendingIsEnd < Const(0),
              bytesCount < Const(0, width: 32),
              dnloadDoneSticky < Const(0),
              prodSeen < producerInBus,
              consumerToggle < producerInBus,
              If(
                ~recoveryJointWithBusReset,
                then: [clearedSticky < Const(1)],
              ),
            ],
            orElse: [
              If(
                clearPulseBus,
                then: [
                  rxValid < Const(0),
                  pendingIsEnd < Const(0),
                  bytesCount < Const(0, width: 32),
                  dnloadDoneSticky < Const(0),
                  prodSeen < producerInBus,
                  consumerToggle < producerInBus,
                  clearAckToggleBus < ~clearAckToggleBus,
                  clearedSticky < Const(1),
                ],
                orElse: [
                  // Capture a freshly-crossed byte into RXDATA, set rx_valid.
                  If(
                    newByte,
                    then: [
                      rxData < byteHold,
                      prodSeen < producerInBus,
                      rxValid < Const(1),
                      bytesCount < bytesCount + Const(1, width: 32),
                      If(
                        endHold,
                        then: [
                          dnloadDoneSticky < Const(1),
                          pendingIsEnd < Const(1),
                        ],
                      ),
                    ],
                  ),
                  // advance: ack the current byte, and the end marker too
                  // if that is what was waiting. Gated on rxValid: with
                  // nothing held, an advance (a stray one, or one that
                  // lands just after a clear already released it) would
                  // otherwise flip the toggle for no byte at all.
                  If(
                    advance & rxValid,
                    then: [
                      consumerToggle < ~consumerToggle,
                      rxValid < Const(0),
                      If(
                        pendingIsEnd,
                        then: [
                          pendingIsEnd < Const(0),
                          doneAckToggleBus < ~doneAckToggleBus,
                        ],
                      ),
                    ],
                  ),
                  If(clearAck, then: [clearedSticky < Const(0)]),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    // done: bus -> USB, pulses once the maskrom's advance has acked the end
    // marker.
    final doneAckTogglePrevUsb = Logic(name: 'done_ack_toggle_prev_usb_q');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [doneAckTogglePrevUsb < Const(0)],
        orElse: [doneAckTogglePrevUsb < doneAckSync.output('sync_out')],
      ),
    ]);
    final doneUsbPulse = (doneAckSync.output('sync_out') ^ doneAckTogglePrevUsb)
        .named('sw_done_usb_pulse');
    dfu.done <= doneUsbPulse;

    // busy: raised the instant the end marker is seen, held until the
    // maskrom's advance drains it through to `done`, or dropped by
    // `clear` so it can never wedge high with no `done` ever due.
    final busyUsb = Logic(name: 'busy_usb_q');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [busyUsb < Const(0)],
        orElse: [
          If(dfu.end, then: [busyUsb < Const(1)]),
          If(doneUsbPulse | dfu.clear, then: [busyUsb < Const(0)]),
        ],
      ),
    ]);
    dfu.busy <= busyUsb;

    // clearDone: bus -> USB, the mirror of clear. Tells the device it is
    // safe to resume the byte stream for the image that follows.
    final clearAckTogglePrevUsb = Logic(name: 'clear_ack_toggle_prev_usb_q');
    Sequential(usbClk, [
      If(
        usbReset,
        then: [clearAckTogglePrevUsb < Const(0)],
        orElse: [clearAckTogglePrevUsb < clearAckSync.output('sync_out')],
      ),
    ]);
    dfu.clearDone <=
        (clearAckSync.output('sync_out') ^ clearAckTogglePrevUsb).named(
          'sw_clear_ack_usb_pulse',
        );

    output('rx_data') <= rxData;
    output('rx_valid') <= rxValid;
    output('dnload_done') <= dnloadDoneSticky;
    output('bytes_count') <= bytesCount;
    output('cleared') <= clearedSticky;
  }
}

/// The lean, software-driven USB DFU subsystem (CAR target): the cheap
/// alternative to [RiverDfuSubsystem] for the LFE5U-25F. Drops the whole
/// hardware RAM-sink tier (no [UsbDfuRamSink], no [HarborCdcFifo], no
/// [RiverWishboneArbiter], no second bus master). Keeps the ch9 core + DFU
/// device and a small register file fed by [RiverDfuSwSink].
///
/// There is no maskrom boot path for this mode: software running later on
/// the CPU (not the maskrom) polls STATUS, reads RXDATA, and writes
/// CONTROL.advance to release the next byte, storing each one wherever it
/// chooses (Cache-as-RAM, a buffer, ...). No SRAM region is needed here.
///
/// `dfu_state` crosses through a [HarborCdcHandshake] (a plain double-flop
/// sync can tear across a multi-bit transition). `configured` crosses
/// through a plain [HarborCdcSync] (one bit cannot tear).
///
/// Word-mapped registers (word offsets within [baseAddress]):
///   0x00 STATUS  (R)  bit0 = rx_valid, bit1 = dnload_done, bit2 = configured,
///                     bit3 = cleared (sticky: the device issued `clear` on
///                     CLRSTATUS, ABORT, a fresh download, or a seen
///                     usb-only reset, W1C via CONTROL bit2), bits[7:4] =
///                     dfu_state. Software must still advance the end
///                     marker (bit1). The host's GETSTATUS keeps reporting
///                     dfuMANIFEST/busy until it does.
///   0x04 CONTROL (R/W) bit0 = usb_enable (pull-up/connect), bit1 = advance
///                     (W1P: ack current byte, release next), bit2 =
///                     clear_ack (W1C: clears STATUS bit3). usb_enable
///                     reads back, the other bits do not.
///   0x08 RXDATA  (R)  bits[7:0] = captured download byte.
///   0x0C BYTES   (R)  running count of bytes captured (debug).
class RiverDfuSubsystemSw extends BridgeModule
    with HarborDeviceTreeNodeProvider {
  final int baseAddress;
  final int busAddressWidth;
  final int busDataWidth;

  RiverDfuSubsystemSw({
    required this.baseAddress,
    this.busAddressWidth = 32,
    this.busDataWidth = 32,
    String? name,
  }) : super('RiverDfuSubsystemSw', name: name ?? 'usb_dfu_sw') {
    // Bus-domain clock/reset (12 MHz). Auto-wired from the bus domain by
    // addPeripheral. The 48 MHz usb_clk/usb_reset are wired manually.
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);

    // USB line pads (bidirectional) + pull-up enable.
    createPort('usb_dp', PortDirection.inOut);
    createPort('usb_dm', PortDirection.inOut);
    addOutput('usb_pullup');

    final usbClk = input('usb_clk');
    final usbReset = input('usb_reset');
    final busClk = input('clk');
    final busReset = input('reset');

    // MMIO slave (bus / 12 MHz domain).
    final bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: BusProtocol.wishbone,
      addressWidth: busAddressWidth,
      dataWidth: busDataWidth,
    );

    // ch9 core + DFU class device (48 MHz USB domain). No flash sink is
    // ever wired up, so the descriptor set only advertises alt 0 (RAM).
    final core = HarborUsbCore(
      descriptors: HarborUsbDfu.dfuDescriptors(includeFlashAlt: false),
      name: 'usb_core',
    );
    addSubModule(core);
    core.input('clk').srcConnection! <= usbClk;
    core.input('reset').srcConnection! <= usbReset;

    final dfu = HarborUsbDfu(name: 'usb_dfu');
    addSubModule(dfu);
    dfu.input('clk').srcConnection! <= usbClk;
    dfu.input('reset').srcConnection! <= usbReset;
    connectInterfaces(core.interface('func'), dfu.interface('usb'));

    // The lean sink: a depth-1 CDC handshake straight into the register file
    // below, no RAM/flash write path.
    final sink = RiverDfuSwSink(name: 'sink');
    addSubModule(sink);
    sink.input('usb_clk').srcConnection! <= usbClk;
    sink.input('usb_reset').srcConnection! <= usbReset;
    sink.input('bus_clk').srcConnection! <= busClk;
    sink.input('bus_reset').srcConnection! <= busReset;
    connectInterfaces(dfu.interface('sink'), sink.interface('dfu'));

    // Bus-domain control regs.
    final usbEnableReg = Logic(name: 'usb_enable_reg');
    final advancePulse = Logic(name: 'advance_pulse'); // bus-domain W1P decode
    final clearAckPulse = Logic(name: 'clear_ack_pulse'); // bus-domain W1C
    final ackReg = Logic(name: 'sw_ack');

    final stb = bus.stb;
    final we = bus.we;
    final wordSel = bus.addr.getRange(2, 4); // bits [3:2] -> 0..3

    Sequential(busClk, [
      If(
        busReset,
        then: [
          usbEnableReg < Const(0),
          ackReg < Const(0),
          advancePulse < Const(0),
          clearAckPulse < Const(0),
        ],
        orElse: [
          // Single-cycle registered ACK.
          ackReg < (stb & ~ackReg),

          // Register writes (CONTROL at word offset 1).
          advancePulse < Const(0),
          clearAckPulse < Const(0),
          If(
            stb & we & ~ackReg & wordSel.eq(Const(1, width: 2)),
            then: [
              usbEnableReg < bus.dataIn.getRange(0, 1),
              // advance (bit1, write-1-pulse): ack the current byte.
              If(
                bus.dataIn.getRange(1, 2).eq(Const(1, width: 1)),
                then: [advancePulse < Const(1)],
              ),
              // clear_ack (bit2, write-1-clear): clear STATUS bit3.
              If(
                bus.dataIn.getRange(2, 3).eq(Const(1, width: 1)),
                then: [clearAckPulse < Const(1)],
              ),
            ],
          ),
        ],
      ),
    ]);
    sink.input('advance').srcConnection! <= advancePulse;
    sink.input('clear_ack').srcConnection! <= clearAckPulse;

    bus.ack <= ackReg;

    // configured: a 1-bit level, so a plain double-flop sync cannot tear.
    final configuredSync = HarborCdcSync(name: 'configured_sync');
    addSubModule(configuredSync);
    configuredSync.input('async_in').srcConnection! <= core.output('configured');
    configuredSync.input('dst_clk').srcConnection! <= busClk;
    configuredSync.input('dst_reset').srcConnection! <= busReset;
    final configured = configuredSync.output('sync_out');

    // dfu_state: 4 bits, crossed through a req/ack handshake instead of a
    // plain sync so the bus domain only ever sees a value the USB domain
    // latched whole, never a mix of old and new bits from mid-transition.
    // dst_data is the handshake's own source-domain register read back
    // raw, so it can keep moving the instant the next transfer is
    // accepted. Latch it into a bus-domain register on dst_valid instead
    // of reading it combinationally.
    final dfuStateXing = HarborCdcHandshake(dataWidth: 4, name: 'dfu_state_xing');
    addSubModule(dfuStateXing);
    dfuStateXing.input('src_clk').srcConnection! <= usbClk;
    dfuStateXing.input('src_reset').srcConnection! <= usbReset;
    dfuStateXing.input('src_data').srcConnection! <= dfu.output('dfu_state');
    dfuStateXing.input('src_valid').srcConnection! <= Const(1);
    dfuStateXing.input('dst_clk').srcConnection! <= busClk;
    dfuStateXing.input('dst_reset').srcConnection! <= busReset;
    dfuStateXing.input('dst_ready').srcConnection! <= Const(1);
    final dfuStateReg = Logic(name: 'dfu_state_reg', width: 4);
    Sequential(busClk, [
      If(
        busReset,
        then: [dfuStateReg < Const(0, width: 4)],
        orElse: [
          If(
            dfuStateXing.output('dst_valid'),
            then: [dfuStateReg < dfuStateXing.output('dst_data')],
          ),
        ],
      ),
    ]);
    final dfuState = dfuStateReg;

    final rxValid = sink.output('rx_valid');
    final dnloadDoneSticky = sink.output('dnload_done');
    final clearedSticky = sink.output('cleared');
    final rxData = sink.output('rx_data');
    final bytesCount = sink.output('bytes_count');
    final statusWord = <Logic>[
      Const(0, width: busDataWidth - 8),
      dfuState, // [7:4]
      clearedSticky, // [3]
      configured, // [2]
      dnloadDoneSticky, // [1]
      rxValid, // [0]
    ].swizzle().named('status_word');
    final controlWord = usbEnableReg
        .zeroExtend(busDataWidth)
        .named('ctrl_word');
    final rxWord = rxData.zeroExtend(busDataWidth).named('rx_word');
    final bytesWord = bytesCount.zeroExtend(busDataWidth).named('bytes_word');

    bus.dataOut <=
        mux(
          wordSel.eq(Const(0, width: 2)),
          statusWord,
          mux(
            wordSel.eq(Const(1, width: 2)),
            controlWord,
            mux(wordSel.eq(Const(2, width: 2)), rxWord, bytesWord),
          ),
        );

    // USB line tristate pads.
    final dpPad = inOut('usb_dp');
    final dmPad = inOut('usb_dm');
    final oe = core.output('oe');
    final dpDrive = TriStateBuffer(core.output('dp_out'), enable: oe);
    final dmDrive = TriStateBuffer(core.output('dm_out'), enable: oe);
    dpPad <= dpDrive.out;
    dmPad <= dmDrive.out;
    core.input('dp').srcConnection! <= dpPad;
    core.input('dm').srcConnection! <= dmPad;

    // Pull-up enable, gated by the CPU-written usb_enable.
    output('usb_pullup') <= core.output('usb_pullup') & usbEnableReg;
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['river,dfu-sw'],
    reg: BusAddressRange(baseAddress, 0x1000),
  );
}
