import 'dart:async';
import 'package:river/river.dart';

import '../dev.dart';
import '../soc.dart';

/// DRAM model for the new Harbor DDR3 stack's two calibration modes. A
/// `train=hw` build has no control window: the controller calibrates itself
/// in hardware, so every array access is correct from reset. A `train=runtime`
/// build keeps a knob register window just above the array (offsets
/// `>= [arraySize]`), mirroring [Ddr3Controller._buildWb2Knobs]
/// (stride 8 bytes):
///   0x00 WLEVEL  (rw, per-lane) write-leveling bit, no effect on correctness
///   0x08 ODELAY  (rw, per-lane) write tap 0..31, no effect on correctness
///   0x10 IDELAY  (rw, per-lane) read tap 0..31, gates read correctness
///   0x18 BITSLIP (rw, per-lane) bitslip bit, no effect on correctness
///   0x20 CTL     (wo) bit0 SET (latch lane from bits[11:8]), bit1 APPLY
///   0x28 STATUS  (ro) always 0 (APPLY commits instantly, cal_failed is a
///                non-concern in train=runtime, which skips the BIST)
///   0x30 CAP     (ro) bit0 active, bits[7:4] lanes, bits[15:8] tapMax
/// Byte lane `b`'s reads are correct only once that lane's IDELAY sits inside
/// its own eye (`[eyeLo[b % lanes], eyeHi[b % lanes]]`). Writes always land,
/// since read training never touches the write path.
class Dram extends Device {
  /// Size of the wb2 control-register window above the array.
  static const int trainCtrlSize = 0x1000;

  // Register indices within the control window (8-byte stride, matching the
  // HDL's wb2 knob-ABI layout).
  static const int _regWlevel = 0;
  static const int _regOdelay = 1;
  static const int _regIdelay = 2;
  static const int _regBitslip = 3;
  static const int _regCtl = 4;
  static const int _regStatus = 5;
  static const int _regCap = 6;

  static const int _ctlSet = 0x1;
  static const int _ctlApply = 0x2;
  static const int _tapMax = 31;

  final bool trainable;
  final int arraySize;
  final int lanes;
  final List<int> eyeLo;
  final List<int> eyeHi;

  List<int> data;

  // Per-lane committed knob state.
  final List<int> idelay;
  final List<int> odelay;
  final List<int> bitslip;
  final List<int> wlevel;

  // Shadow (staged) knob values + dirty flags, committed to the lane
  // selected by CTL SET when CTL APPLY pulses, matching the HDL protocol.
  int _shWlevel = 0, _shOdelay = 0, _shIdelay = 0, _shBitslip = 0;
  bool _dWlevel = false, _dOdelay = false, _dIdelay = false, _dBitslip = false;
  int _laneSel = 0;
  bool _active = false;

  Dram(
    super.config, {
    this.trainable = false,
    this.lanes = 2,
    List<int>? eyeLo,
    List<int>? eyeHi,
  }) : arraySize = trainable
           ? config.range!.size - trainCtrlSize
           : config.range!.size,
       data = List.filled(
         trainable ? config.range!.size - trainCtrlSize : config.range!.size,
         0,
       ),
       eyeLo = eyeLo ?? List.filled(lanes, 8),
       eyeHi = eyeHi ?? List.filled(lanes, 20),
       idelay = List.filled(lanes, 0),
       odelay = List.filled(lanes, 0),
       bitslip = List.filled(lanes, 0),
       wlevel = List.filled(lanes, 0);

  /// True once every lane's read tap sits inside its own eye, so the whole
  /// array reads back correctly. Untrainable (`train=hw`) DRAM is always
  /// trained: hardware calibrated it before the first bus access.
  bool get trained {
    if (!trainable) return true;
    for (var l = 0; l < lanes; l++) {
      if (idelay[l] < eyeLo[l] || idelay[l] > eyeHi[l]) return false;
    }
    return true;
  }

  /// True when byte lane [addr]'s own read tap sits inside its eye.
  bool _laneTrained(int addr) {
    final l = addr % lanes;
    return idelay[l] >= eyeLo[l] && idelay[l] <= eyeHi[l];
  }

  @override
  void reset() {
    data.fillRange(0, data.length, 0);
    idelay.fillRange(0, lanes, 0);
    odelay.fillRange(0, lanes, 0);
    bitslip.fillRange(0, lanes, 0);
    wlevel.fillRange(0, lanes, 0);
    _shWlevel = _shOdelay = _shIdelay = _shBitslip = 0;
    _dWlevel = _dOdelay = _dIdelay = _dBitslip = false;
    _laneSel = 0;
    _active = false;
  }

  @override
  DeviceAccessor? get memAccessor => DramAccessor(this);

  static Device create(
    RiverDevice config,
    Map<String, String> options,
    RiverSoC soc,
  ) {
    return Dram(config, trainable: options['train'] == 'runtime');
  }
}

class DramAccessor extends DeviceAccessor {
  final Dram dram;

  DramAccessor(this.dram);

  bool _isCtrl(int addr) => dram.trainable && addr >= dram.arraySize;

  int _widthMask(int width) =>
      width >= 8 ? -1 : (1 << (8 * width)) - 1; // -1 == all 64 bits set

  @override
  Future<int> read(int addr, int width) async {
    if (_isCtrl(addr)) {
      final reg = (addr - dram.arraySize) >> 3;
      switch (reg) {
        case Dram._regWlevel:
          return dram.wlevel[dram._laneSel];
        case Dram._regOdelay:
          return dram.odelay[dram._laneSel];
        case Dram._regIdelay:
          return dram.idelay[dram._laneSel];
        case Dram._regBitslip:
          return dram.bitslip[dram._laneSel];
        case Dram._regStatus:
          return 0;
        case Dram._regCap:
          return (dram._active ? 1 : 0) |
              (dram.lanes << 4) |
              (Dram._tapMax << 8);
        default:
          return 0;
      }
    }

    if (addr + width > dram.data.length) return 0;
    var value = 0;
    for (var i = 0; i < width; i++) {
      value |= (dram.data[addr + i] & 0xFF) << (8 * i);
    }
    if (dram.trainable) {
      // Corrupt whichever byte lanes are not yet trained, so a per-lane sweep
      // can tell a bad tap from a good one, one byte at a time.
      for (var i = 0; i < width; i++) {
        if (!dram._laneTrained(addr + i)) value ^= 0xFF << (8 * i);
      }
    }
    return value & _widthMask(width);
  }

  @override
  Future<void> write(int addr, int value, int width) async {
    if (_isCtrl(addr)) {
      final reg = (addr - dram.arraySize) >> 3;
      switch (reg) {
        case Dram._regWlevel:
          dram._shWlevel = value & 0x1;
          dram._dWlevel = true;
          break;
        case Dram._regOdelay:
          dram._shOdelay = value & 0x1F;
          dram._dOdelay = true;
          break;
        case Dram._regIdelay:
          dram._shIdelay = value & 0x1F;
          dram._dIdelay = true;
          break;
        case Dram._regBitslip:
          dram._shBitslip = value & 0x1;
          dram._dBitslip = true;
          break;
        case Dram._regCtl:
          if (value & Dram._ctlSet != 0) dram._laneSel = (value >> 8) & 0xF;
          if (value & Dram._ctlApply != 0) {
            dram._active = true;
            final l = dram._laneSel;
            if (dram._dWlevel) dram.wlevel[l] = dram._shWlevel;
            if (dram._dOdelay) dram.odelay[l] = dram._shOdelay;
            if (dram._dIdelay) dram.idelay[l] = dram._shIdelay;
            if (dram._dBitslip) dram.bitslip[l] = dram._shBitslip;
            dram._dWlevel = false;
            dram._dOdelay = false;
            dram._dIdelay = false;
            dram._dBitslip = false;
          }
          break;
        // STATUS and CAP are read-only.
      }
      return;
    }

    // Writes always land: read training never touches the write path.
    if (addr + width > dram.data.length) return;
    for (var i = 0; i < width; i++) {
      dram.data[addr + i] = (value >> (8 * i)) & 0xFF;
    }
  }
}
