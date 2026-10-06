import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../adversarial_memory.dart';
import '../core_harness.dart';

/// Two virtual addresses, ONE physical word: does a store through one of them
/// become visible to a load through the other?
///
/// The L1 D-cache is virtually indexed and virtually tagged. A store is
/// write-through and drops the resident line only when the STORED virtual
/// address hits it (`storeInv < addrHitOf(reqAddr) & cacheableOf(reqAddr)` in
/// harbor l1_cache.dart). A second virtual address for the same physical page
/// carries a DIFFERENT tag, so the store does not drop its line and a later
/// load through it returns the pre-store value.
///
/// RVWMO requires a hart's load to return its own most recent store to the same
/// address, and "the same address" is the PHYSICAL address. So a cache that
/// misses this breaks the memory model, with no fence a compiler or a kernel is
/// obliged to insert.
///
/// Linux creates these aliases constantly: the linear map and vmemmap over the
/// same frames, vmalloc/vmap and module text, kmap, and DMA buffers. The
/// reported failures all have this shape: a word that should be a pointer holds
/// the value it had before some other mapping wrote it.
///
/// Line arithmetic (D-cache 256 B, 8-byte lines, direct mapped, xlen 64):
/// index = VA[7:3], tag = VA[38:8] plus the 2-bit privilege context.
///
///   VA1 0x80002000 -> index (0x80002000 >> 3) & 0x1F = 0, tag 0x800020
///   VA2 0xC0002000 -> index (0xC0002000 >> 3) & 0x1F = 0, tag 0xC00020
///
/// Both are at or above `cacheableBase` (0x80000000), so both take the CACHED
/// path. The index bits live inside the 4 KB page offset, so every synonym of a
/// physical word lands on the SAME line, which is what makes the store's
/// tag-matched invalidate miss it.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const codeBase = 0x00001000; // region 0, identity mapped
  const rootTablePa = 0x00002000;
  const satpValue = 0x8000000000000000 | (rootTablePa >> 12);

  // Region 2 and region 3 both map to the SAME 1 GB physical megapage.
  const va1 = 0x80002000;
  const va2 = 0xC0002000;
  const sharedPa = 0x40002000;

  // Bit 63 stays clear: the harness compares LogicValue.toInt() to a Dart int.
  const initial = 0x0A0A0A0A11111111;
  const poison = 0x0C0C0C0C33333333;

  int megapage(int pa) => ((pa >> 12) << 10) | 0xCF;

  int ld(int rd, int rs1, int imm) =>
      ((imm & 0xfff) << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x03;
  int sd(int rs2, int rs1, int imm) =>
      (((imm >> 5) & 0x7f) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (3 << 12) |
      ((imm & 0x1f) << 7) |
      0x23;
  int jal(int rd, int imm) =>
      (((imm >> 20) & 1) << 31) |
      (((imm >> 1) & 0x3ff) << 21) |
      (((imm >> 11) & 1) << 20) |
      (((imm >> 12) & 0xff) << 12) |
      (rd << 7) |
      0x6f;
  int csrrw(int rd, int csr, int rs1) =>
      (csr << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x73;
  const csrSatp = 0x180;

  String memImage(Map<int, List<int>> words) {
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

  List<int> word64(int v) => [v & 0xFFFFFFFF, (v >> 32) & 0xFFFFFFFF];

  RiverCoreConfig cfg() => RiverCoreConfigV1.full(
    resetVector: codeBase,
    interrupts: [],
    regfileReadLatency: 1,
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

  const posted = AdversarialMemory(
    postedWriteCycles: 3,
    readsPassPendingWrites: true,
    seed: 13,
  );

  //   csrw satp,x29    one address space, two mappings of one page
  //   ld   x5,0(x20)   VA1 -> initial, fills D-cache line 0 with tag(VA1)
  //   sd   x21,0(x22)  store the poison through VA2, the SAME physical word
  //   ld   x6,0(x20)   VA1 again: RVWMO says this is the poison
  //   ld   x7,0(x22)   VA2: the poison, so the store definitely landed
  final body = <int>[
    csrrw(0, csrSatp, 29),
    ld(5, 20, 0),
    sd(21, 22, 0),
    ld(6, 20, 0),
    ld(7, 22, 0),
    jal(0, 0),
  ];
  final parkPc = codeBase + (body.length - 1) * 4;

  final image = memImage({
    codeBase: body,
    rootTablePa: [
      for (final pa in [0x00000000, 0x40000000, 0x40000000, 0x40000000]) ...[
        megapage(pa),
        0,
      ],
    ],
    sharedPa: word64(initial),
  });

  test(
    'a store through one mapping is visible through another mapping',
    timeout: const Timeout(Duration(minutes: 30)),
    () => coreTest(
      image,
      {
        // Controls first: the first load must have seen the page, and the
        // store must have reached memory.
        Register.x5: initial,
        Register.x7: poison,
        // The property under test.
        Register.x6: poison,
      },
      cfg(),
      initRegisters: {
        Register.x20: va1,
        Register.x21: poison,
        Register.x22: va2,
        Register.x29: satpValue,
      },
      startPriv: PrivilegeMode.supervisor,
      nextPc: parkPc,
      maxCycles: 200000,
      memory: posted,
      memStates: {sharedPa: poison},
    ),
  );

  //   Same page, same physical word, but now the SECOND mapping is read first
  //   and the store goes through the FIRST. The hazard is symmetric, so both
  //   orders must hold.
  final bodyReverse = <int>[
    csrrw(0, csrSatp, 29),
    ld(5, 22, 0),
    sd(21, 20, 0),
    ld(6, 22, 0),
    ld(7, 20, 0),
    jal(0, 0),
  ];

  final imageReverse = memImage({
    codeBase: bodyReverse,
    rootTablePa: [
      for (final pa in [0x00000000, 0x40000000, 0x40000000, 0x40000000]) ...[
        megapage(pa),
        0,
      ],
    ],
    sharedPa: word64(initial),
  });

  test(
    'the same, with the two mappings swapped',
    timeout: const Timeout(Duration(minutes: 30)),
    () => coreTest(
      imageReverse,
      {Register.x5: initial, Register.x7: poison, Register.x6: poison},
      cfg(),
      initRegisters: {
        Register.x20: va1,
        Register.x21: poison,
        Register.x22: va2,
        Register.x29: satpValue,
      },
      startPriv: PrivilegeMode.supervisor,
      nextPc: codeBase + (bodyReverse.length - 1) * 4,
      maxCycles: 200000,
      memory: posted,
      memStates: {sharedPa: poison},
    ),
  );
}
