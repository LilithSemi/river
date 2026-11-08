import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';
import '../matrix_encoders.dart';

/// Repro for the rc1-f (delta) register-file wipe seen on real hardware: the
/// first full SD 512-byte block read corrupts the GPR file (gp/sp/ra/tp all read
/// 0 over JTAG, CSRs survive) and Weir floods '0'. The SD path is the first heavy
/// user of `fence`/`fence r,rw` (volatile MMIO ordering) and of an MMIO store /
/// poll / byte-copy loop. These sub-tests seed witness registers that the code
/// under test never touches, so any that come back changed pin a wrong microcode
/// writeback. Absolute expectations (not an emulator-golden compare, which would
/// pass if the emulator shares the bug), same style as the c.jalr link repro.
HarborMmuConfig _mmu() => HarborMmuConfig(
  mxlen: RiscVMxlen.rv64,
  pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
  tlbLevels: const [],
  pmp: HarborPmpConfig.none,
  hasSupervisorUserMemory: true,
  hasMakeExecutableReadable: true,
);

const _clk = HarborClockConfig(
  name: 'test',
  rate: HarborFixedClockRate(12000000),
);

// regfileReadLatency: 1 matches the Arty (openXc7) build, where the integer
// regfile is a registered-read BRAM. The harness otherwise builds a
// target-less core whose flop regfile reads combinationally (latency 0), so a
// microcode read-handshake bug in the registered-read path is invisible. Force
// latency 1 on the (still simulatable) flop backend to expose it.
RiverCoreConfig _rc1f() => RiverCoreConfigV1.full(
  mmu: _mmu(),
  interrupts: [],
  clock: _clk,
  resetVector: 0,
  regfileReadLatency: 1,
);

String _memString(List<int> words) {
  final sb = StringBuffer('@0\n');
  for (final w in words) {
    for (var b = 0; b < 4; b++) {
      sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
  }
  return '${sb.toString().trimRight()}\n';
}

// Witness registers the code under test must never modify. gp (x3) and tp (x4)
// are the strongest tells: software sets them once at boot and never again, and
// the ABI never spills them, so a change is a raw regfile write.
const _witness = <Register, int>{
  Register.x3: 0x3333, // gp
  Register.x4: 0x4444, // tp
  Register.x8: 0x8888, // s0
  Register.x9: 0x9999, // s1
  Register.x18: 0x1818, // s2
};

const _fence = 0x0ff0000f; // fence iorw, iorw
const _fenceRrw =
    0x0230000f; // fence r, rw  (acquire/release form the SD path emits)
const _fenceI = 0x0000100f; // fence.i
const _nop = 0x00000013;

void main() {
  // A: fences alone. The SD path wraps every MMIO poke in these.
  test('rc1-f: fences do not disturb the register file', () async {
    await Simulator.reset();
    final program = <int>[_fence, _fenceRrw, _fenceI, _nop];
    await coreTest(
      _memString(program),
      _witness,
      _rc1f(),
      initRegisters: _witness,
      nextPc: program.length * 4, // 0x10
    );
  }, timeout: Timeout(Duration(minutes: 5)));

  // B: the MMIO store / status-poll / data-read / byte-copy loop, the shape of
  // conduit readData over the harbor SPI master. a0 is the MMIO base (flat RAM
  // here, so the status read returns 0 = ready and the loop drains), a1 the
  // destination buffer, a2 the byte count.
  test('rc1-f: MMIO poke + byte-copy loop keeps the witnesses', () async {
    await Simulator.reset();
    // loop @0x00 (7 insns, 28 bytes); halt nop @0x1c.
    final program = <int>[
      store(16, 13, 10, 0x2), // sw   a3, 16(a0)   MMIO data write (a3 = 0xFF)
      load(8, 10, 0x2, 5), //    lw   t0, 8(a0)    status poll (reads 0 = ready)
      load(16, 10, 0x4, 6), //   lbu  t1, 16(a0)   data byte
      store(0, 6, 11, 0x0), //   sb   t1, 0(a1)    into the buffer
      iimm(1, 11, 0x0, 11), //   addi a1, a1, 1
      iimm(-1, 12, 0x0, 12), //  addi a2, a2, -1
      branch(-24, 0, 12, 0x1), // bne a2, x0, loop
      _nop, // 0x1c halt
    ];
    await coreTest(
      _memString(program),
      _witness,
      _rc1f(),
      initRegisters: <Register, int>{
        ..._witness,
        Register.x10: 0x1000, // a0 MMIO base (flat RAM)
        Register.x11: 0x2000, // a1 buffer
        Register.x12: 4, //      a2 count
        Register.x13: 0xFF, //   a3 data byte
      },
      nextPc: program.length * 4, // 0x20
    );
  }, timeout: Timeout(Duration(minutes: 5)));

  // D: the instruction types the REAL sd_spi readBlocksImpl uses that A/B did
  // not cover: halfword sh/lh/lhu, an indirect jalr call (the c.jalr bug's
  // family), and sext.w/subw. Same loop shape, same witnesses.
  test(
    'rc1-f: halfword + indirect-jalr + word-op loop keeps the witnesses',
    () async {
      await Simulator.reset();
      final program = <int>[
        // loop @0x00
        store(132, 13, 10, 0x1), // sh   a3, 132(a0)   halfword store
        load(130, 10, 0x5, 5), //   lhu  t0, 130(a0)   halfword load unsigned
        load(128, 10, 0x1, 6), //   lh   t1, 128(a0)   halfword load signed
        iimmW(0, 5, 0x0, 7), //     sext.w t2, t0
        rtypeW(0x20, 6, 7, 0x0, 7), // subw t2, t2, t1
        jalr(0, 15, 1), //          jalr ra, 0(a5)     indirect call subroutine
        iimm(-1, 12, 0x0, 12), //   addi a2, a2, -1
        branch(-28, 0, 12, 0x1), // bne  a2, x0, loop (back to 0x00)
        jal(8, 0), //     0x20      j    end (skip subroutine)
        0x00008067, //    0x24      ret (subroutine: jalr x0, 0(ra))
        _nop, //          0x28      halt
      ];
      await coreTest(
        _memString(program),
        _witness,
        _rc1f(),
        initRegisters: <Register, int>{
          ..._witness,
          Register.x10: 0x1000, // a0 MMIO base
          Register.x12: 3, //      a2 count
          Register.x13: 0xFF, //   a3 store data
          Register.x15: 0x24, //   a5 subroutine address
        },
        nextPc: program.length * 4, // 0x2c
      );
    },
    timeout: Timeout(Duration(minutes: 5)),
  );

  // E: I-CACHE THRASH. rc1-f L1 I-cache is 64 bytes, direct-mapped, 8-byte lines
  // (HarborL1CacheConfig.split iSize:64 ways:1 lineSize:8). Tests A/B/D are tiny
  // and fit entirely in cache, so they never exercise eviction/refill. This loop
  // BODY is 80 bytes (20 instrs) > the whole 64-byte cache, so every iteration
  // evicts and refills every line. If the direct-mapped refill/tag path has a
  // bug, the re-fetched instructions are wrong and the witnesses get scribbled
  // or the loop mis-terminates. This is the stress the real 512-iteration SD
  // read applies to the I-cache that a functional flop-sim of tiny code hides.
  test('rc1-f: I-cache thrash (loop body > cache) keeps the witnesses', () async {
    await Simulator.reset();
    final body = <int>[
      for (var i = 0; i < 18; i++)
        iimm(1, 5, 0x0, 5), // 18x addi t0, t0, 1  (0x00..0x44)
      iimm(
        -1,
        12,
        0x0,
        12,
      ), //                            addi a2, a2, -1     (0x48)
      branch(
        -76,
        0,
        12,
        0x1,
      ), //                          bne  a2, x0, 0x00   (0x4c)
    ];
    final program = <int>[...body, _nop]; // halt nop at 0x50
    await coreTest(
      _memString(program),
      _witness,
      _rc1f(),
      initRegisters: <Register, int>{
        ..._witness,
        // 3 iterations: iter 1 fills + evicts lines, iters 2-3 re-fetch the
        // evicted lines. Enough to exercise refill without exceeding the
        // harness maxSimTime (a normal run finishes well under it, so a TIMEOUT
        // here means the core wedged = the bug reproduced).
        Register.x12: 3, // a2 loop count
      },
      nextPc: body.length * 4, // 0x50
    );
  }, timeout: Timeout(Duration(minutes: 6)));

  // F: D-CACHE thrash + stack round-trip. rc1-f L1 D-cache is 256 bytes,
  // direct-mapped, 8-byte lines. This is the closest model of what the SD block
  // read does that IDENTIFY does not: save regs to the stack, then write a
  // buffer LARGER than the D-cache (320 B > 256 B) that evicts the saved stack
  // lines, then reload the saved regs (miss -> refill from memory). If the
  // write-through / eviction / refill round-trip is buggy, the reloaded
  // witnesses come back wrong - which on real code is the epilogue restoring a
  // garbage `ra`, `ret` to a bad address, and the flood. The witnesses are
  // clobbered to 0 after the save, so ONLY a correct reload restores them.
  test('rc1-f: D-cache thrash + stack reload keeps the witnesses', () async {
    await Simulator.reset();
    final program = <int>[
      store(
        0,
        8,
        2,
        0x3,
      ), //   sd s0, 0(sp)     save witnesses to stack (0x4000)
      store(8, 9, 2, 0x3), //   sd s1, 8(sp)
      store(16, 18, 2, 0x3), // sd s2, 16(sp)
      iimm(0, 0, 0x0, 8), //    li s0, 0         clobber, so reload must restore
      iimm(0, 0, 0x0, 9), //    li s1, 0
      iimm(0, 0, 0x0, 18), //   li s2, 0
      // loop @0x18: write 40 dwords (320 B) to the buffer, evicting the stack lines
      store(0, 13, 10, 0x3), // sd a3, 0(a0)
      iimm(8, 10, 0x0, 10), //  addi a0, a0, 8
      iimm(-1, 12, 0x0, 12), // addi a2, a2, -1
      branch(-12, 0, 12, 0x1), // bne a2, x0, 0x18
      load(
        0,
        2,
        0x3,
        8,
      ), //    ld s0, 0(sp)     reload (miss -> refill from memory)
      load(8, 2, 0x3, 9), //    ld s1, 8(sp)
      load(16, 2, 0x3, 18), //  ld s2, 16(sp)
      _nop, // halt
    ];
    await coreTest(
      _memString(program),
      _witness,
      _rc1f(),
      initRegisters: <Register, int>{
        ..._witness,
        // Cacheable DRAM (>= cacheableBase 0x80000000): loads here go through the
        // fill path, so this exercises the real eviction/refill the SD read hits,
        // not the uncached bypass.
        Register.x2: 0x80010000, //  sp stack base
        Register.x10: 0x80010040, // a0 buffer (sp + 64)
        Register.x12: 40, //         a2 dword count (320 B > 256 B D-cache)
        Register.x13: 0xAA, //       a3 buffer fill data
      },
      nextPc: (program.length - 1) * 4, // halt nop
    );
  }, timeout: Timeout(Duration(minutes: 6)));

  // G: MINIMAL round-trip, NO thrash. Save 3 regs to the stack, clobber, reload.
  // If s2 still comes back wrong with no eviction, the bug is a plain
  // store/clobber/reload (or a 3rd-back-to-back-load) issue, not cache eviction.
  test('rc1-f: minimal stack round-trip (no thrash)', () async {
    await Simulator.reset();
    // Does a COMPRESSED c.addi16sp update the regfile copy of sp that FULL
    // instructions read? readBlocks adjusts sp with c.addi16sp, then does full
    // `sd`s. If c.addi16sp updates only the nextSp fast-path, the full store's
    // sp (regfile[2]) is stale -> corruption.
    //   0x00: lui  x2, 0x1        sp = 0x1000
    //   0x04: addi x2, x2, 0x40   sp = 0x1040 (syncs nextSp + regfile[2])
    //   0x08: c.addi16sp sp, +16  sp = 0x1050  (0x6141)
    //   0x0a: c.nop               (0x0001)
    //   0x0c: addi x5, x2, 0      x5 = sp read via REGFILE
    //   0x10: nop
    // The readBlocks pattern: compressed c.sdsp saves + c.ldsp restores around a
    // cacheable sp (nextSp fast-path + D-cache). sp = 0xFFFFFFFF80001000.
    //   lui sp,0x80001 ; c.sdsp s0/s1/s2 ; clobber ; c.ldsp s0/s1/s2 ; nop
    final program = <int>[
      0x80001137, //   lui sp, 0x80001
      0xE426E022, //   c.sdsp s0,0(sp) | c.sdsp s1,8(sp)
      0x0001E84A, //   c.sdsp s2,16(sp) | c.nop
      0x00000413, //   li s0, 0
      0x00000493, //   li s1, 0
      0x00000913, //   li s2, 0
      0x64A26402, //   c.ldsp s0,0(sp) | c.ldsp s1,8(sp)
      0x00016942, //   c.ldsp s2,16(sp) | c.nop
      _nop,
    ];
    await coreTest(
      _memString(program),
      _witness, // s0/s1/s2 must survive the compressed save/restore
      _rc1f(),
      initRegisters: _witness,
      nextPc: 0x20,
    );
  }, timeout: Timeout(Duration(minutes: 6)));
}
