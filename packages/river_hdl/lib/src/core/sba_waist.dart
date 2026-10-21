import 'package:rohd/rohd.dart';

/// Adapts the debug module's System Bus Access (SBA) single-outstanding req/ack
/// port to the register waist of a bus master port, so a debugger can
/// read/write SoC memory over JTAG through the same fabric the core uses.
///
/// SBA side (from [RiverDebugModule]): on [sbaReq] the DM holds [sbaWe],
/// [sbaAddr] (byte address), [sbaWdata] (right-justified) and [sbaSize] (log2
/// of access byte count: 0=byte up to 3=8 bytes) stable until [sbaAck].
/// [sbaRdata] presents read data right-justified on that ack.
///
/// Waist side: drives stb=req, we, byte address, byte-lane-shifted write data
/// and `sel` byte-enables. On the waist ack it returns read data shifted back
/// to lane 0. This mirrors the core's load/store lane convention, where a
/// sub-word access uses an aligned beat with `sel` and the addressed bytes ride
/// their own lane.
class SbaWaistAdapter extends Module {
  /// Bus data width in bits.
  final int dataWidth;

  /// Bus address width in bits.
  final int addressWidth;

  /// SBA data width in bits (the core XLEN).
  final int xlen;

  SbaWaistAdapter({
    required this.dataWidth,
    required this.addressWidth,
    required this.xlen,
    super.name = 'sba_waist',
  }) : super(definitionName: 'SbaWaistAdapter') {
    final selWidth = dataWidth ~/ 8;
    final selBits = (selWidth - 1).bitLength; // byte-offset bits within a beat

    // SBA-facing.
    final sbaReq = addInput('sba_req', Logic());
    final sbaWe = addInput('sba_we', Logic());
    final sbaAddr = addInput('sba_addr', Logic(width: xlen), width: xlen);
    final sbaWdata = addInput('sba_wdata', Logic(width: xlen), width: xlen);
    final sbaSize = addInput('sba_size', Logic(width: 3), width: 3);
    final busAck = addInput('ack', Logic());
    final busRdata = addInput(
      'rdata',
      Logic(width: dataWidth),
      width: dataWidth,
    );

    final sbaRdata = addOutput('sba_rdata', width: xlen);
    final sbaAck = addOutput('sba_ack');
    final busStb = addOutput('stb');
    final busWe = addOutput('we');
    final busAddr = addOutput('addr', width: addressWidth);
    final busWdata = addOutput('wdata', width: dataWidth);
    final busSel = addOutput('sel', width: selWidth);

    // Byte offset of the access within a bus beat, and the matching bit shift.
    final byteOff = selBits == 0
        ? Const(0, width: 1)
        : sbaAddr.getRange(0, selBits);
    final bitShift = [byteOff, Const(0, width: 3)].swizzle(); // byteOff * 8

    // Byte-enable mask: (2^bytes - 1) << byteOff, where bytes = 1 << size.
    // Build a full-width run of ones sized by `size`, then shift into the lane.
    final ones = Logic(name: 'sel_ones', width: selWidth);
    final cases = <int, int>{};
    for (var s = 0; s < 4; s++) {
      final bytes = 1 << s;
      cases[s] = bytes >= selWidth ? (1 << selWidth) - 1 : (1 << bytes) - 1;
    }
    ones <=
        cases.entries.fold<Logic>(
          Const(cases[0]!, width: selWidth),
          (acc, e) => mux(
            sbaSize.eq(Const(e.key, width: 3)),
            Const(e.value, width: selWidth),
            acc,
          ),
        );

    busStb <= sbaReq;
    busWe <= sbaWe;
    // Beat-align the bus address. The data rides its byte lane with `sel`, so
    // the address must point at the aligned beat, not the raw byte offset. The
    // core's dcache and MMU drive the bus the same way. An unaligned address
    // makes the DDR downsizer send a 4-mod-8 access to the next beat, which
    // puts SBA reads and writes of upper halves on the wrong word.
    final alignedAddr = selBits == 0
        ? sbaAddr
        : [sbaAddr.getRange(selBits, xlen), Const(0, width: selBits)].swizzle();
    busAddr <=
        (xlen >= addressWidth
            ? alignedAddr.getRange(0, addressWidth)
            : alignedAddr.zeroExtend(addressWidth));

    // Write data, sign-irrelevant zero-justified to the bus width, shifted up
    // into its addressed byte lane.
    final wdataFull = xlen >= dataWidth
        ? sbaWdata.getRange(0, dataWidth)
        : sbaWdata.zeroExtend(dataWidth);
    busWdata <= (wdataFull << bitShift).named('bus_wdata_shifted');
    busSel <= (ones << byteOff).getRange(0, selWidth);

    sbaAck <= busAck;
    // Shift read data down from its lane to lane 0 (right-justified). Logical
    // shift (`>>>`): ROHD `>>` is arithmetic and would sign-extend.
    final rdataShifted = (busRdata >>> bitShift).named('sba_rdata_shifted');
    sbaRdata <=
        (dataWidth >= xlen
            ? rdataShifted.getRange(0, xlen)
            : rdataShifted.zeroExtend(xlen));
  }
}
