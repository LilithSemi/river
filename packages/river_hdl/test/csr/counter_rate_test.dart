import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Drives [RiscVCsrFile] directly to pin the RATE of mcycle and minstret.
///
/// test/csr/mcycle_increment_test.dart only proves the second read is larger
/// than the first. That passes at half rate, and it passes when minstret is a
/// second copy of the cycle counter, which is why both faults survived:
///
///  * mcycle counted at HALF the clock. The counter fed the backdoor write port
///    from its own backdoor READ through a Sequential, so the write value was a
///    flop output that rohd_hcl sampled one clock later, by which time the read
///    had not moved. The SAME value went out twice and the register advanced
///    once every two cycles. Measured on silicon: 10.000 MHz on a 20 MHz bus.
///  * minstret used the identical per-cycle expression, so it was a second
///    cycle counter. Measured on silicon: IPC exactly 1.000000.
///
/// A module-level test is used here because it can count clock edges exactly.
/// A core-level test cannot: River's csrrs microcode always executes its
/// WriteCsr step, even when rs1 is x0, so a plain `csrr mcycle` writes the
/// value it just read back into the register and rolls the count back by the
/// microstep distance between the read and the write.
void main() {
  const mcycle = 0xB00;
  const minstret = 0xB02;

  tearDown(() async {
    await Simulator.reset();
  });

  /// Builds a bare CSR file and returns it with the handles a test drives.
  Future<
    ({RiscVCsrFile csrs, Logic clk, Logic retire, DataPortInterface csrWrite})
  >
  build() async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final mode = Logic(name: 'mode', width: 3);
    final retire = Logic(name: 'retire');
    final csrRead = DataPortInterface(64, 12);
    final csrWrite = DataPortInterface(64, 12);

    final csrs = RiscVCsrFile(
      clk,
      reset,
      mode,
      mxlen: RiscVMxlen.rv64,
      misa: RiscVMxlen.rv64.misa,
      hasSupervisor: true,
      retire: retire,
      csrRead: csrRead,
      csrWrite: csrWrite,
    );
    await csrs.build();

    csrRead.en.inject(0);
    csrRead.addr.inject(0);
    csrWrite.en.inject(0);
    csrWrite.addr.inject(0);
    csrWrite.data.inject(0);
    retire.inject(0);
    mode.inject(3); // machine
    reset.inject(1);
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    return (csrs: csrs, clk: clk, retire: retire, csrWrite: csrWrite);
  }

  int read(RiscVCsrFile csrs, int addr) =>
      csrs.getData(LogicValue.ofInt(addr, 12))!.toInt();

  test('mcycle advances by one per clock, not one per two clocks', () async {
    final h = await build();

    final first = read(h.csrs, mcycle);
    const span = 40;
    for (var i = 0; i < span; i++) {
      await h.clk.nextPosedge;
    }
    final second = read(h.csrs, mcycle);

    expect(
      second - first,
      span,
      reason:
          'mcycle must advance once per clock. Half rate gives ${span ~/ 2}.',
    );

    // And again over a different span, so a fixed offset cannot pass.
    const span2 = 27;
    for (var i = 0; i < span2; i++) {
      await h.clk.nextPosedge;
    }
    expect(read(h.csrs, mcycle) - second, span2);

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  });

  test('minstret counts retires only, so it is not a cycle counter', () async {
    final h = await build();

    // No retire for a long stretch: minstret must not move while mcycle does.
    final cycStart = read(h.csrs, mcycle);
    final insStart = read(h.csrs, minstret);
    for (var i = 0; i < 30; i++) {
      await h.clk.nextPosedge;
    }
    expect(
      read(h.csrs, minstret) - insStart,
      0,
      reason: 'minstret must not move when nothing retires',
    );
    expect(
      read(h.csrs, mcycle) - cycStart,
      30,
      reason: 'mcycle keeps counting while minstret is still',
    );

    // Now retire 7 instructions, each one pulse, spaced by idle cycles. A
    // multi-cycle microcoded instruction gives exactly this shape: one pulse.
    const retires = 7;
    for (var i = 0; i < retires; i++) {
      h.retire.inject(1);
      await h.clk.nextPosedge;
      h.retire.inject(0);
      await h.clk.nextPosedge;
      await h.clk.nextPosedge;
    }
    expect(
      read(h.csrs, minstret) - insStart,
      retires,
      reason: 'minstret counts one per retire pulse',
    );
    expect(
      read(h.csrs, mcycle) - cycStart,
      30 + retires * 3,
      reason: 'mcycle counted every clock over the same window',
    );
    expect(
      read(h.csrs, minstret),
      isNot(equals(read(h.csrs, mcycle))),
      reason: 'minstret must not track mcycle',
    );

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  });

  test(
    'a software write to mcycle takes effect and counting resumes',
    () async {
      final h = await build();

      const seed = 0x4000;
      h.csrWrite.addr.inject(mcycle);
      h.csrWrite.data.inject(seed);
      h.csrWrite.en.inject(1);
      await h.clk.nextPosedge;
      h.csrWrite.en.inject(0);

      expect(
        read(h.csrs, mcycle),
        seed,
        reason: 'mcycle is read/write per the privileged spec',
      );

      const span = 12;
      for (var i = 0; i < span; i++) {
        await h.clk.nextPosedge;
      }
      expect(
        read(h.csrs, mcycle),
        seed + span,
        reason: 'counting continues from the written value at full rate',
      );

      await Simulator.endSimulation();
      await Simulator.simulationEnded;
    },
  );

  test(
    'a software write to minstret takes effect and counting resumes',
    () async {
      final h = await build();

      const seed = 0x1234;
      h.csrWrite.addr.inject(minstret);
      h.csrWrite.data.inject(seed);
      h.csrWrite.en.inject(1);
      await h.clk.nextPosedge;
      h.csrWrite.en.inject(0);

      expect(read(h.csrs, minstret), seed);

      // Idle cycles must not move it, then three retires must.
      for (var i = 0; i < 5; i++) {
        await h.clk.nextPosedge;
      }
      expect(read(h.csrs, minstret), seed);

      for (var i = 0; i < 3; i++) {
        h.retire.inject(1);
        await h.clk.nextPosedge;
        h.retire.inject(0);
        await h.clk.nextPosedge;
      }
      expect(
        read(h.csrs, minstret),
        seed + 3,
        reason: 'counting continues from the written value',
      );

      await Simulator.endSimulation();
      await Simulator.simulationEnded;
    },
  );
}
