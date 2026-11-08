import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// rc1-s (creek microcode) privilege-return regression.
///
/// On real hardware Ferrite's `csrs sie` (timer_smode.zig:32) traps ILLEGAL,
/// and a Weir M-mode diagnostic proved the core was in U-MODE (mstatus.MPP=0)
/// at that instruction even though Weir dropped to S-mode (MPP=S) and Ferrite's
/// earlier stvec write ran in S. So a privilege RETURN between there landed in
/// U instead of the saved MPP. The prime suspect is the SBI ecall-return `mret`
/// that immediately precedes the timer's `csrs sie`. Linux does constant
/// U/S/M transitions and cannot boot on a broken privilege return.
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
// holding zero bytes (e.g. ecall 0x00000073), so a zero-heavy instruction reads
// back corrupted. A single contiguous load never triggers that.
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
  test('csrs sie is legal from S-mode (rc1-s microcode)', () async {
    await Simulator.reset();
    // Drop to S (MPP=S) then csrs sie: must NOT trap (x7 reaches 0x99).
    final program = <int, int>{
      0x00: 0x34151073, // csrw mepc, x10
      0x04: 0x30059073, // csrw mstatus, x11
      0x08: 0x30200073, // mret
      0x40: 0x10462073, // csrs sie, x12   (S-mode)
      0x44: 0x09900393, // addi x7, x0, 0x99
      0x48: 0x00000013, // nop
    };
    await coreTest(
      _memString(program),
      {Register.x7: 0x99},
      _rc1s(),
      initRegisters: {
        Register.x10: 0x40,
        Register.x11: 0x800,
        Register.x12: 0x20,
      },
      nextPc: 0x4c,
    );
  }, timeout: Timeout(Duration(minutes: 5)));

  test(
    'ecall from S-mode reaches the M handler with correct mepc/mcause',
    () async {
      await Simulator.reset();
      // Isolate the TRAP-ENTRY: drop to S (mret), ecall to M, and HALT in the M
      // handler (no return mret, so no divergence). Read what the ecall trap set.
      //   0x00 csrw mtvec, x13   0x30569073 (x13=0x80)
      //   0x04 csrw mepc, x10    0x34151073 (x10=0x40)
      //   0x08 csrw mstatus,x11  0x30059073 (x11=0x800 MPP=S)
      //   0x0c mret              0x30200073 -> S at 0x40
      //   0x40 ecall             0x00000073 -> M at 0x80
      //   0x80 addi x8,x0,0x11   0x01100413 (handler ran)
      //   0x84 csrr x15, mepc    0x341027f3 (should be 0x40 = the ecall PC)
      //   0x88 csrr x16, mcause  0x34202873 (should be 9 = ecall-from-S)
      //   0x8c nop (halt)        0x00000013
      final entryProgram = <int, int>{
        0x00: 0x30569073,
        0x04: 0x34151073,
        0x08: 0x30059073,
        0x0c: 0x30200073,
        0x40: 0x00000073,
        0x44: 0x00000013,
        0x80: 0x01100413,
        0x84: 0x341027f3,
        0x88: 0x34202873,
        0x8c: 0x00000013,
      };
      await coreTest(
        _memString(entryProgram),
        {
          Register.x8: 0x11, // M handler entered => ecall from S trapped to M
          Register.x15: 0x40, // mepc captured the ecall PC
          Register.x16: 0x9, // mcause = ecall-from-S
        },
        _rc1s(),
        initRegisters: {
          Register.x13: 0x80,
          Register.x10: 0x40,
          Register.x11: 0x800,
        },
        nextPc: 0x8c,
      );
    },
    timeout: Timeout(Duration(minutes: 5)),
  );

  test('ecall from S-mode: mret returns to S, not U (rc1-s microcode)', () async {
    await Simulator.reset();
    // Enter S-mode, ecall to M, the M handler bumps mepc and mret's back. The
    // return MUST land in S: the following `csrs sie` is legal only in S. If the
    // core drops to U on the ecall-return mret, csrs sie traps and x7 never = 0x99.
    //   0x00 csrw mtvec, x13   0x30569073  (x13=0x80 M handler)
    //   0x04 csrw mepc, x10    0x34151073  (x10=0x40 S entry)
    //   0x08 csrw mstatus,x11  0x30059073  (x11=0x800 MPP=S)
    //   0x0c mret              0x30200073
    //   0x40 ecall             0x00000073  (S -> M)
    //   0x44 addi x9,x0,0x55   0x05500493  (ecall returned marker)
    //   0x48 csrs sie, x12     0x10462073  (legal only if back in S)
    //   0x4c addi x7,x0,0x99   0x09900393  (no-trap marker = S)
    //   0x50 nop (halt)        0x00000013
    //   0x80 csrr x14, mepc    0x34102773
    //   0x84 addi x14,x14,4    0x00470713
    //   0x88 csrw mepc, x14    0x34171073
    //   0x8c mret              0x30200073  (return to 0x44 at MPP=S)
    final program = <int, int>{
      0x00: 0x30569073,
      0x04: 0x34151073,
      0x08: 0x30059073,
      0x0c: 0x30200073,
      0x40: 0x00000073,
      0x44: 0x05500493,
      0x48: 0x10462073,
      0x4c: 0x09900393,
      0x50: 0x00000013,
      // M ecall handler: mark x8 (handler entered), bump mepc, mret.
      0x80: 0x01100413, // addi x8, x0, 0x11
      0x84: 0x34102773, // csrr x14, mepc
      0x88: 0x00470713, // addi x14, x14, 4
      0x8c: 0x34171073, // csrw mepc, x14
      0x90: 0x30200073, // mret
    };
    await coreTest(
      _memString(program),
      {
        Register.x8: 0x11, // M ecall handler ran (ecall -> M works)
        Register.x9: 0x55, // ecall round-trip completed (mret returned to 0x44)
        Register.x7: 0x99, // csrs sie did NOT trap => mret returned to S, not U
      },
      _rc1s(),
      initRegisters: {
        Register.x13: 0x80, // mtvec = M ecall handler
        Register.x10: 0x40, // mepc = S entry
        Register.x11: 0x800, // mstatus.MPP = S
        Register.x12: 0x20, // sie bits
      },
      nextPc: 0x54,
    );
  }, timeout: Timeout(Duration(minutes: 5)));
}
