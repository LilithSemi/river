import 'dart:async';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final xlen in [RiscVMxlen.rv32, RiscVMxlen.rv64]) {
    for (final microcoded in [false, true]) {
      for (final scenario in [
        'jal successor',
        'compressed successor',
        'edited dpc',
        'pending fetch',
      ]) {
        test(
          '${xlen.name} ${microcoded ? "microcoded" : "static"} halt $scenario',
          () async {
            final image = <int, int>{};
            void put(int address, int instruction, [int size = 4]) {
              for (var i = 0; i < size; i++) {
                image[address + i] = (instruction >> (8 * i)) & 255;
              }
            }

            put(0, 0x00000493); // li s1,0
            put(4, 0x00000013);
            final compressed = scenario == 'compressed successor';
            final branch = scenario == 'jal successor';
            final pending = scenario == 'pending fetch';
            put(
              8,
              branch
                  ? 0x018002ef
                  : compressed
                  ? 0x0485
                  : 0x00148493,
              compressed ? 2 : 4,
            );
            final successor = branch
                ? 32
                : compressed
                ? 10
                : 12;
            if (!branch) {
              put(successor, 0x01100913); // forbidden path when dpc is edited
              put(successor + 4, 0x0000006f);
            }
            put(32, 0x06600913);
            put(36, 0x0000006f);
            final clk = SimpleClockGenerator(10).clk;
            final reset = Logic()..inject(1);
            final halt = Logic()..inject(0), resume = Logic()..inject(0);
            final write = Logic()..inject(0),
                address = Logic(width: 16)..inject(0);
            final data = Logic(width: xlen.size)..inject(0);
            final ack = Logic()..inject(0),
                readData = Logic(width: xlen.size)..inject(0);
            final core = RiverCore(
              RiverCoreConfig(
                mxlen: xlen,
                type: RiverCoreType.general,
                extensions: [
                  rv32i,
                  if (xlen == RiscVMxlen.rv64) rv64i,
                  rvC,
                  rvZicsr,
                ],
                interrupts: [],
                resetVector: 0,
                microcodeMode: microcoded
                    ? MicrocodeMode.full
                    : MicrocodeMode.none,
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
            for (final entry in <String, Logic>{
              'clk': clk,
              'reset': reset,
              'debug_halt_req': halt,
              'debug_resume_req': resume,
              'debug_reg_write': write,
              'debug_reg_read': Const(0),
              'debug_reg_addr': address,
              'debug_reg_wdata': data,
              'dataBus_ACK': ack,
              'dataBus_DAT_MISO': readData,
            }.entries) {
              core.input(entry.key).srcConnection! <= entry.value;
            }
            await core.build();
            final completions = Logic(width: 8);
            final targetDone =
                core.pipeline.input('enable') &
                core.pipeline.done &
                ~core.pipeline.trap &
                core.pipeline.input('currentPc').eq(8);
            Sequential(clk, [
              If(
                reset,
                then: [completions < 0],
                orElse: [
                  If(targetDone, then: [completions < completions + 1]),
                ],
              ),
            ]);
            var release = !pending;
            var sawPendingFetch = false;
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
              if (!release && a == 8) {
                sawPendingFetch = true;
                return;
              }
              final base = a & ~(xlen.size ~/ 8 - 1);
              var value = BigInt.zero;
              for (var i = 0; i < xlen.size ~/ 8; i++) {
                value |= BigInt.from(image[base + i] ?? 0) << (8 * i);
              }
              readData.inject(value);
              ack.inject(1);
            }

            int reg(int n) =>
                core.regs.getData(LogicValue.ofInt(n, 5))!.toInt();
            bool halted() => core.output('debug_halted').value.toBool();
            Simulator.setMaxSimTime(200000);
            unawaited(Simulator.run());
            try {
              await tick();
              await tick();
              reset.inject(0);
              var reached = false;
              for (var i = 0; i < 2000; i++) {
                await tick();
                if (pending ? sawPendingFetch : targetDone.value.toBool()) {
                  reached = true;
                  break;
                }
              }
              expect(
                reached,
                isTrue,
                reason: 'reach the selected instruction boundary',
              );
              halt.inject(1);
              await tick();
              halt.inject(0);
              if (pending) {
                // A core may stop before this idempotent fetch or finish the
                // instruction. Do not withhold the completion it needs to drain.
                for (var i = 0; i < 10; i++) {
                  await tick();
                }
                release = true;
                for (var i = 0; i < 4; i++) {
                  await tick();
                }
              }
              for (var i = 0; i < 400 && !halted(); i++) {
                await tick();
              }
              expect(halted(), isTrue);
              final retiredAtHalt = completions.value.toInt();
              expect(retiredAtHalt, pending ? anyOf(0, 1) : equals(1));
              expect(
                core.output('debug_dpc').value.toInt(),
                pending && retiredAtHalt == 0 ? 8 : successor,
              );
              if (branch) {
                expect(
                  reg(5),
                  12,
                  reason: 'the branch retired its link register',
                );
              }
              if (compressed) {
                expect(
                  reg(9),
                  1,
                  reason: 'the compressed instruction retired once',
                );
              }
              final edit = pending || scenario == 'edited dpc';
              if (edit) {
                address.inject(0x7b1);
                data.inject(32);
                write.inject(1);
                await tick();
                write.inject(0);
                await tick();
                expect(core.output('debug_dpc').value.toInt(), 32);
              }
              resume.inject(1);
              await tick();
              resume.inject(0);
              release = true;
              for (var i = 0; i < 2000 && reg(18) == 0; i++) {
                await tick();
              }
              expect(reg(18), branch || edit ? 0x66 : 0x11);
              expect(
                completions.value.toInt(),
                retiredAtHalt,
                reason: 'no replay or stale-fetch retirement',
              );
              expect(reg(9), branch ? 0 : retiredAtHalt);
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
