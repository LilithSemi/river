import 'dart:async';

import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const ram = 0x200000;
const secondRam = 0x240000;
const virtualRam = 0x600000;
const boot = 0x10000;
const root = 0x40000;
const leaf = 0x42000;

int addi(int rd, int rs, int n) =>
    ((n & 4095) << 20) | (rs << 15) | (rd << 7) | 0x13;
int csrWrite(int address, int rs) => (address << 20) | (rs << 15) | 0x1073;
int csrRead(int rd, int address) => (address << 20) | (rd << 7) | 0x2073;
int load(int rd, int rs, int offset, int funct) =>
    ((offset & 4095) << 20) | (rs << 15) | (funct << 12) | (rd << 7) | 3;
int shift(int rd, int amount) =>
    (amount << 20) | (rd << 15) | (1 << 12) | (rd << 7) | 0x13;
List<int> li(int rd, int value) => [
  ((value + 2048) & 0xfffff000) | (rd << 7) | 0x37,
  addi(rd, rd, value),
];
int byteAt(int address) => ((address * 37) ^ (address >> 4) ^ 0x95) & 255;
BigInt reference(int address, int size, bool unsigned, int width) {
  var value = BigInt.zero;
  for (var i = 0; i < size; i++)
    value |= BigInt.from(byteAt(address + i)) << (8 * i);
  if (!unsigned && ((value >> (size * 8 - 1)) & BigInt.one) != BigInt.zero)
    value -= BigInt.one << (size * 8);
  return value.toUnsigned(width);
}

Future<void> runLoad(
  RiscVMxlen xlen,
  bool microcoded,
  int bytes,
  bool unsigned,
  int offset, {
  String scenario = 'value',
  bool cached = false,
  bool policy = true,
  bool ackAndErr = false,
  bool emulate = false,
  bool x0 = false,
}) async {
  final busBytes = xlen.size ~/ 8;
  final paged =
      scenario.startsWith('page') ||
      scenario.startsWith('pte') ||
      scenario == 'noncontiguous' ||
      scenario == 'physical IO';
  final crossingPage = paged;
  final address = crossingPage ? virtualRam + 4096 - 2 : ram + offset;
  final actualOffset = address & (busBytes - 1);
  final split = actualOffset + bytes > busBytes;
  final regionDenied =
      scenario == 'IO' ||
      scenario == 'unknown' ||
      scenario == 'non-idempotent' ||
      scenario == 'width';
  final deniedSecond = scenario == 'physical IO';
  final config = RiverCoreConfig(
    resetVector: boot,
    mxlen: xlen,
    extensions: [
      rv32i,
      if (xlen == RiscVMxlen.rv64) rv64i,
      rvPriv,
      rvZicsr,
      if (scenario == 'compressed') rvC,
      if (scenario == 'fp') rvF,
      if (const ['lr', 'sc', 'amo'].contains(scenario)) rvA,
    ],
    type: RiverCoreType.general,
    microcodeMode: microcoded ? MicrocodeMode.full : MicrocodeMode.none,
    interrupts: [],
    l1cache: cached
        ? HarborL1CacheConfig.split(
            iSize: 64,
            dSize: 64,
            ways: 1,
            lineSize: 2 * busBytes,
          )
        : null,
    mmu: HarborMmuConfig(
      mxlen: xlen,
      pagingModes: [
        RiscVPagingMode.bare,
        if (paged)
          xlen == RiscVMxlen.rv64 ? RiscVPagingMode.sv39 : RiscVPagingMode.sv32,
      ],
      pmp: scenario == 'PMP'
          ? const HarborPmpConfig(entries: 8)
          : HarborPmpConfig.none,
      hasPageBasedMemoryTypes: scenario == 'PBMT',
      pma: HarborPmaConfig(
        regions: policy
            ? [
                // A separate eligible region keeps the engine enabled for rejection tests.
                const HarborPmaRegion.memory(start: 0x300000, size: 4096),
                if (scenario != 'unknown')
                  HarborPmaRegion(
                    start: ram,
                    size: 4096,
                    memoryType: scenario == 'IO'
                        ? HarborPmaMemoryType.io
                        : HarborPmaMemoryType.memory,
                    idempotent: scenario != 'non-idempotent',
                    accessWidths: scenario == 'width'
                        ? const [1]
                        : const [1, 2, 4, 8],
                  ),
                if (deniedSecond)
                  const HarborPmaRegion.io(start: secondRam, size: 4096)
                else
                  const HarborPmaRegion.memory(start: secondRam, size: 4096),
              ]
            : const [],
      ),
    ),
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(100000000),
    ),
  );
  final program = <int>[...li(10, address), addi(11, 0, 0x55)];
  if (paged) {
    program.addAll([
      addi(15, 0, 1),
      shift(15, xlen.size - 1),
      addi(15, 15, root >> 12),
      csrWrite(0x180, 15),
      ...li(16, (1 << 17) | (1 << 11)),
      csrWrite(0x300, 16),
    ]);
  }
  if (scenario == 'fp') {
    program.addAll([...li(16, 1 << 13), csrWrite(0x300, 16)]);
  }
  final loadPc = boot + 4 * program.length;
  final funct = bytes.bitLength - 1 + (unsigned ? 4 : 0);
  final instruction = switch (scenario) {
    'compressed' => 0x00010000 | (bytes == 8 ? 0x610c : 0x410c),
    'fp' => load(11, 10, 0, funct) | 4,
    'store' => (11 << 20) | (10 << 15) | (2 << 12) | 0x23,
    'lr' || 'sc' || 'amo' =>
      ((scenario == 'lr'
                  ? 2
                  : scenario == 'sc'
                  ? 3
                  : 0) <<
              27) |
          (10 << 15) |
          (2 << 12) |
          (11 << 7) |
          0x2f,
    _ => load(x0 ? 0 : 11, 10, 0, funct),
  };
  program.addAll([instruction, addi(18, 0, 0x66), 0x6f]);
  final handler = <int>[
    csrRead(5, 0x342),
    csrRead(6, 0x341),
    csrRead(7, 0x343),
  ];
  if (emulate) {
    // Software reference for unsigned halfword loads: two ordinary byte loads.
    handler.addAll([
      load(11, 10, 0, 4),
      load(12, 10, 1, 4),
      shift(12, 8),
      (12 << 20) | (11 << 15) | (6 << 12) | (11 << 7) | 0x33,
      addi(6, 6, 4),
      csrWrite(0x341, 6),
      0x30200073,
    ]);
  } else {
    handler.addAll([addi(19, 0, 1), 0x6f]);
  }
  final image = <int, int>{};
  void put(int at, BigInt value, int size) {
    for (var i = 0; i < size; i++)
      image[at + i] = ((value >> (i * 8)) & BigInt.from(255)).toInt();
  }

  for (var i = 0; i < program.length; i++)
    put(boot + 4 * i, BigInt.from(program[i]), 4);
  for (var i = 0; i < handler.length; i++)
    put(4 * i, BigInt.from(handler[i]), 4);
  int physical(int va) => va < virtualRam + 4096
      ? ram + va - virtualRam
      : secondRam + va - virtualRam - 4096;
  if (paged) {
    final pteBytes = xlen.size ~/ 8;
    if (xlen == RiscVMxlen.rv64) {
      put(root, BigInt.from(((0x41000 >> 12) << 10) | 1), pteBytes);
      put(0x41000 + 3 * 8, BigInt.from(((leaf >> 12) << 10) | 1), pteBytes);
    } else {
      put(root + 4, BigInt.from(((leaf >> 12) << 10) | 1), pteBytes);
    }
    final leafIndex = (virtualRam >> 12) & (xlen.size == 64 ? 511 : 1023);
    put(
      leaf + leafIndex * pteBytes,
      BigInt.from(((ram >> 12) << 10) | 0xc7),
      pteBytes,
    );
    put(
      leaf + (leafIndex + 1) * pteBytes,
      scenario == 'page second'
          ? BigInt.zero
          : BigInt.from(
              ((secondRam >> 12) << 10) |
                  (scenario == 'page permission' ? 0xc9 : 0xc7),
            ),
      pteBytes,
    );
    for (var i = -busBytes; i < bytes + busBytes; i++) {
      image[physical(address + i)] = byteAt(address + i);
    }
  } else {
    for (var i = -busBytes; i < bytes + busBytes; i++)
      image[address + i] = byteAt(address + i);
  }
  final firstAddress = (paged ? physical(address) : address) & ~(busBytes - 1);
  final secondAddress = paged ? secondRam : firstAddress + busBytes;
  final leafIndex = (virtualRam >> 12) & (xlen.size == 64 ? 511 : 1023);
  final errorAddress = scenario == 'bus first'
      ? firstAddress
      : scenario == 'bus second'
      ? secondAddress
      : scenario == 'pte second'
      ? leaf + (leafIndex + 1) * busBytes
      : -1;
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
  final ack = Logic()..inject(0);
  final err = Logic()..inject(0);
  final data = Logic(width: xlen.size)..inject(0);
  core.input('dataBus_ACK').srcConnection! <= ack;
  core.input('dataBus_ERR').srcConnection! <= err;
  core.input('dataBus_DAT_MISO').srcConnection! <= data;
  await core.build();
  final transactions = <({int address, int sel})>[];
  int reg(int n) => core.regs.getData(LogicValue.ofInt(n, 5))!.toInt();
  var armed = false;
  var delay = 0;
  var requestAddress = 0;
  var requestSel = 0;
  var responding = false;
  var reached = false;
  var started = -1;
  var finished = -1;
  Simulator.setMaxSimTime(80000);
  unawaited(Simulator.run());
  try {
    await clk.nextNegedge;
    await clk.nextNegedge;
    reset.inject(0);
    for (var cycle = 0; cycle < 7000; cycle++) {
      await clk.nextNegedge;
      final active =
          core.output('dataBus_CYC').value.toBool() &&
          core.output('dataBus_STB').value.toBool();
      if (responding) {
        ack.inject(0);
        err.inject(0);
        responding = false;
        armed = false;
      } else if (armed) {
        expect(
          active,
          isTrue,
          reason: 'request abandoned before terminal response',
        );
        expect(core.output('dataBus_ADR').value.toInt(), requestAddress);
        expect(core.output('dataBus_SEL').value.toInt(), requestSel);
        if (--delay == 0) {
          final bad = requestAddress == errorAddress;
          var value = BigInt.zero;
          for (var i = 0; i < busBytes; i++)
            value |= BigInt.from(image[requestAddress + i] ?? 0) << (8 * i);
          data.inject(LogicValue.ofBigInt(value, xlen.size));
          err.inject(bad ? 1 : 0);
          ack.inject(!bad || ackAndErr ? 1 : 0);
          transactions.add((address: requestAddress, sel: requestSel));
          responding = true;
        }
      } else if (active) {
        expect(
          core.output('dataBus_WE').value.toBool(),
          isFalse,
          reason: 'load issued a write',
        );
        requestAddress = core.output('dataBus_ADR').value.toInt();
        requestSel = core.output('dataBus_SEL').value.toInt();
        delay = requestAddress == secondAddress ? 5 : 2;
        armed = true;
      }
      if (started < 0 &&
          core.pipeline.input('currentPc').value.toInt() == loadPc)
        started = cycle;
      if (reg(18) == 0x66 || reg(19) == 1) {
        reached = true;
        finished = cycle;
        break;
      }
    }
    expect(
      reached,
      isTrue,
      reason: 'neither successful completion nor handler finished',
    );
    final dataReads = transactions
        .where(
          (t) =>
              t.address >= ram - busBytes && t.address < ram + 4096 ||
              t.address >= secondRam && t.address < secondRam + 4096,
        )
        .toList();
    final aligned = address % bytes == 0;
    final fallback =
        !aligned &&
        (!policy ||
            cached ||
            const [
              'PMP',
              'PBMT',
              'fp',
              'store',
              'lr',
              'sc',
              'amo',
            ].contains(scenario));
    final fault =
        fallback ||
        regionDenied ||
        deniedSecond ||
        scenario.startsWith('bus') ||
        scenario.startsWith('page') ||
        scenario.startsWith('pte');
    if (emulate) {
      expect(reg(18), 0x66);
      expect(
        core.regs.getData(LogicValue.ofInt(11, 5))!.toBigInt(),
        reference(address, bytes, unsigned, xlen.size),
      );
      print(
        'PERF ${xlen.name} microcoded=$microcoded offset=$offset cycles=${finished - started} reads=${dataReads.length} trapped=${reg(5)}',
      );
    } else if (fault && !aligned) {
      final page = scenario.startsWith('page');
      expect(reg(19), 1);
      expect(
        reg(5),
        const ['store', 'sc', 'amo'].contains(scenario)
            ? 6
            : fallback
            ? 4
            : page
            ? 13
            : 5,
      );
      expect(reg(6), loadPc);
      expect(
        reg(7),
        scenario.endsWith('second') ||
                scenario == 'page permission' ||
                deniedSecond
            ? (address & ~(busBytes - 1)) + busBytes
            : address,
      );
      expect(reg(11), 0x55);
      expect(reg(18), 0);
      if (scenario != 'bus second') {
        expect(dataReads.where((t) => t.address == secondAddress), isEmpty);
      }
      if (scenario == 'bus second') {
        expect(dataReads.length, 2);
      } else if (fallback || regionDenied || scenario == 'bus first') {
        expect(dataReads.length, scenario == 'bus first' ? 1 : 0);
      } else {
        expect(dataReads.length, 1);
      }
    } else {
      expect(
        reg(19),
        0,
        reason: 'load trapped with cause=${reg(5)}, tval=${reg(7)}',
      );
      expect(reg(18), 0x66);
      expect(
        core.regs.getData(LogicValue.ofInt(x0 ? 0 : 11, 5))!.toBigInt(),
        x0 ? BigInt.zero : reference(address, bytes, unsigned, xlen.size),
      );
      if (!aligned) {
        expect(dataReads.length, split ? 2 : 1);
        expect(dataReads.first, (
          address: firstAddress,
          sel: (1 << busBytes) - 1,
        ));
        if (split)
          expect(dataReads.last, (
            address: secondAddress,
            sel: (1 << busBytes) - 1,
          ));
      } else {
        // Preserve the existing executor/MMU convention, including its legacy
        // fixed read-size mask. This is an equivalence control, not a claim
        // that the pre-existing aligned MMIO interface is byte-exact.
        final lane = microcoded ? actualOffset : 0;
        expect(dataReads.single, (
          address: firstAddress,
          sel: (15 << lane) & ((1 << busBytes) - 1),
        ));
      }
    }
  } finally {
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }
}

void main() {
  tearDown(Simulator.reset);
  for (final xlen in [RiscVMxlen.rv32, RiscVMxlen.rv64]) {
    for (final microcoded in [false, true]) {
      group('${xlen.name} ${microcoded ? "microcoded" : "static"}', () {
        for (final bytes in [1, 2, 4, if (xlen.size == 64) 8]) {
          for (final unsigned in [false, if (bytes < xlen.size ~/ 8) true]) {
            for (var offset = 0; offset < xlen.size ~/ 8; offset++) {
              test(
                'bytes=$bytes unsigned=$unsigned offset=$offset',
                () => runLoad(xlen, microcoded, bytes, unsigned, offset),
              );
            }
          }
        }
        for (final scenario in [
          'IO',
          'unknown',
          'non-idempotent',
          'width',
          'bus first',
          'bus second',
          // Upstream's MMU does not currently elaborate Sv32; do not turn
          // that unrelated limitation into a misaligned-load implementation.
          if (xlen == RiscVMxlen.rv64) ...[
            'noncontiguous',
            'page second',
            'page permission',
            'pte second',
            'physical IO',
          ],
        ]) {
          for (final ackAndErr in [
            false,
            if (scenario.startsWith('bus')) true,
          ]) {
            test(
              '$scenario ACK+ERR=$ackAndErr',
              () => runLoad(
                xlen,
                microcoded,
                4,
                false,
                xlen.size ~/ 8 - 1,
                scenario: scenario,
                ackAndErr: ackAndErr,
              ),
            );
          }
        }
        for (final scenario in [
          'PMP',
          'PBMT',
          'fp',
          'store',
          'lr',
          'sc',
          'amo',
        ]) {
          test(
            '$scenario retains misalignment trap',
            () => runLoad(xlen, microcoded, 4, false, 1, scenario: scenario),
          );
        }
        for (final size in [4, if (xlen.size == 64) 8]) {
          test(
            'compressed bytes=$size',
            () => runLoad(
              xlen,
              microcoded,
              size,
              false,
              xlen.size ~/ 8 - 1,
              scenario: 'compressed',
            ),
          );
        }
        test(
          'unconfigured retains misalignment trap',
          () => runLoad(xlen, microcoded, 2, false, 1, policy: false),
        );
        test(
          'cached retains misalignment trap',
          () => runLoad(xlen, microcoded, 2, false, 1, cached: true),
        );
        test(
          'misaligned load into x0 still reads',
          () => runLoad(xlen, microcoded, 2, false, 1, x0: true),
        );
        test(
          'aligned device access unchanged',
          () => runLoad(xlen, microcoded, 1, false, 1, scenario: 'IO'),
        );
        for (final offset in [1, xlen.size ~/ 8 - 1]) {
          test(
            'emulation comparison offset=$offset',
            () => runLoad(xlen, microcoded, 2, true, offset, emulate: true),
          );
        }
      });
    }
  }
}
