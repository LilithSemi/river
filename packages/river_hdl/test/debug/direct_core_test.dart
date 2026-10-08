import 'dart:async';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final xlen in [RiscVMxlen.rv32, RiscVMxlen.rv64]) {
    for (final latency in [0, 1]) {
      test('${xlen.name} direct core register latency $latency', () async {
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic()..inject(1);
        final request = Logic()..inject(0), write = Logic()..inject(0);
        final address = Logic(width: 7)..inject(0),
            data = Logic(width: 32)..inject(0);
        final ack = Logic()..inject(0),
            memoryData = Logic(width: xlen.size)..inject(0);
        final core = RiverCore(
          RiverCoreConfig(
            mxlen: xlen,
            type: RiverCoreType.general,
            extensions: [rv32i, if (xlen == RiscVMxlen.rv64) rv64i, rvZicsr],
            interrupts: [],
            resetVector: 0,
            regfileReadLatency: latency == 0 ? null : latency,
            microcodeMode: latency == 0
                ? MicrocodeMode.none
                : MicrocodeMode.full,
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
          busConfig: WishboneConfig(
            addressWidth: xlen.size,
            dataWidth: xlen.size,
          ),
        );
        final dm = RiverDebugModule(
          clk,
          reset,
          Const(0),
          Const(0),
          Const(0),
          Const(1),
          xlen: xlen.size,
          directDmi: true,
          dmiRequest: request,
          dmiWrite: write,
          dmiAddress: address,
          dmiWriteData: data,
          hartHalted: core.output('debug_halted'),
          regReady: core.output('debug_reg_ready'),
          regRdata: core.output('debug_reg_rdata'),
        );
        for (final e in <String, Logic>{
          'clk': clk,
          'reset': reset,
          'debug_halt_req': dm.haltReq,
          'debug_resume_req': dm.resumeReq,
          'debug_reg_read': dm.regRead,
          'debug_reg_write': dm.regWrite,
          'debug_reg_addr': dm.regAddr,
          'debug_reg_wdata': dm.regWdata,
          'dataBus_ACK': ack,
          'dataBus_DAT_MISO': memoryData,
        }.entries) {
          core.input(e.key).srcConnection! <= e.value;
        }
        final response = Logic(width: 32);
        Sequential(clk, [
          If(request & ~write, then: [response < dm.dmiRdata]),
        ]);
        await core.build();
        await dm.build();
        final program = {
          0: 0x00100293,
          4: 0x00128293,
          8: 0xffdff06f,
          32: 0x00128313,
          36: 0x0000006f,
        };
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
          final base =
              core.output('dataBus_ADR').value.toInt() & ~(xlen.size ~/ 8 - 1);
          var word = BigInt.zero;
          for (var i = 0; i < xlen.size ~/ 8; i++) {
            final a = base + i;
            word |=
                BigInt.from(((program[a & ~3] ?? 0) >> (8 * (a & 3))) & 255) <<
                (8 * i);
          }
          memoryData.inject(word);
          ack.inject(1);
        }

        Future<int> access(int addr, [int? value]) async {
          address.inject(addr);
          data.inject(value ?? 0);
          write.inject(value == null ? 0 : 1);
          request.inject(1);
          await tick();
          request.inject(0);
          return value == null ? response.value.toInt() : 0;
        }

        Future<void> waitHalted() async {
          for (var i = 0; i < 2000; i++) {
            if (((await access(0x11)) & (1 << 9)) != 0) return;
          }
          fail('core did not acknowledge halt');
        }

        Future<int> reg(int number, [int? value]) async {
          if (value != null) await access(0x04, value);
          await access(
            0x17,
            ((xlen.size == 64 ? 3 : 2) << 20) |
                (1 << 17) |
                (value == null ? 0 : 1 << 16) |
                number,
          );
          var completed = false;
          for (var i = 0; i < 100; i++) {
            final status = await access(0x16);
            expect((status >> 8) & 7, 0);
            if ((status & (1 << 12)) == 0) {
              completed = true;
              break;
            }
          }
          expect(completed, isTrue);
          return access(0x04);
        }

        Simulator.setMaxSimTime(200000);
        unawaited(Simulator.run());
        try {
          await tick();
          await tick();
          reset.inject(0);
          for (var i = 0; i < 80; i++) {
            await tick();
          }
          await access(0x10, 1);
          expect((await access(0x10)) & 1, 1);
          await access(0x10, 0x80000001);
          await waitHalted();
          await reg(0x1005, 0x55);
          expect(await reg(0x1005), 0x55);
          await reg(0x7b1, 32);
          expect(await reg(0x7b1), 32);
          await access(0x10, 0x40000001);
          var resumed = false;
          for (var i = 0; i < 100; i++) {
            if (((await access(0x11)) & 0x30c00) == 0x30c00) {
              resumed = true;
              break;
            }
          }
          expect(
            resumed,
            isTrue,
            reason: 'running and actual resume acknowledged',
          );
          for (var i = 0; i < 500; i++) {
            await tick();
          }
          await access(0x10, 0x80000001);
          await waitHalted();
          expect(await reg(0x1005), 0x55);
          expect(
            await reg(0x1006),
            0x56,
            reason: 'execute edited dpc using the edited GPR',
          );
          expect((await access(0x11)) & 0x30000, 0x30000);
        } finally {
          await Simulator.endSimulation();
          await Simulator.simulationEnded;
        }
      });
    }
  }
}
