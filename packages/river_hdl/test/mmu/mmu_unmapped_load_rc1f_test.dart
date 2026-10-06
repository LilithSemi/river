import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// A load from an UNMAPPED page must raise a load page fault (cause 13), and
/// must NOT hang the core.
///
/// This is the NULL-pointer-dereference case. On delta the kernel dereferenced a
/// NULL pointer in vfs_coredump (`ld a4,1280(a5)` with a5=0, fs/coredump.c:1099,
/// reached from get_signal) and the CORE FROZE ON THAT LOAD FOREVER instead of
/// faulting: PC pinned across 5 minutes of real runtime, single-step returning
/// "unable to resume hart 0", while the debug module's own bus reads still
/// worked. A normal RISC-V raises a load page fault there and the kernel prints
/// an oops. Because River hangs instead, a whole class of software bugs presents
/// as an unexplained silent wedge rather than a diagnosable crash.
///
/// mmu_fault_test covers a PERMISSION fault on a MAPPED page. Nothing covered an
/// INVALID leaf PTE, which is why this never surfaced in sim.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'rc1-f: Sv39 load from an UNMAPPED page raises loadPageFault (13)',
    timeout: Timeout(Duration(minutes: 5)),
    () async {
      // rc1-f (the delta core): full config WITH the split L1 caches and the
      // microcoded exec unit. The generic-core variant of this test passes, so
      // if this one hangs the defect is in the cache/exec path, not the MMU walk.
      final config = RiverCoreConfigV1.full(
        interrupts: [],
        mmu: HarborMmuConfig(
          mxlen: RiscVMxlen.rv64,
          pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
          hasSupervisorUserMemory: true,
          hasMakeExecutableReadable: true,
        ),
        clock: const HarborClockConfig(
          name: 'sysclk',
          rate: HarborFixedClockRate(48000000),
        ),
      );

      // csrw satp,a0 / lui a5,0x21 / ld a4,0(a5) / nop.
      // l0[0] @ 0x12000 keeps VA 0 mapped so instruction fetch works. l0[0x21]
      // (@ 0x12108) is deliberately ABSENT, so it reads back 0 = invalid PTE and
      // the load from VA 0x21000 must fault.
      const memString = '''@0
73 10 05 18 b7 17 02 00 03 b7 07 00 13 00 00 00
@10000
01 44 00 00 00 00 00 00
@11000
01 48 00 00 00 00 00 00
@12000
0F 00 00 00 00 00 00 00
''';

      final clk = SimpleClockGenerator(20).clk;
      final reset = Logic();
      final addrWidth = config.mxlen.size;
      final wbConfig = WishboneConfig(
        addressWidth: addrWidth,
        dataWidth: config.mxlen.size,
        selWidth: config.mxlen.size ~/ 8,
      );

      // Translation applies only in S/U mode (no MPRV in River), so the store
      // page-fault must be observed from S-mode, not the M-mode reset default.
      final core = RiverCore(
        config,
        busConfig: wbConfig,
        resetPrivilege: PrivilegeMode.supervisor.id,
      );
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
        core.regWritePort.en.inject(1);
        core.regWritePort.addr.inject(LogicValue.ofInt(10, 5));
        // satp: Sv39 (MODE 8) | root PPN 0x10.
        core.regWritePort.data.inject(LogicValue.ofInt(0x8000000000000010, 64));
        storage.loadMemString(memString);
      });
      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      core.regWritePort.en.inject(0);
      while (reset.value.toBool()) {
        await clk.nextPosedge;
      }

      var sawLoadFault = false;
      var sawForbiddenAccess = false;
      for (var i = 0; i < 3000; i++) {
        await clk.nextPosedge;
        // The translated write would target 0x30000, it must never happen.
        final adr = wbAdr.value;
        if (wbCyc.value.toInt() == 1 &&
            wbWe.value.toInt() == 1 &&
            adr.isValid &&
            adr.toInt() == 0x30000) {
          sawForbiddenAccess = true;
        }
        final trap = core.pipeline.trap.value;
        if (trap.isValid && trap.toInt() == 1) {
          final cause = core.pipeline.trapCause.value;
          expect(cause.isValid, isTrue, reason: 'trapCause invalid');
          expect(
            cause.toInt(),
            Trap.loadPageFault.causeCode,
            reason: 'expected loadPageFault (13), got ${cause.toInt()}',
          );
          sawLoadFault = true;
          break;
        }
      }

      await Simulator.endSimulation();
      await Simulator.simulationEnded;

      expect(
        sawLoadFault,
        isTrue,
        reason:
            'CORE HUNG: no loadPageFault raised for an unmapped-page load. '
            'This is the delta vfs_coredump NULL-deref freeze.',
      );
      expect(
        sawForbiddenAccess,
        isFalse,
        reason: 'faulting store must not write memory',
      );
    },
  );
}
