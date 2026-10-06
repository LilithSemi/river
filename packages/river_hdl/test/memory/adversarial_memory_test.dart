import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:test/test.dart';

import '../adversarial_memory.dart';

/// Unit tests for the adversarial memory. They pin the behaviour the core-level
/// tests depend on, and they are also the mutation evidence for it: each
/// ordering rule is shown to hold AND is shown to break when the matching
/// switch is set.
///
/// The master here is a plain Dart Wishbone classic master. It samples on the
/// NEGATIVE edge, in the middle of the cycle, so there is no race with the
/// slave, which drives on the positive edge.
void main() {
  late Logic clk;
  late Logic reset;
  late Logic cyc;
  late Logic stb;
  late Logic we;
  late Logic adr;
  late Logic mosi;
  late Logic sel;
  late Logic ack;
  late Logic miso;
  late SparseMemoryStorage storage;

  /// Builds a slave with [behaviour] and starts the simulator.
  Future<AdversarialWishboneSlave> makeSlave(
    AdversarialMemory behaviour,
  ) async {
    await Simulator.reset();
    clk = SimpleClockGenerator(20).clk;
    reset = Logic(name: 'reset');
    cyc = Logic(name: 'cyc');
    stb = Logic(name: 'stb');
    we = Logic(name: 'we');
    adr = Logic(name: 'adr', width: 64);
    mosi = Logic(name: 'mosi', width: 64);
    sel = Logic(name: 'sel', width: 8);
    ack = Logic(name: 'ack');
    miso = Logic(name: 'miso', width: 64);
    storage = SparseMemoryStorage(
      addrWidth: 64,
      dataWidth: 64,
      alignAddress: (a) => a,
      onInvalidRead: (a, w) => LogicValue.filled(w, LogicValue.zero),
    );
    reset.inject(0);
    cyc.inject(0);
    stb.inject(0);
    we.inject(0);
    adr.inject(0);
    mosi.inject(0);
    sel.inject(0xFF);
    final slave = attachAdversarialMemory(
      clk: clk,
      reset: reset,
      storage: storage,
      dataWidth: 64,
      cyc: cyc,
      stb: stb,
      we: we,
      adr: adr,
      datMosi: mosi,
      ack: ack,
      miso: miso,
      sel: sel,
      behaviour: behaviour,
    );
    Simulator.setMaxSimTime(1000000);
    unawaited(Simulator.run());
    await clk.nextNegedge;
    return slave;
  }

  /// One Wishbone transaction. Returns the number of cycles from the request to
  /// the acknowledge, or -1 if [limit] cycles pass with no acknowledge.
  Future<int> xact({
    required bool write,
    required int addr,
    int data = 0,
    int limit = 60,
  }) async {
    cyc.inject(1);
    stb.inject(1);
    we.inject(write ? 1 : 0);
    adr.inject(LogicValue.ofInt(addr, 64));
    mosi.inject(LogicValue.ofInt(data, 64));
    var n = 0;
    var acked = false;
    while (n < limit) {
      await clk.nextNegedge;
      n++;
      if (ack.value.isValid && ack.value.toBool()) {
        acked = true;
        break;
      }
    }
    cyc.inject(0);
    stb.inject(0);
    await clk.nextNegedge;
    return acked ? n : -1;
  }

  /// The value the last read returned.
  int lastRead() => miso.value.toInt();

  Future<void> idle(int cycles) async {
    for (var i = 0; i < cycles; i++) {
      await clk.nextNegedge;
    }
  }

  Future<void> stop() async {
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }

  tearDown(() async {
    await Simulator.reset();
  });

  test('default behaviour acknowledges one cycle after the request', () async {
    await makeSlave(const AdversarialMemory());
    storage.setData(LogicValue.ofInt(0x100, 64), LogicValue.ofInt(0xABCD, 64));
    expect(await xact(write: false, addr: 0x100), 1);
    expect(lastRead(), 0xABCD);
    await stop();
  });

  test(
    'read latency delays the acknowledge by exactly that many cycles',
    () async {
      await makeSlave(const AdversarialMemory(readLatency: 4));
      storage.setData(
        LogicValue.ofInt(0x100, 64),
        LogicValue.ofInt(0xABCD, 64),
      );
      expect(await xact(write: false, addr: 0x100), 5);
      expect(lastRead(), 0xABCD);
      await stop();
    },
  );

  test('a gap holds the second transaction off the bus', () async {
    final slave = await makeSlave(const AdversarialMemory(minGapCycles: 3));
    expect(await xact(write: false, addr: 0x100), 1);
    // The gap adds its cycles on top of the one-cycle baseline.
    expect(await xact(write: false, addr: 0x108), 4);
    expect(slave.reads, 2);
    await stop();
  });

  test('a write commits at the acknowledge when nothing is posted', () async {
    await makeSlave(const AdversarialMemory());
    expect(await xact(write: true, addr: 0x200, data: 0x1234), 1);
    expect(storage.getData(LogicValue.ofInt(0x200, 64))!.toInt(), 0x1234);
    await stop();
  });

  test('a posted write is acknowledged before it is visible', () async {
    final slave = await makeSlave(
      const AdversarialMemory(postedWriteCycles: 8),
    );
    storage.setData(LogicValue.ofInt(0x200, 64), LogicValue.ofInt(0x11, 64));
    expect(await xact(write: true, addr: 0x200, data: 0x1234), 1);
    expect(slave.pendingWrites, 1);
    expect(storage.getData(LogicValue.ofInt(0x200, 64))!.toInt(), 0x11);
    await idle(12);
    expect(slave.pendingWrites, 0);
    expect(storage.getData(LogicValue.ofInt(0x200, 64))!.toInt(), 0x1234);
    await stop();
  });

  test('by default a read waits for the whole posted queue to drain', () async {
    final slave = await makeSlave(
      const AdversarialMemory(postedWriteCycles: 8),
    );
    storage.setData(LogicValue.ofInt(0x300, 64), LogicValue.ofInt(0x77, 64));
    await xact(write: true, addr: 0x200, data: 0x1234);
    // A read of an UNRELATED address still waits, because the memory keeps
    // total order unless it is told it may reorder.
    final cycles = await xact(write: false, addr: 0x300);
    expect(cycles, greaterThan(1));
    expect(lastRead(), 0x77);
    expect(slave.orderStallCycles, greaterThan(0));
    await stop();
  });

  test(
    'readsPassPendingWrites lets an unrelated read overtake a posted write',
    () async {
      final slave = await makeSlave(
        const AdversarialMemory(
          postedWriteCycles: 8,
          readsPassPendingWrites: true,
        ),
      );
      storage.setData(LogicValue.ofInt(0x300, 64), LogicValue.ofInt(0x77, 64));
      await xact(write: true, addr: 0x200, data: 0x1234);
      expect(slave.pendingWrites, 1);
      expect(await xact(write: false, addr: 0x300), 1);
      expect(lastRead(), 0x77);
      // The write it overtook is still not committed.
      expect(slave.pendingWrites, 1);
      await stop();
    },
  );

  test('a read of a posted address still gets the NEW value', () async {
    // This is the ordering the memory owes its master, and it holds even with
    // reordering across addresses enabled.
    final slave = await makeSlave(
      const AdversarialMemory(
        postedWriteCycles: 8,
        readsPassPendingWrites: true,
      ),
    );
    storage.setData(LogicValue.ofInt(0x200, 64), LogicValue.ofInt(0x11, 64));
    await xact(write: true, addr: 0x200, data: 0x1234);
    final cycles = await xact(write: false, addr: 0x200);
    expect(cycles, greaterThan(1), reason: 'the read did not wait');
    expect(lastRead(), 0x1234);
    expect(slave.staleReads, 0);
    await stop();
  });

  test(
    'the hostile switch makes a read of a posted address go stale',
    () async {
      // The mutation of the rule above. It proves the check can fail, and it is
      // the only way to make this memory return a superseded value.
      final slave = await makeSlave(
        const AdversarialMemory(
          postedWriteCycles: 8,
          readsPassPendingWrites: true,
          hostileReadPassesSameAddress: true,
        ),
      );
      storage.setData(LogicValue.ofInt(0x200, 64), LogicValue.ofInt(0x11, 64));
      await xact(write: true, addr: 0x200, data: 0x1234);
      expect(await xact(write: false, addr: 0x200), 1);
      expect(lastRead(), 0x11, reason: 'the hostile read was not stale');
      expect(slave.staleReads, 1);
      await stop();
    },
  );

  test('SEL selects the bytes a write changes', () async {
    await makeSlave(const AdversarialMemory());
    storage.setData(
      LogicValue.ofInt(0x400, 64),
      LogicValue.ofBigInt(BigInt.parse('0xAAAAAAAAAAAAAAAA'), 64),
    );
    sel.inject(0x02); // byte 1 only
    await xact(write: true, addr: 0x400, data: 0xBBBB);
    expect(
      storage
          .getData(LogicValue.ofInt(0x400, 64))!
          .toBigInt()
          .toRadixString(16),
      'aaaaaaaaaaaabbaa',
    );
    await stop();
  });
}
