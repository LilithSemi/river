import 'dart:async';

import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _pc = 0x10000;
const _root = 0x40000;
const _data = 0x80000000;

int _addi(int rd, int rs, int imm) =>
    ((imm & 0xfff) << 20) | (rs << 15) | (rd << 7) | 0x13;
int _slli(int rd, int rs, int amount) =>
    (amount << 20) | (rs << 15) | (1 << 12) | (rd << 7) | 0x13;
int _csrw(int csr, int rs) => (csr << 20) | (rs << 15) | 0x1073;
int _csrr(int rd, int csr) => (csr << 20) | (rd << 7) | 0x2073;
int _atomic(int funct, int rd) =>
    (funct << 27) | (10 << 15) | (2 << 12) | (rd << 7) | 0x2f;

void main() {
  tearDown(Simulator.reset);
  for (final xlen in [RiscVMxlen.rv32, RiscVMxlen.rv64]) {
    for (final microcoded in [false, true]) {
      group('${xlen.name} ${microcoded ? "microcoded" : "static"}', () {
        for (final cached in [false, true]) {
          group('cached=$cached', () {
            for (final ackAndErr in [false, true]) {
              for (final kind in ['fetch', 'load', 'store']) {
                test(
                  '$kind ACK+ERR=$ackAndErr',
                  () => _run(
                    xlen,
                    microcoded,
                    cached,
                    kind,
                    ackAndErr: ackAndErr,
                  ),
                );
              }
            }
            for (final kind in [
              'lr',
              'sc',
              'amo-read',
              'amo-write',
              'amo-ok',
              if (cached) ...[
                'fetch-refill-tail',
                'load-refill-tail',
                'load-bypass',
                'store-hit',
              ],
              if (xlen == RiscVMxlen.rv64) ...[
                'pte-fetch',
                'pte-load',
                'pte-store',
                'pte-amo-read',
                'page-load',
                'page-store',
                'page-amo-read',
                'page-amo-write',
              ],
            ]) {
              test(kind, () => _run(xlen, microcoded, cached, kind));
            }
          });
        }
      });
    }
    for (final cached in [false, true]) {
      test(
        '${xlen.name} OoO cached=$cached preserves legacy ERR behavior',
        () => _run(xlen, false, cached, 'legacy-ooo', ackAndErr: true),
      );
    }
  }
}

Future<void> _run(
  RiscVMxlen xlen,
  bool microcoded,
  bool cached,
  String kind, {
  bool ackAndErr = false,
}) async {
  final legacyOoO = kind == 'legacy-ooo';
  final paged = kind.startsWith('pte-') || kind.startsWith('page-');
  final bytes = xlen.size ~/ 8;
  final dataAddress = kind == 'load-bypass' ? 0x1f000000 : _data;
  final fetchFault = kind.contains('fetch');
  final store = kind.endsWith('store') || kind == 'store-hit';
  final amo = kind.contains('amo');
  final writeFault = store || kind == 'sc' || kind.endsWith('amo-write');
  final expectedCause = kind == 'amo-ok'
      ? 11
      : kind.startsWith('page-')
      ? (store || amo ? 15 : 13)
      : fetchFault
      ? 1
      : store || amo || kind == 'sc'
      ? 7
      : 5;

  final config = RiverCoreConfig(
    mxlen: xlen,
    extensions: [
      rv32i,
      if (xlen == RiscVMxlen.rv64) rv64i,
      rvA,
      rvZicsr,
      if (paged) rvPriv,
    ],
    type: RiverCoreType.general,
    executionMode: legacyOoO ? ExecutionMode.outOfOrder : ExecutionMode.inOrder,
    speculativeFetch: legacyOoO,
    loadStoreQueue: legacyOoO ? LoadStoreQueue.forwarding : LoadStoreQueue.none,
    microcodeMode: microcoded ? MicrocodeMode.full : MicrocodeMode.none,
    l1cache: cached
        ? HarborL1CacheConfig.split(
            iSize: 64,
            dSize: 64,
            ways: 1,
            lineSize: 2 * bytes,
          )
        : null,
    mmu: HarborMmuConfig(
      mxlen: xlen,
      pagingModes: paged
          ? const [RiscVPagingMode.bare, RiscVPagingMode.sv39]
          : const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    interrupts: [],
    resetVector: _pc,
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(100000000),
    ),
  );
  // Construct the same positive address in RV32 and RV64, avoiding RV64 LUI's
  // sign extension. The faulting instruction starts on an I-cache line boundary.
  final program = <int>[
    _addi(11, 0, 0x55),
    ((dataAddress >> 13) << 12) | (10 << 7) | 0x37,
    _slli(10, 10, 1),
    _addi(0, 0, 0),
  ];
  if (paged) {
    program.addAll([
      _addi(15, 0, 1), _slli(15, 15, 63), _addi(15, 15, _root >> 12),
      _csrw(0x180, 15), // Sv39, with 1 GiB identity-mapped leaves.
      _addi(16, 0, 1), _slli(16, 16, 11), _csrw(0x300, 16), // MPP=S
      (17 << 7) | 0x17, _addi(17, 17, 20), _csrw(0x341, 17),
      0x30200073, // mret to a fresh fetch line in S-mode
      _addi(0, 0, 0), // skipped padding; do not reuse an M-mode fetched word
    ]);
  }
  if (kind == 'sc') program.add(_atomic(2, 12)); // successful LR first
  if (kind == 'store-hit') program.add(0x00052603); // warm D-cache: lw a2,(a0)
  final faultPc = _pc + 4 * program.length;
  program.add(
    amo
        ? _atomic(0, 11) // amoadd.w a1,zero,(a0)
        : kind == 'lr'
        ? _atomic(2, 11)
        : kind == 'sc'
        ? _atomic(3, 11)
        : store
        ? 0x00b52023
        : 0x00052583,
  ); // sw a1 / lw a1
  if (legacyOoO) {
    program.addAll([0x00b52023, _addi(18, 0, 0x66), 0x0000006f]);
  } else {
    program.add(0x00000073); // successful AMO reaches ECALL; failures must not
  }
  final expectedPc = faultPc + (kind == 'amo-ok' ? 4 : 0);
  final expectedTval = kind == 'amo-ok'
      ? 0
      : fetchFault
      ? faultPc
      : dataAddress;
  final image = <int, int>{
    for (var i = 0; i < program.length; i++) _pc + 4 * i: program[i],
    // The handler checks architectural CSR capture and performs another load.
    0: _csrr(5, 0x342), 4: _csrr(6, 0x341), 8: _csrr(7, 0x343),
    12: 0x00052603, 16: _addi(18, 0, 0x66), 20: 0x0000006f,
  };
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic()..inject(1);
  final faultsEnabled = Logic()..inject(1);
  final core = RiverCore(
    config,
    busConfig: WishboneConfig(
      addressWidth: xlen.size,
      dataWidth: xlen.size,
      useErr: true,
    ),
  );
  core.input('clk').srcConnection! <= clk;
  core.input('reset').srcConnection! <= reset;
  final active = core.output('dataBus_CYC') & core.output('dataBus_STB');
  final addr = core.output('dataBus_ADR');
  final we = core.output('dataBus_WE');
  final errorAddress = kind.startsWith('pte-')
      ? _root + (fetchFault ? 0 : 16)
      : fetchFault
      ? faultPc + (kind.endsWith('tail') ? bytes : 0)
      : dataAddress + (kind.endsWith('tail') ? bytes : 0);
  final bad =
      faultsEnabled &
      addr.eq(errorAddress) &
      (kind.startsWith('page-') || kind == 'amo-ok'
          ? Const(0)
          : writeFault && !kind.startsWith('pte-')
          ? we
          : Const(1));
  final response = Logic();
  Sequential(clk, [
    If(reset, then: [response < 0], orElse: [response < active & ~response]),
  ]);
  core.input('dataBus_ACK').srcConnection! <=
      response & (ackAndErr ? Const(1) : ~bad);
  core.input('dataBus_ERR').srcConnection! <= response & bad;
  Logic data = Const(0x1234, width: xlen.size);
  for (final base in image.keys.map((a) => a & ~(bytes - 1)).toSet()) {
    var word = BigInt.zero;
    for (var offset = 0; offset < bytes; offset += 4) {
      word |= BigInt.from(image[base + offset] ?? 0x0000006f) << (8 * offset);
    }
    data = mux(addr.eq(base), Const(word, width: xlen.size), data);
  }
  if (paged) {
    data = mux(addr.eq(_root), Const(0xcf, width: xlen.size), data);
    final pte = kind.startsWith('page-')
        ? (kind == 'page-amo-write' ? 0x200000cb : 0)
        : 0x200000cf;
    data = mux(addr.eq(_root + 16), Const(pte, width: xlen.size), data);
  }
  core.input('dataBus_DAT_MISO').srcConnection! <= data;
  await core.build();
  Simulator.setMaxSimTime(100000);
  unawaited(Simulator.run());
  int reg(int n) => core.regs.getData(LogicValue.ofInt(n, 5))!.toInt();
  try {
    await clk.nextNegedge;
    reset.inject(0);
    var trapped = false;
    var previousTrap = false;
    var recovered = false;
    var writesBeforeTrap = 0;
    // The serial decoder scans the CSR/privileged instruction table for the
    // paging setup and each handler CSR read; allow those scans to finish.
    for (var i = 0; i < (paged && microcoded ? 6000 : 1200); i++) {
      await clk.nextNegedge;
      if (!trapped &&
          active.value.toBool() &&
          response.value.toBool() &&
          we.value.toBool()) {
        writesBeforeTrap++;
      }
      final trapNow = core.pipeline.trap.value.toBool();
      if (trapNow && !previousTrap) {
        expect(legacyOoO, isFalse, reason: 'OoO ERR behavior is unchanged');
        expect(
          trapped,
          isFalse,
          reason: 'fault classification must not leak into the handler',
        );
        trapped = true;
        expect(core.pipeline.trapCause.value.toInt(), expectedCause);
        expect(core.pipeline.trapEpc.value.toInt(), expectedPc);
        expect(core.pipeline.trapTval.value.toInt(), expectedTval);
        faultsEnabled.inject(0);
      }
      previousTrap = trapNow;
      if (reg(18) == 0x66) {
        recovered = true;
        break;
      }
    }
    expect(trapped, !legacyOoO, reason: 'ERR must trap, not hang or retire');
    expect(
      recovered,
      isTrue,
      reason:
          'subsequent accesses must still complete: '
          'pc=${core.pipeline.input("currentPc").value}, '
          'mcause=${reg(5)}, mepc=${reg(6)}, mtval=${reg(7)}, '
          'bus=${active.value}/${addr.value}/${we.value}',
    );
    expect(
      reg(11),
      kind == 'amo-ok' || legacyOoO ? 0x1234 : 0x55,
      reason: 'a failed instruction must preserve its destination',
    );
    if (!legacyOoO) {
      expect(reg(5), expectedCause);
      expect(reg(6), expectedPc);
      expect(reg(7), expectedTval);
      expect(reg(12), 0x1234);
      if (kind == 'amo-read' ||
          kind == 'pte-amo-read' ||
          kind == 'page-amo-read') {
        expect(
          writesBeforeTrap,
          0,
          reason: 'a failed AMO read must not issue its write',
        );
      }
    }
  } finally {
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }
}
