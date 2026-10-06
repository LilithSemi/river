import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Two properties of the page-table walk, driven at the [RiverMmu] boundary.
///
/// 1. A transfer ends on ONE acknowledge. The walk FSM qualifies every
///    acknowledge with `cycR`, the registered CYC the MMU drives, so a slave
///    that holds ACK for a second cycle cannot have that second cycle read as
///    the NEXT page-table entry. Without the guard the walk descends a level on
///    a PTE it already consumed, reads a table entry that belongs to no part of
///    the translation, and faults on a valid page.
///
/// 2. The leaf permission check judges the access by the privilege the
///    requester held when the MMU accepted the request, not by the privilege in
///    effect many cycles later when the leaf returns. A trap between the two
///    moved the mode under the walk, and the U-bit rule then denied a
///    supervisor page to the new mode.
///
/// Both tests also record the bus ADDRESS and the privilege at every access, so
/// a pass proves a real walk ran and says which mode drove it. The second test
/// asserts the address trace is IDENTICAL with and without the mid-walk
/// privilege change, which is the point: the latch decides fault or no fault
/// and never takes part in composing a physical address.
///
/// `mmu_superpage_stress_test.dart` covers the same two properties against a
/// full page-table model. These tests are the unit-level companion: they run in
/// under a second and assert the exact bus ADDRESS sequence, which is what
/// shows that the privilege latch changes the fault decision and nothing else.
///
/// Page tables (Sv39, satp root PPN 0x10):
///   0x10000 -> 0x4401       pointer PTE, next table 0x11000
///   0x11008 -> 0x1000000F   LEAF, 2MB superpage, PPN 0x40000, V|R|W|X, U=0
///   0x40001000 -> 0xCAFEF00D   the translation of vaddr 0x201000
///
/// The leaf has A=0, so the walk also writes the PTE back with A set (Svadu)
/// before it runs the translated access. That writeback is the third bus
/// access of a clean walk, and it consumes an acknowledge through the same
/// guard, so the trace keeps it.
void main() {
  const rootPtePa = 0x10000;
  const leafPtePa = 0x11008;
  const translatedPa = 0x40001000;
  const vaddr = 0x201000;
  const payload = 0xCAFEF00D;

  tearDown(() async {
    await Simulator.reset();
  });

  /// One walked read of [vaddr].
  ///
  /// [ackHoldCycles] is how many cycles the mock slave keeps ACK asserted for
  /// one request. 1 is a well behaved slave. 2 stretches the acknowledge one
  /// cycle past the point where the MMU drops CYC, which is the shape the guard
  /// must reject.
  ///
  /// [startPriv] is the privilege at the moment the MMU accepts the request.
  /// When [privAfterFirstPte] is not null, the privilege changes to it as soon
  /// as the first PTE comes back, which puts the change in the middle of the
  /// walk.
  Future<_WalkResult> walk({
    required int ackHoldCycles,
    required int startPriv,
    int? privAfterFirstPte,
  }) async {
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic(name: 'reset');
    final dportEn = Logic(name: 'dportEn');
    final dportAddr = Logic(name: 'dportAddr', width: 64);
    final satpMode = Logic(name: 'satpMode', width: 4);
    final satpRoot = Logic(name: 'satpRoot', width: 64);
    final privMode = Logic(name: 'privMode', width: 3);
    final sum = Logic(name: 'sum');
    final mxr = Logic(name: 'mxr');

    final wbConfig = WishboneConfig(
      addressWidth: 64,
      dataWidth: 64,
      selWidth: 8,
    );
    final mmuConfig = HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
      hasSupervisorUserMemory: true,
      hasMakeExecutableReadable: true,
    );

    final ackSrc = Logic(name: 'ackSrc');
    final misoSrc = Logic(name: 'misoSrc', width: 64);

    final mmu = RiverMmu(
      clk,
      reset,
      Const(0), // ifetchEn
      Const(0, width: 64), // ifetchAddr
      dportEn,
      dportAddr,
      Const(0), // dportWe, a read
      Const(0, width: 64), // dportWdata
      Const(3, width: 3), // dportSize, 8 bytes
      ackSrc,
      misoSrc,
      mmuConfig: mmuConfig,
      busConfig: wbConfig,
      satpMode: satpMode,
      satpRoot: satpRoot,
      privMode: privMode,
      sum: sum,
      mxr: mxr,
    );

    await mmu.build();

    // Combinational memory. An address outside the table reads 0, which is an
    // invalid PTE, so a walk that leaves the table faults instead of quietly
    // returning a plausible value.
    Logic memData(Logic a) => mux(
      a.eq(rootPtePa),
      Const(0x4401, width: 64),
      mux(
        a.eq(leafPtePa),
        Const(0x1000000F, width: 64),
        mux(a.eq(translatedPa), Const(payload, width: 64), Const(0, width: 64)),
      ),
    );
    misoSrc <= memData(mmu.wbAdr);

    // Mock slave. It arms on CYC & STB when it is idle, then holds ACK for
    // [ackHoldCycles] cycles. With 2 the second cycle lands after the MMU has
    // dropped CYC, which is the case the guard must ignore.
    final ackCnt = Logic(name: 'ackCnt', width: 4);
    Sequential(clk, [
      If(
        reset,
        then: [ackCnt < 0],
        orElse: [
          If(
            mmu.wbCyc & mmu.wbStb & ackCnt.eq(0),
            then: [ackCnt < Const(ackHoldCycles, width: 4)],
            orElse: [
              If(ackCnt.neq(0), then: [ackCnt < (ackCnt - 1)]),
            ],
          ),
        ],
      ),
    ]);
    ackSrc <= ackCnt.neq(0);

    reset.inject(1);
    dportEn.inject(0);
    dportAddr.inject(0);
    satpMode.inject(8); // Sv39
    satpRoot.inject(0x10); // root PPN, table at 0x10000
    privMode.inject(startPriv);
    sum.inject(0);
    mxr.inject(0);

    Simulator.setMaxSimTime(20000);
    unawaited(Simulator.run());

    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    dportEn.inject(1);
    dportAddr.inject(vaddr);

    final trace = <_BusAccess>[];
    var pteCount = 0;
    var done = false;
    var fault = false;
    var rdata = 0;

    for (var i = 0; i < 200; i++) {
      await clk.nextPosedge;

      // Record every acknowledged bus access with the privilege that was live
      // for it. Only an acknowledge while the MMU drives CYC is a real access.
      final cyc = mmu.wbCyc.value.toInt() == 1;
      final ack = ackSrc.value.toInt() == 1;
      if (cyc && ack) {
        trace.add(
          _BusAccess(
            mmu.wbAdr.value.toInt(),
            privMode.value.toInt(),
            mmu.wbWe.value.toInt() == 1,
          ),
        );
        // The first two acknowledged accesses of a clean walk are the two PTE
        // reads. Move the privilege as soon as the first PTE returns, so the
        // change lands in the middle of the walk.
        pteCount++;
        if (pteCount == 1 && privAfterFirstPte != null) {
          privMode.inject(privAfterFirstPte);
        }
      }

      if (mmu.dportDone.value.toInt() == 1) {
        done = true;
        fault = mmu.dportFault.value.toInt() == 1;
        rdata = mmu.dportRdata.value.toInt();
        break;
      }
    }

    await Simulator.endSimulation();
    await Simulator.simulationEnded;

    return _WalkResult(done: done, fault: fault, rdata: rdata, trace: trace);
  }

  test('a well behaved one-cycle acknowledge walks the superpage', () async {
    final r = await walk(
      ackHoldCycles: 1,
      startPriv: PrivilegeMode.supervisor.id,
    );
    expect(r.done, isTrue, reason: 'dportDone never asserted');
    expect(r.fault, isFalse, reason: 'a valid supervisor page must not fault');
    expect(r.rdata, payload);
    expect(
      r.addresses,
      [rootPtePa, leafPtePa, leafPtePa, translatedPa],
      reason:
          'the walk must read the root table, read the leaf, write the leaf '
          'back with A set, then read the data',
    );
    expect(r.writes, [false, false, true, false]);
    expect(
      r.privileges.every((p) => p == PrivilegeMode.supervisor.id),
      isTrue,
      reason: 'every access must run in supervisor mode',
    );
  });

  test('a two-cycle acknowledge is not read as the next PTE', () async {
    // Without the cycR guard the stretched acknowledge is consumed a second
    // time. The walk descends a level on the root PTE it already used, reads
    // 0x12008 (no part of this translation), finds 0 there and page faults on a
    // valid superpage.
    final r = await walk(
      ackHoldCycles: 2,
      startPriv: PrivilegeMode.supervisor.id,
    );
    expect(r.done, isTrue, reason: 'dportDone never asserted');
    expect(
      r.addresses,
      [rootPtePa, leafPtePa, leafPtePa, translatedPa],
      reason:
          'the stretched acknowledge was consumed a second time, so the walk '
          'left the page table: ${r.trace}',
    );
    expect(r.writes, [false, false, true, false]);
    expect(r.fault, isFalse, reason: 'a valid supervisor page must not fault');
    expect(r.rdata, payload);
  });

  test('a privilege change mid-walk does not deny the requester', () async {
    // The request is accepted in supervisor mode. The mode drops to user while
    // the walk is in flight. The leaf has U=0, so judging it at the LIVE user
    // privilege denies it. Judging it at the privilege the request was made at
    // allows it, which is correct.
    final r = await walk(
      ackHoldCycles: 1,
      startPriv: PrivilegeMode.supervisor.id,
      privAfterFirstPte: PrivilegeMode.user.id,
    );
    expect(r.done, isTrue, reason: 'dportDone never asserted');
    expect(
      r.fault,
      isFalse,
      reason: 'a supervisor request was denied by a privilege it never held',
    );
    expect(r.rdata, payload);
    expect(r.addresses, [
      rootPtePa,
      leafPtePa,
      leafPtePa,
      translatedPa,
    ], reason: 'the walk must still read the root table and the leaf');
    // The privilege moved under the walk, which is what the test set up.
    expect(r.privileges.first, PrivilegeMode.supervisor.id);
    expect(r.privileges.last, PrivilegeMode.user.id);
  });

  test('the latched privilege never changes the physical address', () async {
    // The same walk with and without the mid-walk privilege change. The
    // address trace must be identical. The latch decides fault or no fault and
    // takes no part in composing a physical address, so it cannot move an
    // access to a wrong page or a wrong superpage level.
    final steady = await walk(
      ackHoldCycles: 1,
      startPriv: PrivilegeMode.supervisor.id,
    );
    await Simulator.reset();
    final moved = await walk(
      ackHoldCycles: 1,
      startPriv: PrivilegeMode.supervisor.id,
      privAfterFirstPte: PrivilegeMode.user.id,
    );
    expect(moved.addresses, steady.addresses);
    expect(moved.rdata, steady.rdata);
    expect(moved.fault, steady.fault);
  });
}

/// One acknowledged bus access, with the privilege that was live for it.
class _BusAccess {
  final int address;
  final int privilege;
  final bool isWrite;

  const _BusAccess(this.address, this.privilege, this.isWrite);

  @override
  String toString() =>
      '${isWrite ? 'wr' : 'rd'} 0x${address.toRadixString(16)} priv $privilege';
}

class _WalkResult {
  final bool done;
  final bool fault;
  final int rdata;
  final List<_BusAccess> trace;

  const _WalkResult({
    required this.done,
    required this.fault,
    required this.rdata,
    required this.trace,
  });

  List<int> get addresses => trace.map((a) => a.address).toList();
  List<int> get privileges => trace.map((a) => a.privilege).toList();
  List<bool> get writes => trace.map((a) => a.isWrite).toList();
}
