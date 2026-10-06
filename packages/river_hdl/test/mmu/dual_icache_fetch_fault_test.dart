import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Instruction fetch to an unmapped Sv39 page on the DUAL-ISSUE (RC1.ma macro)
/// tier must raise an instruction page fault (cause 12), not hang the fetch.
///
/// The macro tier is the only tier with `issueWidth == IssueWidth.dual`, and
/// dual issue implies the out-of-order pipeline. The I-cache reported the fault
/// and the compressed fetch buffer held it, but the out-of-order commit stage
/// read no fetch fault at all, so the buffer re-presented the same faulting
/// slot every cycle and the core spun on the bad PC. This test holds the
/// front-end fault path for that tier.
///
/// The test asserts on the TRAP, not on the program finishing. A fault taken in
/// S-mode with medeleg = 0 goes to M-mode, where paging is off, so anything
/// after the faulting fetch runs on untranslated addresses and can look correct
/// even when translation never worked. The test therefore also keeps a positive
/// control: it watches the bus for the page-table reads of the faulting virtual
/// address. If the walk never happened, translation was not live and the run
/// proves nothing.
///
/// Program (M-mode setup, then S-mode). satp is COMPUTED, not seeded: the
/// backdoor regfile write does not reach the out-of-order physical regfile.
///
///   0x00 addi x10,x0,1 ; slli x10,x10,63 ; ori x10,x10,0x10 ; csrw satp,x10
///   0x10 addi x11,x0,0x30 ; csrw mepc,x11
///   0x18 addi x12,x0,1 ; slli x12,x12,11 (MPP=S) ; csrw mstatus,x12
///   0x24 addi x14,x0,0x50 ; csrw mtvec,x14
///   0x2c mret                            -> S-mode at 0x30
///   0x30 lui x13,0x8 ; jalr x0,0(x13)    -> fetch VIRTUAL 0x8000 (unmapped)
///   0x50 csrr x5,mcause ; jal loop       -> M-mode handler
///
/// Page tables (Sv39): L2[0]@0x10000 -> L1[0]@0x11000 -> L0[0]@0x12000, a leaf
/// that identity-maps virtual 0x0..0xfff. Virtual 0x8000 has VPN0 = 8, whose L0
/// entry at 0x12040 is zero, so the walk reaches the leaf level and faults.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  int csrw(int csr, int rs1) => (csr << 20) | (rs1 << 15) | (0x1 << 12) | 0x73;
  int csrr(int csr, int rd) => (csr << 20) | (0x2 << 12) | (rd << 7) | 0x73;
  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  int slli(int rd, int rs1, int sh) =>
      (sh << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x13;
  int ori(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13 | (0x6 << 12);
  int lui(int rd, int imm20) => (imm20 << 12) | (rd << 7) | 0x37;
  int jalr(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x67;
  const jalLoop = 0x0000006F;
  const nop = 0x00000013;

  String words(List<int> ws) {
    final sb = StringBuffer();
    for (final w in ws) {
      for (var b = 0; b < 4; b++) {
        sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return sb.toString().trimRight();
  }

  String pte(int v) {
    final sb = StringBuffer();
    for (var b = 0; b < 8; b++) {
      sb.write(((v >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
    return sb.toString().trimRight();
  }

  test(
    'dual-issue: fetch of an unmapped page traps (cause 12), does not hang',
    timeout: const Timeout(Duration(minutes: 20)),
    () async {
      final config = RiverCoreConfigV1.macro(
        clock: const HarborClockConfig(
          name: 'sysclk',
          rate: HarborFixedClockRate(48000000),
        ),
        interrupts: [],
        mmu: HarborMmuConfig(
          mxlen: RiscVMxlen.rv64,
          pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
          hasSupervisorUserMemory: true,
          hasMakeExecutableReadable: true,
        ),
      );

      final prog = words([
        addi(10, 0, 1), //     0 @0x00
        slli(10, 10, 63), //   1 @0x04
        ori(10, 10, 0x10), //  2 @0x08 satp = Sv39 | root PPN 0x10
        csrw(0x180, 10), //    3 @0x0c csrw satp, x10
        addi(11, 0, 0x30), //  4 @0x10
        csrw(0x341, 11), //    5 @0x14 csrw mepc, x11
        addi(12, 0, 1), //     6 @0x18
        slli(12, 12, 11), //   7 @0x1c MPP = supervisor
        csrw(0x300, 12), //    8 @0x20 csrw mstatus, x12
        addi(14, 0, 0x50), //  9 @0x24
        csrw(0x305, 14), //   10 @0x28 csrw mtvec, x14
        0x30200073, //        11 @0x2c mret -> S-mode, pc = 0x30
        lui(13, 0x8), //      12 @0x30 x13 = 0x8000 (unmapped page)
        jalr(0, 13, 0), //    13 @0x34 fetch 0x8000 -> instruction page fault
        nop, nop, nop, nop, nop, nop, // 14-19 @0x38..0x4c
        csrr(0x342, 5), //    20 @0x50 handler: x5 = mcause
        jalLoop, //           21 @0x54 loop
      ]);
      final memString =
          '@0\n$prog\n'
          '@10000\n${pte(0x4401)}\n'
          '@11000\n${pte(0x4801)}\n'
          '@12000\n${pte(0x000F)}\n';

      final clk = SimpleClockGenerator(20).clk;
      final reset = Logic();
      final addrWidth = config.mxlen.size;
      final wbConfig = WishboneConfig(
        addressWidth: addrWidth,
        dataWidth: config.mxlen.size,
        selWidth: config.mxlen.size ~/ 8,
      );

      final core = RiverCore(config, busConfig: wbConfig);
      core.input('clk').srcConnection! <= clk;
      core.input('reset').srcConnection! <= reset;
      await core.build();

      final storage = SparseMemoryStorage(
        addrWidth: addrWidth,
        dataWidth: config.mxlen.size,
        alignAddress: (addr) => addr,
        onInvalidRead: (addr, dataWidth) =>
            LogicValue.filled(dataWidth, LogicValue.zero),
      );

      final memRead = DataPortInterface(config.mxlen.size, addrWidth);
      final memWrite = DataPortInterface(config.mxlen.size, addrWidth);
      // ignore: unused_local_variable
      final mem = MemoryModel(
        clk,
        reset,
        [wrapWriteForRegisterFile(memWrite)],
        [wrapReadForRegisterFile(memRead, clk: clk, readLatency: 0)],
        readLatency: 0,
        storage: storage,
      );

      final wbCyc = core.output('dataBus_CYC');
      final wbStb = core.output('dataBus_STB');
      final wbWe = core.output('dataBus_WE');
      final wbAdr = core.output('dataBus_ADR');
      final wbDatMosi = core.output('dataBus_DAT_MOSI');

      memRead.en <= wbCyc & wbStb & ~wbWe;
      memRead.addr <= wbAdr;
      memWrite.en <= wbCyc & wbStb & wbWe;
      memWrite.addr <= wbAdr;
      memWrite.data <= wbDatMosi;

      final wbAckReg = Logic(name: 'wbAck');
      final readyForAck = wbWe | memRead.valid;
      Sequential(clk, [
        If(
          reset,
          then: [wbAckReg < 0],
          orElse: [
            If(
              wbCyc & wbStb & ~wbAckReg & readyForAck,
              then: [wbAckReg < 1],
              orElse: [wbAckReg < 0],
            ),
          ],
        ),
      ]);
      core.input('dataBus_ACK').srcConnection! <= wbAckReg;
      core.input('dataBus_DAT_MISO').srcConnection! <= memRead.data;

      reset.inject(1);
      Simulator.registerAction(20, () {
        reset.put(0);
        storage.loadMemString(memString);
      });
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());

      // An injected value only lands once the simulator ticks, so step the
      // clock until reset has really dropped.
      for (var i = 0; i < 100; i++) {
        await clk.nextPosedge;
        if (reset.value.isValid && !reset.value.toBool()) break;
      }

      // Positive control: the physical addresses of the Sv39 walk for the
      // faulting virtual address. 0x10000 is the root PTE, 0x12040 is the L0
      // entry for VPN0 = 8. Seeing them proves translation was live.
      const rootPte = 0x10000;
      const leafPte = 0x12040;
      final reads = <int>{};
      var trapCause = -1;

      for (var i = 0; i < 8000; i++) {
        await clk.nextPosedge;
        final cyc = wbCyc.value;
        final stb = wbStb.value;
        final we = wbWe.value;
        // The bus is unknown for the first cycles out of reset, so only sample
        // a settled read.
        if (cyc.isValid &&
            stb.isValid &&
            we.isValid &&
            cyc.toBool() &&
            stb.toBool() &&
            !we.toBool() &&
            wbAdr.value.isValid) {
          reads.add(wbAdr.value.toInt());
        }
        final trap = core.pipeline.trap.value;
        if (trapCause < 0 && trap.isValid && trap.toBool()) {
          final cause = core.pipeline.trapCause.value;
          expect(
            cause.isValid,
            isTrue,
            reason: 'trapCause invalid at the trap',
          );
          trapCause = cause.toInt();
        }
        if (trapCause >= 0 && reads.contains(leafPte)) break;
      }

      await Simulator.endSimulation();
      await Simulator.simulationEnded;

      // The walk must have run, else paging never engaged and the trap (or the
      // absence of one) says nothing about the fetch-fault path.
      expect(
        reads.contains(rootPte),
        isTrue,
        reason:
            'no read of the Sv39 root page table at '
            '0x${rootPte.toRadixString(16)}: translation was never live',
      );
      expect(
        reads.contains(leafPte),
        isTrue,
        reason:
            'no read of the L0 entry at 0x${leafPte.toRadixString(16)}: the '
            'walk of the unmapped virtual address never reached the leaf level',
      );
      expect(
        trapCause,
        Trap.instructionPageFault.causeCode,
        reason: trapCause < 0
            ? 'no trap at all: the dual-issue fetch hung on the faulting refill'
            : 'expected instructionPageFault (12), got $trapCause',
      );
    },
  );
}
