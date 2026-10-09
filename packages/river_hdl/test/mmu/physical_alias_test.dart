import 'dart:async';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final microcoded in [false, true]) {
    for (final (cached, remap, device) in [
      (false, false, false),
      (true, false, false),
      (false, true, false),
      (true, true, false),
      (false, false, true),
      (true, false, true),
    ]) {
      test(
        'Sv39 ${microcoded ? "microcoded" : "static"} cached=$cached ${device
            ? "physical MMIO"
            : remap
            ? "new ASID and root"
            : "store through a physical alias"}',
        () async {
          final pa = device ? 0x200000 : 0x80010000;
          final image = <int, int>{};
          void put(int address, BigInt value, int bytes) {
            for (var i = 0; i < bytes; i++) {
              image[address + i] = ((value >> (8 * i)) & BigInt.from(255))
                  .toInt();
            }
          }

          final program = [
            0x00100293, 0x03f29293, 0x01028293, // t0 = Sv39 | root PPN
            0x00021337, 0x80030313, // t1 = MPRV | MPP=S
            0x00100393, 0x01f39393, // t2 = 0x80000000
            0x00001437, 0x00740433, // s0 = t2 + 4096
            0x222224b7, 0x22248493, // s1 = 0x22222222
            0x18029073, // csrw satp,t0
            0x30031073, // csrw mstatus,t1 (MPRV, MPP=S)
            0x0003a503, // lw a0,0(t2): VA 0x80000000
            device
                ? 0x00000013
                : remap
                ? 0x0003a603
                : 0x00042603, // keep A hot, or read its B alias
            if (remap) ...[
              0x00100693, 0x02c69693, // a3 = ASID 1 << 44
              0x00d282b3, 0x00328293, // t0 = Sv39 | ASID 1 | new root PPN 0x13
              0x18029073,
              0x18002773, // select new address space; read back satp
            ] else
              device ? 0x00000013 : 0x00942023, // sw s1,0(s0)
            0x0003a583, // lw a1,0(t2): must see our preceding store
            0x06600913, // completion marker
            0x0000006f,
          ];
          for (var i = 0; i < program.length; i++) {
            put(4 * i, BigInt.from(program[i]), 4);
          }
          put(0x10010, BigInt.from((0x11 << 10) | 1), 8);
          put(0x11000, BigInt.from((0x12 << 10) | 1), 8);
          for (final pte in [0x12000, 0x12008]) {
            put(pte, BigInt.from(((pa >> 12) << 10) | 0xc7), 8);
          }
          put(pa, BigInt.from(0x11111111), 8);
          put(0x13010, BigInt.from((0x14 << 10) | 1), 8);
          put(0x14000, BigInt.from((0x15 << 10) | 1), 8);
          put(0x15000, BigInt.from(((0x80020000 >> 12) << 10) | 0xc7), 8);
          put(0x80020000, BigInt.from(0x22222222), 8);
          final core = RiverCore(
            RiverCoreConfig(
              mxlen: RiscVMxlen.rv64,
              type: RiverCoreType.general,
              extensions: [rv32i, rv64i, rvZicsr, rvPriv],
              interrupts: [],
              resetVector: 0,
              microcodeMode: microcoded
                  ? MicrocodeMode.full
                  : MicrocodeMode.none,
              l1cache: cached
                  ? const HarborL1CacheConfig.unified(
                      HarborL1dCacheConfig(size: 4096, ways: 1, lineSize: 16),
                    )
                  : null,
              mmu: HarborMmuConfig(
                mxlen: RiscVMxlen.rv64,
                pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
                tlbLevels: const [],
                pmp: HarborPmpConfig.none,
                pma: const HarborPmaConfig(
                  regions: [
                    HarborPmaRegion.memory(start: 0, size: 0x20000),
                    HarborPmaRegion.io(start: 0x200000, size: 0x1000),
                    HarborPmaRegion.memory(start: 0x80000000, size: 0x10000000),
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
          final reset = Logic()..inject(1);
          final ack = Logic()..inject(0), rdata = Logic(width: 64)..inject(0);
          core.input('clk').srcConnection! <= clk;
          core.input('reset').srcConnection! <= reset;
          core.input('dataBus_ACK').srcConnection! <= ack;
          core.input('dataBus_DAT_MISO').srcConnection! <= rdata;
          await core.build();
          var rootReads = 0, stores = 0, dataReads = 0;
          final deviceReads = <(int, int)>[];
          Future<void> tick() async {
            await clk.nextNegedge;
            if (ack.value.toBool()) {
              ack.inject(0);
              return;
            }
            if (!core.output('dataBus_CYC').value.toBool() ||
                !core.output('dataBus_STB').value.toBool()) {
              return;
            }
            final a = core.output('dataBus_ADR').value.toInt();
            final lanes = core.output('dataBus_SEL').value.toInt();
            if (core.output('dataBus_WE').value.toBool()) {
              final value = core.output('dataBus_DAT_MOSI').value.toBigInt();
              for (var i = 0; i < 8; i++) {
                if ((lanes & (1 << i)) != 0) {
                  image[a + i] = ((value >> (8 * i)) & BigInt.from(255))
                      .toInt();
                }
              }
              if (a == pa) stores++;
            } else {
              var value = BigInt.zero;
              for (var i = 0; i < 8; i++) {
                if ((lanes & (1 << i)) != 0) {
                  value |= BigInt.from(image[a + i] ?? 0) << (8 * i);
                }
              }
              if (device && a >= pa && a < pa + 0x1000) {
                deviceReads.add((a, lanes));
              }
              if (a == pa) {
                dataReads++;
                if (device) value = BigInt.from(0x11111111 * dataReads);
              }
              rdata.inject(value);
              if (a == 0x10010) rootReads++;
            }
            ack.inject(1);
          }

          int reg(int n) => core.regs.getData(LogicValue.ofInt(n, 5))!.toInt();
          Simulator.setMaxSimTime(100000);
          unawaited(Simulator.run());
          try {
            await tick();
            await tick();
            reset.inject(0);

            for (var i = 0; i < 4000 && reg(18) != 0x66; i++) {
              await tick();
            }
            expect(
              reg(18),
              0x66,
              reason: 'program completed, not a fixture timeout',
            );
            expect(
              rootReads,
              greaterThan(0),
              reason: 'Sv39 translation was actually active',
            );
            expect(reg(10), 0x11111111);
            if (!device) expect(reg(12), 0x11111111);
            expect(stores, remap || device ? 0 : 1);
            if (remap) {
              expect(
                (reg(14) >> 44) & 0xffff,
                1,
                reason: 'the new ASID is implemented and retained',
              );
            }
            if (device) {
              expect(
                deviceReads,
                [(pa, 15), (pa, 15)],
                reason:
                    'exactly two requested device reads, no cache refill traffic',
              );
            }
            expect(
              reg(11),
              0x22222222,
              reason:
                  'a load must use its current physical mapping and observe prior stores; RAM reads=$dataReads',
            );
          } finally {
            await Simulator.endSimulation();
            await Simulator.simulationEnded;
          }
        },
      );
    }
  }
}
