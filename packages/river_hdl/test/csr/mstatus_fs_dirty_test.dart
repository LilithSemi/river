import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// mstatus.FS (bits 14:13) and mstatus.SD (bit 63 on RV64).
///
/// Linux saves the FP context on a context switch ONLY when FS reads Dirty
/// (`regs->status & SR_FS_DIRTY`). River never set FS, so the context was never
/// saved and a task resumed with the FP registers of another task.
///
/// FS is supplied on the READ path, like the PLIC line in mip.SEIP. It is NOT
/// written into the register. A first attempt DID write it, by adding an
/// "FP write is dirty" term to the single mstatus backdoor writer in
/// _wireTrapState. That writer takes its value from the backdoor READ, which is
/// one cycle behind, so an FP register write in the cycle after an sret wrote
/// the PRE-sret mstatus back and silently undid the SIE/SPIE update. The last
/// test below is that exact case.
void main() {
  const mstatus = 0x300;
  const sstatus = 0x100;

  // mstatus field positions used here.
  const sieBit = 1;
  const spieBit = 5;
  const fsShift = 13;
  const sdBit = 63;

  final fsMask = BigInt.from(3) << fsShift;
  final sdMask = BigInt.one << sdBit;

  tearDown(() async {
    await Simulator.reset();
  });

  Future<
    ({
      RiscVCsrFile csrs,
      Logic clk,
      Logic fpDirty,
      Logic returnActive,
      Logic returnFromM,
      Logic trapActive,
      DataPortInterface csrRead,
      DataPortInterface csrWrite,
    })
  >
  build() async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final mode = Logic(name: 'mode', width: 3);
    final fpDirty = Logic(name: 'fpDirty');
    final trapActive = Logic(name: 'trapActive');
    final trapTargetIsM = Logic(name: 'trapTargetIsM');
    final trapPc = Logic(name: 'trapPc', width: 64);
    final trapCauseVal = Logic(name: 'trapCauseVal', width: 64);
    final trapTval = Logic(name: 'trapTval', width: 64);
    final returnActive = Logic(name: 'returnActive');
    final returnFromM = Logic(name: 'returnFromM');
    final csrRead = DataPortInterface(64, 12);
    final csrWrite = DataPortInterface(64, 12);

    final csrs = RiscVCsrFile(
      clk,
      reset,
      mode,
      mxlen: RiscVMxlen.rv64,
      // F and D set, so mstatus carries the FS field.
      misa: RiscVMxlen.rv64.misa | (1 << 3) | (1 << 5),
      hasSupervisor: true,
      hasUser: true,
      fpDirty: fpDirty,
      trapActive: trapActive,
      trapTargetIsM: trapTargetIsM,
      trapPc: trapPc,
      trapCauseVal: trapCauseVal,
      trapTval: trapTval,
      returnActive: returnActive,
      returnFromM: returnFromM,
      csrRead: csrRead,
      csrWrite: csrWrite,
    );
    await csrs.build();

    csrRead.en.inject(0);
    csrRead.addr.inject(0);
    csrWrite.en.inject(0);
    csrWrite.addr.inject(0);
    csrWrite.data.inject(0);
    fpDirty.inject(0);
    trapActive.inject(0);
    trapTargetIsM.inject(0);
    trapPc.inject(0);
    trapCauseVal.inject(0);
    trapTval.inject(0);
    returnActive.inject(0);
    returnFromM.inject(0);
    mode.inject(3); // machine
    reset.inject(1);
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    return (
      csrs: csrs,
      clk: clk,
      fpDirty: fpDirty,
      returnActive: returnActive,
      returnFromM: returnFromM,
      trapActive: trapActive,
      csrRead: csrRead,
      csrWrite: csrWrite,
    );
  }

  test('an FP register write makes mstatus.FS and SD read Dirty', () async {
    final h = await build();

    Future<BigInt> readCsr(int addr) async {
      h.csrRead.addr.inject(addr);
      h.csrRead.en.inject(1);
      await h.clk.nextPosedge;
      final d = h.csrRead.data.value.toBigInt();
      h.csrRead.en.inject(0);
      return d;
    }

    expect(
      (await readCsr(mstatus)) & fsMask,
      BigInt.zero,
      reason: 'FS starts Off',
    );

    // One retiring FP register write.
    h.fpDirty.inject(1);
    await h.clk.nextPosedge;
    h.fpDirty.inject(0);
    await h.clk.nextPosedge;

    final m = await readCsr(mstatus);
    expect(
      (m & fsMask) >> fsShift,
      BigInt.from(3),
      reason: 'FS must read Dirty after an FP register write',
    );
    expect(
      m & sdMask,
      sdMask,
      reason: 'SD is the summary bit: it must follow FS=Dirty',
    );

    // It is STICKY: it stays Dirty on later cycles with no FP write.
    for (var i = 0; i < 5; i++) {
      await h.clk.nextPosedge;
    }
    expect(((await readCsr(mstatus)) & fsMask) >> fsShift, BigInt.from(3));

    // FS must come from the READ path, so the REGISTER itself must not have
    // been written. A second mstatus writer is what broke the earlier attempt.
    // The raw backdoor value is the register, with no overlay on it.
    final raw = h.csrs.getData(LogicValue.ofInt(mstatus, 12))!.toBigInt();
    expect(
      (raw & fsMask) >> fsShift,
      BigInt.zero,
      reason: 'an FP write must NOT write the mstatus register',
    );

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  });

  test('sstatus and mstatus agree on FS and SD', () async {
    final h = await build();

    Future<BigInt> readCsr(int addr, int modeId) async {
      h.csrRead.addr.inject(addr);
      h.csrRead.en.inject(1);
      await h.clk.nextPosedge;
      final d = h.csrRead.data.value.toBigInt();
      h.csrRead.en.inject(0);
      return d;
    }

    h.fpDirty.inject(1);
    await h.clk.nextPosedge;
    h.fpDirty.inject(0);
    await h.clk.nextPosedge;

    final m = await readCsr(mstatus, 3);
    final s = await readCsr(sstatus, 3);
    expect((m & fsMask) >> fsShift, BigInt.from(3));
    expect(
      (s & fsMask) >> fsShift,
      (m & fsMask) >> fsShift,
      reason: 'sstatus is a VIEW of mstatus, so FS must be the same bits',
    );
    expect(s & sdMask, m & sdMask, reason: 'SD must agree too');

    // The output ports the core reads must agree with the frontdoor reads.
    expect(
      (h.csrs.mstatus.value.toBigInt() & fsMask) >> fsShift,
      BigInt.from(3),
    );
    expect(
      (h.csrs.sstatus!.value.toBigInt() & fsMask) >> fsShift,
      BigInt.from(3),
    );

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  });

  test('software clears FS by writing a new FS value', () async {
    final h = await build();

    Future<BigInt> readCsr(int addr) async {
      h.csrRead.addr.inject(addr);
      h.csrRead.en.inject(1);
      await h.clk.nextPosedge;
      final d = h.csrRead.data.value.toBigInt();
      h.csrRead.en.inject(0);
      return d;
    }

    Future<void> writeCsr(int addr, BigInt data) async {
      h.csrWrite.addr.inject(addr);
      h.csrWrite.data.inject(LogicValue.ofBigInt(data, 64));
      h.csrWrite.en.inject(1);
      await h.clk.nextPosedge;
      h.csrWrite.en.inject(0);
      await h.clk.nextPosedge;
    }

    h.fpDirty.inject(1);
    await h.clk.nextPosedge;
    h.fpDirty.inject(0);
    await h.clk.nextPosedge;
    expect(((await readCsr(mstatus)) & fsMask) >> fsShift, BigInt.from(3));

    // FS <- Clean (2). This is what the OS writes after it saves the context.
    await writeCsr(mstatus, BigInt.from(2) << fsShift);
    final afterClean = await readCsr(mstatus);
    expect(
      (afterClean & fsMask) >> fsShift,
      BigInt.from(2),
      reason: 'a software FS write must stick, not be held Dirty forever',
    );
    expect(
      afterClean & sdMask,
      BigInt.zero,
      reason: 'SD drops when nothing is Dirty',
    );

    // A later FP write makes it Dirty again.
    h.fpDirty.inject(1);
    await h.clk.nextPosedge;
    h.fpDirty.inject(0);
    await h.clk.nextPosedge;
    expect(((await readCsr(mstatus)) & fsMask) >> fsShift, BigInt.from(3));

    // The same, through the sstatus name.
    await writeCsr(sstatus, BigInt.from(1) << fsShift); // FS <- Initial
    expect(
      ((await readCsr(mstatus)) & fsMask) >> fsShift,
      BigInt.from(1),
      reason: 'an sstatus FS write reaches the same state as an mstatus one',
    );

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  });

  test('an FP write right after sret does not undo the SIE/SPIE pop', () async {
    final h = await build();

    Future<BigInt> readCsr(int addr) async {
      h.csrRead.addr.inject(addr);
      h.csrRead.en.inject(1);
      await h.clk.nextPosedge;
      final d = h.csrRead.data.value.toBigInt();
      h.csrRead.en.inject(0);
      return d;
    }

    // Pre-sret state: SIE=0, SPIE=1. An sret must give SIE=1, SPIE=1.
    h.csrWrite.addr.inject(mstatus);
    h.csrWrite.data.inject(LogicValue.ofBigInt(BigInt.one << spieBit, 64));
    h.csrWrite.en.inject(1);
    await h.clk.nextPosedge;
    h.csrWrite.en.inject(0);
    await h.clk.nextPosedge;

    final before = await readCsr(mstatus);
    expect((before >> sieBit) & BigInt.one, BigInt.zero);
    expect((before >> spieBit) & BigInt.one, BigInt.one);

    // The sret retires.
    h.returnActive.inject(1);
    h.returnFromM.inject(0);
    await h.clk.nextPosedge;
    h.returnActive.inject(0);

    // The very next cycle an FP register write retires. With the earlier
    // write-path attempt this drove the mstatus backdoor with the STALE
    // backdoor read, which is the pre-sret value, and SIE went back to 0.
    // __fstate_restore does this 32 times in a row.
    h.fpDirty.inject(1);
    await h.clk.nextPosedge;
    h.fpDirty.inject(0);
    await h.clk.nextPosedge;

    final after = await readCsr(mstatus);
    expect(
      (after >> sieBit) & BigInt.one,
      BigInt.one,
      reason: 'sret set SIE from SPIE; an FP write must not undo it',
    );
    expect(
      (after >> spieBit) & BigInt.one,
      BigInt.one,
      reason: 'sret sets SPIE to 1',
    );
    expect(
      (after & fsMask) >> fsShift,
      BigInt.from(3),
      reason: 'and the FP write still made FS Dirty',
    );

    // Repeat 32 times, the __fstate_restore shape, with an sret in front.
    for (var i = 0; i < 32; i++) {
      h.fpDirty.inject(1);
      await h.clk.nextPosedge;
    }
    h.fpDirty.inject(0);
    await h.clk.nextPosedge;
    final afterBurst = await readCsr(mstatus);
    expect((afterBurst >> sieBit) & BigInt.one, BigInt.one);
    expect((afterBurst >> spieBit) & BigInt.one, BigInt.one);

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  });
}
