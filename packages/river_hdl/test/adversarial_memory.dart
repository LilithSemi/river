import 'dart:io';
import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;

/// A Wishbone memory that is permitted to be SLOW, to REORDER and to POST.
///
/// Every harness in this repo drives the core with a `MemoryModel` at
/// `readLatency: 0` behind an acknowledge register that fires one cycle after
/// the request. That memory is perfectly ordered, single cycle and has no
/// queue, so a read can never observe a write that is still in flight. The real
/// machine is core -> fabric -> clock-domain-crossing FIFO -> DDR3 controller ->
/// PHY -> DRAM, with queues and posted writes. Any core-side dependence on the
/// instantaneous memory is therefore INVISIBLE in simulation.
///
/// This model closes that hole. It is a pure Dart Wishbone classic slave that
/// drives `ACK` and `DAT_MISO` from a [MemoryStorage], and it can:
///
///   * hold a read for [readLatency] cycles, with optional [readLatencyJitter];
///   * acknowledge a write immediately but COMMIT it [postedWriteCycles] later,
///     so a later read can find the old value (a posted-write queue);
///   * demand [minGapCycles] idle cycles between transactions;
///   * let a read to a DIFFERENT address complete while writes are still posted
///     ([readsPassPendingWrites]).
///
/// A read to the SAME address as a posted write is held until that write
/// commits. That is the ordering a real memory system owes its master. The
/// [hostileReadPassesSameAddress] switch breaks it on purpose, and is named
/// separately because it models a memory that is WRONG, not merely slow. Use it
/// only to prove a check can fail.
///
/// The default [AdversarialMemory] is the instantaneous memory the harnesses
/// already had, so opting in without options changes nothing.
class AdversarialMemory {
  /// Extra cycles a read waits before it is acknowledged. 0 is today's memory.
  final int readLatency;

  /// Upper bound of an extra pseudo-random read delay, added to [readLatency].
  /// 0 keeps every read at exactly [readLatency].
  final int readLatencyJitter;

  /// Extra cycles a write waits before it is acknowledged.
  final int writeLatency;

  /// Cycles between the acknowledge of a write and the moment the data becomes
  /// visible to a read. 0 commits the write at acknowledge, as today.
  final int postedWriteCycles;

  /// Maximum number of writes that can be posted at once. A write that arrives
  /// at a full queue is not acknowledged until there is room.
  final int postedWriteDepth;

  /// Idle cycles the memory demands after each acknowledge.
  final int minGapCycles;

  /// If true, a read to an address that no posted write touches completes while
  /// those writes are still pending. If false, a read waits for the queue to
  /// drain, which is total order.
  final bool readsPassPendingWrites;

  /// HOSTILE. If true, a read to the SAME address as a posted write returns the
  /// old value instead of waiting. This is a broken memory, not a slow one.
  final bool hostileReadPassesSameAddress;

  /// Seed for [readLatencyJitter], so a run repeats exactly.
  final int seed;

  /// Creates a memory behaviour. The default is the instantaneous, perfectly
  /// ordered memory the harnesses already used.
  const AdversarialMemory({
    this.readLatency = 0,
    this.readLatencyJitter = 0,
    this.writeLatency = 0,
    this.postedWriteCycles = 0,
    this.postedWriteDepth = 8,
    this.minGapCycles = 0,
    this.readsPassPendingWrites = false,
    this.hostileReadPassesSameAddress = false,
    this.seed = 1,
  });

  /// True if this behaviour is the instantaneous memory, in which case the
  /// caller may keep its existing `MemoryModel` wiring.
  bool get isInstant =>
      readLatency == 0 &&
      readLatencyJitter == 0 &&
      writeLatency == 0 &&
      postedWriteCycles == 0 &&
      minGapCycles == 0 &&
      !hostileReadPassesSameAddress;

  /// Reads a behaviour out of the environment, so an EXISTING suite can be
  /// re-run against a slow memory without editing the suite. Returns null when
  /// no `RIVER_MEM_*` variable is set, which keeps the default path.
  ///
  ///   RIVER_MEM_READ_LATENCY   extra read cycles
  ///   RIVER_MEM_READ_JITTER    extra pseudo-random read cycles
  ///   RIVER_MEM_WRITE_LATENCY  extra write cycles
  ///   RIVER_MEM_POSTED         posted-write commit delay in cycles
  ///   RIVER_MEM_POSTED_DEPTH   posted-write queue depth
  ///   RIVER_MEM_GAP            idle cycles between transactions
  ///   RIVER_MEM_PASS           1 to let reads pass writes to other addresses
  ///   RIVER_MEM_HOSTILE_SAME   1 to let reads pass a write to the SAME address
  ///   RIVER_MEM_SEED           jitter seed
  static AdversarialMemory? fromEnvironment([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    if (!e.keys.any((k) => k.startsWith('RIVER_MEM_'))) return null;
    int i(String k, int d) => int.tryParse(e[k] ?? '') ?? d;
    bool b(String k) => e[k] == '1' || e[k] == 'true';
    return AdversarialMemory(
      readLatency: i('RIVER_MEM_READ_LATENCY', 0),
      readLatencyJitter: i('RIVER_MEM_READ_JITTER', 0),
      writeLatency: i('RIVER_MEM_WRITE_LATENCY', 0),
      postedWriteCycles: i('RIVER_MEM_POSTED', 0),
      postedWriteDepth: i('RIVER_MEM_POSTED_DEPTH', 8),
      minGapCycles: i('RIVER_MEM_GAP', 0),
      readsPassPendingWrites: b('RIVER_MEM_PASS'),
      hostileReadPassesSameAddress: b('RIVER_MEM_HOSTILE_SAME'),
      seed: i('RIVER_MEM_SEED', 1),
    );
  }

  @override
  String toString() =>
      'AdversarialMemory(readLatency: $readLatency, jitter: $readLatencyJitter, '
      'writeLatency: $writeLatency, posted: $postedWriteCycles/$postedWriteDepth, '
      'gap: $minGapCycles, pass: $readsPassPendingWrites, '
      'hostileSame: $hostileReadPassesSameAddress)';
}

/// One write that is acknowledged but not yet visible.
class _PostedWrite {
  final LogicValue alignedAddr;
  final LogicValue data;
  final LogicValue? mask;
  int cyclesLeft;
  _PostedWrite(this.alignedAddr, this.data, this.mask, this.cyclesLeft);
}

/// A Wishbone classic slave written in Dart, backed by [storage] and shaped by
/// an [AdversarialMemory]. Attach it with [attachAdversarialMemory].
///
/// Timing contract at the default behaviour, which matches the `MemoryModel`
/// plus acknowledge-register the harnesses already used: the request is sampled
/// at the clock edge, and `ACK` plus `DAT_MISO` are driven for the ONE cycle
/// that follows. `ACK` then drops for at least one cycle, so a back-to-back
/// stream of transactions runs at one transaction every two cycles.
class AdversarialWishboneSlave {
  /// The behaviour this slave applies.
  final AdversarialMemory behaviour;

  /// The memory this slave answers from.
  final MemoryStorage storage;

  /// Data width in bits.
  final int dataWidth;

  /// Number of reads acknowledged.
  int reads = 0;

  /// Number of writes acknowledged.
  int writes = 0;

  /// Cycles a request was held because the ordering rules blocked it.
  int orderStallCycles = 0;

  /// Reads that returned a value a posted write had already superseded. This is
  /// non-zero only with [AdversarialMemory.hostileReadPassesSameAddress].
  int staleReads = 0;

  final Logic _clk;
  final Logic _reset;
  final Logic _cyc;
  final Logic _stb;
  final Logic _we;
  final Logic _adr;
  final Logic _datMosi;
  final Logic? _sel;
  final Logic _ack;
  final Logic _miso;
  final Random _rng;

  final List<_PostedWrite> _posted = [];
  bool _acking = false;
  int _gap = 0;
  int _wait = -1;

  AdversarialWishboneSlave._(
    this.behaviour,
    this.storage,
    this.dataWidth,
    this._clk,
    this._reset,
    this._cyc,
    this._stb,
    this._we,
    this._adr,
    this._datMosi,
    this._sel,
    this._ack,
    this._miso,
  ) : _rng = Random(behaviour.seed) {
    _ack.inject(0);
    _miso.inject(LogicValue.filled(dataWidth, LogicValue.zero));
    _reset.posedge.listen((_) => _clear());
    _clk.posedge.listen((_) => _onEdge());
  }

  /// Writes that are acknowledged but not yet visible to a read.
  int get pendingWrites => _posted.length;

  /// Commits every posted write at once. A test calls this before it reads the
  /// final memory state, so a pending write is not mistaken for a lost one.
  void flush() {
    while (_posted.isNotEmpty) {
      _commit(_posted.removeAt(0));
    }
  }

  void _clear() {
    _posted.clear();
    _acking = false;
    _gap = 0;
    _wait = -1;
    _ack.inject(0);
    storage.reset();
  }

  void _commit(_PostedWrite w) {
    final mask = w.mask;
    if (mask == null || !mask.isValid) {
      storage.writeData(w.alignedAddr, w.data);
      return;
    }
    final current = storage.readData(w.alignedAddr);
    storage.writeData(
      w.alignedAddr,
      [
        for (var i = 0; i < dataWidth ~/ 8; i++)
          mask[i].toBool()
              ? w.data.getRange(i * 8, (i + 1) * 8)
              : current.getRange(i * 8, (i + 1) * 8),
      ].rswizzle(),
    );
  }

  void _onEdge() {
    if (_reset.previousValue == LogicValue.one) {
      _clear();
      return;
    }
    // Age the queue first, so a write posted for N cycles is visible on the
    // Nth edge after its acknowledge.
    for (final w in _posted) {
      w.cyclesLeft--;
    }
    while (_posted.isNotEmpty && _posted.first.cyclesLeft <= 0) {
      _commit(_posted.removeAt(0));
    }
    // The acknowledge lasts exactly one cycle. Drop it, then take the gap.
    if (_acking) {
      _acking = false;
      _ack.inject(0);
      _gap = behaviour.minGapCycles;
      _wait = -1;
      return;
    }
    if (_gap > 0) {
      _gap--;
      return;
    }
    final cyc = _cyc.previousValue;
    final stb = _stb.previousValue;
    if (cyc == null || stb == null || !cyc.isValid || !stb.isValid) return;
    if (!cyc.toBool() || !stb.toBool()) {
      _wait = -1;
      return;
    }
    final we = _we.previousValue;
    final addr = _adr.previousValue;
    if (we == null || addr == null || !we.isValid || !addr.isValid) return;
    final isWrite = we.toBool();
    if (_wait < 0) {
      _wait = isWrite
          ? behaviour.writeLatency
          : behaviour.readLatency +
                (behaviour.readLatencyJitter == 0
                    ? 0
                    : _rng.nextInt(behaviour.readLatencyJitter + 1));
    }
    if (_wait > 0) {
      _wait--;
      return;
    }
    final aligned = storage.alignAddress(addr);
    if (isWrite) {
      if (behaviour.postedWriteCycles > 0 &&
          _posted.length >= behaviour.postedWriteDepth) {
        orderStallCycles++;
        return;
      }
      final w = _PostedWrite(
        aligned,
        _datMosi.previousValue!,
        _sel?.previousValue,
        behaviour.postedWriteCycles,
      );
      if (behaviour.postedWriteCycles > 0) {
        _posted.add(w);
      } else {
        _commit(w);
      }
      writes++;
      _grant();
      return;
    }
    if (_posted.isNotEmpty) {
      final hit = _posted.any((w) => w.alignedAddr == aligned);
      if (hit) {
        // A read of an address a posted write owns. An ordered memory owes the
        // master the new value, so hold the read until the write commits.
        if (!behaviour.hostileReadPassesSameAddress) {
          orderStallCycles++;
          return;
        }
        staleReads++;
      } else if (!behaviour.readsPassPendingWrites) {
        orderStallCycles++;
        return;
      }
    }
    _miso.inject(storage.readData(aligned));
    reads++;
    _grant();
  }

  void _grant() {
    _ack.inject(1);
    _acking = true;
    _wait = -1;
  }
}

/// Attaches an [AdversarialWishboneSlave] to a Wishbone classic master.
///
/// [ack] and [miso] must be undriven [Logic]s that the caller feeds to the
/// master's `ACK` and `DAT_MISO` inputs. Pass [sel] to honour the Wishbone byte
/// enables, exactly as the masked memory port does.
AdversarialWishboneSlave attachAdversarialMemory({
  required Logic clk,
  required Logic reset,
  required MemoryStorage storage,
  required int dataWidth,
  required Logic cyc,
  required Logic stb,
  required Logic we,
  required Logic adr,
  required Logic datMosi,
  required Logic ack,
  required Logic miso,
  Logic? sel,
  AdversarialMemory behaviour = const AdversarialMemory(),
}) => AdversarialWishboneSlave._(
  behaviour,
  storage,
  dataWidth,
  clk,
  reset,
  cyc,
  stb,
  we,
  adr,
  datMosi,
  sel,
  ack,
  miso,
);
