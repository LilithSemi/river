import 'dart:async';

import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

// Shared fixtures for the RiverDfuSwSink tests. Mirrors the shape of
// Harbor's own usb_dfu_sink_harness.dart, but drives the sink's `dfu`
// interface directly instead of through a real USB transaction: the tests
// here are about the sink's internal handshake, not USB protocol framing.

/// Drives [RiverDfuSwSink]'s own `dfu` interface directly, standing in for
/// [HarborUsbDfu], so a test can inject data/valid/end/clear and observe
/// ready/busy/done/clearDone without a real USB transaction.
class DfuProviderStub extends BridgeModule {
  DfuProviderStub({String? name})
    : super('DfuProviderStub', name: name ?? 'dfu_stub') {
    createPort('data_in', PortDirection.input, width: 8);
    createPort('valid_in', PortDirection.input);
    createPort('end_in', PortDirection.input);
    createPort('clear_in', PortDirection.input);

    addOutput('ready_out');
    addOutput('busy_out');
    addOutput('error_out', width: 4);
    addOutput('done_out');
    addOutput('clear_done_out');

    final dfuRef = addInterface(
      UsbDfuSinkInterface(),
      name: 'dfu',
      role: PairRole.provider,
    );
    final dfu = dfuRef.internalInterface!;

    dfu.data <= input('data_in');
    dfu.valid <= input('valid_in');
    dfu.block <= Const(0, width: 16);
    dfu.target <= Const(0, width: 8);
    dfu.blockDone <= Const(0);
    dfu.end <= input('end_in');
    dfu.clear <= input('clear_in');

    output('ready_out') <= dfu.ready;
    output('busy_out') <= dfu.busy;
    output('error_out') <= dfu.error;
    output('done_out') <= dfu.done;
    output('clear_done_out') <= dfu.clearDone;
  }
}

/// Wraps [DfuProviderStub] and a real [RiverDfuSwSink] on two independent
/// clocks, exposing the sink's byte/end/clear handshake and register-file
/// taps as plain top-level ports.
class SwSinkHarness extends BridgeModule {
  SwSinkHarness({String? name})
    : super('SwSinkHarness', name: name ?? 'sw_sink_h') {
    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);
    createPort('bus_clk', PortDirection.input);
    createPort('bus_reset', PortDirection.input);
    createPort('advance', PortDirection.input);
    createPort('clear_ack', PortDirection.input);
    createPort('data_in', PortDirection.input, width: 8);
    createPort('valid_in', PortDirection.input);
    createPort('end_in', PortDirection.input);
    createPort('clear_in', PortDirection.input);

    addOutput('ready_out');
    addOutput('busy_out');
    addOutput('error_out', width: 4);
    addOutput('done_out');
    addOutput('clear_done_out');
    addOutput('rx_data', width: 8);
    addOutput('rx_valid');
    addOutput('dnload_done');
    addOutput('bytes_count', width: 32);
    addOutput('cleared');

    final stub = DfuProviderStub(name: 'stub');
    addSubModule(stub);
    stub.input('data_in').srcConnection! <= input('data_in');
    stub.input('valid_in').srcConnection! <= input('valid_in');
    stub.input('end_in').srcConnection! <= input('end_in');
    stub.input('clear_in').srcConnection! <= input('clear_in');

    final sink = RiverDfuSwSink(name: 'sink');
    addSubModule(sink);
    sink.input('usb_clk').srcConnection! <= input('usb_clk');
    sink.input('usb_reset').srcConnection! <= input('usb_reset');
    sink.input('bus_clk').srcConnection! <= input('bus_clk');
    sink.input('bus_reset').srcConnection! <= input('bus_reset');
    sink.input('advance').srcConnection! <= input('advance');
    sink.input('clear_ack').srcConnection! <= input('clear_ack');
    connectInterfaces(stub.interface('dfu'), sink.interface('dfu'));

    output('ready_out') <= stub.output('ready_out');
    output('busy_out') <= stub.output('busy_out');
    output('error_out') <= stub.output('error_out');
    output('done_out') <= stub.output('done_out');
    output('clear_done_out') <= stub.output('clear_done_out');
    output('rx_data') <= sink.output('rx_data');
    output('rx_valid') <= sink.output('rx_valid');
    output('dnload_done') <= sink.output('dnload_done');
    output('bytes_count') <= sink.output('bytes_count');
    output('cleared') <= sink.output('cleared');
  }
}

/// The DUT plus the raw clock/reset/control signals a test pokes directly.
class SwSinkFixture {
  final SwSinkHarness dut;
  final Logic usbClk;
  final Logic busClk;
  final Logic usbReset;
  final Logic busReset;
  final Logic dataIn;
  final Logic validIn;
  final Logic endIn;
  final Logic clearIn;
  final Logic advance;
  final Logic clearAck;

  SwSinkFixture({
    required this.dut,
    required this.usbClk,
    required this.busClk,
    required this.usbReset,
    required this.busReset,
    required this.dataIn,
    required this.validIn,
    required this.endIn,
    required this.clearIn,
    required this.advance,
    required this.clearAck,
  });
}

/// Builds a [SwSinkHarness] on two independent, coprime-period clocks
/// (an odd clock ratio by default: 9 USB-domain units per 23 bus-domain
/// units), releases reset, and returns the fixture.
Future<SwSinkFixture> buildSwSinkFixture({
  int usbClkPeriod = 9,
  int busClkPeriod = 23,
  int maxSimTime = 4000000,
}) async {
  final dut = SwSinkHarness();

  final usbClk = SimpleClockGenerator(usbClkPeriod).clk;
  final busClk = SimpleClockGenerator(busClkPeriod).clk;
  final usbReset = Logic(name: 'usb_reset');
  final busReset = Logic(name: 'bus_reset');
  final dataIn = Logic(name: 'data_in', width: 8);
  final validIn = Logic(name: 'valid_in');
  final endIn = Logic(name: 'end_in');
  final clearIn = Logic(name: 'clear_in');
  final advance = Logic(name: 'advance');
  final clearAck = Logic(name: 'clear_ack');

  dut.input('usb_clk').srcConnection! <= usbClk;
  dut.input('usb_reset').srcConnection! <= usbReset;
  dut.input('bus_clk').srcConnection! <= busClk;
  dut.input('bus_reset').srcConnection! <= busReset;
  dut.input('data_in').srcConnection! <= dataIn;
  dut.input('valid_in').srcConnection! <= validIn;
  dut.input('end_in').srcConnection! <= endIn;
  dut.input('clear_in').srcConnection! <= clearIn;
  dut.input('advance').srcConnection! <= advance;
  dut.input('clear_ack').srcConnection! <= clearAck;

  await dut.build();

  usbReset.inject(1);
  busReset.inject(1);
  dataIn.inject(0);
  validIn.inject(0);
  endIn.inject(0);
  clearIn.inject(0);
  advance.inject(0);
  clearAck.inject(0);

  Simulator.setMaxSimTime(maxSimTime);
  unawaited(Simulator.run());

  await usbClk.nextPosedge;
  await busClk.nextPosedge;
  await busClk.nextPosedge;
  usbReset.inject(0);
  busReset.inject(0);
  // Let the reset-boundary recovery window (RiverDfuSwSink's busRecovering/
  // usbRecovering) finish settling on both clocks before handing the
  // fixture to a test, so the recovery forcing from this power-on reset
  // never bleeds into the test's own first byte/advance.
  for (var i = 0; i < 20; i++) {
    await usbClk.nextPosedge;
  }
  for (var i = 0; i < 20; i++) {
    await busClk.nextPosedge;
  }

  return SwSinkFixture(
    dut: dut,
    usbClk: usbClk,
    busClk: busClk,
    usbReset: usbReset,
    busReset: busReset,
    dataIn: dataIn,
    validIn: validIn,
    endIn: endIn,
    clearIn: clearIn,
    advance: advance,
    clearAck: clearAck,
  );
}

/// Waits (polling on the USB clock) until `ready_out` reports high, then
/// pulses [dataIn]/[validIn] with [data] for one cycle. Mirrors how
/// [HarborUsbDfu] only ever asserts `valid` once `ready` is already high.
///
/// Always advances at least one edge before checking, even when ready is
/// already high: injecting signals in the same simulation delta a prior
/// wait-loop returned in (without an intervening clock edge) can read back
/// as X on the very next edge, a timing hazard in how this simulator
/// interleaves injected values with awaited edges, not a DUT bug.
Future<void> pushByteWhenReady(
  SwSinkFixture f,
  int data, {
  int maxCycles = 500,
}) async {
  for (var i = 0; i < maxCycles; i++) {
    await f.usbClk.nextPosedge;
    if (f.dut.output('ready_out').value.toBool()) break;
  }
  f.dataIn.inject(data);
  f.validIn.inject(1);
  await f.usbClk.nextPosedge;
  f.validIn.inject(0);
  f.dataIn.inject(0);
}

/// Pulses the zero-length DNLOAD's end marker for one cycle, regardless of
/// `ready` (the real device never gates `end` on it either).
Future<void> pulseEnd(SwSinkFixture f) async {
  f.endIn.inject(1);
  await f.usbClk.nextPosedge;
  f.endIn.inject(0);
}

/// Pulses `clear` for one cycle.
Future<void> pulseClear(SwSinkFixture f) async {
  f.clearIn.inject(1);
  await f.usbClk.nextPosedge;
  f.clearIn.inject(0);
}

/// Pulses the bus-domain `advance` input for one cycle.
Future<void> pulseAdvance(SwSinkFixture f) async {
  f.advance.inject(1);
  await f.busClk.nextPosedge;
  f.advance.inject(0);
}

/// Pulses the bus-domain `clear_ack` input for one cycle.
Future<void> pulseClearAck(SwSinkFixture f) async {
  f.clearAck.inject(1);
  await f.busClk.nextPosedge;
  f.clearAck.inject(0);
}

/// Polls (on the bus clock) until `rx_valid` is high, or fails the test
/// after [maxCycles]. Always advances at least one edge first; see
/// [pushByteWhenReady] for why.
Future<void> waitRxValid(SwSinkFixture f, {int maxCycles = 500}) async {
  for (var i = 0; i < maxCycles; i++) {
    await f.busClk.nextPosedge;
    if (f.dut.output('rx_valid').value.toBool()) return;
  }
  throw StateError('rx_valid never asserted');
}

/// Polls (on the USB clock) until `ready_out` is high, or fails the test
/// after [maxCycles]. Always advances at least one edge first; see
/// [pushByteWhenReady] for why.
Future<void> waitReady(SwSinkFixture f, {int maxCycles = 500}) async {
  for (var i = 0; i < maxCycles; i++) {
    await f.usbClk.nextPosedge;
    if (f.dut.output('ready_out').value.toBool()) return;
  }
  throw StateError('ready_out never returned high');
}
