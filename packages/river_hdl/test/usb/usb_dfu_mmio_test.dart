import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

// Register-map tests for the two usb-dfu MMIO slaves: RiverDfuStatus
// (hardware mode) and RiverDfuSubsystemSw (software mode), both driven
// over their own Wishbone `bus` slave port through a small master stub.
// The "STATUS word bit layout" group below additionally drives a real
// USB full-speed transfer into RiverDfuSubsystemSw's own `usb_dp`/
// `usb_dm` pads through a real host (_UsbHost below), which decodes the
// device's own replies and retries on NAK or no reply like a real USB
// host, then reads the actual result back over MMIO, so rx_valid,
// dnload_done, configured and dfu_state are all genuine, not stand-ins.

const _addrWidth = 32;
const _dataWidth = 32;
final _wbConfig = WishboneConfig(
  addressWidth: _addrWidth,
  dataWidth: _dataWidth,
);

/// A bare Wishbone master a test drives directly: plain input ports in,
/// a provider-role `bus` interface out.
class WishboneMasterStub extends BridgeModule {
  WishboneMasterStub({String? name})
    : super('WishboneMasterStub', name: name ?? 'wb_master_stub') {
    createPort('cyc_in', PortDirection.input);
    createPort('stb_in', PortDirection.input);
    createPort('we_in', PortDirection.input);
    createPort('adr_in', PortDirection.input, width: _addrWidth);
    createPort('dat_mosi_in', PortDirection.input, width: _dataWidth);
    createPort('sel_in', PortDirection.input, width: _dataWidth ~/ 8);
    addOutput('ack_out');
    addOutput('dat_miso_out', width: _dataWidth);

    final ref = addInterface(
      WishboneInterface(_wbConfig),
      name: 'bus',
      role: PairRole.provider,
    );
    final bus = ref.internalInterface!;

    bus.cyc <= input('cyc_in');
    bus.stb <= input('stb_in');
    bus.we <= input('we_in');
    bus.adr <= input('adr_in');
    bus.datMosi <= input('dat_mosi_in');
    bus.sel <= input('sel_in');
    output('ack_out') <= bus.ack;
    output('dat_miso_out') <= bus.datMiso;
  }
}

/// Wires a DUT's `bus` slave interface to a [WishboneMasterStub], with the
/// master's own plain ports forwarded up as this module's own ports so a
/// test can drive them directly. The DUT's non-bus ports are left for the
/// test to wire straight onto [dut] before [build].
class MmioTop extends BridgeModule {
  final BridgeModule dut;

  MmioTop(this.dut, {String? name}) : super('MmioTop', name: name ?? 'mmio_top') {
    createPort('cyc_in', PortDirection.input);
    createPort('stb_in', PortDirection.input);
    createPort('we_in', PortDirection.input);
    createPort('adr_in', PortDirection.input, width: _addrWidth);
    createPort('dat_mosi_in', PortDirection.input, width: _dataWidth);
    createPort('sel_in', PortDirection.input, width: _dataWidth ~/ 8);
    addOutput('ack_out');
    addOutput('dat_miso_out', width: _dataWidth);

    addSubModule(dut);
    final master = WishboneMasterStub(name: 'master');
    addSubModule(master);

    master.input('cyc_in').srcConnection! <= input('cyc_in');
    master.input('stb_in').srcConnection! <= input('stb_in');
    master.input('we_in').srcConnection! <= input('we_in');
    master.input('adr_in').srcConnection! <= input('adr_in');
    master.input('dat_mosi_in').srcConnection! <= input('dat_mosi_in');
    master.input('sel_in').srcConnection! <= input('sel_in');
    connectInterfaces(master.interface('bus'), dut.interface('bus'));

    output('ack_out') <= master.output('ack_out');
    output('dat_miso_out') <= master.output('dat_miso_out');
  }
}

/// Drives one Wishbone transaction at a time into a [MmioTop] over the raw
/// signals feeding its driver ports, polling `ack_out` for completion.
class WbDriver {
  final MmioTop top;
  final Logic clk;
  final Logic cyc;
  final Logic stb;
  final Logic we;
  final Logic adr;
  final Logic datMosi;
  final Logic sel;

  WbDriver({
    required this.top,
    required this.clk,
    required this.cyc,
    required this.stb,
    required this.we,
    required this.adr,
    required this.datMosi,
    required this.sel,
  });

  Future<int> read(int address) async {
    cyc.inject(1);
    stb.inject(1);
    we.inject(0);
    adr.inject(address);
    sel.inject((1 << (_dataWidth ~/ 8)) - 1);
    var result = 0;
    for (var i = 0; i < 50; i++) {
      await clk.nextPosedge;
      if (top.output('ack_out').value.toBool()) {
        result = top.output('dat_miso_out').value.toInt();
        break;
      }
    }
    cyc.inject(0);
    stb.inject(0);
    return result;
  }

  Future<void> write(int address, int value) async {
    cyc.inject(1);
    stb.inject(1);
    we.inject(1);
    adr.inject(address);
    datMosi.inject(value);
    sel.inject((1 << (_dataWidth ~/ 8)) - 1);
    for (var i = 0; i < 50; i++) {
      await clk.nextPosedge;
      if (top.output('ack_out').value.toBool()) break;
    }
    cyc.inject(0);
    stb.inject(0);
    we.inject(0);
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('RiverDfuStatus (hardware mode)', () {
    test('STATUS/CONTROL/ENTRY/BYTES offsets map to the right fields', () async {
      final dut = RiverDfuStatus(
        baseAddress: 0,
        busAddressWidth: _addrWidth,
        busDataWidth: _dataWidth,
      );
      final top = MmioTop(dut);

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final imageReady = Logic(name: 'image_ready');
      final entryAddr = Logic(name: 'entry_addr', width: _addrWidth);
      final bytesWritten = Logic(name: 'bytes_written', width: 32);
      final cyc = Logic(name: 'cyc');
      final stb = Logic(name: 'stb');
      final we = Logic(name: 'we');
      final adr = Logic(name: 'adr', width: _addrWidth);
      final datMosi = Logic(name: 'dat_mosi', width: _dataWidth);
      final sel = Logic(name: 'sel', width: _dataWidth ~/ 8);

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('image_ready').srcConnection! <= imageReady;
      dut.input('entry_addr').srcConnection! <= entryAddr;
      dut.input('bytes_written').srcConnection! <= bytesWritten;
      top.input('cyc_in').srcConnection! <= cyc;
      top.input('stb_in').srcConnection! <= stb;
      top.input('we_in').srcConnection! <= we;
      top.input('adr_in').srcConnection! <= adr;
      top.input('dat_mosi_in').srcConnection! <= datMosi;
      top.input('sel_in').srcConnection! <= sel;

      await top.build();

      reset.inject(1);
      imageReady.inject(0);
      entryAddr.inject(0x08000000);
      bytesWritten.inject(0);
      cyc.inject(0);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      datMosi.inject(0);
      sel.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      final wb = WbDriver(
        top: top,
        clk: clk,
        cyc: cyc,
        stb: stb,
        we: we,
        adr: adr,
        datMosi: datMosi,
        sel: sel,
      );

      // ENTRY (0x08) and BYTES (0x0C) pass the inputs straight through.
      expect(await wb.read(0x08), equals(0x08000000));
      expect(await wb.read(0x0C), equals(0));

      // CONTROL (0x04): usb_enable read/write.
      expect(await wb.read(0x04), equals(0));
      await wb.write(0x04, 0x1);
      expect(await wb.read(0x04), equals(0x1));
      expect(dut.usbEnable.value.toBool(), isTrue);

      // STATUS (0x00): sticky image_ready, bit0.
      expect(await wb.read(0x00), equals(0));
      imageReady.inject(1);
      await clk.nextPosedge;
      imageReady.inject(0);
      await clk.nextPosedge;
      expect(await wb.read(0x00), equals(1));

      await Simulator.endSimulation();
    });
  });

  group('RiverDfuSubsystemSw (software mode)', () {
    test(
      'STATUS/CONTROL/RXDATA/BYTES offsets, W1P advance, usb_enable '
      'readback and the cleared (W1C) bit',
      () async {
        final dut = RiverDfuSubsystemSw(baseAddress: 0);
        final top = MmioTop(dut);

        final busClk = SimpleClockGenerator(23).clk;
        final usbClk = SimpleClockGenerator(9).clk;
        final busReset = Logic(name: 'bus_reset');
        // usb_reset is released once (no real USB transfer ever runs):
        // this checks the register plumbing. Held forever it would also
        // hold RiverDfuSwSink's seen-usb-reset recovery active, which
        // keeps the cleared sticky set the whole time.
        final usbReset = Logic(name: 'usb_reset_hold');
        final dp = Logic(name: 'usb_dp_wire');
        final dm = Logic(name: 'usb_dm_wire');
        final cyc = Logic(name: 'cyc');
        final stb = Logic(name: 'stb');
        final we = Logic(name: 'we');
        final adr = Logic(name: 'adr', width: _addrWidth);
        final datMosi = Logic(name: 'dat_mosi', width: _dataWidth);
        final sel = Logic(name: 'sel', width: _dataWidth ~/ 8);

        dut.input('clk').srcConnection! <= busClk;
        dut.input('reset').srcConnection! <= busReset;
        dut.input('usb_clk').srcConnection! <= usbClk;
        dut.input('usb_reset').srcConnection! <= usbReset;
        dut.inOut('usb_dp') <= dp;
        dut.inOut('usb_dm') <= dm;
        top.input('cyc_in').srcConnection! <= cyc;
        top.input('stb_in').srcConnection! <= stb;
        top.input('we_in').srcConnection! <= we;
        top.input('adr_in').srcConnection! <= adr;
        top.input('dat_mosi_in').srcConnection! <= datMosi;
        top.input('sel_in').srcConnection! <= sel;

        await top.build();

        busReset.inject(1);
        usbReset.inject(1);
        dp.inject(1);
        dm.inject(0);
        cyc.inject(0);
        stb.inject(0);
        we.inject(0);
        adr.inject(0);
        datMosi.inject(0);
        sel.inject(0);
        Simulator.setMaxSimTime(4000000);
        unawaited(Simulator.run());
        await usbClk.nextPosedge;
        await busClk.nextPosedge;
        await busClk.nextPosedge;
        busReset.inject(0);
        usbReset.inject(0);
        // Let RiverDfuSwSink's seen-usb-reset recovery window finish
        // settling before touching any register.
        for (var i = 0; i < 20; i++) {
          await usbClk.nextPosedge;
        }
        for (var i = 0; i < 20; i++) {
          await busClk.nextPosedge;
        }

        final wb = WbDriver(
          top: top,
          clk: busClk,
          cyc: cyc,
          stb: stb,
          we: we,
          adr: adr,
          datMosi: datMosi,
          sel: sel,
        );

        // CONTROL (0x04): usb_enable reads back. advance/clear_ack do not.
        expect(await wb.read(0x04), equals(0));
        await wb.write(0x04, 0x1); // usb_enable=1
        expect(await wb.read(0x04), equals(0x1));
        await wb.write(0x04, 0x7); // usb_enable=1, advance=1, clear_ack=1
        expect(
          await wb.read(0x04),
          equals(0x1),
          reason: 'advance/clear_ack are W1P/W1C, never read back set',
        );

        // usb_pullup mirrors usb_enable (the core's own pullup output is
        // a constant 1).
        expect(dut.output('usb_pullup').value.toBool(), isTrue);

        // RXDATA/BYTES (0x08/0x0C): idle with usb held in reset.
        expect(await wb.read(0x08), equals(0));
        expect(await wb.read(0x0C), equals(0));

        // STATUS (0x00) bit3: cleared starts low, and clear_ack on an
        // already-clear bit is a harmless no-op.
        expect(await wb.read(0x00) & 0x8, equals(0));
        await wb.write(0x04, 0x5); // usb_enable=1, clear_ack=1
        expect(await wb.read(0x00) & 0x8, equals(0));

        await Simulator.endSimulation();
      },
    );
  });

  group('STATUS word bit layout', () {
    test(
      'a real DNLOAD byte and end marker drive every STATUS bit, read '
      'over MMIO',
      () => _runStatusBitLayoutScenario(0),
    );

    // The old sender sent its ACK on a fixed timer after its IN token,
    // so the ACK sometimes landed on top of the device's own reply and
    // the transfer never completed, with nothing to retry it. Only a
    // couple of gap values out of a 100-400 sweep happened to dodge the
    // overlap. The host now watches for a decoded reply the instant it
    // completes and retries on NAK or no reply instead, so padding its
    // post-NAK retry backoff with extra slack must never change the
    // outcome.
    for (final extraGap in [150, 400]) {
      test(
        'STATUS bit layout still passes with $extraGap cycles of extra '
        'retry-backoff padding',
        () => _runStatusBitLayoutScenario(extraGap),
      );
    }
  });
}

/// Builds a fresh [RiverDfuSubsystemSw], enumerates it, downloads one
/// byte and the end marker over real USB, and checks every STATUS bit
/// over MMIO. [extraGap] pads the host's post-NAK retry backoff, to
/// prove the result does not depend on its exact value.
Future<void> _runStatusBitLayoutScenario(int extraGap) async {
  final dut = RiverDfuSubsystemSw(baseAddress: 0);
  final top = MmioTop(dut);

  final busClk = SimpleClockGenerator(23).clk;
  final usbClk = SimpleClockGenerator(9).clk;
  final busReset = Logic(name: 'bus_reset');
  final usbReset = Logic(name: 'usb_reset');
  final cyc = Logic(name: 'cyc');
  final stb = Logic(name: 'stb');
  final we = Logic(name: 'we');
  final adr = Logic(name: 'adr', width: _addrWidth);
  final datMosi = Logic(name: 'dat_mosi', width: _dataWidth);
  final sel = Logic(name: 'sel', width: _dataWidth ~/ 8);

  dut.input('clk').srcConnection! <= busClk;
  dut.input('reset').srcConnection! <= busReset;
  dut.input('usb_clk').srcConnection! <= usbClk;
  dut.input('usb_reset').srcConnection! <= usbReset;
  top.input('cyc_in').srcConnection! <= cyc;
  top.input('stb_in').srcConnection! <= stb;
  top.input('we_in').srcConnection! <= we;
  top.input('adr_in').srcConnection! <= adr;
  top.input('dat_mosi_in').srcConnection! <= datMosi;
  top.input('sel_in').srcConnection! <= sel;

  // usb_core is RiverDfuSubsystemSw's own private HarborUsbCore
  // submodule. Its oe/dp_out/dm_out outputs are the device's reply
  // before the shared pad, so the host's RX reads them straight,
  // uncontended by anything this host itself drives onto the pad.
  final core = dut.subModules.firstWhere((m) => m.name == 'usb_core');

  // The only driver onto the pads besides the device's own
  // TriStateBuffer: see _UsbHost's class comment for why it always
  // drives idle-J rather than releasing the bus. A second,
  // separately-injected constant driver here would permanently contend
  // with every 0 bit this host ever sends.
  final host = _UsbHost(
    clk: usbClk,
    reset: usbReset,
    dpPad: dut.inOut('usb_dp'),
    dmPad: dut.inOut('usb_dm'),
    devOe: core.output('oe'),
    devDp: core.output('dp_out'),
    devDm: core.output('dm_out'),
    extraGap: extraGap,
  );

  await top.build();
  await host.build();

  busReset.inject(1);
  usbReset.inject(1);
  cyc.inject(0);
  stb.inject(0);
  we.inject(0);
  adr.inject(0);
  datMosi.inject(0);
  sel.inject(0);
  Simulator.setMaxSimTime(20000000);
  unawaited(Simulator.run());
  await usbClk.nextPosedge;
  await busClk.nextPosedge;
  await busClk.nextPosedge;
  busReset.inject(0);
  usbReset.inject(0);
  for (var i = 0; i < 20; i++) {
    await usbClk.nextPosedge;
  }
  for (var i = 0; i < 20; i++) {
    await busClk.nextPosedge;
  }

  final wb = WbDriver(
    top: top,
    clk: busClk,
    cyc: cyc,
    stb: stb,
    we: we,
    adr: adr,
    datMosi: datMosi,
    sel: sel,
  );

  // Enumerate: SET_ADDRESS(1), SET_CONFIGURATION(1), SET_INTERFACE
  // alt 0.
  await _controlNoData(host, 0, _stdSetup(0x00, 5, 1));
  await _controlNoData(host, 1, _stdSetup(0x00, 9, 1));
  await _controlNoData(host, 1, _stdSetup(0x01, 11, 0));

  // Nothing has cleared anything yet: bit2 (configured) is the only
  // one set.
  expect(
    await wb.read(0x00) & 0xC,
    equals(0x4),
    reason: 'configured set, cleared still 0, before any DNLOAD',
  );

  // DNLOAD block 0: one byte. A fresh download starting from
  // dfuIDLE is one of HarborUsbDfu's own `clear` triggers (see
  // RiverDfuSwSink's class comment), so STATUS bit3 goes high here
  // too, a real clear this time, not a reset. GETSTATUS then moves
  // dfuDNLOAD_SYNC on to dfuDNLOAD_IDLE (software mode is never
  // busy, so one poll is always enough).
  await _controlWriteOneBlock(host, 1, _stdSetup(0x21, 1, 0, wLength: 1), [0x55]);
  await _getStatus(host, 1);

  // The byte is now captured in the sink. Ack it over MMIO so the
  // device's sink is ready again before the end marker.
  final afterByte = await _pollUntil(
    wb,
    busClk,
    0x00,
    (v) => v & 0x1 == 1,
  );
  expect(afterByte & 0x1, equals(1), reason: 'rx_valid after DNLOAD');
  expect(afterByte & 0x8, equals(8), reason: 'cleared after the fresh-download clear');
  expect(await wb.read(0x08), equals(0x55), reason: 'RXDATA');
  await wb.write(0x04, 0x2); // advance (bit1), no usb_enable

  // The zero-length DNLOAD that ends the transfer. Block 0's clear
  // sticky is never W1C'd here, so it is expected to still read 1.
  await _controlNoData(host, 1, _stdSetup(0x21, 1, 1));

  final status = await _pollUntil(
    wb,
    busClk,
    0x00,
    (v) => v & 0x2 != 0,
  );
  expect(status & 0x1, equals(1), reason: 'bit0 rx_valid');
  expect(status & 0x2, equals(2), reason: 'bit1 dnload_done');
  expect(status & 0x4, equals(4), reason: 'bit2 configured');
  expect(status & 0x8, equals(8), reason: 'bit3 cleared');
  expect(
    (status >> 4) & 0xF,
    equals(6),
    reason: 'bits[7:4] dfu_state == dfuMANIFEST_SYNC',
  );

  await Simulator.endSimulation();
}

// --- Minimal USB full-speed test host. ---
//
// Encoding (CRC5/16, PID bytes, NRZI + bit-stuffing + SYNC/EOP) and the
// RX-decode shape (HarborUsbFsRx fed from the device's own oe/dp_out/
// dm_out) are ported from Harbor's test/peripherals/usb_test_host.dart
// (test-only there, not exported from its lib/).

int _usbCrc5(int data, int nbits) {
  var crc = 0x1F;
  for (var i = 0; i < nbits; i++) {
    final bit = (data >> i) & 1;
    final xorIn = (crc & 1) ^ bit;
    crc >>= 1;
    if (xorIn != 0) crc ^= 0x14;
  }
  return (~crc) & 0x1F;
}

int _usbCrc16(List<int> bytes) {
  var crc = 0xFFFF;
  for (final b in bytes) {
    for (var i = 0; i < 8; i++) {
      final bit = (b >> i) & 1;
      final xorIn = (crc & 1) ^ bit;
      crc >>= 1;
      if (xorIn != 0) crc ^= 0xA001;
    }
  }
  return (~crc) & 0xFFFF;
}

List<int> _usbTokenBytes(int addr, int endp) {
  final field = (addr & 0x7F) | ((endp & 0xF) << 7);
  final v = field | (_usbCrc5(field, 11) << 11);
  return [v & 0xFF, (v >> 8) & 0xFF];
}

int _usbPidByte(int nibble) => (nibble & 0xF) | ((~nibble & 0xF) << 4);

List<List<int>> _usbEncode(List<int> bytes) {
  final raw = <int>[];
  for (final b in [0x80, ...bytes]) {
    for (var i = 0; i < 8; i++) {
      raw.add((b >> i) & 1);
    }
  }
  final stuffed = <int>[];
  var ones = 0;
  for (final bit in raw) {
    stuffed.add(bit);
    if (bit == 1) {
      ones++;
      if (ones == 6) {
        stuffed.add(0);
        ones = 0;
      }
    } else {
      ones = 0;
    }
  }
  final out = <List<int>>[];
  var line = 1;
  for (final bit in stuffed) {
    if (bit == 0) line = 1 - line;
    out.add(line == 1 ? [1, 0] : [0, 1]);
  }
  out.add([0, 0]);
  out.add([0, 0]);
  out.add([1, 0]);
  return out;
}

/// Drives SETUP/DATA/handshake packets onto a shared inOut pad pair, and
/// decodes the device's own replies through a real HarborUsbFsRx fed
/// from its core's oe/dp_out/dm_out, retrying the IN (or redoing a
/// write) on NAK or no reply, like a real host.
///
/// TX never releases the pads to Z: a sustained undriven gap has
/// nothing pulling it to idle-J the way a real bus's pull-up would, and
/// HarborUsbFsResetDet samples the raw pads every cycle regardless of
/// who is transmitting, so an extended Z window reads as neither J nor
/// a real SE0 and corrupts internal device state with X (confirmed by
/// removing the release). Driving idle-J by default instead briefly
/// contends with the device's own replies while this host's own TX
/// line sits idle, but RX reads the device's dp_out/dm_out straight
/// from its core, before the pad, so that contention never reaches the
/// decode.
///
/// devOe/devDp/devDm belong to the DUT's own private core submodule, so
/// a real wire (`<=`) from them into _rx's inputs would cross outside
/// that submodule's own hierarchy, which ROHD's module rules forbid.
/// _sample copies their value into _rx's plain inputs with `.inject()`
/// every cycle instead: a testbench-side mirror, not a hardware wire.
class _UsbHost {
  final Logic clk;
  final Logic reset;
  final Logic devOe;
  final Logic devDp;
  final Logic devDm;
  final int extraGap;
  final Logic driveDp = Logic(name: 'host_drive_dp');
  final Logic driveDm = Logic(name: 'host_drive_dm');
  final Logic _rxDp = Logic(name: 'host_rx_dp');
  final Logic _rxDn = Logic(name: 'host_rx_dn');

  late final HarborUsbFsRx _rx;
  final _rxBytes = <int>[];
  int _pktFirst = 0;

  // The last fully decoded packet, captured the instant it completes,
  // by whichever call happens to be ticking the clock at the time
  // (idle, drive, or an explicit wait). A real host's receiver is
  // always listening, regardless of which upper-layer routine is "in
  // control" when a reply lands. Without this, a wait-for-packet call
  // that starts only after a blind idle can miss a reply that already
  // finished during that idle, since pkt_end is a one-cycle pulse, not
  // a level.
  _UsbPacket? _pendingPacket;

  _UsbHost({
    required this.clk,
    required this.reset,
    required Logic dpPad,
    required Logic dmPad,
    required this.devOe,
    required this.devDp,
    required this.devDm,
    this.extraGap = 0,
  }) {
    dpPad <= driveDp;
    dmPad <= driveDm;
    driveDp.inject(1);
    driveDm.inject(0);
    _rxDp.inject(1);
    _rxDn.inject(0);
  }

  Future<void> build() async {
    _rx = HarborUsbFsRx(name: 'usb_test_rx');
    _rx.input('clk').srcConnection! <= clk;
    _rx.input('reset').srcConnection! <= reset;
    _rx.input('dp').srcConnection! <= _rxDp;
    _rx.input('dn').srcConnection! <= _rxDn;
    await _rx.build();
  }

  // Mirrors the device's own reply onto _rx's plain inputs: idle-J
  // whenever the device is not driving, its real dp_out/dm_out while it
  // is. This is the device's value before the shared pad, so it is
  // never corrupted by anything this host itself drives onto the pad.
  void _mirrorDeviceReply() {
    final oe = devOe.value;
    final transmitting = oe.isValid && oe.toBool();
    _rxDp.inject(transmitting ? devDp.value : LogicValue.one);
    _rxDn.inject(transmitting ? devDm.value : LogicValue.zero);
  }

  Future<void> _idle(int cycles) async {
    driveDp.inject(1);
    driveDm.inject(0);
    for (var i = 0; i < cycles; i++) {
      await clk.nextPosedge;
      await _sample();
    }
  }

  // The gap between two packets this host sends back to back, such as
  // a token and the data packet right after it: no device reply is
  // involved, so a couple of cycles is enough.
  Future<void> _interPacketGap() => _idle(2);

  // A short backoff before retrying after a NAK or no reply. extraGap
  // pads this further to prove the result does not depend on its exact
  // value: this host never needs a timed gap to catch a reply, since
  // _sample is watching on every single cycle regardless of what this
  // host itself is doing, so padding a mere backoff changes nothing.
  Future<void> _retryBackoff() => _idle(50 + extraGap);

  Future<void> _driveSymbols(List<List<int>> syms) async {
    // A packet captured but never claimed by a wait call is stale the
    // moment this host starts a new transmission: either the reply to
    // something earlier that nobody asked for, or a late straggler
    // that arrived after a previous wait's own timeout. Carrying it
    // forward would let it leak into a later, unrelated wait call.
    _pendingPacket = null;
    for (final s in syms) {
      for (var t = 0; t < 4; t++) {
        driveDp.inject(s[0]);
        driveDm.inject(s[1]);
        await clk.nextPosedge;
        await _sample();
      }
    }
    driveDp.inject(1);
    driveDm.inject(0);
  }

  Future<void> sendToken(int pid, int addr, int endp) =>
      _driveSymbols(_usbEncode([_usbPidByte(pid), ..._usbTokenBytes(addr, endp)]));

  Future<void> sendData(int pid, List<int> bytes) {
    final crc = _usbCrc16(bytes);
    return _driveSymbols(
      _usbEncode([_usbPidByte(pid), ...bytes, crc & 0xFF, (crc >> 8) & 0xFF]),
    );
  }

  Future<void> sendHandshake(int pid) =>
      _driveSymbols(_usbEncode([_usbPidByte(pid)]));

  // A full-speed data packet runs 4 line cycles per bit. A 64-byte
  // payload, the largest full-speed packet, plus its PID and CRC16,
  // takes about 2200 cycles to arrive; the default leaves headroom
  // above that so a full-size packet is never mistaken for a timeout.
  //
  // Checks for a packet that already completed (captured by _sample
  // during a preceding idle or _driveSymbols call) before falling back
  // to watching the line for a new one, so a reply is never missed
  // just because something else was ticking the clock when it arrived.
  Future<_UsbPacket?> _waitPacket({int maxCycles = 3000}) =>
      _awaitPendingPacket(maxCycles);

  Future<_UsbPacket?> _awaitPendingPacket(int maxCycles) async {
    if (_pendingPacket != null) {
      final p = _pendingPacket;
      _pendingPacket = null;
      return p;
    }
    for (var i = 0; i < maxCycles; i++) {
      await clk.nextPosedge;
      await _sample();
      if (_pendingPacket != null) {
        final p = _pendingPacket;
        _pendingPacket = null;
        return p;
      }
    }
    return null;
  }

  // USB 2.0 7.1.19.1: a host waits at least 18 bit times for a
  // response to start before giving up. A real host watches the line
  // from the moment its own packet ends, not after an arbitrary blind
  // wait, so this starts looking immediately rather than after a fixed
  // delay. The budget stays well above that spec minimum: a SETUP can
  // land on a control endpoint that is still finishing an aborted data
  // stage or a run of NAKed retries, so the ACK can be later than the
  // bare wire turnaround, just nowhere near the much larger budget a
  // full data packet needs.
  static const _handshakeTimeoutCycles = 500; // 125 bit times.

  Future<bool> _waitForSetupAck() async {
    final pkt = await _awaitPendingPacket(_handshakeTimeoutCycles);
    return pkt?.pid == 2;
  }

  // The IN status stage: send the IN token, wait for the device's
  // zero-length DATA1, then ACK it. Retries the IN on NAK or no reply.
  Future<bool> _waitStatusIn(int addr) async {
    var retries = 0;
    while (retries < 200) {
      await sendToken(9, addr, 0); // IN (status stage)

      final resp = await _waitPacket();
      if (resp == null || resp.pid == 10) {
        retries++;
        await _retryBackoff();
        continue;
      }
      if (resp.pid != 11) return false; // STALL, or not the expected ZLP

      await _interPacketGap();
      await sendHandshake(2); // ACK
      return true;
    }
    return false;
  }

  // The OUT status stage: send the OUT token and a zero-length DATA1,
  // then wait for the handshake. ACK means success, NAK resends the OUT
  // and the ZLP, STALL or a timeout fails outright.
  Future<bool> _waitStatusOut(int addr) async {
    var retries = 0;
    while (retries < 200) {
      await sendToken(1, addr, 0); // OUT (status stage)
      await _interPacketGap();
      await sendData(11, []); // zero-length DATA1

      final resp = await _waitPacket();
      if (resp == null) return false;
      if (resp.pid == 2) return true; // ACK
      if (resp.pid == 10) {
        retries++;
        await _retryBackoff();
        continue;
      }
      return false; // STALL
    }
    return false;
  }

  /// A no-data-stage control transfer: SETUP, then the IN status stage.
  Future<bool> controlNoData(int addr, List<int> setup) async {
    await sendToken(13, addr, 0); // SETUP
    await _interPacketGap();
    await sendData(3, setup); // DATA0
    if (!await _waitForSetupAck()) return false;
    return _waitStatusIn(addr);
  }

  /// An OUT control transfer, split into [maxPacket]-byte data packets,
  /// then the IN status stage. Retries a data packet on NAK or no reply.
  Future<bool> controlWrite(
    int addr,
    List<int> setup,
    List<int> data, {
    int maxPacket = 64,
  }) async {
    await sendToken(13, addr, 0); // SETUP
    await _interPacketGap();
    await sendData(3, setup); // DATA0
    if (!await _waitForSetupAck()) return false;

    var offset = 0;
    var dataToggle = 1;
    while (offset < data.length) {
      final end = offset +
          (data.length - offset > maxPacket ? maxPacket : data.length - offset);
      final chunk = data.sublist(offset, end);
      final pid = dataToggle == 1 ? 11 : 3;

      var acked = false;
      var retries = 0;
      while (retries < 200) {
        await sendToken(1, addr, 0); // OUT
        await _interPacketGap();
        await sendData(pid, chunk);

        final resp = await _waitPacket();
        if (resp != null && resp.pid == 2) {
          acked = true;
          break;
        }
        if (resp != null && resp.pid == 14) return false; // STALL

        retries++;
        await _retryBackoff();
      }
      if (!acked) return false;

      offset = end;
      dataToggle = 1 - dataToggle;
    }

    return _waitStatusIn(addr);
  }

  /// A control read: SETUP, the IN data stage (ACKed here, retried on
  /// NAK or no reply), then the OUT status stage.
  Future<List<int>?> controlRead(int addr, List<int> setup) async {
    await sendToken(13, addr, 0); // SETUP
    await _interPacketGap();
    await sendData(3, setup); // DATA0
    if (!await _waitForSetupAck()) return null;

    final wLength = setup.length >= 8 ? setup[6] | (setup[7] << 8) : 0;
    final result = <int>[];
    var dataToggle = 1;
    var retries = 0;
    const maxRetries = 200;

    while (retries < maxRetries) {
      await sendToken(9, addr, 0); // IN (data stage)

      final pkt = await _waitPacket();
      if (pkt == null || pkt.pid == 10) {
        retries++;
        await _retryBackoff();
        continue;
      }
      if (pkt.pid == 14) return null; // STALL

      final expectedPid = dataToggle == 1 ? 11 : 3;
      if (pkt.pid != expectedPid) return null; // wrong data toggle

      result.addAll(pkt.payload);

      await _interPacketGap();
      await sendHandshake(2); // ACK

      if (pkt.payload.length < 64 || result.length >= wLength) break;
      dataToggle = 1 - dataToggle;
      retries = 0;
    }

    if (!await _waitStatusOut(addr)) return null;
    return result;
  }

  Future<void> _sample() async {
    _mirrorDeviceReply();
    final start = _rx.output('pkt_start').value;
    if (start.isValid && start.toInt() == 1) _pktFirst = _rxBytes.length;
    final put = _rx.output('rx_data_put').value;
    if (put.isValid && put.toInt() == 1) {
      final d = _rx.output('rx_data').value;
      if (d.isValid) _rxBytes.add(d.toInt());
    }
    final end = _rx.output('pkt_end').value;
    if (end.isValid && end.toInt() == 1) {
      final p = _rx.output('pid').value;
      if (p.isValid) {
        final pktPid = p.toInt();
        var payload = _rxBytes.sublist(_pktFirst);
        _rxBytes.clear();
        _pktFirst = 0;
        // DATA0/DATA1 carry a trailing CRC16 the caller never needs.
        if ((pktPid == 3 || pktPid == 11) && payload.length >= 2) {
          payload = payload.sublist(0, payload.length - 2);
        }
        _pendingPacket = _UsbPacket(pid: pktPid, payload: payload);
      }
    }
  }
}

class _UsbPacket {
  final int pid;
  final List<int> payload;

  _UsbPacket({required this.pid, required this.payload});
}

List<int> _stdSetup(
  int bmRequestType,
  int bRequest,
  int wValue, {
  int wIndex = 0,
  int wLength = 0,
}) => [
  bmRequestType,
  bRequest,
  wValue & 0xFF,
  (wValue >> 8) & 0xFF,
  wIndex & 0xFF,
  (wIndex >> 8) & 0xFF,
  wLength & 0xFF,
  (wLength >> 8) & 0xFF,
];

/// Thin wrappers keeping the scenario's call sites short: a failed
/// stage throws, since that means the test itself is broken rather than
/// a condition the test should assert on separately.
Future<void> _controlNoData(_UsbHost host, int addr, List<int> setup) async {
  if (!await host.controlNoData(addr, setup)) {
    throw StateError('control transfer (no data stage) failed for addr=$addr');
  }
}

Future<void> _controlWriteOneBlock(
  _UsbHost host,
  int addr,
  List<int> setup,
  List<int> data,
) async {
  if (!await host.controlWrite(addr, setup, data)) {
    throw StateError('control write failed for addr=$addr');
  }
}

Future<void> _getStatus(_UsbHost host, int addr) async {
  final result = await host.controlRead(
    addr,
    _stdSetup(0xA1, 3, 0, wLength: 6),
  );
  if (result == null) {
    throw StateError('GETSTATUS failed for addr=$addr');
  }
}

/// Polls a Wishbone register until [cond] is true, or fails the test.
Future<int> _pollUntil(
  WbDriver wb,
  Logic clk,
  int address,
  bool Function(int) cond, {
  int maxTries = 100,
}) async {
  for (var i = 0; i < maxTries; i++) {
    final v = await wb.read(address);
    if (cond(v)) return v;
    for (var j = 0; j < 20; j++) {
      await clk.nextPosedge;
    }
  }
  throw StateError(
    'poll timed out waiting on 0x${address.toRadixString(16)}',
  );
}
