import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:harbor/harbor.dart';

/// Direct-mapped instruction cache between the fetch unit(s) and the MMU ifetch
/// port. Hit serves one cycle after the address is presented; miss fills the
/// whole line from the MMU one word at a time. Two lookup ports serve both
/// dual-dispatch fetch lanes when their addresses land in the same line.
///
/// Virtually addressed (pre-translation), so flush on fence.i / satp write. Bare
/// mode is vaddr==paddr, no flush needed.
///
/// Storage split so it fits a 25F: wide per-line DATA in a [HarborRegisterFile]
/// maps to a block RAM (ECP5 DP16KD) instead of a flop array indexed at runtime
/// (N-way mux + N-way write decoder). Narrow VALID/TAG stay in flops: valid must
/// clear in one cycle for fence.i (a block RAM cannot), tag compare is a few LUTs.
///
/// Block-RAM read is registered ([HarborRegisterFile.readLatency] forced to 1 so
/// the sim flop model matches the DP16KD). Hit detection compares against a
/// one-cycle-delayed request address ([_addrQ]): the fetcher holds its address
/// until `done`, so last cycle's lookup answers this cycle. `done` is suppressed
/// during a fill and one cycle after commit, so no read crosses a
/// read-after-write to the same block-RAM entry.
class RiverICache extends BridgeModule {
  final int xlen;
  final int lineWords; // words per cache line
  final int numLines; // number of (direct-mapped) lines
  final bool dualPort; // second lookup port for dual-dispatch

  // Port 0 response.
  Logic get done0 => output('done0');
  Logic get valid0 => output('valid0');
  Logic get rdata0 => output('rdata0');
  // Port 1 response (dual only).
  Logic get done1 => output('done1');
  Logic get valid1 => output('valid1');
  Logic get rdata1 => output('rdata1');
  // Downstream MMU ifetch request (misses).
  Logic get memEn => output('mem_en');
  Logic get memAddr => output('mem_addr');

  RiverICache(
    Logic clk,
    Logic reset, {
    required Logic req0En,
    required Logic req0Addr,
    Logic? req1En,
    Logic? req1Addr,
    required Logic memDone,
    required Logic memValid,
    required Logic memRdata,
    required Logic flush,
    this.xlen = 64,
    this.lineWords = 4,
    this.numLines = 16,
    this.dualPort = false,
    // Physical address bits the fetch stream can present. Sizes the tag store
    // and compares instead of [xlen], so a tiny cache over a <=32-bit map does
    // not pay for a 58-bit tag (upper bits are constant 0 but yosys cannot prove
    // the stored tag is zero-extended). Null = xlen. MUST cover every fetchable
    // address.
    int? physAddrBits,
    // FPGA/ASIC target for the data block RAM. Null (sim / std-cell) uses the
    // flop backend at the same forced read latency, verifying the registered
    // read without the EBR blackbox.
    HarborDeviceTarget? target,
    String name = 'river_icache',
  }) : super('RiverICache', name: name) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    req0En = addInput('req0_en', req0En);
    req0Addr = addInput('req0_addr', req0Addr, width: xlen);
    if (dualPort) {
      req1En = addInput('req1_en', req1En!);
      req1Addr = addInput('req1_addr', req1Addr!, width: xlen);
    }
    memDone = addInput('mem_done', memDone);
    memValid = addInput('mem_valid', memValid);
    memRdata = addInput('mem_rdata', memRdata, width: xlen);
    flush = addInput('flush', flush);

    addOutput('done0');
    addOutput('valid0');
    addOutput('rdata0', width: xlen);
    if (dualPort) {
      addOutput('done1');
      addOutput('valid1');
      addOutput('rdata1', width: xlen);
    }
    addOutput('mem_en');
    addOutput('mem_addr', width: xlen);

    final wordBytes = xlen ~/ 8;
    final offBits = (lineWords - 1).bitLength; // bits to index word in line
    final idxBits = (numLines - 1).bitLength; // bits to index line
    final byteBits = (wordBytes - 1).bitLength; // bits within a word
    final tagLo = byteBits + offBits + idxBits;
    // Tag spans [paBits-1 : tagLo]. paBits <= xlen; addresses above paBits are
    // guaranteed 0 by the memory map, so ignoring them cannot alias.
    final reqPa = physAddrBits ?? xlen;
    final paBits = reqPa > xlen ? xlen : reqPa;
    final tagBits = paBits - tagLo;

    Logic idxOf(Logic addr) => idxBits == 0
        ? Const(0, width: 1)
        : addr.slice(byteBits + offBits + idxBits - 1, byteBits + offBits);
    Logic tagOf(Logic addr) => addr.slice(paBits - 1, tagLo);
    // Combined {line, word} index into the flat data RAM (the whole in-line
    // address field, aligned to a word). offBits+idxBits wide.
    Logic dataEntryOf(Logic addr) => (offBits + idxBits) == 0
        ? Const(0, width: 1)
        : addr.slice(byteBits + offBits + idxBits - 1, byteBits);

    // Per-line VALID + TAG kept in flops: valid must reset/flush in one cycle,
    // and the tag compare is cheap. Read combinationally at the (registered)
    // index.
    final lineValid = List.generate(numLines, (i) => Logic(name: 'valid_$i'));
    final lineTag = List.generate(
      numLines,
      (i) => Logic(name: 'tag_$i', width: tagBits),
    );

    // N-way read of a flop array by line index.
    Logic muxLine(List<Logic> arr, Logic idx) {
      var r = arr[0];
      for (var i = 1; i < numLines; i++) {
        r = mux(idx.eq(i), arr[i], r);
      }
      return r;
    }

    // Per-line DATA in a block RAM (one read port per lookup port, one shared
    // write port for fills). The cache expects read latency 1, which the sim
    // flop model and the ECP5 DP16KD registered read both give. The iCE40
    // block RAM reads at latency 0, so one flop after it gives the same timing.
    final nEntries = numLines * lineWords;
    final ramLatency = HarborRegisterFile.blockRamReadLatency(target) ?? 1;
    final dataRam = HarborRegisterFile(
      numEntries: nEntries,
      dataWidth: xlen,
      numReadPorts: dualPort ? 2 : 1,
      numWritePorts: 1,
      reservedZero: false,
      target: target,
      forceReadLatency: ramLatency,
      name: 'icache_data',
    );
    addSubModule(dataRam);
    dataRam.input('clk').srcConnection! <= clk;
    dataRam.input('reset').srcConnection! <= reset;
    dataRam.input('rd0_addr').srcConnection! <= dataEntryOf(req0Addr);
    if (dualPort) {
      dataRam.input('rd1_addr').srcConnection! <= dataEntryOf(req1Addr!);
    }

    // Miss/fill FSM state.
    final filling = Logic(name: 'filling');
    // High for one cycle after a fill commits: the just-written line's block-RAM
    // entry was the read-during-write target, so its registered read is only
    // trustworthy the cycle after. Gates `done` off for that settling cycle.
    final fillSettle = Logic(name: 'fillSettle');
    final fillIdx = Logic(name: 'fillIdx', width: idxBits == 0 ? 1 : idxBits);
    final fillTag = Logic(name: 'fillTag', width: tagBits);
    final fillBase = Logic(name: 'fillBase', width: xlen);
    final fillWord = Logic(
      name: 'fillWord',
      width: (offBits == 0 ? 1 : offBits) + 1,
    );

    // One-cycle-delayed copy of each port's request address: last cycle's
    // block-RAM read answers this cycle, so hit detection compares against this.
    // req==addrQ means the answer is for the wanted address; req!=addrQ
    // suppresses a stale hit and the new lookup answers next cycle.
    final addr0Q = Logic(name: 'addr0Q', width: xlen);
    final addr1Q = dualPort ? Logic(name: 'addr1Q', width: xlen) : null;

    // A fill or its one-cycle settle blocks any hit response.
    final blockHit = (filling | fillSettle).named('blockHit');

    Logic committedHit(Logic addrQ) =>
        muxLine(lineValid, idxOf(addrQ)) &
        muxLine(lineTag, idxOf(addrQ)).eq(tagOf(addrQ));

    // A port is "answered" this cycle when its held address matches the one the
    // block RAM just looked up. Hit = answered & committed & not blocked.
    Logic answered(Logic en, Logic addr, Logic addrQ) => en & addr.eq(addrQ);

    final ans0 = answered(req0En, req0Addr, addr0Q).named('ans0');
    final hit0 = (ans0 & committedHit(addr0Q) & ~blockHit).named('hit0');
    final ans1 = dualPort
        ? answered(req1En!, req1Addr!, addr1Q!).named('ans1')
        : Const(0);
    final hit1 = dualPort
        ? (ans1 & committedHit(addr1Q!) & ~blockHit).named('hit1')
        : Const(0);

    // A port misses when its lookup is answered but not a hit (and we are idle,
    // so the block-RAM read is clean). Port 0 has priority for starting a fill.
    final miss0 = (ans0 & ~committedHit(addr0Q) & ~blockHit).named('miss0');
    final miss1 = dualPort
        ? (ans1 & ~committedHit(addr1Q!) & ~blockHit).named('miss1')
        : Const(0);
    final wantFill = miss0 | miss1;
    // Fill from the registered (stable, held) address of the missing port.
    final fillAddr = mux(miss0, addr0Q, dualPort ? addr1Q! : addr0Q);

    // Line base address (aligned to the line) for the chosen fill addr.
    final lineMask = Const(
      ((BigInt.one << (byteBits + offBits)) - BigInt.one),
      width: xlen,
    );
    final fillLineBase = fillAddr & ~lineMask;

    // Drive the MMU request during a fill.
    final memEnR = Logic(name: 'memEnR');
    final memAddrR = Logic(name: 'memAddrR', width: xlen);
    memEn <= memEnR;
    memAddr <= memAddrR;

    // Responses. `done`/`data` are aligned: done from the flop tag compare on
    // addrQ, data from the block-RAM read that answers addrQ this cycle.
    done0 <= hit0;
    valid0 <= hit0;
    Logic ramRead(int r) => ramLatency == 1
        ? dataRam.readData(r)
        : flop(clk, dataRam.readData(r));
    rdata0 <= ramRead(0);
    if (dualPort) {
      done1 <= hit1;
      valid1 <= hit1;
      rdata1 <= ramRead(1);
    }

    // Data block-RAM write port: one fill word per MMU response.
    final fillWrEn = (filling & memDone & memValid).named('fillWrEn');
    // Write entry = {fillIdx, low offBits of fillWord}.
    final Logic fillEntry;
    if (offBits == 0) {
      fillEntry = fillIdx;
    } else if (idxBits == 0) {
      fillEntry = fillWord.slice(offBits - 1, 0);
    } else {
      fillEntry = [fillIdx, fillWord.slice(offBits - 1, 0)].swizzle();
    }
    dataRam.input('wr_en').srcConnection! <= fillWrEn;
    dataRam.input('wr_addr').srcConnection! <= fillEntry;
    dataRam.input('wr_data').srcConnection! <= memRdata;

    final lastWord = Const(lineWords - 1, width: fillWord.width);

    Sequential(clk, [
      // Track the delayed request addresses for the read-latency alignment.
      addr0Q < req0Addr,
      if (dualPort) addr1Q! < req1Addr!,
      If(
        reset | flush,
        then: [
          ...List.generate(numLines, (i) => lineValid[i] < 0),
          filling < 0,
          fillSettle < 0,
          memEnR < 0,
        ],
        orElse: [
          fillSettle < 0,
          If(
            filling,
            then: [
              // Awaiting a fill word from the MMU (the write port captures it).
              If(
                memDone & memValid,
                then: [
                  If(
                    fillWord.eq(lastWord),
                    then: [
                      // Last word written this edge: commit the line and finish.
                      memEnR < 0,
                      filling < 0,
                      fillSettle < 1,
                      ...List.generate(
                        numLines,
                        (l) => If(
                          fillIdx.eq(l),
                          then: [lineValid[l] < 1, lineTag[l] < fillTag],
                        ),
                      ),
                    ],
                    orElse: [
                      // Next word.
                      fillWord < fillWord + 1,
                      memAddrR <
                          (fillBase +
                              ((fillWord + 1).zeroExtend(xlen) *
                                  Const(wordBytes, width: xlen))),
                    ],
                  ),
                ],
              ),
            ],
            orElse: [
              // Idle: start a fill for the highest-priority missing port.
              If(
                wantFill,
                then: [
                  filling < 1,
                  fillIdx < idxOf(fillAddr),
                  fillTag < tagOf(fillAddr),
                  fillBase < fillLineBase,
                  fillWord < 0,
                  memEnR < 1,
                  memAddrR < fillLineBase,
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}
