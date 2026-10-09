import 'package:river/river.dart';

/// The config table for the test matrix: maps (mxlen, microarch, instruction
/// category) to a RiverCoreConfig + label, and gates which microarch x category
/// combinations are actually buildable. List-driven and extensible.

/// Microarchitecture axis.
enum Uarch { inOrder, ooo, oooDual }

String uarchLabel(Uarch u) => switch (u) {
  Uarch.inOrder => 'inorder',
  Uarch.ooo => 'ooo',
  Uarch.oooDual => 'ooo_dual',
};

String mxlenLabel(RiscVMxlen m) => m == RiscVMxlen.rv64 ? 'rv64' : 'rv32';

/// Extensions each instruction category needs beyond the base ISA. The category
/// key is also the directory name (`test/<category>/`). Adding an extension is
/// a new entry here + an entry in the instruction table.
final Map<String, List<RiscVExtension>> categoryExtensions = {
  'base': <RiscVExtension>[],
  'loadstore': <RiscVExtension>[],
  'branch': <RiscVExtension>[],
  'csr': <RiscVExtension>[], // Zicsr is always enabled in matrixConfig

  'm': [rvM],
  'a': [rvA],
  'bitmanip': [rvZba, rvZbb, rvZbs],
  'zicond': [rvZicond],
  'zacas': [rvA, rvZacas],
  // Single-precision F. The fd cells are all .s and now elaborate + pass on
  // BOTH rv32 and rv64 (task #71 coerced the FP read/write ports, the result
  // switch, and the roundSatFpToInt W/L mux to the mxlen width). Double stays
  // its own rv64-only 'd' category.
  'fd': [rvF],
  // Double-precision (rv64 only - see generator gate). rv64+D elaborates fine.
  'd': [rvF, rvD],
  'v': [rvV], // vector (VLEN defaults to 128 in RiverCoreConfig)
};

/// Categories that run ONLY on speculative (OoO/dual) configs. Empty now: the
/// in-order taken-branch path is fixed (#69 - exec.dart branch target was
/// missing `currentPc +` and the lt/ge/ltu/geu condition used the unsigned diff
/// sign), so the branch category runs in-order too without a predictor.
const _speculativeOnlyCategories = <String>{};

/// Categories that run ONLY on the in-order path for now. Reasons per category:
///  - loadstore/a/zacas: the OoO memory FU is incomplete (stores don't drain/
///    commit, AMO writeback returns 0, sign-ext loads don't sign-extend - see
///    project_hdl_ooo_state / project_hdl_lsq).
///  (csr now runs on OoO too - #70 fixed: the CsrUnit op-decode + the zimm
///  plumbing were wrong; csrrw/csrrs/csrrc/csrrwi all pass on OoO.)
///  - fd: the OoO core is INTEGER-ONLY (no FP functional unit); F/D execute
///    only on the in-order path (project_hdl_fpu).
/// Flip a category out the moment its OoO path lands - the matrix then
/// validates it immediately.
const _inOrderOnlyCategories = {
  'loadstore',
  'a',
  'zacas',
  'fd',
  'd',
  'v', // vector uses vector loads/stores (OoO mem FU incomplete) + in-order path
};

/// Whether (microarch, category) is a buildable + runnable matrix cell-set.
bool microarchSupports(Uarch u, String category) {
  if (u == Uarch.inOrder) return !_speculativeOnlyCategories.contains(category);
  return !_inOrderOnlyCategories.contains(category);
}

/// Build the config for (mxlen, microarch, category): base ISA + the category's
/// extensions, on the requested mxlen and pipeline personality.
/// The split L1 the rc1 tiers carry. The matrix ran with NO cache at all, so
/// every cell reached memory directly and the real I-cache/D-cache never saw a
/// single hit, fill, store or fault. Two shipped bugs lived in exactly that gap:
/// the D-cache had no faulting-response path (a NULL dereference froze the core
/// instead of trapping), and both L1s went stale across an address-space switch.
/// Pass `cached: true` to run a config through the real hierarchy.
/// The default line is 8 bytes, which on rv64 is exactly ONE word, so the D-cache
/// fill FSM never iterates. Pass a bigger [lineSize] to cover the multi-word fill
/// loop (the fillWord counter and the per-word refill address walk).
HarborL1CacheConfig matrixL1({
  int iSize = 64,
  int dSize = 256,
  int lineSize = 8,
}) => HarborL1CacheConfig.split(
  iSize: iSize,
  dSize: dSize,
  ways: 1,
  lineSize: lineSize,
);

/// The paged matrix variant runs the SAME cells through Sv39 translation. The
/// whole matrix ran in bare mode, so no cell ever went through the translation
/// datapath, the TLB or the page-table walker. The core ships in Sv39 under
/// Linux, and bugs lived in exactly that gap (both virtually tagged L1 caches
/// kept their lines across an address-space switch).
///
/// The map is an IDENTITY map of Sv39 1GB megapages, so VA == PA. No cell
/// address changes and the emulator goldens stay valid.

/// Physical address of the Sv39 root page table for the paged variant. It is
/// above every address the cells use and below the 1MB emulator SRAM top.
const matrixRootTable = 0x40000;

/// satp for the identity map: Sv39 mode (8) plus the root table PPN.
const matrixSatp = 0x8000000000000000 | (matrixRootTable >> 12);

/// Reset vector of a paged config. A two-instruction prologue sits here, turns
/// translation on and jumps to the cell program at 0. The cells keep their own
/// addresses, so `nextPc` and the goldens do not move.
const matrixPagedResetVector = 0x400;

/// The prologue: `csrw satp,x31` then `jalr x0,0(x0)`.
const matrixPagedPrologue = [0x180F9073, 0x00000067];

/// The GPR that carries the satp value into the prologue. No cell uses x31.
const matrixSatpSeedReg = Register.x31;

/// Sv39 leaf PTE for the 1GB megapage at [pa]. The flags are V|R|W|X|A|D. A and
/// D are pre-set, so no hardware A/D writeback adds bus traffic.
int matrixMegapage(int pa) => ((pa >> 12) << 10) | 0xCF;

/// The identity root table as 32-bit words (low half of each PTE first). Entry
/// N maps VA [N GB, N+1 GB) to the same physical range; four entries cover the
/// low 4GB, which is more than every cell touches.
Map<int, List<int>> matrixPageTable() => {
  for (var i = 0; i < 4; i++)
    matrixRootTable + i * 8: [matrixMegapage(i << 30), 0],
};

RiverCoreConfig matrixConfig(
  RiscVMxlen mxlen,
  Uarch u,
  String category, {
  int? regfileReadLatency,
  MicrocodeMode microcodeMode = MicrocodeMode.none,
  bool cached = false,
  bool paged = false,
  // Cache geometry override for a [cached] config. Null takes the [matrixL1]
  // default (a split 64B I / 256B D, 1 way, 8B line).
  HarborL1CacheConfig? l1,
}) {
  final base = mxlen == RiscVMxlen.rv64
      ? <RiscVExtension>[rv64i, rv32i]
      : <RiscVExtension>[rv32i];
  return RiverCoreConfig(
    resetVector: paged ? matrixPagedResetVector : 0,
    l1cache: cached ? (l1 ?? matrixL1()) : null,
    regfileReadLatency: regfileReadLatency,
    microcodeMode: microcodeMode,
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: mxlen,
    extensions: [
      ...base,
      rvZicsr,
      rvZifencei,
      ...categoryExtensions[category]!,
    ],
    interrupts: const [],
    mmu: HarborMmuConfig(
      mxlen: mxlen,
      pagingModes: paged
          ? const [RiscVPagingMode.bare, RiscVPagingMode.sv39]
          : const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
      hasSupervisorUserMemory: paged,
      hasMakeExecutableReadable: paged,
    ),
    type: RiverCoreType.general,
    executionMode: u == Uarch.inOrder
        ? ExecutionMode.inOrder
        : ExecutionMode.outOfOrder,
    issueWidth: u == Uarch.oooDual ? IssueWidth.dual : IssueWidth.single,
    speculativeFetch: u != Uarch.inOrder,
    // A predictor is required for the taken-branch redirect path to resolve
    // (with none, a taken branch wedges - see task #69). btfn is the validated
    // predictor (core_bpred_test). The config rejects a predictor without
    // speculativeFetch, so in-order stays predictor-less (and branch-free in
    // the matrix until #69 is resolved).
    branchPredictor: u == Uarch.inOrder
        ? BranchPredictor.none
        : BranchPredictor.btfn,
  );
}
