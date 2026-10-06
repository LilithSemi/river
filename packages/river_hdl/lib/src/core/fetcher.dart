import 'package:rohd/rohd.dart';
import '../data_port.dart';

/// Fetches one instruction from memory, transparently handling the RISC-V "C"
/// (compressed) extension for both 32-bit and 64-bit memory interfaces.
///
/// An aligned memory word holds `dataWidth/16` instruction halfwords. The PC may
/// point at any 2-byte halfword within (or, for a 32-bit instruction, spanning)
/// that word, so the unit:
///   * selects the halfword at the PC's offset (`pc[log2(words)-1:1]`),
///   * treats it as a 16-bit instruction when `bits[1:0] != 0b11`, otherwise
///   * forms a 32-bit instruction from this halfword and the next one, issuing
///     a second aligned read when the 32-bit instruction straddles the word
///     boundary (its upper half lives in the following memory word).
///
/// This is width-general: 32-bit memory has 2 halfwords/word (straddle when the
/// PC is at the high halfword), 64-bit memory has 4 (straddle at the top one).
class FetchUnit extends Module {
  final bool hasCompressed;

  Logic get done => output('done');
  Logic get valid => output('valid');
  Logic get compressed => output('compressed');
  Logic get result => output('result');

  /// PC of the instruction currently being delivered (the latched fetch PC).
  /// In speculative mode this is the fetcher's self-sequenced PC, which the
  /// front-end uses as the instruction's PC instead of the (commit-paced) arch
  /// PC.
  Logic get pcOut => output('pc_out');

  /// Marks a delivered instruction access/page fault. The pipeline traps
  /// instead of executing; [pcOut] supplies the instruction-start EPC.
  Logic get fetchFault => output('fetch_fault');

  /// Faulting instruction portion's address, valid with [fetchFault].
  /// [pcOut] remains the instruction start for EPC.
  Logic get fetchFaultTval => output('fetch_fault_tval');

  FetchUnit(
    Logic clk,
    Logic reset,
    Logic enable,
    Logic pc,
    DataPortInterface memRead, {
    this.hasCompressed = false,
    Logic? advance,
    Logic? redirect,
    Logic? redirectPc,
    Logic? stride,
    // The fetch port's page-fault signal (asserted with done & ~valid when an
    // instruction-fetch translation faults). When wired, a faulting read is
    // delivered as done & ~valid with `fetch_fault` set instead of retried.
    Logic? fault,
    // Physical access fault, sampled with a failed completion and retained
    // through decode/execute just like the aggregate fetch_fault marker.
    Logic? accessFault,
    super.name = 'river_fetch_unit',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    enable = addInput('enable', enable);
    pc = addInput('pc', pc, width: pc.width);

    // Speculative-fetch controls (default tied off → classic lockstep fetch,
    // where the unit holds the fetched instruction until `enable` toggles).
    // `advance`: the delivered instruction was accepted downstream, so self-
    //   sequence to the next PC (pcLatch += instruction size) and fetch it.
    // `redirect`/`redirectPc`: squash the in-flight fetch and restart at the
    //   given PC (branch/exception recovery).
    advance = addInput('advance', advance ?? Const(0));
    redirect = addInput('redirect', redirect ?? Const(0));
    redirectPc = addInput(
      'redirect_pc',
      redirectPc ?? Const(0, width: pc.width),
      width: pc.width,
    );
    // Self-sequencing stride on `advance`. Defaults to the instruction size
    // (single-fetch). Dual-dispatch drives it to the bundle stride (8 when both
    // lanes accept, else 4) so the two fetchers step over each other's lanes.
    final strideIn = stride != null
        ? addInput('stride', stride, width: pc.width)
        : null;
    final accessFaultIn = addInput('access_fault', accessFault ?? Const(0));
    final faultIn =
        (fault == null ? Const(0) : addInput('fault', fault)) | accessFaultIn;

    memRead = memRead.clone()
      ..connectIO(
        this,
        memRead,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'memRead_$og',
      );

    addOutput('done');
    addOutput('valid');
    if (hasCompressed) addOutput('compressed');
    addOutput('result', width: 32);
    addOutput('pc_out', width: pc.width);
    addOutput('fetch_fault');
    addOutput('fetch_fault_tval', width: pc.width);
    final accessFaulted = Logic(name: 'accessFaulted');
    Sequential(clk, [
      If(
        reset,
        then: [accessFaulted < 0],
        orElse: [
          If(
            memRead.en & memRead.done & ~memRead.valid,
            then: [accessFaulted < accessFaultIn],
          ),
        ],
      ),
    ]);
    addOutput('fetch_access_fault') <= output('fetch_fault') & accessFaulted;

    final dataW = memRead.data.width;
    final fetchAlignBits = switch (dataW) {
      32 => 2,
      64 => 3,
      _ => throw 'Unsupported memory data width=$dataW',
    };
    final wordBytes = dataW ~/ 8; // bytes per aligned memory word (4 or 8)
    final nHalves = dataW ~/ 16; // instruction halfwords per word (2 or 4)
    final lastOff = nHalves - 1;
    // Bits of pc that index the halfword within a word: pc[offBits:1].
    final offBits = (nHalves - 1).bitLength; // 1 for 32-bit, 2 for 64-bit

    final alignment = Const(~((1 << fetchAlignBits) - 1), width: pc.width);
    final wordStep = Const(wordBytes, width: pc.width);

    final enableRead = Logic(name: 'enableRead');
    memRead.en <= enableRead;

    final readData = Logic(name: 'readData', width: dataW);
    final secondData = Logic(name: 'secondData', width: dataW);
    final complete = Logic(name: 'complete');
    final phase2 = Logic(name: 'phase2'); // second read in flight (straddle)
    // A speculative redirect can hit while a memory read is in flight. The
    // memory will still return data for the pre-redirect address; if accepted,
    // that stale instruction would be delivered paired with the post-redirect
    // pcOut (a one-instruction skew). `discardResp` marks that the next read
    // response belongs to the squashed pre-redirect fetch and must be dropped.
    final discardResp = Logic(name: 'discardResp');
    final pcLatch = Logic(name: 'pcLatch', width: pc.width);
    // Latched when a fetch read returns a page fault; delivered alongside the
    // (held) done & ~valid so the pipeline can raise an instruction page fault.
    final faulted = Logic(name: 'faulted');

    // The halfword offset of the (latched) PC within an aligned word.
    final hwOff = pcLatch.slice(offBits, 1).named('hwOff');

    // Split a memory word into its halfwords (index 0 = lowest address).
    List<Logic> halvesOf(Logic data) => [
      for (var i = 0; i < nHalves; i++) data.slice(16 * i + 15, 16 * i),
    ];

    // Select item `[off]` from a list via a mux chain (off is offBits wide).
    Logic selByOff(Logic off, List<Logic> items) {
      var r = items[0];
      for (var i = 1; i < items.length; i++) {
        r = mux(off.eq(i), items[i], r);
      }
      return r;
    }

    // Low halfword of the instruction (and whether it is a 16-bit instruction)
    // computed from a given word source at the latched offset.
    Logic loHalfOf(Logic data) => selByOff(hwOff, halvesOf(data));
    Logic isCompOf(Logic data) => loHalfOf(data).slice(1, 0).neq(0x3);

    // From the latched first word: low halfword, compressed flag, and the
    // upper halfword that lives within the same word (valid unless straddling).
    final loHalf = loHalfOf(readData).named('loHalf');
    final isComp = isCompOf(readData).named('isComp');
    // hiSameWord[off] = halves[off+1]; the top slot is unused (straddle covers).
    final halves = halvesOf(readData);
    final hiSameWord = selByOff(hwOff, [
      for (var i = 1; i < nHalves; i++) halves[i],
      halves[lastOff],
    ]).named('hiSameWord');
    final straddle = (~isComp & hwOff.eq(lastOff)).named('straddle');
    final hiHalf = mux(
      straddle,
      secondData.slice(15, 0),
      hiSameWord,
    ).named('hiHalf');
    // With C: a 16-bit instruction occupies the low half, otherwise the 32-bit
    // instruction is assembled from this halfword and the next. Without C the
    // unit is a plain 32-bit fetch, none of the compressed logic above is used.
    final instrResult =
        (hasCompressed
                ? mux(isComp, loHalf.zeroExtend(32), [hiHalf, loHalf].swizzle())
                : [hiSameWord, loHalf].swizzle())
            .named('instrResult');

    // Straddle decision at first-read latch time uses the fresh bus data, since
    // `readData` only updates on the same clock edge.
    final straddleFresh =
        (hasCompressed
                ? (~isCompOf(memRead.data) & hwOff.eq(lastOff))
                : Const(0))
            .named('straddleFresh');

    // Size of the delivered instruction, for speculative self-sequencing.
    final instrSizeBytes =
        (hasCompressed
                ? mux(
                    isComp,
                    Const(2, width: pc.width),
                    Const(4, width: pc.width),
                  )
                : Const(4, width: pc.width))
            .named('instrSizeBytes');
    final nextLatch = (pcLatch + (strideIn ?? instrSizeBytes)).named(
      'nextLatch',
    );

    Sequential(clk, [
      If(
        reset,
        then: [
          pcLatch < 0,
          enableRead < 0,
          memRead.addr < 0,
          done < 0,
          valid < 0,
          result < 0,
          pcOut < 0,
          complete < 0,
          phase2 < 0,
          discardResp < 0,
          readData < 0,
          secondData < 0,
          faulted < 0,
          fetchFaultTval < 0,
          if (hasCompressed) compressed < 0,
        ],
        orElse: [
          done < 0,
          valid < 0,
          result < 0,
          If.block([
            // Speculative redirect (highest priority): squash the in-flight
            // fetch and restart at redirectPc. A read may already be in flight
            // for the old address, flag its response for discard so it is not
            // delivered with the new pcOut.
            Iff(redirect, [
              pcLatch < redirectPc,
              complete < 0,
              phase2 < 0,
              faulted < 0,
              discardResp < 1,
              enableRead < 1,
              memRead.addr < (redirectPc & alignment),
            ]),
            // Discard the stale pre-redirect read response (one in flight), then
            // re-issue at the redirected pcLatch. Higher priority than the
            // first/second-read latch branches so the stale data is never
            // accepted. If no response was actually in flight this costs one
            // extra cycle but stays correct (the read is simply re-issued).
            Iff(discardResp & memRead.done, [
              discardResp < 0,
              complete < 0,
              phase2 < 0,
              enableRead < 1,
              memRead.addr < (pcLatch & alignment),
            ]),
            // Issue the first (aligned) read.
            Iff(enable & ~complete & ~phase2 & ~enableRead, [
              pcLatch < pc,
              enableRead < 1,
              memRead.addr < (pc & alignment),
            ]),
            // Awaiting the first read.
            Iff(enable & ~complete & ~phase2 & enableRead & ~memRead.done, [
              enableRead < 1,
              memRead.addr < (pcLatch & alignment),
            ]),
            // First read returned data.
            Iff(
              enable &
                  ~complete &
                  ~phase2 &
                  enableRead &
                  memRead.done &
                  memRead.valid,
              [
                readData < memRead.data,
                // Freeze the instruction's PC with its data (pcLatch keeps
                // advancing as the fetch moves on), so pcOut corresponds to the
                // delivered `result` and stays paired through the decoder.
                pcOut < pcLatch,
                If(
                  straddleFresh,
                  then: [
                    // Upper half is in the next word: issue a second read.
                    phase2 < 1,
                    enableRead < 1,
                    memRead.addr < ((pcLatch & alignment) + wordStep),
                  ],
                  orElse: [
                    complete < 1,
                    // Retire the request on its response edge. Waiting until
                    // delivery leaves EN high beyond the MMU completion bubble,
                    // allowing a duplicate walk to outlive a trap redirect.
                    enableRead < 0,
                    memRead.addr < (pcLatch & alignment),
                  ],
                ),
              ],
            ),
            // First read returned invalid. A page fault (faultIn) is delivered
            // as a held done & ~valid; otherwise it is a transient miss, retry.
            Iff(
              enable &
                  ~complete &
                  ~phase2 &
                  enableRead &
                  memRead.done &
                  ~memRead.valid,
              [
                If(
                  faultIn,
                  then: [
                    complete < 1,
                    faulted < 1,
                    fetchFaultTval < pcLatch,
                    pcOut < pcLatch,
                    enableRead < 0,
                    memRead.addr < (pcLatch & alignment),
                  ],
                  orElse: [
                    enableRead < 1,
                    memRead.addr < (pcLatch & alignment),
                  ],
                ),
              ],
            ),
            // Awaiting the straddle second read.
            Iff(enable & ~complete & phase2 & ~memRead.done, [
              enableRead < 1,
              memRead.addr < ((pcLatch & alignment) + wordStep),
            ]),
            // Second read returned data.
            Iff(enable & ~complete & phase2 & memRead.done & memRead.valid, [
              secondData < memRead.data,
              complete < 1,
              phase2 < 0,
              enableRead < 0,
              memRead.addr < (pcLatch & alignment),
            ]),
            // Second (straddle) read returned invalid: a page fault means the
            // instruction crosses into an unmapped page, deliver the fault.
            Iff(enable & ~complete & phase2 & memRead.done & ~memRead.valid, [
              If(
                faultIn,
                then: [
                  complete < 1,
                  faulted < 1,
                  // Only the upper halfword failed; EPC still uses pcLatch.
                  fetchFaultTval < pcLatch + Const(2, width: pc.width),
                  phase2 < 0,
                  pcOut < pcLatch,
                  enableRead < 0,
                  memRead.addr < (pcLatch & alignment),
                ],
                orElse: [
                  enableRead < 1,
                  memRead.addr < ((pcLatch & alignment) + wordStep),
                ],
              ),
            ]),
            // Accepted downstream (speculative): the instruction was delivered
            // and taken this cycle, so self-sequence to the next PC and fetch
            // it. `done` falls (default above), this instruction is consumed.
            Iff(enable & complete & advance, [
              pcLatch < nextLatch,
              complete < 0,
              phase2 < 0,
              faulted < 0,
              enableRead < 1,
              memRead.addr < (nextLatch & alignment),
            ]),
            // Deliver the instruction (held until accepted/redirected). pcOut
            // is registered alongside result so the two correspond (result is
            // registered, pcLatch is not, using pcLatch directly would run the
            // PC one instruction ahead of the decoded instruction). A fetch fault
            // is delivered as a valid instruction with `fetch_fault` set so the
            // pipeline flows normally and the exec stage overrides it with an
            // instruction page fault (the result is don't-care, it never writes
            // back). pcOut already holds the faulting PC.
            Iff(enable & complete, [
              done < 1,
              valid < 1,
              // The instruction is already captured, so do NOT re-issue the read
              // while holding it. A redundant re-read is harmless for physical
              // memory but, through the MMU, re-walks the page table every cycle
              // and starves the data port (a translated load would never run).
              enableRead < 0,
              memRead.addr < (pcLatch & alignment),
              // On a fetch fault deliver a NOP (addi x0,x0,0): the fetched bits
              // are garbage, and the microcode decoder will not validate garbage
              // (decode_valid stays low), so exec never runs and the fetch_fault
              // override never fires. A NOP decodes cleanly, exec runs, and the
              // held fetch_fault turns it into an instruction page fault.
              result < mux(faulted, Const(0x13, width: 32), instrResult),
              if (hasCompressed) compressed < mux(faulted, Const(0), isComp),
            ]),
            // Disabled: drop transient state. `faulted` is per-instruction
            // transient state too: the pipeline squashes the fetcher (~enable)
            // when it traps on a fetch fault and resteers via currentPc, so if
            // `faulted` is not dropped here it stays latched and the NEXT
            // (successfully fetched) instruction is delivered with a stale
            // fetch_fault -> a spurious instruction page fault loop.
            Iff(~enable, [
              complete < 0,
              phase2 < 0,
              pcLatch < pc,
              faulted < 0,
              if (hasCompressed) compressed < 0,
              enableRead < 0,
              memRead.addr < 0,
            ]),
          ]),
        ],
      ),
    ]);

    // The fault is signalled with the held done & ~valid delivery.
    output('fetch_fault') <= done & faulted;
  }
}
