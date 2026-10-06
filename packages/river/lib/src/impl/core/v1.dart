import 'package:harbor/harbor.dart';
import '../../river_base.dart';
import '../../fp_extra.dart';

/// V1 core tier definitions.
///
/// Each tier is a complete identity: ISA, supervisor/user, and pipeline
/// personality (execution mode + issue width) are all set by the tier and not
/// overridable. To experiment with a different pipeline configuration, define
/// a new tier rather than punching a hole through an existing one.
class RiverCoreConfigV1 extends RiverCoreConfig {
  /// Default split L1 for the cache-bearing RC1 tiers: direct-mapped with
  /// single-word lines, so each miss is one paced memory read rather than a
  /// burst. Boards may override via the tier's `l1cache` parameter.
  static HarborL1CacheConfig _rc1L1() =>
      HarborL1CacheConfig.split(iSize: 64, dSize: 256, ways: 1, lineSize: 8);

  /// RC1.n - River Core V1 nano (RV32IC), in-order single-issue, MCU tier
  /// (e.g. iCESugar up5k). Lean and FPGA-friendly.
  RiverCoreConfigV1.nano({
    super.vendorId = 0,
    super.archId = riverArchId,
    super.hartId = 0,
    super.resetVector = 0,
    required super.mmu,
    required super.interrupts,
    required super.clock,
    super.l1cache,
  }) : super(
         mxlen: RiscVMxlen.rv32,
         extensions: [rvC, rv32i],
         hasSupervisor: false,
         hasUser: false,
         type: RiverCoreType.mcu,
         executionMode: ExecutionMode.inOrder,
         issueWidth: IssueWidth.single,
         // MCU tier: no L1 cache, area-first. Microcode datapath (ROM + one
         // shared ALU) instead of the static per-instruction fabric: smaller
         // area, slower per instruction.
         microcodeMode: MicrocodeMode.full,
       );

  /// RC1.mi - River Core V1 micro (RV32IMAC_Zicsr_Zifencei), in-order
  /// single-issue, embedded general-purpose tier.
  RiverCoreConfigV1.micro({
    super.vendorId = 0,
    super.archId = riverArchId,
    super.hartId = 0,
    super.resetVector = 0,
    required super.mmu,
    required super.interrupts,
    required super.clock,
    super.l1cache,
  }) : super(
         mxlen: RiscVMxlen.rv32,
         extensions: [rvC, rvZicsr, rvZifencei, rvM, rvA, rvPriv, rv32i],
         type: RiverCoreType.general,
         executionMode: ExecutionMode.inOrder,
         issueWidth: IssueWidth.single,
         // Embedded tier: no L1 cache (l1cache stays null), area-first.
       );

  /// RC1.s - River Core V1 small (RV64IMAC_Zicsr_Zifencei), in-order
  /// single-issue, RV64 general-purpose tier.
  RiverCoreConfigV1.small({
    super.vendorId = 0,
    super.archId = riverArchId,
    super.hartId = 0,
    super.resetVector = 0,
    required super.mmu,
    required super.interrupts,
    required super.clock,
    super.regfileReadLatency,
    HarborL1CacheConfig? l1cache,
  }) : super(
         l1cache: l1cache ?? _rc1L1(),
         mxlen: RiscVMxlen.rv64,
         extensions: [rvC, rvZicsr, rvZifencei, rvM, rvA, rvPriv, rv64i, rv32i],
         type: RiverCoreType.general,
         executionMode: ExecutionMode.inOrder,
         issueWidth: IssueWidth.single,
         // Split L1 (see [_rc1L1]) is part of this tier: single-word fills mean
         // DRAM sees only paced reads, a correctness lever on creek's DDR PHY,
         // not just a perf choice. Microcode datapath (shared ALU) over the
         // static fabric: ~12k vs ~21k LUT on small FPGAs.
         microcodeMode: MicrocodeMode.full,
         // Decode 2 pattern-ROM entries/cycle: halves the decode pattern-scan
         // (the biggest per-instruction cost) for a couple of comparators of
         // area, staying fully microcoded + patchable. Bigger tiers scale up.
         microcodeDecodeLanes: 2,
       );

  /// RC1.f - River Core V1 full (RV64GC_Zicsr_Zifencei), in-order single-issue,
  /// the RV64 application tier with hardware floating point (G = IMAFD). Same
  /// scalar personality as [small]; adds F/D. See docs/core/design.md.
  RiverCoreConfigV1.full({
    super.vendorId = 0,
    super.archId = riverArchId,
    super.hartId = 0,
    super.resetVector = 0,
    required super.mmu,
    required super.interrupts,
    required super.clock,
    super.regfileReadLatency,
    HarborL1CacheConfig? l1cache,
  }) : super(
         l1cache: l1cache ?? _rc1L1(),
         mxlen: RiscVMxlen.rv64,
         extensions: [
           rvC,
           rvZicsr,
           rvZifencei,
           rvM,
           rvA,
           rvF,
           rvD,
           rvFExtra,
           rvDExtra,
           // c.fld/c.fsd/c.fldsp/c.fsdsp. They belong to C only when D is
           // present, so they are a separate extension (see rvZcd).
           rvZcd,
           rvPriv,
           rv64i,
           rv32i,
         ],
         type: RiverCoreType.general,
         executionMode: ExecutionMode.inOrder,
         issueWidth: IssueWidth.single,
         // Same scalar personality as [small] (+ F/D), so it carries the same
         // L1 caches (see [_rc1L1]) and the same microcode datapath: the shared
         // ALU keeps area near ~12k (+ FPU) instead of the ~21k-LUT static
         // fabric, and it lets yosys synthesize (the static exec unit's giant
         // FSM does not converge). Matches [small]'s microcode settings.
         microcodeMode: MicrocodeMode.full,
         microcodeDecodeLanes: 2,
       );

  /// RC1.ma - River Core V1 macro (RV64GC_Zba_Zbb_Zbs): out-of-order,
  /// dual-issue RV64GC, the big-chip superscalar tier (docs/core/design.md).
  /// The CompressedFetchBuffer + InstructionAligner co-dispatch two
  /// variable-length instructions per cycle; the static decoder handles RVC.
  RiverCoreConfigV1.macro({
    super.vendorId = 0,
    super.archId = riverArchId,
    super.hartId = 0,
    super.resetVector = 0,
    required super.mmu,
    required super.interrupts,
    required super.clock,
    HarborL1CacheConfig? l1cache,
  }) : super(
         l1cache: l1cache ?? _rc1L1(),
         mxlen: RiscVMxlen.rv64,
         // Base ISA first: the OoO static decoder takes the first matching
         // pattern, and Zba/Zbb/Zbs share OP-IMM/OP opcodes with the base ALU
         // ops, so base-first gives plain add/addi decode priority.
         extensions: [
           rv64i,
           rv32i,
           rvC,
           rvZicsr,
           rvZifencei,
           rvM,
           rvA,
           rvPriv,
           rvF,
           rvD,
           rvFExtra,
           rvDExtra,
           // c.fld/c.fsd/c.fldsp/c.fsdsp (see rvZcd).
           rvZcd,
           rvZba,
           rvZbb,
           rvZbs,
         ],
         type: RiverCoreType.general,
         executionMode: ExecutionMode.outOfOrder,
         speculativeFetch: true,
         issueWidth: IssueWidth.dual,
         // OoO dual-issue: L1 caches (see [_rc1L1]) are part of the tier; the
         // I-cache runs dual-port (both fetch lanes), wired from issueWidth.
       );
}
