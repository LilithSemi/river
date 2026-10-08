import 'dart:async';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

int addi(int rd, int rs, int value) =>
    ((value & 4095) << 20) | (rs << 15) | (rd << 7) | 0x13;

Future<void> exercise(
  RiscVMxlen xlen,
  bool microcoded,
  bool store, {
  bool pulse = false,
}) async {
  const dataAddress = 0x200000;
  const accessPc = 8;
  final bytes = xlen.size ~/ 8;
  final program = [
    0x00200537,
    addi(11, 0, 0x55),
    store ? 0x00b52023 : 0x00052583,
    addi(18, 0, 0x66),
    0x0000006f,
  ];
  final image = <int, int>{};
  for (var i = 0; i < program.length; i++) {
    for (var j = 0; j < 4; j++) {
      image[4 * i + j] = (program[i] >> (8 * j)) & 255;
    }
  }
  final core = RiverCore(
    RiverCoreConfig(
      mxlen: xlen,
      type: RiverCoreType.general,
      extensions: [rv32i, if (xlen == RiscVMxlen.rv64) rv64i, rvZicsr],
      interrupts: [],
      resetVector: 0,
      microcodeMode: microcoded ? MicrocodeMode.full : MicrocodeMode.none,
      mmu: HarborMmuConfig(
        mxlen: xlen,
        pagingModes: const [RiscVPagingMode.bare],
        pmp: HarborPmpConfig.none,
      ),
      clock: const HarborClockConfig(
        name: 'test',
        rate: HarborFixedClockRate(100000000),
      ),
    ),
    withDebug: true,
    busConfig: WishboneConfig(addressWidth: xlen.size, dataWidth: xlen.size),
  );
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic()..inject(1);
  final halt = Logic()..inject(0), resume = Logic()..inject(0);
  final debugWrite = Logic()..inject(0), debugRead = Logic()..inject(0);
  final debugAddress = Logic(width: 16)..inject(0);
  final debugData = Logic(width: xlen.size)..inject(0);
  final ack = Logic()..inject(0), readData = Logic(width: xlen.size)..inject(0);
  core.input('clk').srcConnection! <= clk;
  core.input('reset').srcConnection! <= reset;
  core.input('debug_halt_req').srcConnection! <= halt;
  core.input('debug_resume_req').srcConnection! <= resume;
  core.input('debug_reg_write').srcConnection! <= debugWrite;
  core.input('debug_reg_read').srcConnection! <= debugRead;
  core.input('debug_reg_addr').srcConnection! <= debugAddress;
  core.input('debug_reg_wdata').srcConnection! <= debugData;
  core.input('dataBus_ACK').srcConnection! <= ack;
  core.input('dataBus_DAT_MISO').srcConnection! <= readData;
  await core.build();
  var releaseData = false;
  final effects = <int>[];
  bool active() =>
      core.output('dataBus_CYC').value.toBool() &&
      core.output('dataBus_STB').value.toBool();
  bool halted() => core.output('debug_halted').value.toBool();
  int reg(int n) => core.regs.getData(LogicValue.ofInt(n, 5))!.toInt();
  Future<void> tick() async {
    await clk.nextNegedge;
    if (ack.value.toBool()) {
      ack.inject(0);
      return;
    }
    if (!active()) return;
    final address = core.output('dataBus_ADR').value.toInt();
    if (address == dataAddress) {
      if (!releaseData) return;
      expect(core.output('dataBus_WE').value.toBool(), store);
      final value = store
          ? core.output('dataBus_DAT_MOSI').value.toInt()
          : 0x1111 * (effects.length + 1);
      effects.add(value);
      readData.inject(value);
    } else {
      expect(core.output('dataBus_WE').value.toBool(), isFalse);
      var word = BigInt.zero;
      for (var i = 0; i < bytes; i++) {
        word |= BigInt.from(image[address + i] ?? 0) << (8 * i);
      }
      readData.inject(LogicValue.ofBigInt(word, xlen.size));
    }
    ack.inject(1);
  }

  Future<void> until(bool Function() predicate) async {
    for (var i = 0; i < 5000; i++) {
      await tick();
      if (predicate()) return;
    }
    fail('bounded core/debug progress timeout');
  }

  Simulator.setMaxSimTime(200000);
  unawaited(Simulator.run());
  try {
    await tick();
    await tick();
    reset.inject(0);
    await until(
      () => active() && core.output('dataBus_ADR').value.toInt() == dataAddress,
    );
    halt.inject(1);
    if (pulse) {
      await tick();
      halt.inject(0);
    }
    for (var i = 0; i < 20; i++) {
      await tick();
    }
    releaseData = true;
    // Let the external side effect complete even if the hart halted prematurely.
    for (var i = 0; i < 20; i++) {
      await tick();
    }
    await until(halted);
    final savedPc = core.output('debug_dpc').value.toInt();
    final savedValue = reg(11);
    debugAddress.inject(0x100b);
    debugData.inject(0x99);
    debugWrite.inject(1);
    for (var i = 0; i < 3; i++) {
      await tick();
    }
    debugWrite.inject(0);
    for (var i = 0; i < 5; i++) {
      await tick();
    }
    expect(reg(11), 0x99, reason: 'debugger write must land while halted');
    halt.inject(0);
    resume.inject(1);
    await tick();
    resume.inject(0);
    await until(() => reg(18) == 0x66);
    expect(effects, [
      store ? 0x55 : 0x1111,
    ], reason: 'halt/resume must not replay an externally completed operation');
    expect(
      savedPc,
      accessPc + 4,
      reason: 'dpc must identify the completed access successor',
    );
    expect(
      savedValue,
      store ? 0x55 : 0x1111,
      reason: 'accepted load must complete before debug edits',
    );
    expect(reg(11), 0x99, reason: 'old work must not overwrite debugger state');
  } finally {
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }
}

void main() {
  tearDown(Simulator.reset);
  for (final xlen in [RiscVMxlen.rv32, RiscVMxlen.rv64]) {
    for (final microcoded in [false, true]) {
      for (final store in [false, true]) {
        test(
          '${xlen.name} ${microcoded ? "microcoded" : "static"} ${store ? "store" : "MMIO read"} is not replayed across halt',
          () => exercise(xlen, microcoded, store),
        );
        test(
          '${xlen.name} ${microcoded ? "microcoded" : "static"} ${store ? "store" : "MMIO read"} drains after a halt pulse',
          () => exercise(xlen, microcoded, store, pulse: true),
        );
      }
    }
  }
}
