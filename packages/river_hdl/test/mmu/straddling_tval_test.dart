import 'dart:async';

import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _boot = 0x10000;
const _root = 0x40000;
const _boundary =
    0x40000000; // Sv39 level-2 leaf boundary; also a cache boundary.
const _start = _boundary - 2;

int _addi(int rd, int rs, int imm) =>
    ((imm & 0xfff) << 20) | (rs << 15) | (rd << 7) | 0x13;
int _csrw(int csr, int rs) => (csr << 20) | (rs << 15) | 0x1073;
int _csrr(int rd, int csr) => (csr << 20) | (rd << 7) | 0x2073;

void main() {
  tearDown(Simulator.reset);
  for (final xlen in [RiscVMxlen.rv32, RiscVMxlen.rv64]) {
    for (final microcoded in [false, true]) {
      for (final cached in [false, true]) {
        group(
          '${xlen.name} ${microcoded ? "microcoded" : "static"} cached=$cached',
          () {
            for (final fault in [
              'access',
              if (xlen == RiscVMxlen.rv64) 'page',
            ]) {
              for (final portion in ['first', 'second', 'success']) {
                for (final ackAndErr in [
                  false,
                  if (fault == 'access' && portion != 'success') true,
                ]) {
                  test(
                    '$fault $portion ACK+ERR=$ackAndErr',
                    () => _run(
                      xlen,
                      microcoded,
                      cached,
                      fault,
                      portion,
                      ackAndErr,
                    ),
                  );
                }
              }
            }
          },
        );
      }
    }
  }
}

Future<void> _run(
  RiscVMxlen xlen,
  bool microcoded,
  bool cached,
  String fault,
  String portion,
  bool ackAndErr,
) async {
  final paged = fault == 'page';
  final success = portion == 'success';
  final second = portion == 'second';
  final bytes = xlen.size ~/ 8;
  final expectedCause = success ? (paged ? 9 : 11) : (paged ? 12 : 1);
  final expectedEpc = success ? _start + 4 : _start;
  final expectedTval = success
      ? 0
      : second
      ? _boundary
      : _start;
  final config = RiverCoreConfig(
    mxlen: xlen,
    extensions: [
      rv32i,
      if (xlen == RiscVMxlen.rv64) rv64i,
      rvC,
      rvZicsr,
      if (paged) rvPriv,
    ],
    type: RiverCoreType.general,
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
    resetVector: _boot,
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(100000000),
    ),
  );
  final boot = <int>[
    _addi(11, 0, 0x55),
    0x40000537, // lui a0,0x40000
    _addi(10, 10, -2),
    if (paged) ...[
      _addi(15, 0, 1),
      (63 << 20) | (15 << 15) | (1 << 12) | (15 << 7) | 0x13,
      _addi(15, 15, _root >> 12), _csrw(0x180, 15), // Sv39
      _addi(16, 0, 1),
      (11 << 20) | (16 << 15) | (1 << 12) | (16 << 7) | 0x13,
      _csrw(0x300, 16), // MPP=S
      _csrw(0x341, 10), 0x30200073, // mret to the straddling instruction
    ] else
      0x00050067, // jalr zero,0(a0)
  ];
  final halfwords = <int, int>{};
  void instruction(int address, int value) {
    halfwords[address] = value & 0xffff;
    halfwords[address + 2] = value >> 16;
  }

  for (var i = 0; i < boot.length; i++) {
    instruction(_boot + 4 * i, boot[i]);
  }
  instruction(_start, _addi(11, 0, 0x66)); // must not execute on either fault
  instruction(_start + 4, 0x00000073); // successful-fetch control: ECALL
  instruction(0, _csrr(5, 0x342));
  instruction(4, _csrr(6, 0x341));
  instruction(8, _csrr(7, 0x343));
  instruction(12, _addi(18, 0, 0x77));
  instruction(16, 0x0000006f);

  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic()..inject(1);
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
  final bad = !paged && !success
      ? addr.eq(second ? _boundary : _boundary - bytes)
      : Const(0);
  final response = Logic();
  Sequential(clk, [
    If(reset, then: [response < 0], orElse: [response < active & ~response]),
  ]);
  core.input('dataBus_ACK').srcConnection! <=
      response & (ackAndErr ? Const(1) : ~bad);
  core.input('dataBus_ERR').srcConnection! <= response & bad;
  Logic data = Const(0, width: xlen.size);
  for (final base in halfwords.keys.map((a) => a & ~(bytes - 1)).toSet()) {
    var word = BigInt.zero;
    for (var offset = 0; offset < bytes; offset += 2) {
      word |=
          BigInt.from(halfwords[base + offset] ?? 1) <<
          (8 * offset); // c.nop padding
    }
    data = mux(addr.eq(base), Const(word, width: xlen.size), data);
  }
  if (paged) {
    data = mux(
      addr.eq(_root),
      Const(portion == 'first' ? 0 : 0xcf, width: xlen.size),
      data,
    );
    data = mux(
      addr.eq(_root + 8),
      Const(success ? 0x100000cf : 0, width: xlen.size),
      data,
    );
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
    final reads = <int>{};
    for (var i = 0; i < 6000; i++) {
      await clk.nextNegedge;
      if (active.value.toBool() && response.value.toBool()) {
        reads.add(addr.value.toInt());
      }
      final trapNow = core.pipeline.trap.value.toBool();
      if (trapNow && !previousTrap) {
        expect(
          trapped,
          isFalse,
          reason: 'the handler must not inherit the fetch fault',
        );
        trapped = true;
        expect(core.pipeline.trapCause.value.toInt(), expectedCause);
        expect(
          core.pipeline.trapEpc.value.toInt(),
          expectedEpc,
          reason: 'EPC identifies the instruction start',
        );
        expect(
          core.pipeline.trapTval.value.toInt(),
          expectedTval,
          reason: 'TVAL identifies the faulting instruction portion',
        );
      }
      previousTrap = trapNow;
      if (reg(18) == 0x77) {
        recovered = true;
        break;
      }
    }
    expect(trapped, isTrue);
    expect(recovered, isTrue, reason: 'trap handler must complete');
    expect(
      reg(11),
      success ? 0x66 : 0x55,
      reason: 'a faulting instruction must not write rd',
    );
    expect(reg(5), expectedCause);
    expect(reg(6), expectedEpc);
    expect(reg(7), expectedTval);
    if (second || success) {
      expect(reads, contains(_boundary - bytes));
    }
    if (paged) {
      expect(reads, contains(_root), reason: 'translation must actually run');
      if (second || success) {
        expect(reads, contains(_root + 8));
      }
    }
  } finally {
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }
}
