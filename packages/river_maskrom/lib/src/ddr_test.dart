import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// A DDR bring-up payload for the serial monitor: writes a known pattern
/// across the DRAM window, reads it back, and reports over the UART.
///
/// Coverage is deliberate, not bulk: the four words of one BL8 line (every
/// beat-select), a neighboring line, and strides that cross the column,
/// row, and bank fields of the address mapping. A final byte store into a
/// written word proves the SEL-to-DM masking path end to end (MMU lane
/// shift, controller wrMask, PHY DM timing, part-side merge).
///
/// Prints `DDR OK` when every readback matches, or `DDR ER` and spins on
/// the first mismatch. Position-independent code, like the other maskrom
/// programs; only the UART and DRAM bases are absolute.
class RiverDdrTest extends Module {
  @override
  final RiscVIsaConfig isa;

  RiverDdrTest({
    required this.isa,
    required int uartBase,
    required int dramBase,
    int clockHz = 48000000,
    int baud = 115200,
    // When true, re-run the readback+verdict forever (with a delay between
    // prints) instead of printing once and spinning. On real hardware the
    // FPGA reconfiguration glitches the first UART bytes, so a one-shot print
    // is unreadable; a looping print streams clean copies once the line
    // settles. The DRAM writes still happen once up front, so the loop also
    // exercises data retention.
    bool loopForever = false,
    // Diagnostic: test ONLY the first word (write 0x0, read it back, no
    // neighbor writes, no byte-merge). Isolates a broken read path (this fails)
    // from BL8-line DM-mask clobber by neighbor writes (this passes, the full
    // test fails).
    bool singleWord = false,
  }) {
    // Word-write/readback targets: one full BL8 line (4 words), the next
    // line, then column/row/bank field crossings.
    final fullOffsets = [
      // One BL8 line (every beat-select) + column/row/bank crossings.
      0x0, 0x4, 0x8, 0xC, 0x10, 0x800, 0x100000,
      // Dense coverage of main Weir's .bss-clear span (0x9830..0x843a40,
      // ~8.6MB): a contiguous memset main does before setting mtvec, so a
      // single bad address here faults the boot with no output (the
      // observed boot loop). Unique pattern per offset (write-all then
      // read-all) also catches a high-address alias clobbering a low one.
      0x200000, 0x400000, 0x600000, 0x800000, 0x840000, 0x843a3c,
      // High bank/rank crossing well past the .bss span.
      0x4000000,
    ];
    final offsets = singleWord ? [0x0] : fullOffsets;
    // Bit 31 MUST be clear: on RV64 `lw` sign-extends the loaded word while the
    // `li` that builds the expected value zero-extends it, so a bit-31-set
    // pattern (e.g. 0xC0DE...) read back as 0xFFFFFFFF_C0DE... never matches the
    // 0x00000000_C0DE... it was compared against - a false "DDR ER" even on
    // perfect memory. Keep every pattern <= 0x7FFFFFFF.
    int patternFor(int i) => 0x40DE0000 + i * 0x1111;

    // ns16550a setup, same dance as the other programs (the divisor gates
    // the transmitter, so this is mandatory).
    final divisor = (clockHz ~/ baud).clamp(1, 0xffff);
    register(Register.x13).bind(li(uartBase));
    register(Register.x11).bind(li(0x83)); // LCR: DLAB=1, 8N1
    sb(register(Register.x13), register(Register.x11), offset: 3);
    register(Register.x11).bind(li(divisor & 0xff)); // DLL
    sb(register(Register.x13), register(Register.x11), offset: 0);
    register(Register.x11).bind(li((divisor >> 8) & 0xff)); // DLM
    sb(register(Register.x13), register(Register.x11), offset: 1);
    register(Register.x11).bind(li(0x03)); // LCR: DLAB=0, 8N1
    sb(register(Register.x13), register(Register.x11), offset: 3);

    // DRAM-INIT SETTLE: the DDR sequencer's JEDEC init runs ~700 us (sPower
    // 200us + sResetHold 500us) AFTER its reset releases; the core comes out of
    // reset at the same instant and would otherwise write/read an uninitialised
    // DRAM. Burn a generous fixed countdown (~200k core cycles, ~8 ms at 25 MHz)
    // before ANY DRAM access so init has finished. (A STATUS init_done poll is
    // the clean form, but a fixed delay cannot hang if init never completes,
    // which keeps the failure observable during bring-up.)
    register(Register.x22).bind(li(0x30000));
    final settle = label('initsettle');
    register(Register.x22).bind(addi(register(Register.x22), -1));
    blt(register(Register.x0), register(Register.x22), settle);

    // Per-check error report: on a mismatch (x14 != x11) print "DDR E<tag>=<hex>"
    // (tag = offset index, or 'm'/'b' for byte-merge) and CONTINUE, so one run
    // yields the full corruption map. x25 counts failures.
    void checkXa(String tag) {
      final ok = label('ck$tag');
      beq(register(Register.x14), register(Register.x11), ok);
      register(Register.x25).bind(addi(register(Register.x25), 1)); // err count
      register(Register.x24).bind(addi(register(Register.x14), 0)); // save read
      _print('DDR E$tag=');
      register(Register.x14).bind(addi(register(Register.x24), 0));
      _printHexX14();
      _print('\r\n');
      placeLabel(ok);
    }

    // Error counter (x25): incremented by checkXa on every mismatch; the final
    // verdict prints "DDR OK" only when it is still 0.
    register(Register.x25).bind(li(0));

    // Write the pattern.
    for (var i = 0; i < offsets.length; i++) {
      register(Register.x10).bind(li(dramBase + offsets[i]));
      register(Register.x11).bind(li(patternFor(i)));
      sw(register(Register.x10), register(Register.x11));
    }

    // Read it back; report every mismatch.
    for (var i = 0; i < offsets.length; i++) {
      register(Register.x10).bind(li(dramBase + offsets[i]));
      register(Register.x11).bind(li(patternFor(i)));
      register(Register.x14).bind(lw(register(Register.x10)));
      checkXa('$i');
    }

    // Byte-merge: replace byte 1 of word 0 (0x40DE0000 -> 0x40DE5500),
    // then check both the merged word and a sub-word readback. Skipped in
    // [singleWord] mode (it is itself a sub-word DM write).
    if (!singleWord) {
      register(Register.x10).bind(li(dramBase));
      register(Register.x11).bind(li(0x55));
      sb(register(Register.x10), register(Register.x11), offset: 1);
      // Expected merged word = word0's pattern with byte 1 replaced by 0x55.
      // Compute it from patternFor(0) so it is correct in dense mode too (dense
      // word0 = 0x01001000, not the non-dense 0x40DE0000); hardcoding the
      // non-dense value made the byte-merge check a false error under DENSE.
      register(Register.x11).bind(li((patternFor(0) & 0xFFFF00FF) | 0x5500));
      register(Register.x14).bind(lw(register(Register.x10)));
      checkXa('m');
      register(Register.x11).bind(li(0x55));
      register(Register.x14).bind(lbu(register(Register.x10), offset: 1));
      checkXa('b');
    }

    // Verdict, streamed in a loop: "DDR OK" only when x25 (mismatch count) is 0,
    // else "DDR ERRS=<count>". The per-offset "DDR E<tag>=<val>" lines above
    // already streamed the full corruption map once. Looping the verdict rides
    // out the FPGA-reconfig UART glitch.
    final vtop = label('vtop');
    final okLbl = label('vok');
    final vdone = label('vdone');
    beq(register(Register.x25), register(Register.x0), okLbl);
    _print('DDR ERRS=');
    register(Register.x14).bind(addi(register(Register.x25), 0));
    _printHexX14();
    _print('\r\n');
    jal(vdone);
    placeLabel(okLbl);
    _print('DDR OK\r\n');
    placeLabel(vdone);
    jal(vtop);
  }

  /// THRE-polled UART print, one unrolled poll loop per byte.
  void _print(String message) {
    for (var i = 0; i < message.length; i++) {
      final poll = label('p');
      final lsr = lbu(register(Register.x13), offset: 5);
      register(Register.x14).bind(andi(lsr, 0x20));
      beq(register(Register.x14), register(Register.x0), poll);
      register(Register.x11).bind(li(message.codeUnitAt(i)));
      sb(register(Register.x13), register(Register.x11));
    }
  }

  /// Prints x14 as eight uppercase hex digits, MSB first (clobbers x15..x18).
  void _printHexX14() {
    register(Register.x17).bind(li(0x3A));
    register(Register.x18).bind(li(28));
    final nibble = label('nib');
    register(
      Register.x15,
    ).bind(srl(register(Register.x14), register(Register.x18)));
    register(Register.x15).bind(andi(register(Register.x15), 0xF));
    register(Register.x15).bind(addi(register(Register.x15), 0x30));
    final noAdjust = Label('noadj');
    blt(register(Register.x15), register(Register.x17), noAdjust);
    register(Register.x15).bind(addi(register(Register.x15), 7));
    placeLabel(noAdjust);
    final poll = label('p');
    final lsr = lbu(register(Register.x13), offset: 5);
    register(Register.x16).bind(andi(lsr, 0x20));
    beq(register(Register.x16), register(Register.x0), poll);
    sb(register(Register.x13), register(Register.x15));
    register(Register.x18).bind(addi(register(Register.x18), -4));
    bge(register(Register.x18), register(Register.x0), nibble);
  }

  /// Raw machine code for a monitor load frame.
  Uint8List generateBytes() => Uint8List.fromList(generateBinary());
}
