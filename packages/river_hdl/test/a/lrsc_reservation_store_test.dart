import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// A store to the reserved address must break the LR/SC reservation.
///
/// River keeps the reservation in two registers, `reservationValid` and
/// `reservationAddr` (exec.dart:535). LR sets them and SC clears them. NOTHING
/// else clears them: not a plain store to the reserved address, not a trap, and
/// not an interrupt. A reservation therefore survives any code that runs between
/// the LR and the SC.
///
/// That breaks Linux `cmpxchg`, which is an LR/SC loop. If an interrupt lands
/// between the LR and the SC, and the handler writes the same address with a
/// plain store (per-CPU counters, semaphore fields and slub freelists all do
/// this), then the SC still succeeds. It writes a value computed from the stale
/// old value and it DESTROYS the handler's write. The result is a silent lost
/// update in kernel data, which is the shape of the delta stack-protector panics
/// in `up()` and `___slab_alloc`.
///
/// The interrupt is only the delivery mechanism. This test drives the same
/// hardware condition directly, with a plain store between the LR and the SC, so
/// it runs in seconds and needs no interrupt controller.
///
///   x10 = 0x80001000 (cached), x11 = 0xa5 (the other write), x12 = 0x5a (SC)
///   0x00 lr.d x6, (x10)
///   0x04 sd   x11, 0(x10)      ; breaks the reservation set
///   0x08 sc.d x7, x12, (x10)   ; must FAIL: x7 != 0, memory keeps 0xa5
///   0x0c jal  x0, 0
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig cfg() => RiverCoreConfigV1.full(
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    clock: const HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
  );

  String asm(List<int> words) {
    final sb = StringBuffer('@0\n');
    for (final w in words) {
      for (var b = 0; b < 4; b++) {
        sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return sb.toString();
  }

  const lrD = 0x1005332f; // lr.d x6, (x10)
  const sdX11 = 0x00b53023; // sd x11, 0(x10)
  const scD = 0x18c533af; // sc.d x7, x12, (x10)
  const park = 0x0000006f; // jal x0, 0

  // Control: with nothing between them the SC MUST succeed. This proves the
  // encodings and the harness are right, so a failure below is a real defect.
  test(
    'lr.d then sc.d with no intervening store succeeds',
    timeout: Timeout(Duration(minutes: 8)),
    () async {
      await coreTest(
        asm([lrD, scD, park]),
        {Register.x7: 0}, // 0 = SC succeeded
        cfg(),
        initRegisters: {
          Register.x10: 0x80001000,
          Register.x11: 0xa5,
          Register.x12: 0x5a,
        },
        memStates: {0x80001000: 0x5a},
        nextPc: 0x08,
      );
    },
  );

  test(
    'a plain store to the reserved address makes the following sc.d fail',
    timeout: Timeout(Duration(minutes: 8)),
    () async {
      await coreTest(
        asm([lrD, sdX11, scD, park]),
        {Register.x7: 1}, // 1 = SC failed, which the spec requires here
        cfg(),
        initRegisters: {
          Register.x10: 0x80001000,
          Register.x11: 0xa5,
          Register.x12: 0x5a,
        },
        // The store's value must survive. 0x5a here means the SC overwrote it.
        memStates: {0x80001000: 0xa5},
        nextPc: 0x0c,
      );
    },
  );

  // The case QEMU calls out as explicitly required by ISA version 2.2: a TRAP
  // between the LR and the SC must drop the reservation. QEMU clears
  // `env->load_res` in riscv_cpu_set_mode, so every privilege change kills it,
  // and QEMU's SC also compares the loaded VALUE. River does neither. This is
  // why the QEMU River fork boots NixOS while the same kernel corrupts on the
  // real core: on hardware the reservation survives the interrupt AND survives
  // the handler's store, so cmpxchg silently loses the handler's update.
  //
  //   0x000 csrw mtvec, x5      ; x5 = 0x100
  //   0x004 lr.d x6, (x10)      ; reserve
  //   0x008 ecall               ; trap, stands in for the timer interrupt
  //   0x00c sc.d x7, x12, (x10) ; must FAIL
  //   0x010 jal x0, 0
  //   0x100 sd x11, 0(x10)      ; the handler writes the reserved address
  //   0x104 csrr x1, mepc
  //   0x108 addi x1, x1, 4      ; step over the ecall
  //   0x10c csrw mepc, x1
  //   0x110 mret
  test(
    'a trap between lr.d and sc.d drops the reservation',
    timeout: Timeout(Duration(minutes: 8)),
    () async {
      final words = <int, int>{
        0x000: 0x30529073, // csrw mtvec, x5
        0x004: lrD,
        0x008: 0x00000073, // ecall
        0x00c: scD,
        0x010: park,
        0x100: sdX11, // sd x11, 0(x10)
        0x104: 0x341020f3, // csrr x1, mepc
        0x108: 0x00408093, // addi x1, x1, 4
        0x10c: 0x34109073, // csrw mepc, x1
        0x110: 0x30200073, // mret
      };
      final sb = StringBuffer('@0\n');
      final maxA = words.keys.reduce((a, b) => a > b ? a : b);
      for (var addr = 0; addr <= maxA + 4; addr += 4) {
        final w = words[addr] ?? 0x00000013; // nop
        for (var b = 0; b < 4; b++) {
          sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }

      await coreTest(
        sb.toString(),
        {Register.x7: 1}, // 1 = SC failed, which the trap must force
        cfg(),
        initRegisters: {
          Register.x5: 0x100, // mtvec
          Register.x10: 0x80001000,
          Register.x11: 0xa5,
          Register.x12: 0x5a,
        },
        memStates: {0x80001000: 0xa5},
        nextPc: 0x010,
      );
    },
  );
}
