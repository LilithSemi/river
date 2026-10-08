import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

// Drives a withDebug core directly (no JTAG): halt, set dcsr.ebreakm, resume
// into `li a0,0x42 ; ebreak ; j _start`, and assert the core self-halts at the
// ebreak (debug_halted=1, dpc=4, a0=0x42).
void main() {
  tearDown(() async => Simulator.reset());

  test(
    'ebreak with dcsr.ebreakm enters debug',
    timeout: Timeout(Duration(seconds: 120)),
    () async {
      final config = RiverCoreConfigV1.small(
        mmu: HarborMmuConfig(
          mxlen: RiscVMxlen.rv64,
          pagingModes: const [RiscVPagingMode.bare],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
        ),
        interrupts: [],
        clock: const HarborClockConfig(
          name: 't',
          rate: HarborFixedClockRate(10000),
        ),
      );
      final aw = config.mxlen.size;
      final clk = SimpleClockGenerator(20).clk;
      final reset = Logic();
      final wbConfig = WishboneConfig(
        addressWidth: aw,
        dataWidth: aw,
        selWidth: aw ~/ 8,
      );
      final core = RiverCore(config, busConfig: wbConfig, withDebug: true);
      core.input('clk').srcConnection! <= clk;
      core.input('reset').srcConnection! <= reset;
      await core.build();

      final storage = SparseMemoryStorage(
        addrWidth: aw,
        dataWidth: aw,
        alignAddress: (a) => a,
        onInvalidRead: (a, w) => LogicValue.filled(w, LogicValue.zero),
      );
      final memRead = DataPortInterface(aw, aw);
      final memWrite = DataPortInterface(aw, aw);
      // ignore: unused_local_variable
      final mem = MemoryModel(
        clk,
        reset,
        [wrapWriteForRegisterFile(memWrite)],
        [wrapReadForRegisterFile(memRead)],
        storage: storage,
      );
      final wbCyc = core.output('dataBus_CYC'),
          wbStb = core.output('dataBus_STB');
      final wbWe = core.output('dataBus_WE'),
          wbAdr = core.output('dataBus_ADR');
      memRead.en <= wbCyc & wbStb & ~wbWe;
      memRead.addr <= wbAdr;
      memWrite.en <= wbCyc & wbStb & wbWe;
      memWrite.addr <= wbAdr;
      memWrite.data <= core.output('dataBus_DAT_MOSI');
      final wbAckReg = Logic();
      Sequential(clk, [
        If(
          reset,
          then: [wbAckReg < 0],
          orElse: [
            If(
              wbCyc & wbStb & ~wbAckReg & (wbWe | memRead.valid),
              then: [wbAckReg < 1],
              orElse: [wbAckReg < 0],
            ),
          ],
        ),
      ]);
      core.input('dataBus_ACK').srcConnection! <= wbAckReg;
      core.input('dataBus_DAT_MISO').srcConnection! <= memRead.data;

      // debug port drivers
      final dHalt = Logic(),
          dResume = Logic(),
          dRegRead = Logic(),
          dRegWrite = Logic();
      final dRegAddr = Logic(width: 16), dRegWdata = Logic(width: aw);
      core.input('debug_halt_req').srcConnection! <= dHalt;
      core.input('debug_resume_req').srcConnection! <= dResume;
      core.input('debug_reg_read').srcConnection! <= dRegRead;
      core.input('debug_reg_write').srcConnection! <= dRegWrite;
      core.input('debug_reg_addr').srcConnection! <= dRegAddr;
      core.input('debug_reg_wdata').srcConnection! <= dRegWdata;
      for (final s in [dHalt, dResume, dRegRead, dRegWrite]) {
        s.inject(0);
      }
      dRegAddr.inject(0);
      dRegWdata.inject(0);
      reset.inject(1);

      // Program at 0: li a0,0x42 ; ebreak ; j _start
      Simulator.registerAction(20, () {
        reset.put(0);
        storage.setData(
          LogicValue.ofInt(0, aw),
          LogicValue.ofBigInt(BigInt.parse('0010007304200513', radix: 16), aw),
        );
        storage.setData(
          LogicValue.ofInt(8, aw),
          LogicValue.ofBigInt(BigInt.parse('00000013ff9ff06f', radix: 16), aw),
        );
      });

      final halted = core.output('debug_halted');
      final dpc = core.output('debug_dpc');
      unawaited(Simulator.run());
      // let it come out of reset and run a bit
      for (var i = 0; i < 6; i++) {
        await clk.nextPosedge;
      }
      // halt
      dHalt.inject(1);
      await clk.nextPosedge;
      dHalt.inject(0);
      // A halt may finish the current ~80-cycle microcoded instruction.
      // Bound the acknowledgement, not an unsafe four-cycle abort latency.
      for (var i = 0; i < 400; i++) {
        await clk.nextPosedge;
        if (halted.value.toInt() == 1) break;
      }
      expect(
        halted.value.toInt(),
        1,
        reason: 'core should be halted by haltreq',
      );
      // write dcsr.ebreakm (0xb000) and dpc=0
      dRegWrite.inject(1);
      dRegAddr.inject(0x7b0);
      dRegWdata.inject(0xb000);
      await clk.nextPosedge;
      dRegAddr.inject(0x7b1);
      dRegWdata.inject(0);
      await clk.nextPosedge;
      dRegWrite.inject(0);
      await clk.nextPosedge;
      // resume
      dResume.inject(1);
      await clk.nextPosedge;
      dResume.inject(0);
      // run; expect self-halt on ebreak within N cycles
      var sawHalt = false;
      // The rc1-s microcode core is ~80-85 cyc/instr in this bare harness, so the
      // ebreak commits (self-halt) around cycle 166. The loop breaks on halt, so a
      // generous bound just avoids a premature give-up, it does not slow the pass.
      for (var i = 0; i < 400; i++) {
        await clk.nextPosedge;
        if (halted.value.isValid && halted.value.toInt() == 1) {
          sawHalt = true;
          break;
        }
      }
      final a0 = core.regs.getData(LogicValue.ofInt(10, 5));
      await Simulator.endSimulation();
      expect(
        sawHalt,
        true,
        reason: 'ebreak (ebreakm set) should re-enter debug',
      );
      // dpc latches the ebreak PC (0x4) and a0 holds the value set before it.
      expect(dpc.value.toInt(), 0x4);
      expect(a0!.toInt(), 0x42);
    },
  );
}
