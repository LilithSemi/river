import 'dart:async';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Full-core witnesses deliberately honor SEL on reads. Returning unselected
// bytes would hide a truncated LD/FLD/LR.D or a wrong upper-word byte lane.
void main() {
  tearDown(Simulator.reset);
  for (final microcoded in [false, true]) {
    for (final kind in [
      'integer',
      'floating',
      'atomic word',
      'atomic doubleword',
      // The all-ROM executor does not implement RVV memory operations.
      if (!microcoded) 'vector',
    ]) {
      final atomic = kind.startsWith('atomic');
      final vector = kind == 'vector';
      final floating = kind == 'floating';
      for (final policy
          in atomic || vector
              ? ['RAM', 'partial RAM']
              : ['RAM', 'partial RAM', 'device', 'unknown', 'unknown values']) {
        test(
          'Sv39 sized reads ${microcoded ? "microcoded" : "static"} $kind $policy',
          () async {
            const pa = 0x80002000;
            final word = BigInt.parse('8877665544332211', radix: 16);
            final signedUpper = (BigInt.from(0xffffffff) << 32) | (word >> 32);
            final vectorWord =
                (BigInt.parse('99aabbccddeeff00', radix: 16) << 64) | word;
            final image = <int, int>{};
            void put(int address, BigInt value, int bytes) {
              for (var i = 0; i < bytes; i++) {
                image[address + i] = ((value >> (i * 8)) & BigInt.from(255))
                    .toInt();
              }
            }

            BigInt get(int address, int bytes) {
              var value = BigInt.zero;
              for (var i = 0; i < bytes; i++) {
                value |= BigInt.from(image[address + i] ?? 0) << (i * 8);
              }
              return value;
            }

            int csr(int address, int rs) =>
                (address << 20) | (rs << 15) | 0x1073;
            final expected = <int, BigInt>{};
            final expectedReads = <(int, int)>[];
            final body = <int>[];
            if (kind == 'integer') {
              var rd = 10;
              for (var log = 0; log <= 3; log++) {
                final bytes = 1 << log;
                for (var offset = 0; offset < 8; offset += bytes) {
                  final funct = [4, 5, 6, 3][log]; // LBU/LHU/LWU/LD
                  body.add(
                    (offset << 20) | (7 << 15) | (funct << 12) | (rd << 7) | 3,
                  );
                  expected[rd++] =
                      (word >> (offset * 8)) &
                      ((BigInt.one << (bytes * 8)) - BigInt.one);
                  expectedReads.add((pa, ((1 << bytes) - 1) << offset));
                }
              }
            } else if (floating) {
              body.addAll([
                (4 << 20) |
                    (7 << 15) |
                    (2 << 12) |
                    (1 << 7) |
                    7, // FLW f1,4(t2)
                (0x70 << 25) | (1 << 15) | (10 << 7) | 0x53, // FMV.X.W a0,f1
                (7 << 15) | (3 << 12) | (2 << 7) | 7, // FLD f2,0(t2)
                (0x71 << 25) | (2 << 15) | (11 << 7) | 0x53, // FMV.X.D a1,f2
              ]);
              expected.addAll({10: signedUpper, 11: word});
              expectedReads.addAll([(pa, 0xf0), (pa, 0xff)]);
            } else if (atomic) {
              final log = kind == 'atomic word' ? 2 : 3;
              final offset = log == 2 ? 4 : 0;
              int amo(int funct, int rd, int rs2) =>
                  (funct << 27) |
                  (rs2 << 20) |
                  (7 << 15) |
                  (log << 12) |
                  (rd << 7) |
                  0x2f;
              body.addAll([
                (offset << 20) | (7 << 15) | (7 << 7) | 0x13,
                0x12300493, // s1 = 0x123
                amo(2, 10, 0), // LR.W/D
                amo(3, 11, 9), // SC.W/D
                amo(0, 12, 9), // AMOADD.W/D
              ]);
              expected.addAll({
                10: log == 2 ? signedUpper : word,
                11: BigInt.zero,
                12: BigInt.from(0x123),
              });
              final mask = ((1 << (1 << log)) - 1) << offset;
              expectedReads.addAll([(pa, mask), (pa, mask)]);
            } else {
              body.addAll([
                0x00400293, // t0 = 4 elements
                (16 << 20) |
                    (5 << 15) |
                    (7 << 12) |
                    0x57, // VSETVLI zero,t0,e32,m1
                (1 << 25) |
                    (7 << 15) |
                    (6 << 12) |
                    (1 << 7) |
                    7, // VLE32.V v1,(t2)
                (0x100 << 20) | (7 << 15) | (8 << 7) | 0x13,
                (1 << 25) |
                    (8 << 15) |
                    (6 << 12) |
                    (1 << 7) |
                    0x27, // VSE32.V v1,(s0)
              ]);
              expectedReads.addAll([(pa, 0xff), (pa + 8, 0xff)]);
            }
            final program = [
              0x40000e13, csr(0x305, 28), // a bounded trap handler
              0x00100293, 0x03f29293, 0x01028293, csr(0x180, 5),
              0x00023337, vector ? 0xa0030313 : 0x80030313,
              csr(0x300, 6), // MPRV, MPP=S, FS Initial (and VS Initial for V)
              0x00100393, 0x01f39393, // t2 = VA 0x80000000
              ...body,
              0x06600f13, 0x0000006f, // completion marker in t5
            ];
            for (var i = 0; i < program.length; i++) {
              put(4 * i, BigInt.from(program[i]), 4);
            }
            put(0x400, BigInt.from(0x07e00e93), 4); // trap marker in t4
            put(0x404, BigInt.from(0x0000006f), 4);
            put(0x10010, BigInt.from(0x4401), 8);
            put(0x11000, BigInt.from(0x4801), 8);
            put(0x12000, BigInt.from(((pa >> 12) << 10) | 0xcf), 8);
            put(pa, vector ? vectorWord : word, vector ? 16 : 8);
            final span = vector ? 16 : 8;
            final core = RiverCore(
              RiverCoreConfig(
                mxlen: RiscVMxlen.rv64,
                type: RiverCoreType.general,
                extensions: [
                  rv32i,
                  rv64i,
                  rvZicsr,
                  rvPriv,
                  if (atomic) rvA,
                  if (floating || vector) ...[rvF, rvD],
                  if (vector) rvV,
                ],
                interrupts: [],
                resetVector: 0,
                microcodeMode: microcoded
                    ? MicrocodeMode.full
                    : MicrocodeMode.none,
                l1cache: HarborL1CacheConfig.split(
                  iSize: 64,
                  dSize: 128,
                  ways: 1,
                  lineSize: 32,
                ),
                mmu: HarborMmuConfig(
                  mxlen: RiscVMxlen.rv64,
                  pagingModes: const [
                    RiscVPagingMode.bare,
                    RiscVPagingMode.sv39,
                  ],
                  tlbLevels: const [],
                  pmp: HarborPmpConfig.none,
                  pma: HarborPmaConfig(
                    regions: [
                      const HarborPmaRegion.memory(start: 0, size: 0x20000),
                      if (policy == 'RAM')
                        const HarborPmaRegion.memory(start: pa, size: 0x100),
                      if (policy == 'partial RAM') ...[
                        HarborPmaRegion.memory(start: pa, size: span),
                        HarborPmaRegion.io(
                          start: pa + span,
                          size: 32 - span,
                          accessWidths: const [1, 2, 4, 8],
                        ),
                      ],
                      if (policy == 'device')
                        const HarborPmaRegion.io(
                          start: pa,
                          size: 0x100,
                          accessWidths: [1, 2, 4, 8],
                        ),
                      const HarborPmaRegion.memory(start: pa + 0x100, size: 32),
                    ],
                  ),
                ),
                clock: const HarborClockConfig(
                  name: 'test',
                  rate: HarborFixedClockRate(100000000),
                ),
              ),
              busConfig: WishboneConfig(
                addressWidth: 64,
                dataWidth: 64,
                selWidth: 8,
              ),
            );
            final clk = SimpleClockGenerator(10).clk;
            final reset = Logic()..inject(1), ack = Logic()..inject(0);
            final rdata = Logic(width: 64)..inject(0);
            core.input('clk').srcConnection! <= clk;
            core.input('reset').srcConnection! <= reset;
            core.input('dataBus_ACK').srcConnection! <= ack;
            core.input('dataBus_DAT_MISO').srcConnection! <= rdata;
            await core.build();
            var rootReads = 0;
            final reads = <(int, int)>[];
            Future<void> tick() async {
              await clk.nextNegedge;
              if (ack.value.toBool()) {
                ack.inject(0);
                return;
              }
              if (!core.output('dataBus_CYC').value.toBool() ||
                  !core.output('dataBus_STB').value.toBool())
                return;
              final address = core.output('dataBus_ADR').value.toInt();
              final sel = core.output('dataBus_SEL').value.toInt();
              if (core.output('dataBus_WE').value.toBool()) {
                final value = core.output('dataBus_DAT_MOSI').value.toBigInt();
                for (var i = 0; i < 8; i++) {
                  if ((sel & (1 << i)) != 0)
                    put(address + i, value >> (8 * i), 1);
                }
              } else {
                var value = BigInt.zero;
                for (var i = 0; i < 8; i++) {
                  if ((sel & (1 << i)) != 0)
                    value |= get(address + i, 1) << (8 * i);
                }
                rdata.inject(value);
                if (address == 0x10010) rootReads++;
                if (address >= pa && address < pa + 0x100)
                  reads.add((address, sel));
              }
              ack.inject(1);
            }

            BigInt reg(int n) =>
                core.regs.getData(LogicValue.ofInt(n, 5))!.toBigInt();
            Simulator.setMaxSimTime(300000);
            unawaited(Simulator.run());
            try {
              await tick();
              await tick();
              reset.inject(0);
              for (
                var i = 0;
                i < 20000 &&
                    reg(30) != BigInt.from(0x66) &&
                    reg(29) != BigInt.from(0x7e);
                i++
              ) {
                await tick();
              }
              expect(
                reg(29),
                isNot(BigInt.from(0x7e)),
                reason: 'unexpected architectural trap',
              );
              expect(
                reg(30),
                BigInt.from(0x66),
                reason: 'program completed within the fixture bound',
              );
              expect(rootReads, greaterThan(0));
              for (final entry in expected.entries) {
                expect(reg(entry.key), entry.value, reason: 'x${entry.key}');
              }
              if (atomic) {
                expect(
                  get(pa, 8),
                  kind == 'atomic word'
                      ? (BigInt.from(0x246) << 32) |
                            (word & BigInt.from(0xffffffff))
                      : BigInt.from(0x246),
                );
              }
              if (vector) expect(get(pa + 0x100, 16), vectorWord);
              if (policy == 'RAM') {
                expect(reads, isNotEmpty);
                expect(reads.map((r) => r.$2), everyElement(0xff));
              } else if (policy != 'unknown values') {
                expect(
                  reads,
                  expectedReads,
                  reason:
                      'bypass retains exact operand widths and never refills adjacent I/O',
                );
              }
            } finally {
              await Simulator.endSimulation();
              await Simulator.simulationEnded;
            }
          },
        );
      }
    }
  }
}
