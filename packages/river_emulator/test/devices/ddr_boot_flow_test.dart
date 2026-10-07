import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

/// End-to-end boot flow in the emulator: an FSBL (Weir's first-stage boot
/// loader, in `train=runtime` mode) runs from SRAM, drives the real wb2
/// knob-ABI sequence to sweep the IDELAY read tap into the eye, initialises
/// main RAM by writing a tiny payload into the now-usable DRAM, then jumps to
/// and executes that payload from DRAM. Proves the DDR-training -> main-RAM
/// -> jump leg works as a whole, against the same register protocol Weir's
/// `ddr_train.zig` drives on real hardware: write the knob, CTL SET, CTL
/// APPLY, then check the array. CAR (rcache* CSRs -> l1d.lockRange) and flash
/// XIP are exercised separately. This focuses on the DRAM bring-up leg.
void main() {
  // RV64 instruction encoders (subset).
  int lui(int rd, int imm20) => ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37;
  int iimm(int rd, int rs1, int imm, int f3) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
  int addi(int rd, int rs1, int imm) => iimm(rd, rs1, imm, 0x0);
  int store(int rs2, int rs1, int imm, int f3) {
    final lo = imm & 0x1F;
    final hi = (imm >> 5) & 0x7F;
    return (hi << 25) |
        (rs2 << 20) |
        (rs1 << 15) |
        (f3 << 12) |
        (lo << 7) |
        0x23;
  }

  int sw(int rs2, int rs1, int imm) => store(rs2, rs1, imm, 0x2);
  int lw(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (0x2 << 12) | (rd << 7) | 0x03;
  int branch(int rs1, int rs2, int imm, int f3) {
    final b12 = (imm >> 12) & 0x1;
    final b11 = (imm >> 11) & 0x1;
    final b10_5 = (imm >> 5) & 0x3F;
    final b4_1 = (imm >> 1) & 0xF;
    return (b12 << 31) |
        (b10_5 << 25) |
        (rs2 << 20) |
        (rs1 << 15) |
        (f3 << 12) |
        (b4_1 << 8) |
        (b11 << 7) |
        0x63;
  }

  int beq(int rs1, int rs2, int imm) => branch(rs1, rs2, imm, 0x0);
  int bne(int rs1, int rs2, int imm) => branch(rs1, rs2, imm, 0x1);
  int jal(int rd, int imm) {
    final b20 = (imm >> 20) & 0x1;
    final b10_1 = (imm >> 1) & 0x3FF;
    final b11 = (imm >> 11) & 0x1;
    final b19_12 = (imm >> 12) & 0xFF;
    return (b20 << 31) |
        (b10_1 << 21) |
        (b11 << 20) |
        (b19_12 << 12) |
        (rd << 7) |
        0x6F;
  }

  int jalr(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x67;

  // Load a 32-bit constant into rd (lui + addi with the addi sign carry).
  List<int> li(int rd, int v) {
    v &= 0xFFFFFFFF;
    final lo = v & 0xFFF;
    var hi = (v >> 12) & 0xFFFFF;
    if (lo & 0x800 != 0) hi = (hi + 1) & 0xFFFFF;
    final loSigned = lo & 0x800 != 0 ? lo - 0x1000 : lo;
    return [lui(rd, hi), addi(rd, rd, loSigned)];
  }

  test('FSBL trains DDR, inits main RAM, and runs a payload from DRAM', () async {
    const mxlen = RiscVMxlen.rv64;
    final config = RiverCoreConfigV1.small(
      mmu: HarborMmuConfig(
        mxlen: mxlen,
        pagingModes: const [RiscVPagingMode.bare],
        tlbLevels: const [],
        pmp: HarborPmpConfig.none,
      ),
      interrupts: const [],
      clock: const HarborClockConfig(
        name: 'test',
        rate: HarborFixedClockRate(10000),
      ),
      resetVector: 0,
    );

    // Base bit31 must be clear so RV64 `lui` builds a positive address (lui
    // sign-extends bit31; 0x80000000 would become 0xFFFFFFFF80000000).
    const dramBase = 0x40000000;
    const arraySize = 0x10000; // 64KB array
    const eyeLo = 8, eyeHi = 20;

    // The wb2 knob-ABI register offsets, relative to ctrlBase (matches
    // Ddr3Controller._buildWb2Knobs, stride 8 bytes).
    const regIdelay = 0x10;
    const regCtl = 0x20;
    const ctlSet = 0x1, ctlApply = 0x2;

    final sram = Sram(
      const RiverDevice(
        name: 'sram',
        compatible: 'river,sram',
        range: BusAddressRange(0, 0x10000),
      ),
    );
    final dram = Dram(
      const RiverDevice(
        name: 'dram',
        compatible: 'river,dram',
        range: BusAddressRange(dramBase, arraySize + Dram.trainCtrlSize),
      ),
      trainable: true,
      lanes: 1,
      eyeLo: const [eyeLo],
      eyeHi: const [eyeHi],
    );

    // The payload that runs from DRAM: store the boot magic to SRAM[0x100],
    // then return (jr ra). Built as data, copied into DRAM by the FSBL.
    const magic = 0xB0074EE7;
    const markerAddr = 0x100; // in SRAM
    final payload0 = sw(23, 22, 0); // sw x23, 0(x22)   (x22=marker, x23=magic)
    final payload1 = jalr(0, 1, 0); // jr ra

    const pattern = 0x600DCAFE; // sweep test pattern (bit31 clear: load-safe)
    const payloadDram = dramBase + 0x400; // 0x40000400

    // FSBL program (at 0x0 in SRAM). Registers:
    //   x10=ctrl base, x20=dram base, x21=pattern, x5=tap (IDELAY), x6=CTL
    //   value, x22=marker, x23=magic
    final prog = <int>[
      lui(10, 0x40010), // x10 = ctrlBase (0x40010000)
      lui(20, 0x40000), // x20 = dramBase (0x40000000)
      ...li(21, pattern), // x21 = pattern
      addi(5, 0, 0), // x5 = tap = 0
      // sweep: (pc of this instr = sweepPc)
      sw(5, 10, regIdelay), // IDELAY = tap
      addi(6, 0, ctlSet),
      sw(6, 10, regCtl), // CTL = SET (lane 0)
      addi(6, 0, ctlApply),
      sw(6, 10, regCtl), // CTL = APPLY
      sw(21, 20, 0x00), // DRAM[0] = pattern
      lw(7, 20, 0x00), // read back
      beq(7, 21, 0), // placeholder offset -> patched to 'found'
      addi(5, 5, 1), // tap++
      addi(8, 0, 32),
      bne(5, 8, 0), // placeholder -> back to sweep
      jal(0, 0), // fail: halt-in-place (offset 0 = self loop)
      // found:
      addi(22, 0, markerAddr), // x22 = SRAM marker addr
      ...li(23, magic), // x23 = boot magic
      ...li(24, payload0), // payload instr 0
      sw(24, 20, 0x400), // DRAM[0x400] = payload0
      ...li(25, payload1), // payload instr 1
      sw(25, 20, 0x404), // DRAM[0x404] = payload1
      sw(5, 0, 0x104), // SRAM[0x104] = found tap
      ...li(26, payloadDram), // x26 = DRAM payload addr
      jalr(1, 26, 0), // jump+link: EXECUTE the payload from DRAM
      // returns here:
      jal(0, 0), // done: halt-in-place
    ];

    // Patch the branch offsets now that the layout is known (4 bytes/instr).
    // Indices are into the FLATTENED prog list, so they count li()'s two words.
    final sweepIdx = prog.indexOf(sw(5, 10, regIdelay)); // first sweep instr
    final beqIdx = prog.indexOf(beq(7, 21, 0)); // the beq placeholder
    final bneIdx = prog.indexOf(bne(5, 8, 0)); // the bne placeholder
    final foundIdx = prog.indexOf(addi(22, 0, markerAddr)); // 'found:' instr
    prog[beqIdx] = beq(7, 21, (foundIdx - beqIdx) * 4);
    prog[bneIdx] = bne(5, 8, (sweepIdx - bneIdx) * 4);

    final core = RiverCore(
      config,
      memDevices: Map.fromEntries([sram.mem!, dram.mem!]),
    );
    core.reset();

    // Load the FSBL into SRAM at 0.
    for (var i = 0; i < prog.length; i++) {
      await core.mmu.write(i * 4, prog[i], 4);
    }

    // Run until the program parks in a self-loop (pc stops advancing) or a cap.
    var pc = config.resetVector;
    for (var i = 0; i < 200000; i++) {
      final next = await core.runPipeline(pc);
      if (next == pc) break; // hit a `jal x0, 0` self-loop
      pc = next;
    }

    // The payload executed from DRAM and wrote the magic into SRAM.
    final marker = await core.mmu.read(markerAddr, 4);
    expect(
      marker & 0xFFFFFFFF,
      magic,
      reason: 'payload should have run from DRAM and written the magic',
    );

    // The FSBL recorded a working tap, and it is inside the eye.
    final tap = await core.mmu.read(0x104, 4);
    expect(
      tap,
      inInclusiveRange(eyeLo, eyeHi),
      reason: 'FSBL should have trained the IDELAY tap into the eye',
    );
  });
}
