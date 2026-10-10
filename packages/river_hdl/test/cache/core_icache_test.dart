import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// L1 instruction cache integration: the core fetches through the icache
/// (hits in one cycle, misses fill a line from the MMU). Verifies correctness
/// with the cache enabled, in both single- and dual-dispatch.
void main() => instructionCacheTests();

void instructionCacheTests({HarborL1CacheConfig? cacheConfig}) {
  tearDown(() async {
    await Simulator.reset();
  });

  HarborMmuConfig mmu() => HarborMmuConfig(
    mxlen: RiscVMxlen.rv32,
    pagingModes: const [RiscVPagingMode.bare],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
  );

  RiverCoreConfig icacheSingle() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv32,
    extensions: [rv32i, rvZicsr, rvZifencei, rvM],
    interrupts: [],
    mmu: mmu(),
    type: RiverCoreType.general,
    executionMode: ExecutionMode.outOfOrder,
    speculativeFetch: true,
    l1cache:
        cacheConfig ??
        HarborL1CacheConfig.split(iSize: 32, dSize: 64, ways: 1, lineSize: 4),
  );

  RiverCoreConfig icacheDual() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv32,
    extensions: [rv32i, rvZicsr, rvZifencei, rvM],
    interrupts: [],
    mmu: mmu(),
    type: RiverCoreType.general,
    executionMode: ExecutionMode.outOfOrder,
    speculativeFetch: true,
    issueWidth: IssueWidth.dual,
    l1cache:
        cacheConfig ??
        HarborL1CacheConfig.split(iSize: 32, dSize: 64, ways: 1, lineSize: 4),
  );

  int iimm(int imm, int rs1, int f3, int rd) =>
      (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
  String prog(List<int> words) {
    final sb = StringBuffer('@0\n');
    for (final w in words) {
      for (var b = 0; b < 4; b++) {
        sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return '$sb\n';
  }

  // Single-dispatch through the icache: tight RAW chain (also re-fetches the
  // same lines as the program is short, exercising cache hits).
  test(
    'icache: single-dispatch RAW chain',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(1, 0, 0x0, 1),
        iimm(1, 1, 0x0, 2),
        iimm(1, 2, 0x0, 3),
        iimm(1, 3, 0x0, 4),
        iimm(1, 4, 0x0, 5),
        ...List.filled(8, 0x00000013),
      ]),
      {
        Register.x1: 1,
        Register.x2: 2,
        Register.x3: 3,
        Register.x4: 4,
        Register.x5: 5,
      },
      icacheSingle(),
      nextPc: 0x34,
    ),
  );

  // Dual-dispatch through the icache: independent ALU pairs. Both fetch lanes
  // hit the same cache line and are served the same cycle.
  test(
    'icache: dual-dispatch independent pairs',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(0x111, 0, 0x0, 1),
        iimm(0x222, 0, 0x0, 2),
        iimm(0x333, 0, 0x0, 3),
        iimm(0x444, 0, 0x0, 4),
        ...List.filled(8, 0x00000013),
      ]),
      {
        Register.x1: 0x111,
        Register.x2: 0x222,
        Register.x3: 0x333,
        Register.x4: 0x444,
      },
      icacheDual(),
      nextPc: 0x2C,
    ),
  );
}
