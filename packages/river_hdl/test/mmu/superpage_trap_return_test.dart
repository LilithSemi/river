import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// rc1-f: a supervisor trap and return, taken from and returned to code inside
/// a 2MB superpage, must keep supervisor mode and must not fault.
///
/// This is the regression test for the sstatus.SPP restore path. `core.dart`
/// restores the mode on SRET from `sstatus[8]`, so an SRET that reads SPP=0
/// puts the core in USER mode while it runs kernel code. Every following fetch
/// and every following load of a kernel page (U=0) is then denied by the MMU
/// U-bit rule, which is cause 12 at a page whose V R X A D bits are all
/// correct. That is the Arty S7 NixOS oops signature.
///
///   M-mode boot: satp, medeleg, mstatus.MPP=S, mepc, stvec, mret
///   S-mode in the superpage: ecall, delegated to stvec
///   handler: read sstatus (SPP must be 1) and scause, step sepc, sret
///   S-mode again: sfence.vma, a LOAD out of the same superpage, then park
///
/// The test cannot pass vacuously. The park address exists only through the
/// page table (0xffffffff80000018 is not physical memory), so reaching it
/// proves the MMU walked and translated. x5 pins sstatus.SPP=1 at trap entry,
/// so a return to the wrong privilege fails here instead of at the next fetch.
/// x30 pins the LAST trap as cause 9 (ecall from S), so a spurious instruction
/// page fault (cause 12) fails the test instead of hiding in the handler.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig rc1f() => RiverCoreConfigV1.full(
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

  /// Builds a memory image from 32-bit words. A 64-bit value (a PTE) is two
  /// entries, low half first.
  String mem(Map<int, List<int>> words) {
    final sb = StringBuffer();
    final addrs = words.keys.toList()..sort();
    for (final a in addrs) {
      sb.writeln('@${a.toRadixString(16)}');
      for (final w in words[a]!) {
        for (var i = 0; i < 4; i++) {
          sb.write(((w >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }
      sb.writeln();
    }
    return sb.toString();
  }

  const kernelVa = 0xFFFFFFFF80000000; // 2MB superpage -> PA 0x200000
  const handlerVa = 0xFFFFFFFF80000100;
  const dataVa = 0xFFFFFFFF80000800;
  const parkVa = 0xFFFFFFFF80000018;

  final image = mem({
    // ---- M-mode boot, fetched physically (paging is off in M-mode) ----
    0x00: [
      0x18051073, // csrw satp, a0
      0x30259073, // csrw medeleg, a1
      0x30061073, // csrw mstatus, a2   (MPP = 01 = supervisor)
      0x34169073, // csrw mepc, a3
      0x10571073, // csrw stvec, a4
      0x30200073, // mret
    ],

    // ---- Sv39 tables ----
    // root[0] = 1GB leaf, identity, V R W X A D, U=0 (the boot code's page).
    0x10000: [0x000000CF, 0],
    // root[510] -> the level-1 table at 0x11000.
    0x10FF0: [0x00004401, 0],
    // L1[0] = 2MB leaf -> PA 0x200000, V R W X A D, U=0.
    0x11000: [0x000800CF, 0],

    // ---- S-mode code, VA 0xffffffff80000000 = PA 0x200000 ----
    0x200000: [
      0x00100313, // addi x6, x0, 1
      0x00000073, // ecall                 -> cause 9, delegated to stvec
      0x00200393, // addi x7, x0, 2        (runs after sret)
      0x12000073, // sfence.vma x0, x0
      0x00300E13, // addi x28, x0, 3
      0x0007BF83, // ld x31, 0(x15)        x15 = dataVa, same superpage
      0x0000006F, // jal x0, 0             park at parkVa
    ],

    // ---- S-mode trap handler, VA 0xffffffff80000100 = PA 0x200100 ----
    0x200100: [
      0x100022F3, // csrr x5, sstatus      SPP must be 1 (trap taken from S)
      0x14202F73, // csrr x30, scause      must be 9, never 12
      0x14102EF3, // csrr x29, sepc
      0x004E8E93, // addi x29, x29, 4
      0x141E9073, // csrw sepc, x29
      0x10200073, // sret
    ],

    // ---- data in the same superpage, VA 0xffffffff80000800 ----
    0x200800: [0xDEADBEEF, 0],
  });

  test(
    'rc1-f: trap and sret inside a 2MB superpage keep supervisor mode',
    timeout: Timeout(Duration(minutes: 30)),
    () => coreTest(
      image,
      {
        Register.x5: 0x100, // sstatus at trap entry: SPP=1, SIE=0, SPIE=0
        Register.x6: 1, // reached the superpage code
        Register.x7: 2, // the sret returned into the superpage
        Register.x28: 3, // ran on past an sfence.vma
        Register.x30: 9, // the LAST trap was the ecall, not a page fault
        Register.x31: 0xDEADBEEF, // the data walk translated too
      },
      rc1f(),
      initRegisters: {
        Register.x10: 0x8000000000000010, // a0 = satp: Sv39, root PPN 0x10
        Register.x11: 0xFFFF, // a1 = medeleg: delegate everything to S
        Register.x12: 0x800, // a2 = mstatus: MPP = supervisor
        Register.x13: kernelVa, // a3 = mepc
        Register.x14: handlerVa, // a4 = stvec
        Register.x15: dataVa, // x15 = the load address
      },
      nextPc: parkVa,
      maxCycles: 6000,
    ),
  );
}
