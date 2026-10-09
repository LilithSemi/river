import 'package:river/river.dart';
import 'package:rohd/rohd.dart';

/// Serialized physical-memory stage. Translation and permission checks happen
/// upstream. Walks bypass allocation; walker writes invalidate D-cache copies
/// of page tables (including hardware A/D updates).
class RiverPhysicalL1 extends Module {
  RiverPhysicalL1(
    Logic clk,
    Logic reset,
    Logic valid,
    Logic addr,
    Logic write,
    Logic data,
    Logic size,
    Logic fetch,
    Logic walk,
    Logic flush,
    Logic ack,
    Logic error,
    Logic rdata, {
    required HarborL1CacheConfig config,
    required HarborPmaConfig pma,
    HarborDeviceTarget? target,
  }) {
    final xlen = addr.width;
    final laneBits = (xlen ~/ 8 - 1).bitLength;
    for (final bytes in [
      config.d.lineSize,
      if (config.i != null) config.i!.lineSize,
    ]) {
      if (bytes < xlen ~/ 8 || bytes > 4096 || (bytes & (bytes - 1)) != 0) {
        throw ArgumentError(
          'Physical L1 lines must fit one translation page and contain whole beats',
        );
      }
    }
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    valid = addInput('valid', valid);
    addr = addInput('request_addr', addr, width: xlen);
    write = addInput('write', write);
    data = addInput('request_data', data, width: xlen);
    size = addInput('size', size, width: 3);
    fetch = addInput('fetch', fetch);
    walk = addInput('walk', walk);
    flush = addInput('flush', flush);
    ack = addInput('ack', ack);
    error = addInput('error', error);
    rdata = addInput('rdata', rdata, width: xlen);
    // Refills may read beyond the architectural operand. Admit a cache only
    // when its ENTIRE line lies in explicit, readable, idempotent RAM and the
    // physical beat width is supported. Unknown/partial/device regions bypass.
    // BigInt validation avoids host-int overflow hiding malformed overlaps.
    final regions = [...pma.regions]
      ..sort((a, b) => a.start.compareTo(b.start));
    var previousEnd = BigInt.zero;
    for (final region in regions) {
      final start = BigInt.from(region.start);
      final end = start + BigInt.from(region.size);
      if (start < previousEnd ||
          region.size <= 0 ||
          end > (BigInt.one << xlen)) {
        throw ArgumentError('Invalid or overlapping physical cache PMA region');
      }
      previousEnd = end;
    }
    Logic cacheableLine(int bytes, {required bool executable}) {
      final base = addr & ~Const(bytes - 1, width: xlen);
      Logic allowed = Const(0);
      for (final region in regions) {
        if (region.memoryType != HarborPmaMemoryType.memory ||
            !region.readable ||
            !region.idempotent ||
            (executable && !region.executable) ||
            !region.accessWidths.contains(xlen ~/ 8) ||
            region.size < bytes) {
          continue;
        }
        final last =
            BigInt.from(region.start) +
            BigInt.from(region.size) -
            BigInt.from(bytes);
        allowed =
            allowed |
            (base.gte(Const(region.start, width: xlen)) &
                base.lte(Const(last, width: xlen)));
      }
      return allowed;
    }

    final selectI =
        (config.i == null
            ? Const(0)
            : cacheableLine(config.i!.lineSize, executable: true)) &
        ~walk &
        fetch;
    final selectD =
        cacheableLine(config.d.lineSize, executable: false) & ~walk & ~fetch;
    final bypass = ~selectI & ~selectD;

    final done = Logic(name: 'memoryDone');
    final success = Logic(name: 'memorySuccess');
    final result = Logic(name: 'memoryResult', width: xlen);
    final active = Logic(name: 'memoryActive');
    final busAddr = Logic(name: 'memoryAddr', width: xlen);
    final busWrite = Logic(name: 'memoryWrite');
    final busData = Logic(name: 'memoryData', width: xlen);
    final busSize = Logic(name: 'memorySize', width: 3);
    // Owner survives flushes while an accepted external operation drains.
    final owner = Logic(name: 'memoryOwner', width: 2);
    final iDone = done & owner.eq(1);
    final dDone = done & owner.eq(2);

    HarborL1ICache? icache;
    if (config.i != null) {
      icache = HarborL1ICache(
        config: config.i!,
        xlen: xlen,
        reqAddrBits: xlen,
        target: target,
      );
      icache.input('clk').srcConnection! <= clk;
      icache.input('reset').srcConnection! <= reset;
      icache.input('req_addr').srcConnection! <= addr;
      icache.input('req_valid').srcConnection! <= valid & selectI;
      icache.input('flush').srcConnection! <= flush;
      icache.input('mem_done').srcConnection! <= iDone;
      icache.input('mem_valid').srcConnection! <= success;
      icache.input('mem_fault').srcConnection! <= Const(0);
      icache.input('mem_rdata').srcConnection! <= result;
    }
    final dcache = HarborL1DCache(
      config: config.d,
      xlen: xlen,
      reqAddrBits: xlen,
      cacheableBase: 0,
      memFaultIn: Const(0),
      target: target,
    );
    dcache.input('clk').srcConnection! <= clk;
    dcache.input('reset').srcConnection! <= reset;
    dcache.input('req_addr').srcConnection! <= addr;
    dcache.input('req_valid').srcConnection! <= valid & selectD;
    dcache.input('req_write').srcConnection! <= write;
    dcache.input('req_data').srcConnection! <= data;
    dcache.input('req_size').srcConnection! <= size;
    dcache.input('flush').srcConnection! <= flush | (valid & bypass & write);
    dcache.input('mem_done').srcConnection! <= dDone;
    dcache.input('mem_valid').srcConnection! <= success;
    // D-cache bypass responses are lane-zero; refill beats are aligned.
    dcache.input('mem_rdata').srcConnection! <=
        result >> [busAddr.getRange(0, laneBits), Const(0, width: 3)].swizzle();
    final iEn = icache?.memEn ?? Const(0);
    final dEn = dcache.memEn;
    final bypassEn = valid & bypass;
    final request = iEn | dEn | bypassEn;
    final requestAddr = mux(
      iEn,
      icache?.memAddr ?? addr,
      mux(dEn, dcache.memAddr, addr),
    );
    final requestWrite = mux(iEn, Const(0), mux(dEn, dcache.memWe, write));
    final requestData = mux(dEn, dcache.memWdata, data);
    final requestSize = mux(
      iEn,
      Const(laneBits, width: 3),
      mux(dEn, dcache.memSize, size),
    );
    Sequential(clk, [
      If(
        reset,
        then: [
          active < 0,
          done < 0,
          success < 0,
          result < 0,
          owner < 0,
          busAddr < 0,
          busWrite < 0,
          busData < 0,
          busSize < 0,
        ],
        orElse: [
          done < 0,
          If(
            active,
            then: [
              If(
                ack | error,
                then: [active < 0, done < 1, success < ~error, result < rdata],
              ),
            ],
            orElse: [
              // Completion bubble lets a refill advance or a bypass withdraw.
              If(
                ~done & request,
                then: [
                  active < 1,
                  busAddr < requestAddr,
                  busWrite < requestWrite,
                  busData < requestData,
                  busSize < requestSize,
                  owner <
                      mux(
                        iEn,
                        Const(1, width: 2),
                        mux(dEn, Const(2, width: 2), Const(0, width: 2)),
                      ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
    final iOk = icache?.respValid ?? Const(0);
    final iErr = icache?.respFault ?? Const(0);
    final dOk = dcache.respValid;
    final dErr = dcache.respFault;
    final bypassDone = done & owner.eq(0);
    addOutput('response_ack') <=
        valid & mux(selectI, iOk, mux(selectD, dOk, bypassDone & success));
    addOutput('response_error') <=
        valid & mux(selectI, iErr, mux(selectD, dErr, bypassDone & ~success));
    // The upstream MMU still performs its existing lane extraction.
    final laneShift = [
      addr.getRange(0, laneBits),
      Const(0, width: 3),
    ].swizzle();
    addOutput('response_data', width: xlen) <=
        mux(
          selectI,
          icache?.respData ?? result,
          mux(selectD, dcache.respData << laneShift, result),
        );
    addOutput('cyc') <= active;
    addOutput('we') <= busWrite;
    addOutput('addr', width: xlen) <=
        [busAddr.getRange(laneBits, xlen), Const(0, width: laneBits)].swizzle();
    addOutput('data', width: xlen) <=
        busData <<
            [busAddr.getRange(0, laneBits), Const(0, width: 3)].swizzle();
    final lanes = xlen ~/ 8;
    final mask = mux(
      busSize.eq(0),
      Const(1, width: lanes),
      mux(
        busSize.eq(1),
        Const(3, width: lanes),
        mux(
          busSize.eq(2),
          Const(15, width: lanes),
          Const((1 << lanes) - 1, width: lanes),
        ),
      ),
    );
    addOutput('sel', width: lanes) <= mask << busAddr.getRange(0, laneBits);
  }
}
