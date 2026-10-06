import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// sstatus is NOT a register. The privileged spec makes it a restricted VIEW of
/// mstatus: every bit sstatus shows (SIE, SPIE, SPP, SUM, MXR, FS) is the same
/// physical bit that mstatus shows.
///
/// River had two independent registers, and mstatus carried only MIE, MPIE and
/// MPP. Two things broke because of that:
///
///  * SPP. M-mode firmware sets up a return to S-mode through mstatus. With no
///    SPP field the write was dropped, so a later SRET read SPP=0 and dropped
///    the core into USER mode while it ran kernel code.
///  * SUM and MXR. The MMU reads mstatus[18] and mstatus[19]. With no field
///    there they were permanently 0, so SUM could never be enabled and every
///    kernel access to a user page took a page fault.
///
/// Each test below reads the state back through the OTHER name, so a pair of
/// separate registers cannot pass.
RiverCoreConfig _rc1s() => RiverCoreConfigV1.small(
  mmu: HarborMmuConfig(
    mxlen: RiscVMxlen.rv64,
    pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
    hasSupervisorUserMemory: true,
    hasMakeExecutableReadable: true,
  ),
  interrupts: [],
  clock: const HarborClockConfig(
    name: 'test',
    rate: HarborFixedClockRate(12000000),
  ),
  resetVector: 0,
);

// Emit ONE contiguous block from @0, gaps filled with nop. A per-word `@addr`
// form makes SparseMemoryStorage take sub-8-byte writes that mis-pack a word
// holding zero bytes, so a zero-heavy instruction reads back corrupted.
String _memString(Map<int, int> words) {
  const nop = 0x00000013;
  final maxAddr = words.keys.reduce((a, b) => a > b ? a : b);
  final sb = StringBuffer('@0\n');
  for (var addr = 0; addr <= maxAddr + 4; addr += 4) {
    final w = words[addr] ?? nop;
    for (var b = 0; b < 4; b++) {
      sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
  }
  return sb.toString();
}

void main() {
  // mstatus bits the two names share: SIE=1, SPIE=5, SPP=8, SUM=18, MXR=19.
  // The M-only bits: MIE=3, MPIE=7, MPP=[12:11].
  const sBits = 0x40122; // SIE | SPIE | SPP | SUM
  const mBits = 0x1888; // MIE | MPIE | MPP=M

  test(
    'a mstatus write is visible through sstatus',
    () async {
      await Simulator.reset();
      //   csrw mstatus,x11   x11 = SPP | SUM
      //   csrr x5,sstatus    must show the same bits
      final program = <int, int>{
        0x00: 0x30059073, // csrw mstatus,x11
        0x04: 0x100022f3, // csrr x5,sstatus
        0x08: 0x00000013, // nop
      };
      await coreTest(
        _memString(program),
        {Register.x5: 0x40100},
        _rc1s(),
        initRegisters: {Register.x11: 0x40100},
        nextPc: 0x0c,
        maxCycles: 30000,
      );
    },
    timeout: Timeout(Duration(minutes: 10)),
  );

  test(
    'a sstatus write reaches mstatus and leaves MIE/MPIE/MPP alone',
    () async {
      await Simulator.reset();
      //   csrw mstatus,x11   x11 = MIE | MPIE | MPP=M
      //   csrw sstatus,x12   x12 = SIE | SPIE | SPP | SUM
      //   csrr x6,mstatus    must show BOTH sets
      //   csrr x5,sstatus    must show only the S subset
      final program = <int, int>{
        0x00: 0x30059073, // csrw mstatus,x11
        0x04: 0x10061073, // csrw sstatus,x12
        0x08: 0x30002373, // csrr x6,mstatus
        0x0c: 0x100022f3, // csrr x5,sstatus
        0x10: 0x00000013, // nop
      };
      await coreTest(
        _memString(program),
        {Register.x6: mBits | sBits, Register.x5: sBits},
        _rc1s(),
        initRegisters: {Register.x11: mBits, Register.x12: sBits},
        nextPc: 0x14,
        maxCycles: 30000,
      );
    },
    timeout: Timeout(Duration(minutes: 10)),
  );

  test(
    'sret returns to the privilege mstatus.SPP names',
    () async {
      await Simulator.reset();
      // M-mode sets up a return to S-mode through mstatus, which is how real
      // firmware does it, then SRETs.
      //   csrw mtvec,x13     x13 = 0xC0, the illegal-instruction handler
      //   csrw sepc,x10      x10 = 0x40, the S entry
      //   csrw mstatus,x11   x11 = SPP -> return to supervisor
      //   sret
      // 0x40 runs in S if SPP survived. csrr sepc is an S-level CSR, so in USER
      // mode it traps and the core never reaches 0x4c.
      final program = <int, int>{
        0x00: 0x30569073, // csrw mtvec,x13
        0x04: 0x14151073, // csrw sepc,x10
        0x08: 0x30059073, // csrw mstatus,x11
        0x0c: 0x10200073, // sret
        0x40: 0x141023f3, // csrr x7,sepc
        0x44: 0x05500413, // addi x8,x0,0x55
        0x48: 0x00000013, // nop
        0xC0: 0x06600493, // addi x9,x0,0x66   (only a fault gets here)
        0xC4: 0x0000006F, // j .
      };
      await coreTest(
        _memString(program),
        {Register.x7: 0x40, Register.x8: 0x55, Register.x9: 0},
        _rc1s(),
        initRegisters: {
          Register.x13: 0xC0,
          Register.x10: 0x40,
          Register.x11: 0x100, // SPP = supervisor
        },
        nextPc: 0x4c,
        maxCycles: 30000,
      );
    },
    timeout: Timeout(Duration(minutes: 10)),
  );

  test(
    'M-mode firmware can redirect a trap into S-mode through mstatus.SPP',
    () async {
      await Simulator.reset();
      // The OpenSBI-style redirect, which is the path the board really uses.
      // A trap reaches M-mode, and M-mode firmware hands it to the S-mode
      // handler in SOFTWARE: it writes sepc, sets SPP so the handler's later
      // SRET comes back to S, sets MPP=S, and MRETs. M-mode can only reach SPP
      // through mstatus, so with no SPP field the request is silently dropped
      // and the handler's SRET drops the core into USER mode.
      //   0x00 csrw mtvec,x13   x13 = 0x80, the firmware trap handler
      //   0x04 csrw mepc,x10    x10 = 0x40, the S entry
      //   0x08 csrw mstatus,x11 x11 = MPP=S
      //   0x0c mret             -> S at 0x40
      //   0x40 ecall            -> M at 0x80 (medeleg is 0)
      //   0x80 csrw sepc,x14    x14 = 0x100, the S handler
      //   0x84 csrw mstatus,x12 x12 = MPP=S | SPP=S
      //   0x88 csrw mepc,x14
      //   0x8c mret             -> S at 0x100
      //   0x100 csrw sepc,x16   x16 = 0x140, where the handler resumes
      //   0x104 sret            -> SPP says supervisor
      //   0x140 csrr x7,sepc    an S-level CSR: in USER mode this traps
      final program = <int, int>{
        0x000: 0x30569073, // csrw mtvec,x13
        0x004: 0x34151073, // csrw mepc,x10
        0x008: 0x30059073, // csrw mstatus,x11
        0x00c: 0x30200073, // mret
        0x040: 0x00000073, // ecall
        0x044: 0x00000013, // nop
        0x080: 0x14171073, // csrw sepc,x14
        0x084: 0x30061073, // csrw mstatus,x12
        0x088: 0x34171073, // csrw mepc,x14
        0x08c: 0x30200073, // mret
        0x100: 0x14181073, // csrw sepc,x16
        0x104: 0x10200073, // sret
        0x140: 0x141023f3, // csrr x7,sepc
        0x144: 0x05500413, // addi x8,x0,0x55
        0x148: 0x00000013, // nop
      };
      await coreTest(
        _memString(program),
        {Register.x7: 0x140, Register.x8: 0x55},
        _rc1s(),
        initRegisters: {
          Register.x13: 0x80,
          Register.x10: 0x40,
          Register.x11: 0x800, // MPP = supervisor
          Register.x12: 0x900, // MPP = supervisor, SPP = supervisor
          Register.x14: 0x100,
          Register.x16: 0x140,
        },
        nextPc: 0x14c,
        maxCycles: 40000,
      );
    },
    timeout: Timeout(Duration(minutes: 10)),
  );

  test(
    'a trap taken in S-mode pushes SPP/SPIE into mstatus',
    () async {
      await Simulator.reset();
      // Delegate ecall-from-S (cause 9) to S, enter S, then ecall. M-mode sets
      // SPP and SPIE, so the SRET leaves S-mode with SIE=1, SPIE=1, SPP=0
      // (x7 = 0x22). The ecall then pushes: SIE<-0, SPIE<-old SIE=1, SPP<-1
      // (x5 = 0x120). The two reads together show the push really happened.
      //   csrw medeleg,x14   x14 = 1<<9
      //   csrw stvec,x13     x13 = 0x80
      //   csrw sepc,x10      x10 = 0x40
      //   csrw mstatus,x11   x11 = SPP | SPIE
      //   sret               -> S at 0x40
      //   ecall              -> S at 0x80
      //   csrr x5,sstatus    (mstatus is M-level, so S must not read it here)
      final program = <int, int>{
        0x00: 0x30271073, // csrw medeleg,x14
        0x04: 0x30569073, // csrw mtvec,x13
        0x08: 0x10569073, // csrw stvec,x13
        0x0c: 0x14151073, // csrw sepc,x10
        0x10: 0x30059073, // csrw mstatus,x11
        0x14: 0x10200073, // sret
        0x40: 0x100023f3, // csrr x7,sstatus
        0x44: 0x00000073, // ecall
        0x48: 0x00000013, // nop
        0x80: 0x100022f3, // csrr x5,sstatus
        0x84: 0x00000013, // nop
      };
      await coreTest(
        _memString(program),
        {Register.x7: 0x22, Register.x5: 0x120},
        _rc1s(),
        initRegisters: {
          Register.x14: 1 << 9,
          Register.x13: 0x80,
          Register.x10: 0x40,
          Register.x11: 0x120, // SPP | SPIE
        },
        nextPc: 0x88,
        maxCycles: 30000,
      );
    },
    timeout: Timeout(Duration(minutes: 10)),
  );
}
