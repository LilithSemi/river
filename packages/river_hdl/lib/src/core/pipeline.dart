import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import '../data_port.dart';
import '../microcode_rom.dart';

import 'decode_control.dart';
import 'decoder.dart';
import 'exec.dart';
import 'compressed_fetch_buffer.dart';
import 'fetcher.dart';
import 'prefetch_fetcher.dart';
import 'pipelined_fetcher.dart';
import 'fu_alu.dart';
import 'fu_branch.dart';
import 'fu_csr.dart';
import 'fu_mem.dart';
import 'issue.dart';
import 'load_queue.dart';
import 'lsq.dart';
import 'rename.dart';
import 'rob.dart';
import 'stages.dart';

/// River OoO dual-issue pipeline.
///
/// Uses Harbor's [PipelineBuilder] for the in-order front-end
/// (fetch → decode → rename), then dispatches to an [IssueQueue]
/// that feeds OoO functional units (2× ALU, 1× memory, 1× branch, 1× CSR).
/// A [ReorderBuffer] ensures in-order commit.
class RiverPipeline extends Module {
  final MicrocodeRom microcode;
  final RiscVMxlen mxlen;
  final int vlen;

  Logic get done => output('done');
  Logic get valid => output('valid');
  Logic get nextSp => output('nextSp');
  Logic get nextPc => output('nextPc');
  Logic get nextMode => output('nextMode');
  Logic get trap => output('trap');
  Logic get trapCause => output('trapCause');
  Logic get trapInterrupt => output('trapInterrupt');
  Logic get trapTval => output('trapTval');
  Logic get fpFlags => output('fpFlags');
  Logic get trapEpc => output('trapEpc');
  Logic get isReturn => output('isReturn');
  Logic get returnLevel => output('returnLevel');
  Logic get memGuest => output('memGuest');
  Logic get fence => output('fence');
  Logic get interruptHold => output('interruptHold');
  Logic get counter => output('counter');

  // FetchUnit, or PrefetchFetchUnit when prefetchFetch is enabled. Both expose
  // done/valid/result/pc_out outputs; the pipeline reads them via output wires.
  late final Module fetcher;

  RiverPipeline(
    Logic clk,
    Logic reset,
    Logic enable,
    Logic currentSp,
    Logic currentPc,
    Logic currentMode,
    DataPortInterface? csrRead,
    DataPortInterface? csrWrite,
    DataPortInterface memFetchRead,
    DataPortInterface memExecRead,
    DataPortInterface memWrite,
    DataPortInterface rs1Read,
    DataPortInterface rs2Read,
    DataPortInterface rdWrite,
    DataPortInterface? microcodeDecodeRead,
    DataPortInterface? microcodeExecRead, {
    bool useOoO = false,
    bool speculative = false,
    bool dualDispatch = false,
    bool prefetchFetch = false,
    int prefetchDepth = 2,
    int fetchOutstanding = 1,
    FetchReadInterface? fetchReadPort,
    BranchPredictor branchPredictor = BranchPredictor.none,
    LoadStoreQueue loadStoreQueue = LoadStoreQueue.none,
    int robDepth = 64,
    int storeQueueDepth = 8,
    int loadQueueDepth = 8,
    bool useMixedDecoders = false,
    bool useMixedExecution = false,
    bool hasSupervisor = false,
    bool enableMisalignedLoads = false,
    Logic? loadFaultTval,
    bool hasUser = false,
    bool hasCompressed = false,
    required this.microcode,
    required this.mxlen,
    this.vlen = 128,
    Logic? mideleg,
    Logic? medeleg,
    Logic? mtvec,
    Logic? stvec,
    Logic? interruptTake,
    Logic? interruptCause,
    // Floating-point register ports, owned by the core module next to the
    // integer file. Null on a core without F/D.
    DataPortInterface? fpRs1Port,
    DataPortInterface? fpRs2Port,
    DataPortInterface? fpRdPort,
    // mret/sret return targets (for the OoO commit-stage fetcher redirect).
    Logic? mepc,
    Logic? sepc,
    // Backdoor seed for the OoO physical regfile (so test harnesses can preset
    // architectural registers). prfSeedAddr is the 5-bit ARCH index, which the
    // identity rename map (reset state) maps to the same physical reg. Driven
    // only while the core is frozen (no writeback), so it is exclusive with the
    // normal prf writeback. No effect on the in-order path.
    Logic? prfSeedEn,
    Logic? prfSeedAddr,
    Logic? prfSeedData,
    Logic? virt,
    Logic? mstateen0Se0,
    Logic? hstateen0Se0,
    Logic? memFaultGuest,
    // rpipelinectl vendor CSR (speculation control). When wired, bit [1] (BPD)
    // suppresses branch prediction at runtime (forces predicted-not-taken).
    // Other bits (SSBD/SERIALIZE/DTLBFC) are consumed elsewhere / reserved.
    Logic? specCtl,
    // The fetch port's instruction page-fault signal (MMU ifetch_fault). When
    // wired and translateFetch is on, a faulting fetch is delivered as a fetch
    // fault that the exec stage turns into instructionPageFault.
    Logic? ifetchFault,
    // In-order access/page classification; queued OoO frontends are separate.
    Logic? ifetchAccessFault,
    Logic? memAccessFault,
    Logic? frm,
    Logic? fpEnabled,
    DataPortInterface? rdWrite1,
    DataPortInterface? memFetchRead1,
    Logic? wr0Ready,
    Logic? wr1Ready,
    int counterWidth = 32,
    List<String> staticInstructions = const [],
    super.name = 'river_pipeline',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    enable = addInput('enable', enable);

    currentSp = addInput('currentSp', currentSp, width: mxlen.size);
    currentPc = addInput('currentPc', currentPc, width: mxlen.size);
    currentMode = addInput('currentMode', currentMode, width: 3);

    if (csrRead != null) {
      csrRead = csrRead.clone()
        ..connectIO(
          this,
          csrRead,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'csrRead_$og',
        );
    }

    if (csrWrite != null) {
      csrWrite = csrWrite.clone()
        ..connectIO(
          this,
          csrWrite,
          outputTags: {DataPortGroup.control, DataPortGroup.data},
          inputTags: {DataPortGroup.integrity},
          uniquify: (og) => 'csrWrite_$og',
        );
    }

    memFetchRead = memFetchRead.clone()
      ..connectIO(
        this,
        memFetchRead,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'memFetchRead_$og',
      );
    // Multiple-outstanding fetch port (master side): drives the request channel,
    // reads ready + response. Used instead of memFetchRead when a pipelined
    // fetch memory feeds a PipelinedFetchUnit (fetchOutstanding > 1).
    if (fetchReadPort != null) {
      fetchReadPort = fetchReadPort.clone()
        ..connectIO(
          this,
          fetchReadPort,
          outputTags: {FetchReadGroup.request},
          inputTags: {FetchReadGroup.requestReady, FetchReadGroup.response},
          uniquify: (og) => 'fetchReadPort_$og',
        );
    }
    memExecRead = memExecRead.clone()
      ..connectIO(
        this,
        memExecRead,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'memExecRead_$og',
      );
    // Dual-dispatch: second instruction-fetch port (lane 1).
    if (memFetchRead1 != null) {
      memFetchRead1 = memFetchRead1.clone()
        ..connectIO(
          this,
          memFetchRead1,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'memFetchRead1_$og',
        );
    }
    memWrite = memWrite.clone()
      ..connectIO(
        this,
        memWrite,
        outputTags: {DataPortGroup.control, DataPortGroup.data},
        inputTags: {DataPortGroup.integrity},
        uniquify: (og) => 'memWrite_$og',
      );

    rs1Read = rs1Read.clone()
      ..connectIO(
        this,
        rs1Read,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'rs1Read_$og',
      );
    rs2Read = rs2Read.clone()
      ..connectIO(
        this,
        rs2Read,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'rs2Read_$og',
      );
    rdWrite = rdWrite.clone()
      ..connectIO(
        this,
        rdWrite,
        outputTags: {DataPortGroup.control, DataPortGroup.data},
        inputTags: {DataPortGroup.integrity},
        uniquify: (og) => 'rdWrite_$og',
      );

    // The FP register file lives in the core module beside the integer file, so
    // its ports cross this boundary exactly as the integer ports do.
    final fpRs1In = fpRs1Port;
    if (fpRs1In != null) {
      fpRs1Port = fpRs1In.clone()
        ..connectIO(
          this,
          fpRs1In,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'fpRs1Port_$og',
        );
    }
    final fpRs2In = fpRs2Port;
    if (fpRs2In != null) {
      fpRs2Port = fpRs2In.clone()
        ..connectIO(
          this,
          fpRs2In,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'fpRs2Port_$og',
        );
    }
    final fpRdIn = fpRdPort;
    if (fpRdIn != null) {
      fpRdPort = fpRdIn.clone()
        ..connectIO(
          this,
          fpRdIn,
          outputTags: {DataPortGroup.control, DataPortGroup.data},
          inputTags: {DataPortGroup.integrity},
          uniquify: (og) => 'fpRdPort_$og',
        );
    }

    // Dual-commit: second register write port + its back-pressure inputs.
    if (rdWrite1 != null) {
      rdWrite1 = rdWrite1.clone()
        ..connectIO(
          this,
          rdWrite1,
          outputTags: {DataPortGroup.control, DataPortGroup.data},
          inputTags: {DataPortGroup.integrity},
          uniquify: (og) => 'rdWrite1_$og',
        );
    }
    if (wr0Ready != null) {
      wr0Ready = addInput('wr0Ready', wr0Ready);
    }
    if (wr1Ready != null) {
      wr1Ready = addInput('wr1Ready', wr1Ready);
    }

    if (microcodeDecodeRead != null) {
      microcodeDecodeRead = microcodeDecodeRead.clone()
        ..connectIO(
          this,
          microcodeDecodeRead,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'microcodeDecodeRead_$og',
        );
    }

    if (microcodeExecRead != null) {
      microcodeExecRead = microcodeExecRead.clone()
        ..connectIO(
          this,
          microcodeExecRead,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'microcodeExecRead_$og',
        );
    }

    if (mideleg != null) {
      mideleg = addInput('mideleg', mideleg, width: mxlen.size);
    }
    if (medeleg != null) {
      medeleg = addInput('medeleg', medeleg, width: mxlen.size);
    }
    if (mtvec != null) mtvec = addInput('mtvec', mtvec, width: mxlen.size);
    if (stvec != null) stvec = addInput('stvec', stvec, width: mxlen.size);
    if (interruptTake != null) {
      interruptTake = addInput('interruptTake', interruptTake);
      interruptCause = addInput('interruptCause', interruptCause!, width: 6);
    }
    if (mepc != null) mepc = addInput('mepc', mepc, width: mxlen.size);
    if (sepc != null) sepc = addInput('sepc', sepc, width: mxlen.size);
    final prfSeedEnIn = prfSeedEn == null
        ? Const(0)
        : addInput('prfSeedEn', prfSeedEn);
    final prfSeedAddrIn = prfSeedAddr == null
        ? Const(0, width: 5)
        : addInput('prfSeedAddr', prfSeedAddr, width: 5);
    final prfSeedDataIn = prfSeedData == null
        ? Const(0, width: mxlen.size)
        : addInput('prfSeedData', prfSeedData, width: mxlen.size);
    if (virt != null) virt = addInput('virtIn', virt);
    if (mstateen0Se0 != null) {
      mstateen0Se0 = addInput('mstateen0Se0', mstateen0Se0);
    }
    if (hstateen0Se0 != null) {
      hstateen0Se0 = addInput('hstateen0Se0', hstateen0Se0);
    }
    if (memFaultGuest != null) {
      memFaultGuest = addInput('memFaultGuest', memFaultGuest);
    }
    // Speculation-control bits (rpipelinectl). Default 0 = no override when the
    // CSR is absent, so non-Zicsr cores keep their compile-time behaviour.
    final specCtlIn = specCtl == null
        ? Const(0, width: 4)
        : addInput('specCtl', specCtl, width: 4);
    final bpdDisable = specCtlIn[1].named('bpdDisable');
    final ssbdDisable = specCtlIn[0].named('ssbdDisable');
    final ifetchAccessFaultIn = addInput(
      'ifetchAccessFault',
      ifetchAccessFault ?? Const(0),
    );
    final loadFaultTvalIn = loadFaultTval == null
        ? null
        : addInput('loadFaultTval', loadFaultTval, width: mxlen.size);
    addOutput('misalignedLoad');
    addOutput('loadSize', width: 3);
    final memAccessFaultIn = addInput(
      'memAccessFault',
      memAccessFault ?? Const(0),
    );
    final ifetchFaultIn = ifetchFault == null
        ? Const(0)
        : addInput('ifetchFault', ifetchFault);

    addOutput('done');
    addOutput('valid');
    addOutput('nextSp', width: mxlen.size);
    addOutput('nextPc', width: mxlen.size);
    addOutput('nextMode', width: 3);
    addOutput('trap');
    addOutput('trapCause', width: 6);
    addOutput('trapInterrupt');
    addOutput('trapTval', width: mxlen.size);
    addOutput('fpFlags', width: 5);
    final frmIn = frm == null ? null : addInput('frm', frm, width: 3);
    final fpEnabledIn = fpEnabled == null
        ? null
        : addInput('fpEnabled', fpEnabled);
    addOutput('trapEpc', width: mxlen.size);
    addOutput('isReturn');
    addOutput('returnLevel', width: 3);
    // memGuest is a *combinational* passthrough (driven below, not registered)
    // so it aligns with the direct exec mem-port -> dport path, holding the
    // guest-translation routing steady across the multi-cycle MMU walk.
    addOutput('memGuest');
    addOutput('fence');
    addOutput('interruptHold');
    addOutput('counter', width: counterWidth);

    // Speculative-fetch control wires (driven in the OoO section below). When
    // not speculative they stay null → FetchUnit defaults them off (lockstep).
    final fetchAdvance = speculative ? Logic(name: 'fetchAdvance') : null;
    final fetchRedirect = speculative ? Logic(name: 'fetchRedirect') : null;
    final fetchRedirectPc = speculative
        ? Logic(name: 'fetchRedirectPc', width: mxlen.size)
        : null;

    // Dual-dispatch uses the CompressedFetchBuffer: one wide fetch port streams
    // aligned words into a FIFO, and a variable-length aligner presents TWO
    // instructions per cycle, instr0 at the current PC, instr1 at PC + size0*2
    // (works for compressed and fixed-width alike). Dispatch consumes 1 or 2 per
    // cycle via consume0/consume1 (driven in the OoO section below). This
    // replaces the old two-FetchUnit lane1=lane0+4 scheme, which could not align
    // variable-length instructions. See project_hdl_dualissue / prefetch buffer.
    final useCompressedFetch = dualDispatch;
    final bufConsume0 = useCompressedFetch ? Logic(name: 'bufConsume0') : null;
    final bufConsume1 = useCompressedFetch ? Logic(name: 'bufConsume1') : null;

    // The pipelined prefetch fetcher (single-issue, non-compressed, speculative
    // OoO only, see config validation) fetches one ahead into a FIFO so fetch
    // latency overlaps decode/rename/alloc. Drop-in outputs. See
    // project_hdl_prefetch.
    // Multiple-outstanding fetch: a PipelinedFetchUnit over the decoupled
    // fetchReadPort (fed by a pipelined fetch memory in the core) keeps several
    // reads in flight, hiding fetch latency the single-outstanding fetchers
    // cannot. Same constraints as prefetch (single-issue, non-compressed,
    // speculative), plus fetchOutstanding > 1 and a port supplied.
    final usePipelined =
        prefetchFetch &&
        speculative &&
        !dualDispatch &&
        !hasCompressed &&
        fetchOutstanding > 1 &&
        fetchReadPort != null;
    final usePrefetch =
        prefetchFetch &&
        speculative &&
        !dualDispatch &&
        !hasCompressed &&
        !usePipelined;
    CompressedFetchBuffer? cfb;
    final Logic fetchOutDone, fetchOutValid, fetchOutResult, fetchOutPc;
    if (useCompressedFetch) {
      cfb = CompressedFetchBuffer(
        clk,
        reset,
        enable,
        currentPc,
        memFetchRead,
        redirect: fetchRedirect,
        redirectPc: fetchRedirectPc,
        consume0: bufConsume0,
        consume1: bufConsume1,
        fault: ifetchFaultIn,
        depth: prefetchDepth < 4 ? 4 : prefetchDepth,
      );
      fetcher = cfb;
      // Lane 0 = the buffer's first instruction. valid0 already gates on enable,
      // so present `done` high → fetchDone == valid0.
      fetchOutDone = Const(1);
      fetchOutValid = cfb.valid0;
      fetchOutResult = cfb.instr0;
      fetchOutPc = cfb.pc0;
      // One wide port feeds both lanes, so the second fetch port is unused here;
      // tie it off so it presents no bus traffic.
      if (memFetchRead1 != null) {
        memFetchRead1.en <= Const(0);
        memFetchRead1.addr <= Const(0, width: memFetchRead1.addr.width);
      }
    } else if (usePipelined) {
      // Fetch comes from the decoupled pipelined port; the single-outstanding
      // memFetchRead is unused, so tie its request channel off (no bus traffic).
      memFetchRead.en <= Const(0);
      memFetchRead.addr <= Const(0, width: memFetchRead.addr.width);
      fetcher = PipelinedFetchUnit(
        clk,
        reset,
        enable,
        currentPc,
        fetchReadPort,
        advance: fetchAdvance,
        redirect: fetchRedirect,
        redirectPc: fetchRedirectPc,
        depth: prefetchDepth,
        maxOutstanding: fetchOutstanding,
      );
      fetchOutDone = fetcher.output('done');
      fetchOutValid = fetcher.output('valid');
      fetchOutResult = fetcher.output('result');
      fetchOutPc = fetcher.output('pc_out');
    } else {
      fetcher = usePrefetch
          ? PrefetchFetchUnit(
              clk,
              reset,
              enable,
              currentPc,
              memFetchRead,
              advance: fetchAdvance,
              redirect: fetchRedirect,
              redirectPc: fetchRedirectPc,
              depth: prefetchDepth,
            )
          : FetchUnit(
              clk,
              reset,
              enable,
              currentPc,
              memFetchRead,
              hasCompressed: hasCompressed,
              advance: fetchAdvance,
              redirect: fetchRedirect,
              redirectPc: fetchRedirectPc,
              fault: usePrefetch ? null : ifetchFaultIn,
              accessFault: ifetchAccessFaultIn,
            );
      fetchOutDone = fetcher.output('done');
      fetchOutValid = fetcher.output('valid');
      fetchOutResult = fetcher.output('result');
      fetchOutPc = fetcher.output('pc_out');
    }

    // The fetch-fault marker. The plain FetchUnit and the compressed fetch buffer
    // carry fetch faults (delivered as a bubble that exec turns into an
    // instruction page fault); the prefetch/pipelined fetchers do not yet.
    final usePlainFetchUnit =
        !useCompressedFetch && !usePrefetch && !usePipelined;
    final fetchFaultSig = usePlainFetchUnit
        ? fetcher.output('fetch_fault')
        : useCompressedFetch
        ? cfb!.fetchFault
        : Const(0);

    final fetchAccessFaultSig = usePlainFetchUnit
        ? fetcher.output('fetch_access_fault')
        : Const(0);

    // Helper: resize signal to target width (truncate or zero-extend)
    Logic fitWidth(Logic sig, int targetWidth) {
      if (sig.width == targetWidth) return sig;
      if (sig.width > targetWidth) return sig.slice(targetWidth - 1, 0);
      return sig.zeroExtend(targetWidth);
    }

    final fetchDone = fetchOutDone & fetchOutValid & enable;

    // The fetcher's PC of the delivered instruction flows through the decoder
    // (pcIn → pcOut), registered with the decode, so PC + instruction + decode
    // stay paired (fixes the OoO branch/decode skew).
    final decoder0 = microcodeDecodeRead != null
        ? DynamicInstructionDecoder(
            clk,
            reset,
            fetchDone,
            fetchOutResult,
            microcodeDecodeRead,
            microcode: microcode,
            mxlen: mxlen,
            staticInstructions: staticInstructions,
            counterWidth: counterWidth,
            pcIn: fetchOutPc,
          )
        : StaticInstructionDecoder(
            clk,
            reset,
            fetchDone,
            fetchOutResult,
            microcode: microcode,
            mxlen: mxlen,
            staticInstructions: staticInstructions,
            counterWidth: counterWidth,
            pcIn: fetchOutPc,
          );

    final decodeDone = decoder0.done;
    final decodeValid = decoder0.valid;

    // Lane-1 decoder (dual-dispatch). Static decoder only (dual-dispatch
    // requires speculative + non-microcoded; see config validation).
    final fetchDone1 = dualDispatch ? (cfb!.valid1 & enable) : null;
    final decoder1 = dualDispatch
        ? StaticInstructionDecoder(
            clk,
            reset,
            fetchDone1!,
            cfb!.instr1,
            microcode: microcode,
            mxlen: mxlen,
            staticInstructions: staticInstructions,
            counterWidth: counterWidth,
            pcIn: cfb.pc1,
            name: 'static_instruction_decoder_1',
          )
        : null;

    if (!useOoO) {
      // =======================================================================
      // Classic in-order pipeline (fetch → decode → execute)
      // =======================================================================

      final readyExecution =
          (fetchOutValid & fetchOutDone & decodeValid & decodeDone).named(
            'readyExecution',
          );

      final exec = microcodeExecRead != null
          ? DynamicExecutionUnit(
              clk,
              reset,
              readyExecution,
              currentSp,
              currentPc,
              currentMode,
              decoder0.index,
              decoder0.instrTypeMap,
              decoder0.fields,
              csrRead,
              csrWrite,
              memExecRead,
              memWrite,
              rs1Read,
              rs2Read,
              rdWrite,
              microcodeExecRead,
              hasSupervisor: hasSupervisor,
              hasUser: hasUser,
              microcode: microcode,
              mxlen: mxlen,
              mideleg: mideleg,
              medeleg: medeleg,
              mtvec: mtvec,
              stvec: stvec,
              interruptTake: interruptTake,
              interruptCause: interruptCause,
              virtIn: virt,
              mstateen0Se0: mstateen0Se0,
              hstateen0Se0: hstateen0Se0,
              memFaultGuest: memFaultGuest,
              fetchFault: fetchFaultSig,
              fetchAccessFault: fetchAccessFaultSig,
              fetchFaultTval: usePlainFetchUnit
                  ? fetcher.output('fetch_fault_tval')
                  : null,
              memAccessFault: memAccessFaultIn,
              enableMisalignedLoads: enableMisalignedLoads,
              loadFaultTval: loadFaultTvalIn,
              frm: frmIn,
              fpEnabled: fpEnabledIn,
              staticInstructions: staticInstructions,
              fpRs1Port: fpRs1Port,
              fpRs2Port: fpRs2Port,
              fpRdPort: fpRdPort,
              counterWidth: counterWidth,
            )
          : StaticExecutionUnit(
              clk,
              reset,
              readyExecution,
              currentSp,
              currentPc,
              currentMode,
              decoder0.index,
              decoder0.instrTypeMap,
              decoder0.fields,
              csrRead,
              csrWrite,
              memExecRead,
              memWrite,
              rs1Read,
              rs2Read,
              rdWrite,
              hasSupervisor: hasSupervisor,
              hasUser: hasUser,
              microcode: microcode,
              mxlen: mxlen,
              vlen: vlen,
              mideleg: mideleg,
              medeleg: medeleg,
              mtvec: mtvec,
              stvec: stvec,
              interruptTake: interruptTake,
              interruptCause: interruptCause,
              virtIn: virt,
              mstateen0Se0: mstateen0Se0,
              hstateen0Se0: hstateen0Se0,
              memFaultGuest: memFaultGuest,
              fetchFault: fetchFaultSig,
              fetchAccessFault: fetchAccessFaultSig,
              fetchFaultTval: usePlainFetchUnit
                  ? fetcher.output('fetch_fault_tval')
                  : null,
              memAccessFault: memAccessFaultIn,
              enableMisalignedLoads: enableMisalignedLoads,
              loadFaultTval: loadFaultTvalIn,
              frm: frmIn,
              fpEnabled: fpEnabledIn,
              staticInstructions: staticInstructions,
              fpRs1Port: fpRs1Port,
              fpRs2Port: fpRs2Port,
              fpRdPort: fpRdPort,
              counterWidth: counterWidth,
            );

      final execDone = exec.done;
      final execValid = exec.valid;

      // Illegal-instruction detection is the pipeline's responsibility, not the
      // exec unit's: a fetched instruction whose decode finished with no
      // matching operation (decodeDone & ~decodeValid) is a reserved or
      // unimplemented encoding, e.g. the all-zero 0x0000 a jump into cleared
      // memory lands on. The pipeline asserts the illegal-instruction exception
      // here so the core faults at once instead of silently advancing past it
      // (which let a bad PC sled forward through zeroed memory).
      final decodeIllegal =
          (fetchOutValid & fetchOutDone & decodeDone & ~decodeValid).named(
            'decodeIllegal',
          );
      final illegalCause = Const(2, width: 6); // illegal instruction
      final illegalIsIntr = Const(0);
      final Logic illegalTrapMode;
      final Logic illegalTrapPc;
      if (mtvec != null) {
        illegalTrapMode = selectTrapTargetModeTop(
          illegalIsIntr,
          illegalCause,
          currentMode,
          mideleg,
          medeleg,
          hasCsr: csrRead != null && csrWrite != null,
          hasSupervisor: hasSupervisor,
        ).named('illegalTrapMode');
        final tvec = stvec != null
            ? mux(
                illegalTrapMode.eq(Const(PrivilegeMode.machine.id, width: 3)),
                mtvec,
                stvec,
              )
            : mtvec;
        illegalTrapPc = computeTrapVectorPcTop(
          tvec,
          illegalCause,
          illegalIsIntr,
          mxlen,
          suffix: 'Illegal',
        );
      } else {
        illegalTrapMode = currentMode;
        illegalTrapPc = currentPc;
      }

      Sequential(clk, [
        If(
          reset | (~execDone & ~decodeIllegal),
          then: [
            done < 0,
            valid < 0,
            nextSp < 0,
            nextPc < 0,
            nextMode < 0,
            trap < 0,
            trapCause < 0,
            trapInterrupt < 0,
            trapTval < 0,
            fpFlags < 0,
            trapEpc < 0,
            isReturn < 0,
            returnLevel < 0,
            fence < 0,
            counter < 0,
          ],
          orElse: [
            If(
              decodeIllegal,
              // Decode matched nothing: commit an illegal-instruction trap
              // (cause 2) at the faulting PC. exec never ran for this cycle, so
              // these outputs come straight from the pipeline.
              then: [
                done < 1,
                valid < 1,
                nextSp < currentSp,
                nextPc < illegalTrapPc,
                nextMode < illegalTrapMode,
                trap < 1,
                trapCause < illegalCause,
                trapInterrupt < 0,
                trapTval < 0,
                fpFlags < 0,
                trapEpc < currentPc,
                isReturn < 0,
                returnLevel < 0,
                fence < 0,
                interruptHold < 0,
                If(enable, then: [counter < (counter + 1)]),
              ],
              orElse: [
                done < fetchOutDone & decodeDone & execDone,
                valid < fetchOutValid & decodeValid & execValid,
                nextSp < exec.nextSp,
                nextPc < exec.nextPc,
                nextMode < exec.nextMode,
                trap < exec.trap,
                trapCause < exec.trapCause,
                trapInterrupt < exec.trapInterrupt,
                trapTval < exec.trapTval,
                fpFlags < exec.fpFlags,
                trapEpc < exec.trapEpc,
                isReturn < exec.isReturn,
                returnLevel < exec.returnLevel,
                fence < exec.fence,
                interruptHold < exec.interruptHold,
                If(enable, then: [counter < (counter + 1)]),
              ],
            ),
          ],
        ),
      ]);

      // Combinational passthrough (NOT registered) so it tracks the direct
      // exec mem-port -> dport timing throughout the MMU walk.
      output('memGuest') <= exec.memGuest;
      output('misalignedLoad') <= exec.misalignedLoad;
      output('loadSize') <= exec.loadSize;
    } else {
      // =======================================================================
      // OoO dual-issue pipeline
      // =======================================================================

      fpFlags <= Const(0, width: 5);
      output('misalignedLoad') <= Const(0);
      output('loadSize') <= Const(2, width: 3);
      // Decoded field signals (combinational from decoder)
      final decoderFields = decoder0.fields;
      final decodedRd = (decoderFields['rd'] ?? Const(0, width: 5))
          .zeroExtend(5)
          .named('decoded_rd');
      final decodedRs1 = (decoderFields['rs1'] ?? Const(0, width: 5))
          .zeroExtend(5)
          .named('decoded_rs1');
      final decodedRs2 = (decoderFields['rs2'] ?? Const(0, width: 5))
          .zeroExtend(5)
          .named('decoded_rs2');
      final decodedImm = fitWidth(
        decoderFields['imm'] ?? Const(0, width: mxlen.size),
        64,
      ).named('decoded_imm');
      final decodedOpIndex = fitWidth(
        decoder0.index,
        kOpIndex.width,
      ).named('decoded_op_idx');

      // Lane-1 decoded fields + control ROM (dual-dispatch).
      final decoder1Fields = dualDispatch ? decoder1!.fields : null;
      final decodedRd1 = dualDispatch
          ? (decoder1Fields!['rd'] ?? Const(0, width: 5)).zeroExtend(5)
          : null;
      final decodedRs1_1 = dualDispatch
          ? (decoder1Fields!['rs1'] ?? Const(0, width: 5)).zeroExtend(5)
          : null;
      final decodedRs2_1 = dualDispatch
          ? (decoder1Fields!['rs2'] ?? Const(0, width: 5)).zeroExtend(5)
          : null;
      final decodedImm1 = dualDispatch
          ? fitWidth(decoder1Fields!['imm'] ?? Const(0, width: mxlen.size), 64)
          : null;
      final ctrlRom1 = dualDispatch
          ? DecodeControlRom(decoder1!.index, operations: microcode.execLookup)
          : null;

      // Build Harbor pipeline for the decode→rename boundary (registered)
      final frontEnd = PipelineBuilder<RiverStage>(parent: this)
          .stage(
            RiverStage.decode,
            payloads: [
              kPC,
              kInstruction,
              kRd,
              kRs1,
              kRs2,
              kImm,
              kOpIndex,
              kFormatType,
              kWritesRd,
              kIsLoad,
              kIsStore,
              kIsBranch,
              kIsCsr,
              kIsReturn,
              kReturnLevel,
              kMemSize,
              kFuType,
              kAluFunct,
              kBranchCond,
              kIsJump,
              kIsJalr,
              kIsCompressed,
              kUseImm,
              kSignExtend,
              if (dualDispatch) ...[
                kSlot1Valid,
                kPC1,
                kInstruction1,
                kRd1,
                kRs1_1,
                kRs2_1,
                kImm1,
                kWritesRd1,
                kIsLoad1,
                kIsStore1,
                kIsBranch1,
                kIsCsr1,
                kIsReturn1,
                kReturnLevel1,
                kMemSize1,
                kFuType1,
                kAluFunct1,
                kBranchCond1,
                kIsJump1,
                kIsJalr1,
                kIsCompressed1,
                kUseImm1,
                kSignExtend1,
              ],
            ],
          )
          .register(clk: clk, reset: reset)
          .stage(
            RiverStage.rename,
            payloads: [
              kPdst,
              kPsrc1,
              kPsrc2,
              kPdstOld,
              kRobTag,
              if (dualDispatch) ...[
                kPdst1,
                kPsrc1_1,
                kPsrc2_1,
                kPdstOld1,
                kRobTag1,
              ],
            ],
          )
          .build();

      // Decode-control ROM: op index → flat control bundle for the issue queue
      // and functional units. Combinational from the (decode-stage) op index, so
      // the control signals register through to rename alongside the rest of the
      // decode payloads.
      final ctrlRom = DecodeControlRom(
        decoder0.index,
        operations: microcode.execLookup,
      );

      // Drive decode stage (pipeline entry point) from fetch + decoder
      final decodeNode = frontEnd[RiverStage.decode];
      // PC of the instruction being decoded comes from the decoder's PC
      // passthrough (pcOut), which is registered alongside the decoded fields,
      // so the PC and the control signals (fuType/branchCond/rd) always describe
      // the same instruction. (Using a live/latched PC here races it ahead of
      // the 1-cycle-registered decoder output and mis-routes branches.)
      decodeNode[kPC] <= fitWidth(decoder0.pcOut, 64);
      decodeNode[kInstruction] <= fetchOutResult;
      decodeNode[kRd] <= decodedRd;
      decodeNode[kRs1] <= decodedRs1;
      decodeNode[kRs2] <= decodedRs2;
      decodeNode[kImm] <= decodedImm;
      decodeNode[kOpIndex] <= decodedOpIndex;
      decodeNode[kFormatType] <= Const(0, width: 4);
      decodeNode[kWritesRd] <= ctrlRom.writesRd;
      decodeNode[kIsLoad] <= ctrlRom.isLoad;
      decodeNode[kIsStore] <= ctrlRom.isStore;
      decodeNode[kIsBranch] <=
          ctrlRom.fuType.eq(Const(FuType.branch.index, width: 2));
      decodeNode[kIsCsr] <= ctrlRom.isCsr;
      decodeNode[kIsReturn] <= ctrlRom.isReturn;
      decodeNode[kReturnLevel] <= ctrlRom.returnLevel;
      decodeNode[kMemSize] <= ctrlRom.memSize;
      decodeNode[kFuType] <= ctrlRom.fuType;
      decodeNode[kAluFunct] <= ctrlRom.aluFunct;
      decodeNode[kBranchCond] <= ctrlRom.branchCond;
      decodeNode[kIsJump] <= ctrlRom.isJump;
      decodeNode[kIsJalr] <= ctrlRom.isJalr;
      // Compressed-ness rides alongside the instruction (kInstruction <=
      // fetchOutResult = cfb.instr0), so the branch unit can form the link as
      // PC+2. Non-compressed fetchers carry no C-ext ops, so 0 is correct there.
      decodeNode[kIsCompressed] <= (cfb?.compressed0 ?? Const(0));
      decodeNode[kUseImm] <= ctrlRom.useImm;
      decodeNode[kSignExtend] <= ~ctrlRom.memUnsigned;
      decodeNode.valid <= decodeDone & decodeValid;

      // Lane-1 decode payloads (dual-dispatch).
      if (dualDispatch) {
        decodeNode[kSlot1Valid] <= fetchDone1!;
        decodeNode[kPC1] <= fitWidth(decoder1!.pcOut, 64);
        decodeNode[kInstruction1] <= cfb!.instr1;
        decodeNode[kRd1] <= decodedRd1!;
        decodeNode[kRs1_1] <= decodedRs1_1!;
        decodeNode[kRs2_1] <= decodedRs2_1!;
        decodeNode[kImm1] <= decodedImm1!;
        decodeNode[kWritesRd1] <= ctrlRom1!.writesRd;
        decodeNode[kIsLoad1] <= ctrlRom1.isLoad;
        decodeNode[kIsStore1] <= ctrlRom1.isStore;
        decodeNode[kIsBranch1] <=
            ctrlRom1.fuType.eq(Const(FuType.branch.index, width: 2));
        decodeNode[kIsCsr1] <= ctrlRom1.isCsr;
        decodeNode[kIsReturn1] <= ctrlRom1.isReturn;
        decodeNode[kReturnLevel1] <= ctrlRom1.returnLevel;
        decodeNode[kMemSize1] <= ctrlRom1.memSize;
        decodeNode[kFuType1] <= ctrlRom1.fuType;
        decodeNode[kAluFunct1] <= ctrlRom1.aluFunct;
        decodeNode[kBranchCond1] <= ctrlRom1.branchCond;
        decodeNode[kIsJump1] <= ctrlRom1.isJump;
        decodeNode[kIsJalr1] <= ctrlRom1.isJalr;
        decodeNode[kIsCompressed1] <= cfb.compressed1;
        decodeNode[kUseImm1] <= ctrlRom1.useImm;
        decodeNode[kSignExtend1] <= ~ctrlRom1.memUnsigned;
      }

      // -----------------------------------------------------------------------
      // Register rename
      // -----------------------------------------------------------------------

      final renameNode = frontEnd[RiverStage.rename];

      // Drive the front-end's tail handshake. The register link wires
      // valid forward and ready backward, but the last stage's `ready` is the
      // consumer's responsibility and `cancel` is never driven by a register
      // link, leaving both X, which makes `renameNode.isFiring` (valid & ready
      // & ~cancel) X and poisons rename/issue/ROB.
      //
      // Lockstep: accept every cycle (the fetcher holds one instruction and the
      // commit-driven PC paces allocation). Speculative: apply real
      // back-pressure, only accept when the ROB, IQ, and free list can take the
      // instruction (driven below, once those modules exist).
      final renameReady = speculative ? Logic(name: 'renameReady') : Const(1);
      renameNode.ready <= renameReady;

      // Speculative redirect/flush wires (driven below, once the ROB exists).
      // specFlush pulses when a committing branch/jump redirects control flow:
      // it squashes the ROB/IQ, rolls back rename, and redirects the fetcher.
      // After a redirect, wrong-path instructions still in the decode→rename
      // register must not allocate. Rather than time the squash, suppress
      // allocation by PC: while `awaitingTarget`, cancel any instruction whose
      // PC is not the redirect target. The first instruction with PC==target is
      // the correct-path instruction; it (and everything after) allocates. The
      // PC is reliable here because it flows aligned through the decoder.
      final specFlush = speculative ? Logic(name: 'specFlush') : null;
      final awaitingTarget = speculative ? Logic(name: 'awaitingTarget') : null;
      final targetPcReg = speculative
          ? Logic(name: 'targetPcReg', width: mxlen.size)
          : null;
      // Flush condition for the rename table, ROB, IQ, and functional units:
      // reset, plus a speculative redirect.
      final flushOrRedirect = speculative ? (reset | specFlush!) : reset;
      final renamePcNow = speculative
          ? fitWidth(renameNode[kPC], mxlen.size)
          : null;
      renameNode.cancel <=
          (speculative
              ? (awaitingTarget! & renamePcNow!.neq(targetPcReg!))
              : Const(0));
      decodeNode.cancel <= Const(0);

      // One-shot allocation. The PC only advances at commit, so the fetcher
      // re-presents the same instruction for many cycles and `isFiring` would
      // otherwise allocate a fresh ROB/IQ entry every cycle (one instruction →
      // dozens of duplicate entries). Allocate only when the renamed PC differs
      // from the last one allocated. Because each instruction therefore commits
      // (updating the arch regfile) before the next is fetched, reading source
      // operands from the arch regfile at rename is also correct here.
      final lastAllocPc = Logic(name: 'lastAllocPc', width: mxlen.size);
      final lastAllocValid = Logic(name: 'lastAllocValid');
      final renamePc = fitWidth(renameNode[kPC], mxlen.size);
      final newInstr = (~lastAllocValid | renamePc.neq(lastAllocPc)).named(
        'newInstr',
      );
      final doAlloc = (renameNode.isFiring & newInstr).named('doAlloc');
      Sequential(clk, [
        If(
          reset,
          then: [lastAllocValid < 0, lastAllocPc < 0],
          orElse: [
            If(doAlloc, then: [lastAllocValid < 1, lastAllocPc < renamePc]),
          ],
        ),
      ]);

      // ---- Lane-1 allocation + fetch coordination (dual-dispatch) ----
      // Slot-1 rename source/dest locals (Const(0) when single-dispatch so the
      // rename/ROB/IQ slot-1 ports can be wired unconditionally below).
      final r1Rs1 = dualDispatch ? renameNode[kRs1_1] : Const(0, width: 5);
      final r1Rs2 = dualDispatch ? renameNode[kRs2_1] : Const(0, width: 5);
      final r1Rd = dualDispatch ? renameNode[kRd1] : Const(0, width: 5);
      final r1WritesRd = dualDispatch ? renameNode[kWritesRd1] : Const(0);
      Logic doAlloc1 = Const(0);
      if (dualDispatch) {
        final renamePc1 = fitWidth(renameNode[kPC1], mxlen.size);
        // Co-dispatch eligibility. Slot 1 must hold a decoded instruction at
        // exactly slot0.pc+4 (self-correcting alignment guard); neither slot may
        // be a control transfer (a taken slot-0 branch makes slot 1 wrong-path),
        // a CSR (serialised), or a memory op (single mem port + ordering).
        // Intra-bundle RAW (slot 1 reads a register slot 0 writes) is also NOT
        // co-dispatched: slot 0's busy bit/PRF value are not yet visible the
        // cycle they co-allocate. Deferring slot 1 to the next cycle turns it
        // into a cross-bundle RAW, which the PRF busy scoreboard + wakeup
        // forwarding handle correctly.
        final intraRaw =
            (doAlloc &
                    renameNode[kWritesRd] &
                    renameNode[kRd].neq(Const(0, width: 5)) &
                    (renameNode[kRd].eq(r1Rs1) | renameNode[kRd].eq(r1Rs2)))
                .named('intraBundleRaw');
        final slot0Ctrl =
            renameNode[kIsBranch] | renameNode[kIsJump] | renameNode[kIsJalr];
        final slot1Ctrl =
            renameNode[kIsBranch1] |
            renameNode[kIsJump1] |
            renameNode[kIsJalr1];
        final slot0Mem = renameNode[kIsLoad] | renameNode[kIsStore];
        final slot1Mem = renameNode[kIsLoad1] | renameNode[kIsStore1];
        // The fetch buffer emits the pair from one aligned window, so instr1
        // always starts at instr0.pc + size0*2, lane-1's PC is correct by
        // construction (compressed or fixed-width). No fixed +4 guard needed.
        final pcAligned = Const(1);
        final slot1Squash = awaitingTarget != null
            ? (awaitingTarget & renamePc1.neq(targetPcReg!))
            : Const(0);
        // With a load-store queue, memory ops MAY co-dispatch: they still leave
        // the issue queue one at a time (single mem port) and execute in program
        // order (slot 0 has the older sequence number), so the queue sees them
        // in order and intra-bundle store→load aliasing is handled by forwarding.
        // EXCEPTION: a load+load bundle currently deadlocks (two loads in flight
        // through the single mem port + dual-commit); it falls back to single
        // dispatch (still correct). Without an LSQ, any memory op blocks.
        final bothLoad = renameNode[kIsLoad] & renameNode[kIsLoad1];
        final memBlock = (loadStoreQueue != LoadStoreQueue.none)
            ? bothLoad
            : (slot0Mem | slot1Mem);
        final slot1Eligible =
            (renameNode[kSlot1Valid] &
                    pcAligned &
                    ~slot0Ctrl &
                    ~slot1Ctrl &
                    ~renameNode[kIsCsr] &
                    ~renameNode[kIsCsr1] &
                    ~memBlock &
                    ~intraRaw &
                    ~slot1Squash)
                .named('slot1Eligible');
        // Slot 1 co-dispatches ONLY together with slot 0 (doAlloc). It is the
        // instruction at slot0.pc+4, so when slot 0 allocates a new bundle and
        // slot 1 is eligible, slot 1 is also new, no separate one-shot is
        // needed, and gating on doAlloc prevents slot 1 from allocating while
        // slot 0 is a stale re-presentation (which would double-allocate slot
        // 1's instruction when it later becomes slot 0).
        doAlloc1 = (doAlloc & slot1Eligible).named('doAlloc1');
        // Drive the buffer's consume ports: consume slot 0 when it allocates,
        // and slot 1 additionally when it co-allocates. The buffer advances its
        // head by size0 (+ size1 when slot 1 co-allocates) and presents the next
        // pair. A branch/predict redirect (fetchRedirect/fetchRedirectPc, driven
        // below) flushes the buffer and resteers to the target, including
        // mid-word (compressed-aligned) targets.
        bufConsume0! <= doAlloc;
        bufConsume1! <= doAlloc1;
      }

      // Placeholders for commit-time connections (wired after ROB is created)
      final freeValid0Wire = Logic(name: 'freeValid0Wire');
      final freeReg0Wire = Logic(name: 'freeReg0Wire', width: 7);
      final freeValid1Wire = Logic(name: 'freeValid1Wire');
      final freeReg1Wire = Logic(name: 'freeReg1Wire', width: 7);
      final commitValid0Wire = Logic(name: 'commitValid0Wire');
      final commitRd0Wire = Logic(name: 'commitRd0Wire', width: 5);
      final commitPdst0Wire = Logic(name: 'commitPdst0Wire', width: 7);
      final commitValid1Wire = Logic(name: 'commitValid1Wire');
      final commitRd1Wire = Logic(name: 'commitRd1Wire', width: 5);
      final commitPdst1Wire = Logic(name: 'commitPdst1Wire', width: 7);

      final renameTable = RegisterRenameTable(
        clk,
        reset,
        rs1Arch0: renameNode[kRs1],
        rs2Arch0: renameNode[kRs2],
        rdArch0: renameNode[kRd],
        valid0: doAlloc,
        writesRd0: renameNode[kWritesRd],
        rs1Arch1: r1Rs1,
        rs2Arch1: r1Rs2,
        rdArch1: r1Rd,
        valid1: doAlloc1,
        writesRd1: r1WritesRd,
        freeValid0: freeValid0Wire,
        freeReg0: freeReg0Wire,
        freeValid1: freeValid1Wire,
        freeReg1: freeReg1Wire,
        commitValid0: commitValid0Wire,
        commitRd0: commitRd0Wire,
        commitPdst0: commitPdst0Wire,
        commitValid1: commitValid1Wire,
        commitRd1: commitRd1Wire,
        commitPdst1: commitPdst1Wire,
        flush: flushOrRedirect,
        numPhysRegs: 96,
      );

      // Drive rename stage payload outputs
      renameNode[kPdst] <= renameTable.pdst0;
      renameNode[kPsrc1] <= renameTable.psrc1_0;
      renameNode[kPsrc2] <= renameTable.psrc2_0;
      renameNode[kPdstOld] <= renameTable.pdstOld0;
      if (dualDispatch) {
        renameNode[kPdst1] <= renameTable.pdst1;
        renameNode[kPsrc1_1] <= renameTable.psrc1_1;
        renameNode[kPsrc2_1] <= renameTable.psrc2_1;
        renameNode[kPdstOld1] <= renameTable.pdstOld1;
      }

      // -----------------------------------------------------------------------
      // Reorder buffer, create interconnect wires first, then instantiate
      // -----------------------------------------------------------------------

      final lsqEnabled = loadStoreQueue != LoadStoreQueue.none;
      final forwarding =
          loadStoreQueue == LoadStoreQueue.forwarding ||
          loadStoreQueue == LoadStoreQueue.speculative;
      final speculativeLsq = loadStoreQueue == LoadStoreQueue.speculative;
      final robTagBits = robDepth.bitLength - 1; // log2(robDepth)
      final numPhysRegs =
          96; // physical registers (must match RegisterRenameTable)

      // Store-queue status, forward-declared: the issue queue (in-order mem
      // dispatch + store back-pressure) and the memory unit (load wait/forward)
      // consume these, but the StoreQueue is built after them. Wired below.
      final sqFullWire = Logic(name: 'sqFull');
      final sqEmptyWire = Logic(name: 'sqEmpty');
      final sqFwdHitWire = Logic(name: 'sqFwdHit');
      final sqFwdDataWire = Logic(name: 'sqFwdData', width: mxlen.size);
      final sqFwdStallWire = Logic(name: 'sqFwdStall');
      // Speculative LSQ: a store→load ordering violation from the load queue,
      // forward-declared (the LoadQueue is built after the memory unit).
      final lqCamViolationWire = Logic(name: 'lqCamViolation');

      // ROB allocate wires
      final robAllocValid0 = Logic(name: 'robAllocValid0');
      final robAllocPc0 = Logic(name: 'robAllocPc0', width: mxlen.size);
      final robAllocPdst0 = Logic(name: 'robAllocPdst0', width: 7);
      final robAllocPdstOld0 = Logic(name: 'robAllocPdstOld0', width: 7);
      final robAllocRd0 = Logic(name: 'robAllocRd0', width: 5);
      final robAllocWritesRd0 = Logic(name: 'robAllocWritesRd0');
      final robAllocValid1 = Logic(name: 'robAllocValid1');
      final robAllocPc1 = Logic(name: 'robAllocPc1', width: mxlen.size);
      final robAllocPdst1 = Logic(name: 'robAllocPdst1', width: 7);
      final robAllocPdstOld1 = Logic(name: 'robAllocPdstOld1', width: 7);
      final robAllocRd1 = Logic(name: 'robAllocRd1', width: 5);
      final robAllocWritesRd1 = Logic(name: 'robAllocWritesRd1');

      // ROB complete wires
      final robCompleteValid0 = Logic(name: 'robCompleteValid0');
      final robCompleteTag0 = Logic(name: 'robCompleteTag0', width: robTagBits);
      final robCompleteResult0 = Logic(
        name: 'robCompleteResult0',
        width: mxlen.size,
      );
      final robCompleteException0 = Logic(name: 'robCompleteException0');
      final robCompleteCause0 = Logic(name: 'robCompleteCause0', width: 6);
      // Port-0 (memory) redirect: a store→load violation re-fetches after it.
      final robCompleteRedirects0 = Logic(name: 'robCompleteRedirects0');
      final robCompleteTarget0 = Logic(
        name: 'robCompleteTarget0',
        width: mxlen.size,
      );
      final robCompleteValid1 = Logic(name: 'robCompleteValid1');
      final robCompleteTag1 = Logic(name: 'robCompleteTag1', width: robTagBits);
      final robCompleteResult1 = Logic(
        name: 'robCompleteResult1',
        width: mxlen.size,
      );
      final robCompleteException1 = Logic(name: 'robCompleteException1');
      final robCompleteCause1 = Logic(name: 'robCompleteCause1', width: 6);

      // Complete port 2: the branch unit (driven after it is built). Carries
      // the redirect bit + target PC so the redirect applies at commit.
      final robCompleteValid2 = Logic(name: 'robCompleteValid2');
      final robCompleteTag2 = Logic(name: 'robCompleteTag2', width: robTagBits);
      final robCompleteResult2 = Logic(
        name: 'robCompleteResult2',
        width: mxlen.size,
      );
      final robCompleteException2 = Logic(name: 'robCompleteException2');
      final robCompleteCause2 = Logic(name: 'robCompleteCause2', width: 6);
      final robCompleteRedirects2 = Logic(name: 'robCompleteRedirects2');
      final robCompleteTarget2 = Logic(
        name: 'robCompleteTarget2',
        width: mxlen.size,
      );

      // ROB commit ack wires
      final robCommitAck0 = Logic(name: 'robCommitAck0');
      final robCommitAck1 = Logic(name: 'robCommitAck1');
      final robFlush = Logic(name: 'robFlush');

      // Drive allocate wires
      robAllocValid0 <= doAlloc;
      robAllocPc0 <= fitWidth(renameNode[kPC], mxlen.size);
      robAllocPdst0 <= renameTable.pdst0;
      robAllocPdstOld0 <= renameTable.pdstOld0;
      robAllocRd0 <= renameNode[kRd];
      robAllocWritesRd0 <= renameNode[kWritesRd];
      robAllocValid1 <= doAlloc1;
      robAllocPc1 <=
          (dualDispatch
              ? fitWidth(renameNode[kPC1], mxlen.size)
              : Const(0, width: mxlen.size));
      robAllocPdst1 <= renameTable.pdst1.zeroExtend(7);
      robAllocPdstOld1 <= renameTable.pdstOld1.zeroExtend(7);
      robAllocRd1 <= r1Rd;
      robAllocWritesRd1 <= r1WritesRd;
      robFlush <= flushOrRedirect;

      final rob = ReorderBuffer(
        clk,
        reset,
        allocValid0: robAllocValid0,
        allocPc0: robAllocPc0,
        allocPdst0: robAllocPdst0,
        allocPdstOld0: robAllocPdstOld0,
        allocRd0: robAllocRd0,
        allocWritesRd0: robAllocWritesRd0,
        allocValid1: robAllocValid1,
        allocPc1: robAllocPc1,
        allocPdst1: robAllocPdst1,
        allocPdstOld1: robAllocPdstOld1,
        allocRd1: robAllocRd1,
        allocWritesRd1: robAllocWritesRd1,
        allocIsStore0: lsqEnabled ? renameNode[kIsStore] : Const(0),
        allocIsStore1: (lsqEnabled && dualDispatch)
            ? renameNode[kIsStore1]
            : Const(0),
        allocIsReturn0: renameNode[kIsReturn],
        allocReturnLevel0: renameNode[kReturnLevel],
        allocIsReturn1: dualDispatch ? renameNode[kIsReturn1] : Const(0),
        allocReturnLevel1: dualDispatch
            ? renameNode[kReturnLevel1]
            : Const(0, width: 2),
        completeValid0: robCompleteValid0,
        completeTag0: robCompleteTag0,
        completeResult0: robCompleteResult0,
        completeRedirects0: speculativeLsq ? robCompleteRedirects0 : null,
        completeTarget0: speculativeLsq ? robCompleteTarget0 : null,
        completeException0: robCompleteException0,
        completeCause0: robCompleteCause0,
        completeValid1: robCompleteValid1,
        completeTag1: robCompleteTag1,
        completeResult1: robCompleteResult1,
        completeException1: robCompleteException1,
        completeCause1: robCompleteCause1,
        completeValid2: robCompleteValid2,
        completeTag2: robCompleteTag2,
        completeResult2: robCompleteResult2,
        completeException2: robCompleteException2,
        completeCause2: robCompleteCause2,
        completeRedirects2: robCompleteRedirects2,
        completeTarget2: robCompleteTarget2,
        commitAck0: robCommitAck0,
        commitAck1: robCommitAck1,
        flush: robFlush,
        depth: robDepth,
        xlen: mxlen.size,
        physRegBits: 7,
      );

      renameNode[kRobTag] <= rob.allocTag0.zeroExtend(7);
      if (dualDispatch) {
        renameNode[kRobTag1] <= rob.allocTag1.zeroExtend(7);
      }

      // -----------------------------------------------------------------------
      // Issue queue, wires created externally and passed
      // -----------------------------------------------------------------------

      // IQ wakeup wires (driven after FUs are created)
      final iqWakeupValid0 = Logic(name: 'iqWakeupValid0');
      final iqWakeupTag0 = Logic(name: 'iqWakeupTag0', width: 7);
      final iqWakeupValue0 = Logic(name: 'iqWakeupValue0', width: mxlen.size);
      final iqWakeupValid1 = Logic(name: 'iqWakeupValid1');
      final iqWakeupTag1 = Logic(name: 'iqWakeupTag1', width: 7);
      final iqWakeupValue1 = Logic(name: 'iqWakeupValue1', width: mxlen.size);
      // Dedicated 3rd wakeup port for the branch/CSR completion, so ALU1 (port 1)
      // and branch/CSR no longer collide in dual-dispatch (dropped wakeup →
      // dependent never fires → deadlock on long loop bodies).
      final iqWakeupValid2 = Logic(name: 'iqWakeupValid2');
      final iqWakeupTag2 = Logic(name: 'iqWakeupTag2', width: 7);
      final iqWakeupValue2 = Logic(name: 'iqWakeupValue2', width: mxlen.size);

      // Driven after the MemoryUnit is built; tells the IQ not to dispatch a
      // second memory op while one is in flight.
      final memBusyWire = Logic(name: 'memBusyWire');
      // Likewise for the ALUs: a multi-cycle mul/div holds the unit busy, so the
      // IQ must not dispatch another op to it until the result lands.
      final aluBusy0Wire = Logic(name: 'aluBusy0Wire');
      final aluBusy1Wire = Logic(name: 'aluBusy1Wire');

      // --------------------------------------------------------------------
      // Physical register file + busy scoreboard (operand availability)
      // --------------------------------------------------------------------
      // Operand VALUES come from this PRF (written at FU writeback, indexed by
      // physical register), NOT the architectural regfile. That makes in-flight
      // RAW correct: a consumer whose producer has not yet committed reads the
      // forwarded/written-back value instead of the stale committed one. An
      // operand is ready iff its source physreg is not busy. busy[p] is set when
      // p is allocated as a destination and cleared when its result writes back.
      //
      // The FU result carries the ROB tag (the ROB is indexed by it); the
      // forwarding/PRF index is the physical register. tagToPdst/tagWritesRd
      // translate a completing ROB tag back to its physreg + whether it writes a
      // register, both recorded at allocation.
      final prf = List.generate(
        numPhysRegs,
        (i) => Logic(name: 'prf_$i', width: mxlen.size),
      );
      final prfBusy = List.generate(
        numPhysRegs,
        (i) => Logic(name: 'prfBusy_$i'),
      );
      final tagToPdst = List.generate(
        robDepth,
        (i) => Logic(name: 'tagToPdst_$i', width: 7),
      );
      final tagWritesRd = List.generate(
        robDepth,
        (i) => Logic(name: 'tagWritesRd_$i'),
      );

      Logic muxArr(List<Logic> arr, Logic idx) {
        var r = arr[0];
        for (var i = 1; i < arr.length; i++) {
          r = mux(idx.eq(i), arr[i], r);
        }
        return r;
      }

      // A source is ready if its physreg is not busy, OR a writeback this cycle
      // targets it (enqueue↔wakeup bypass: PRF/busy update one cycle late, so an
      // instruction enqueueing the same cycle its producer writes back must take
      // the value off the wakeup bus directly or it would wait forever).
      // x0 reads as 0 and is always ready. River renames x0 like any register,
      // so an instruction that writes x0 (e.g. the canonical nop addi x0,x0,0)
      // would otherwise mark x0's physreg busy and make later x0 readers wait on
      // it (a false dependency chain). Special-case the arch source x0 here so it
      // never waits and always supplies 0. SAFE because this is the out-of-order
      // path, which is INTEGER-ONLY (no FP functional unit; FP runs only on the
      // in-order/microcode exec path), so `arch` is always an integer reg number
      // and can never be an FP reg f0. If OoO FP is ever added, gate this on a
      // per-source integer-reg flag. See project_hdl_frontend_perf, task #58.
      final zeroReg = Const(0, width: 5);
      Logic srcReady(Logic arch, Logic psrc) =>
          arch.eq(zeroReg) |
          ~muxArr(prfBusy, psrc) |
          (iqWakeupValid0 & iqWakeupTag0.eq(psrc)) |
          (iqWakeupValid1 & iqWakeupTag1.eq(psrc));
      Logic srcValue(Logic arch, Logic psrc) => mux(
        arch.eq(zeroReg),
        Const(0, width: mxlen.size),
        mux(
          iqWakeupValid0 & iqWakeupTag0.eq(psrc),
          iqWakeupValue0,
          mux(
            iqWakeupValid1 & iqWakeupTag1.eq(psrc),
            iqWakeupValue1,
            muxArr(prf, psrc),
          ),
        ),
      );

      final iq = IssueQueue(
        clk,
        reset,
        enqValid0: doAlloc,
        enqTag0: rob.allocTag0,
        enqPsrc10: renameTable.psrc1_0,
        enqPsrc20: renameTable.psrc2_0,
        enqPdst0: renameTable.pdst0,
        // For CSR ops the general imm field is unused (the csr ADDRESS is
        // plumbed separately as csrAddr), so carry the 5-bit zimm (instr[19:15])
        // here for csrrwi/csrrsi/csrrci - the CsrUnit reads it as the immediate
        // source. Without this it got the csr addr (the I-type imm) instead.
        enqImm0: mux(
          renameNode[kFuType].eq(Const(FuType.csr.index, width: 2)),
          fitWidth(
            renameNode[kInstruction],
            32,
          ).slice(19, 15).zeroExtend(mxlen.size),
          fitWidth(renameNode[kImm], mxlen.size),
        ),
        enqPc0: fitWidth(renameNode[kPC], mxlen.size),
        enqFunct0: renameNode[kAluFunct],
        enqFuType0: renameNode[kFuType],
        enqWritesRd0: renameNode[kWritesRd],
        enqIsStore0: renameNode[kIsStore],
        enqMemSize0: renameNode[kMemSize],
        enqBranchCond0: renameNode[kBranchCond],
        enqIsJump0: renameNode[kIsJump],
        enqIsJalr0: renameNode[kIsJalr],
        enqIsCompressed0: renameNode[kIsCompressed],
        enqUseImm0: renameNode[kUseImm],
        // CSR op = funct3 (instr[14:12]); CSR address = instr[31:20]. The
        // CsrUnit maps funct3 → read/set/clear (+ immediate variants).
        enqCsrOp0: fitWidth(renameNode[kInstruction], 32).slice(14, 12),
        enqCsrAddr0: fitWidth(renameNode[kInstruction], 32).slice(31, 20),
        enqSignExtend0: renameNode[kSignExtend],
        enqValid1: doAlloc1,
        enqTag1: rob.allocTag1,
        enqPsrc11: renameTable.psrc1_1,
        enqPsrc21: renameTable.psrc2_1,
        enqPdst1: renameTable.pdst1,
        // Same CSR-zimm carry as slot 0 (a CSR is serialised so it never reaches
        // slot 1, but keep the lanes consistent).
        enqImm1: dualDispatch
            ? mux(
                renameNode[kFuType1].eq(Const(FuType.csr.index, width: 2)),
                fitWidth(
                  renameNode[kInstruction1],
                  32,
                ).slice(19, 15).zeroExtend(mxlen.size),
                fitWidth(renameNode[kImm1], mxlen.size),
              )
            : Const(0, width: mxlen.size),
        enqPc1: dualDispatch
            ? fitWidth(renameNode[kPC1], mxlen.size)
            : Const(0, width: mxlen.size),
        enqFunct1: dualDispatch ? renameNode[kAluFunct1] : Const(0, width: 7),
        enqFuType1: dualDispatch ? renameNode[kFuType1] : Const(0, width: 2),
        enqWritesRd1: r1WritesRd,
        enqIsStore1: dualDispatch ? renameNode[kIsStore1] : Const(0),
        enqMemSize1: dualDispatch ? renameNode[kMemSize1] : Const(0, width: 3),
        enqBranchCond1: dualDispatch
            ? renameNode[kBranchCond1]
            : Const(0, width: 3),
        enqIsJump1: dualDispatch ? renameNode[kIsJump1] : Const(0),
        enqIsJalr1: dualDispatch ? renameNode[kIsJalr1] : Const(0),
        enqIsCompressed1: dualDispatch ? renameNode[kIsCompressed1] : Const(0),
        enqUseImm1: dualDispatch ? renameNode[kUseImm1] : Const(0),
        enqCsrOp1: dualDispatch
            ? fitWidth(renameNode[kInstruction1], 32).slice(14, 12)
            : Const(0, width: 3),
        enqCsrAddr1: dualDispatch
            ? fitWidth(renameNode[kInstruction1], 32).slice(31, 20)
            : Const(0, width: 12),
        enqSignExtend1: dualDispatch ? renameNode[kSignExtend1] : Const(0),
        enqSrc1Value0: srcValue(renameNode[kRs1], renameTable.psrc1_0),
        enqSrc2Value0: srcValue(renameNode[kRs2], renameTable.psrc2_0),
        enqSrc1Ready0: srcReady(renameNode[kRs1], renameTable.psrc1_0),
        enqSrc2Ready0: srcReady(renameNode[kRs2], renameTable.psrc2_0),
        enqSrc1Value1: srcValue(r1Rs1, renameTable.psrc1_1),
        enqSrc2Value1: srcValue(r1Rs2, renameTable.psrc2_1),
        enqSrc1Ready1: srcReady(r1Rs1, renameTable.psrc1_1),
        enqSrc2Ready1: srcReady(r1Rs2, renameTable.psrc2_1),
        wakeupValid0: iqWakeupValid0,
        wakeupTag0: iqWakeupTag0,
        wakeupValue0: iqWakeupValue0,
        wakeupValid1: iqWakeupValid1,
        wakeupTag1: iqWakeupTag1,
        wakeupValue1: iqWakeupValue1,
        wakeupValid2: iqWakeupValid2,
        wakeupTag2: iqWakeupTag2,
        wakeupValue2: iqWakeupValue2,
        aluBusy0: aluBusy0Wire,
        aluBusy1: aluBusy1Wire,
        memBusy: memBusyWire,
        branchBusy: Const(0),
        csrBusy: Const(0),
        flush: flushOrRedirect,
        inOrderMem: lsqEnabled,
        speculativeMem: speculativeLsq,
        sqFull: lsqEnabled ? sqFullWire : null,
        depth: 16,
        xlen: mxlen.size,
        physRegBits: 7,
        robTagBits: robTagBits,
      );

      // Privileged trap/return delivery (#75). Computed once at the OoO-branch
      // scope so BOTH the speculative fetch-redirect block (inside the
      // `if (speculative)` below) and the commit output block (further down) can
      // use it. A committing exception or mret/sret must flush the younger
      // (wrong-path) entries and steer the fetcher, exactly like a branch
      // redirect, and additionally trap/return delivery sets nextMode + isReturn
      // so core.dart writes mcause/mepc/mstatus and restores pc/mode.
      final commitException = (rob.commitValid0 & rob.commitException0).named(
        'commitException',
      );
      final commitReturn = (rob.commitValid0 & rob.commitIsReturn0).named(
        'commitReturn',
      );
      final machineMode = Const(PrivilegeMode.machine.id, width: 3);
      // returnLevel: ROB stores the 2-bit privilege level (3=M/1=S); zeroExtend
      // recovers the 3-bit value core.dart compares against M (==3).
      final commitReturnLevel3 = rob.commitReturnLevel0
          .zeroExtend(3)
          .named('commitReturnLevel3');

      // Front-end instruction page fault. The fetcher could not deliver the
      // instruction, so nothing is allocated into the ROB and no functional
      // unit can ever report the fault at commit. The fault must therefore be
      // taken here, from the front end. It waits for the ROB to drain, so every
      // older instruction has retired and the exception stays precise.
      //
      // Without this the OoO pipeline simply ignored fetch_fault: the fetch
      // buffer held the faulting slot (it clears only on a redirect) and
      // re-presented the same bubble every cycle, so the core spun on the bad
      // PC instead of trapping. The in-order pipeline has always taken this
      // fault through its exec unit.
      final feFaultCause = Const(Trap.instructionPageFault.causeCode, width: 6);
      final Logic frontEndFault;
      if (speculative && useCompressedFetch) {
        // One-shot: fetch_fault is held until the redirect lands, so latch that
        // the trap was taken and re-arm only once the fetcher has moved on.
        final feFaultTaken = Logic(name: 'feFaultTaken');
        frontEndFault = (fetchFaultSig & rob.empty & enable & ~feFaultTaken)
            .named('frontEndFault');
        Sequential(clk, [
          If(
            reset,
            then: [feFaultTaken < 0],
            orElse: [
              If(
                frontEndFault,
                then: [feFaultTaken < 1],
                orElse: [
                  If(~fetchFaultSig, then: [feFaultTaken < 0]),
                ],
              ),
            ],
          ),
        ]);
      } else {
        // No speculative redirect path, so the fetcher cannot be resteered to a
        // trap vector from here.
        frontEndFault = Const(0);
      }
      // The cause that drives the trap vector and the target mode: the front-end
      // fault carries its own, everything else comes from the committing entry.
      final trapCauseSel = mux(
        frontEndFault,
        feFaultCause,
        rob.commitCause0,
      ).named('trapCauseSel');
      // Either source takes a trap this cycle.
      final anyTrap = (commitException | frontEndFault).named('anyTrap');

      final Logic trapTargetMode;
      final Logic trapVecPc;
      if (mtvec != null) {
        final isIntr = Const(0); // commit exceptions are synchronous
        trapTargetMode = selectTrapTargetModeTop(
          isIntr,
          trapCauseSel,
          currentMode,
          mideleg,
          medeleg,
          hasCsr: csrRead != null && csrWrite != null,
          hasSupervisor: hasSupervisor,
        ).named('oooTrapMode');
        final tvec = stvec != null
            ? mux(trapTargetMode.eq(machineMode), mtvec, stvec)
            : mtvec;
        trapVecPc = computeTrapVectorPcTop(
          tvec,
          trapCauseSel,
          isIntr,
          mxlen,
          suffix: 'Ooo',
        );
      } else {
        trapTargetMode = currentMode;
        trapVecPc = currentPc;
      }
      // Return target for the fetcher: {m,s}epc by the return level. core.dart
      // restores the architectural pc/mode in parallel; this only steers fetch.
      final Logic retVecPc = mepc == null
          ? currentPc
          : (sepc != null
                ? mux(commitReturnLevel3.eq(machineMode), mepc, sepc)
                : mepc);

      // Speculative front-end control. Back-pressure: accept only when the ROB,
      // IQ, and free list can all take the instruction. Advance the fetcher when
      // an instruction is actually allocated (doAlloc), so it self-sequences to
      // the next PC. On a committing branch/jump redirect: squash the back-end
      // (flushOrRedirect via specFlush) and steer the fetcher to the target.
      if (speculative) {
        // CSR serialisation barrier: keep CSR side effects off the speculative
        // path. A CSR may not allocate until the ROB has drained (so it is the
        // oldest instruction → on the correct path), and once a CSR is in flight
        // nothing younger may allocate until it commits (so nothing executes
        // speculatively after it). CSRs are rare, so the full drain is fine.
        final renameIsCsr = renameNode[kIsCsr];
        final csrInFlight = Logic(name: 'csrInFlight');
        final csrBarrierStall = (csrInFlight | (renameIsCsr & ~rob.empty))
            .named('csrBarrierStall');
        renameReady <=
            (rob.allocReady &
                    iq.enqReady &
                    renameTable.ready &
                    ~csrBarrierStall)
                .named('renameReadySpec');
        Sequential(clk, [
          If(
            reset,
            then: [csrInFlight < 0],
            orElse: [
              If(
                doAlloc & renameIsCsr,
                then: [csrInFlight < 1],
                orElse: [
                  If(csrInFlight & rob.commitValid0, then: [csrInFlight < 0]),
                ],
              ),
            ],
          ),
        ]);
        // Alloc cadence: when the load-store queue is present (so memory is
        // properly disambiguated), advance the fetcher whenever the back-end can
        // accept a delivered instruction, not only when the current one
        // allocates. This pipelines fetch->decode->rename (each stage holds a
        // distinct instruction) instead of one round trip per instruction (the
        // ~3 cyc/instr front-end floor). WITHOUT the LSQ the legacy store-at-
        // execute memory path relies on the slower cadence for store->load
        // visibility, so keep the doAlloc cadence there. (Correct given the fetch
        // memory never emits X.) See project_hdl_frontend_perf.
        fetchAdvance! <= (lsqEnabled ? (renameReady & fetchDone) : doAlloc);
        // Retirement strobe (perf counter / IPC measurement).
        addOutput('retire_valid') <= rob.commitValid0;

        // ---- Branch prediction (rename stage) ----
        // Predict a conditional branch's direction; when predicted taken (or for
        // an unconditional JAL), redirect the FETCH stream to the target NOW, so
        // a correctly-predicted branch costs no pipeline flush. The branch unit
        // re-checks at execute (issuePredictedTaken) and the commit redirect only
        // fires on a real misprediction. JALR is not predicted (target = rs1+imm,
        // unknown at rename) → predicted not-taken → resolves at execute.
        final renIsCond = renameNode[kIsBranch] & ~renameNode[kIsJump];
        final renIsJal = renameNode[kIsJump] & ~renameNode[kIsJalr];
        final renImm = fitWidth(renameNode[kImm], mxlen.size);
        final immBackward = renImm[mxlen.size - 1]; // sign: negative = backward
        final isPredicting = branchPredictor != BranchPredictor.none;
        final Logic predDir;
        switch (branchPredictor) {
          case BranchPredictor.none:
            predDir = Const(0);
            break;
          case BranchPredictor.btfn:
            predDir = immBackward; // backward branches (loops) taken
            break;
          case BranchPredictor.bimodal:
            throw UnimplementedError('bimodal predictor not yet wired');
        }
        // BPD (rpipelinectl[1]) forces predicted-not-taken at runtime.
        final predTaken =
            ((isPredicting ? ((renIsCond & predDir) | renIsJal) : Const(0)) &
                    ~bpdDisable)
                .named('predTaken');
        final predictTarget = (renamePcNow! + renImm).named('predictTarget');
        final predictRedirect = (doAlloc & predTaken).named('predictRedirect');

        // A committing branch/jump misprediction, exception, or privileged
        // return redirects with a full flush (squashing wrong-path younger
        // entries); a new prediction just steers the fetcher (no flush). Commit
        // redirect has priority. Redirect target: exception -> trap vector,
        // return -> {m,s}epc, branch -> commit target.
        final commitBranchRedir = (rob.commitValid0 & rob.commitRedirects0)
            .named('commitBranchRedir');
        // A front-end fetch fault steers the fetcher exactly like a committing
        // exception. The flush is a no-op for the (drained) back end, but the
        // redirect is what clears the fetch buffer's held fault and restarts it
        // at the trap vector.
        specFlush! <=
            (commitBranchRedir | commitException | commitReturn | frontEndFault)
                .named('specF');
        final anyRedirect = (specFlush | predictRedirect).named('anyRedirect');
        final commitRedirPc = mux(
          anyTrap,
          trapVecPc,
          mux(commitReturn, retVecPc, rob.commitTarget0),
        ).named('commitRedirPc');
        final redirectPc = mux(
          specFlush,
          commitRedirPc,
          predictTarget,
        ).named('redirPc');
        fetchRedirect! <= anyRedirect;
        fetchRedirectPc! <= redirectPc;

        // Wrong-path squash by PC: on any redirect, latch the target and suppress
        // allocation (renameNode.cancel) until an instruction with PC==target
        // reaches rename. (Already-allocated wrong-path entries on a commit flush
        // are squashed by the flush itself.)
        Sequential(clk, [
          If(
            reset,
            then: [awaitingTarget! < 0, targetPcReg! < 0],
            orElse: [
              If(
                anyRedirect,
                then: [awaitingTarget < 1, targetPcReg < redirectPc],
                orElse: [
                  If(
                    awaitingTarget &
                        renameNode.isFiring &
                        renamePcNow.eq(targetPcReg),
                    then: [awaitingTarget < 0],
                  ),
                ],
              ),
            ],
          ),
        ]);
      }

      // -----------------------------------------------------------------------
      // Functional units
      // -----------------------------------------------------------------------

      final alu0 = AluUnit(
        clk,
        reset,
        issueValid: iq.dispatchAluValid0,
        issueTag: iq.dispatchAluTag0,
        issueSrc1: iq.dispatchAluSrc10,
        issueSrc2: iq.dispatchAluSrc20,
        issueImm: iq.dispatchAluImm0,
        issueFunct: iq.dispatchAluFunct0,
        issueUseImm: iq.dispatchAluUseImm0,
        issuePc: iq.dispatchAluPc0,
        flush: flushOrRedirect,
        xlen: mxlen.size,
        robTagBits: robTagBits,
        name: 'alu_0',
      );
      final alu1 = AluUnit(
        clk,
        reset,
        issueValid: iq.dispatchAluValid1,
        issueTag: iq.dispatchAluTag1,
        issueSrc1: iq.dispatchAluSrc11,
        issueSrc2: iq.dispatchAluSrc21,
        issueImm: iq.dispatchAluImm1,
        issueFunct: iq.dispatchAluFunct1,
        issueUseImm: iq.dispatchAluUseImm1,
        issuePc: iq.dispatchAluPc1,
        flush: flushOrRedirect,
        xlen: mxlen.size,
        robTagBits: robTagBits,
        name: 'alu_1',
      );

      // Predicted-taken for the branch unit's misprediction check. Must match
      // the rename-stage prediction for the same branch: BTFN predicts a
      // conditional branch taken iff its displacement is negative (backward),
      // and JAL always taken; JALR (and `none`) → not-taken.
      final branchUnitPredTaken = (branchPredictor == BranchPredictor.none)
          ? Const(0)
          : ((iq.dispatchBranchIsJump & ~iq.dispatchBranchIsJalr) |
                    (~iq.dispatchBranchIsJump &
                        iq.dispatchBranchImm[mxlen.size - 1]))
                .named('branchUnitPredTaken');

      // Branch unit
      final branchUnit = BranchUnit(
        clk,
        reset,
        issueValid: iq.dispatchBranchValid,
        issueTag: iq.dispatchBranchTag,
        issueSrc1: iq.dispatchBranchSrc1,
        issueSrc2: iq.dispatchBranchSrc2,
        issueImm: iq.dispatchBranchImm,
        issuePc: iq.dispatchBranchPc,
        issueCondition: iq.dispatchBranchCondition,
        issueIsJump: iq.dispatchBranchIsJump,
        issueIsJalr: iq.dispatchBranchIsJalr,
        issueIsCompressed: iq.dispatchBranchIsCompressed,
        issuePredictedTaken: branchUnitPredTaken,
        flush: flushOrRedirect,
        xlen: mxlen.size,
        robTagBits: robTagBits,
      );

      // CSR unit (only if CSR ports available). Self-serialising FSM that reads
      // then writes the CSR file and returns the OLD value as rd. CSRs are kept
      // off the speculative path by the barrier in the rename backpressure
      // (csrBarrierStall) below; in lockstep OoO the single-in-flight front-end
      // serialises them naturally.
      CsrUnit? csrUnit;
      if (csrRead != null && csrWrite != null) {
        csrUnit = CsrUnit(
          clk,
          reset,
          csrRead,
          csrWrite,
          issueValid: iq.dispatchCsrValid,
          issueTag: iq.dispatchCsrTag,
          issueSrc1: iq.dispatchCsrSrc1,
          issueImm: iq.dispatchCsrImm,
          issueOp: iq.dispatchCsrOp,
          issueCsrAddr: iq.dispatchCsrAddr,
          flush: flushOrRedirect,
          xlen: mxlen.size,
          robTagBits: robTagBits,
        );
      }

      // Complete the branch in the ROB (port 2), recording its redirect/target
      // so control flow is corrected at commit. Without this a branch's ROB
      // entry would never complete and the core would stall. The CSR unit shares
      // this port: a branch and a CSR are mutually exclusive in flight (a CSR is
      // serialised to run alone), so muxing on csr.resultValid is race-free. A
      // CSR never redirects, so its redirect/target are 0.
      final csrComplete = csrUnit?.resultValid ?? Const(0);
      robCompleteValid2 <= branchUnit.resultValid | csrComplete;
      robCompleteTag2 <=
          mux(
            csrComplete,
            csrUnit?.resultTag ?? Const(0, width: robTagBits),
            branchUnit.resultTag,
          );
      robCompleteResult2 <=
          mux(
            csrComplete,
            csrUnit?.resultData ?? Const(0, width: mxlen.size),
            branchUnit.resultData,
          );
      robCompleteException2 <=
          mux(
            csrComplete,
            csrUnit?.resultException ?? Const(0),
            branchUnit.resultException,
          );
      robCompleteCause2 <=
          mux(
            csrComplete,
            csrUnit?.resultCause ?? Const(0, width: 6),
            branchUnit.resultCause,
          );
      robCompleteRedirects2 <= mux(csrComplete, Const(0), branchUnit.redirect);
      robCompleteTarget2 <=
          mux(csrComplete, Const(0, width: mxlen.size), branchUnit.redirectPc);

      // Memory unit (loads/stores). Speaks Wishbone; bridged to the pipeline's
      // memExecRead/memWrite DataPortInterfaces below. The slave response
      // (wbAck/wbDatMiso) is fed back from those ports.
      final memWbAck = Logic(name: 'mem_wb_ack');
      final memWbDatMiso = Logic(name: 'mem_wb_dat_miso', width: mxlen.size);
      // Page-fault for the in-flight load/store (dport done & ~valid), driven in
      // the bridge below. Lets a faulting access trap at commit instead of
      // hanging the request FSM (which never gets an ack on a fault).
      final memFaultWire = Logic(name: 'mem_fault');
      final memUnit = MemoryUnit(
        clk,
        reset,
        issueValid: iq.dispatchMemValid,
        issueTag: iq.dispatchMemTag,
        issueSrc1: iq.dispatchMemSrc1,
        issueSrc2: iq.dispatchMemSrc2,
        issueImm: iq.dispatchMemImm,
        issueIsStore: iq.dispatchMemIsStore,
        issueSize: iq.dispatchMemSize,
        issueSignExtend: iq.dispatchMemSignExtend,
        flush: flushOrRedirect,
        wbAck: memWbAck,
        wbDatMiso: memWbDatMiso,
        wbErr: Const(0),
        memFault: memFaultWire,
        memFaultGuest: memFaultGuest,
        lsqStores: lsqEnabled,
        // storeQueue mode: a load waits for the queue to fully drain. forwarding
        // mode: a load only waits when a store partially overlaps it (fwdStall);
        // exact matches forward and non-aliasing loads read the bus immediately.
        // SSBD (rpipelinectl[0]) forces the forwarding/speculative path to the
        // conservative store-queue stall (wait until every older store drains)
        // at runtime, closing the speculative-store-bypass v4 surface. The
        // store-queue mode is already conservative, so ssbd is a no-op there.
        loadStall: lsqEnabled
            ? (forwarding
                  ? mux(ssbdDisable, ~sqEmptyWire, sqFwdStallWire)
                  : ~sqEmptyWire)
            : null,
        fwdHit: forwarding ? sqFwdHitWire : null,
        fwdData: forwarding ? sqFwdDataWire : null,
        issuePc: speculativeLsq ? iq.dispatchMemPc : null,
        camViolation: speculativeLsq ? lqCamViolationWire : null,
        xlen: mxlen.size,
        robTagBits: robTagBits,
      );
      memBusyWire <= memUnit.busy;
      aluBusy0Wire <= alu0.busy;
      aluBusy1Wire <= alu1.busy;
      // Store→load violation redirect (speculative LSQ). resultRedirect is only
      // high when the memory unit completes a violating store (so it implies the
      // mem unit won port 0). The TARGET must be gated the same way: otherwise
      // its held (stale) value would be stamped onto every other port-0 commit's
      // entry, corrupting unrelated ALU0/load completions.
      robCompleteRedirects0 <= memUnit.resultRedirect;
      robCompleteTarget0 <=
          mux(
            memUnit.resultRedirect,
            memUnit.resultTarget,
            Const(0, width: mxlen.size),
          );

      // Bridge the MemoryUnit's Wishbone master to the DataPortInterfaces.
      final memLoadReq = memUnit.wbCyc & memUnit.wbStb & ~memUnit.wbWe;
      final memStoreReq = memUnit.wbCyc & memUnit.wbStb & memUnit.wbWe;
      memExecRead.en <= memLoadReq;
      memExecRead.addr <= memUnit.wbAdr;
      memWbDatMiso <= memExecRead.data;
      // memWrite.data carries {size[6:0], value[xlen-1:0]} (the core's dport
      // demux decodes the byte-count prefix into a log2 size for the MMU).

      // Page fault for the active access: the dport completed (done) but did not
      // validate (~valid) -> the MMU walk faulted. Gated by the MemoryUnit's own
      // load/store request so the LSQ commit-drain path (which drives memWrite
      // independently) never raises a spurious fault on the MemoryUnit.
      memFaultWire <=
          (memLoadReq & memExecRead.done & ~memExecRead.valid) |
              (memStoreReq & memWrite.done & ~memWrite.valid);

      if (lsqEnabled) {
        // Store queue: a store pushes at execute and RETIRES immediately at
        // commit (no stall); its memory write drains in the BACKGROUND as the
        // head entry, in program order. A load waits for the queue to empty.
        // `commitValid` advances the queue's commit pointer when a store
        // retires; the head entry then becomes drainable.
        // A store retiring in slot 0, and (dual-commit) a store retiring in
        // slot 1 the same cycle. robCommitAck0 == commitValid0 (the head always
        // retires when valid) and commitValid1 implies commitValid0 (in-order
        // dual commit), and a slot-1 store is no longer held back, so both
        // signals reduce to commitValid{0,1} & commitIsStore{0,1}. The queue
        // advances its commit pointer by however many fire (0/1/2), so store
        // pairs need no throttling and the queue is robust to the commit
        // cadence. See project_hdl_frontend_perf.
        final storeCommit =
            (rob.commitValid0 & rob.commitIsStore0 & robCommitAck0).named(
              'sqStoreCommit',
            );
        final storeCommit1 = (rob.commitValid1 & rob.commitIsStore1).named(
          'sqStoreCommit1',
        );
        final drainDone = Logic(
          name: 'sqDrainDone',
        ); // head write completed (set below)

        final storeQueue = StoreQueue(
          clk,
          reset,
          flush: flushOrRedirect,
          pushValid: memUnit.storeFillValid,
          pushTag: memUnit.storeFillTag,
          pushAddr: memUnit.storeFillAddr,
          pushData: memUnit.storeFillData,
          pushSize: memUnit.storeFillSize,
          commitValid: storeCommit,
          commitValid2: storeCommit1,
          popValid: drainDone,
          // Forwarding query: the dispatching load's effective address + size.
          fwdQueryAddr: (iq.dispatchMemSrc1 + iq.dispatchMemImm).named(
            'loadQueryAddr',
          ),
          fwdQuerySize: iq.dispatchMemSize,
          depth: storeQueueDepth,
          xlen: mxlen.size,
          robTagBits: robTagBits,
        );
        sqFullWire <= storeQueue.full;
        sqEmptyWire <= storeQueue.empty;
        sqFwdHitWire <= storeQueue.fwdHit;
        sqFwdDataWire <= storeQueue.fwdData;
        sqFwdStallWire <= storeQueue.fwdStall;

        // Load queue (speculative mode): records executed loads; a resolving
        // store CAMs it for younger aliasing loads that read too early.
        if (speculativeLsq) {
          final loadQueue = LoadQueue(
            clk,
            reset,
            flush: flushOrRedirect,
            // A completing load records its access.
            pushValid: memUnit.resultValid & ~memUnit.resultIsStore,
            pushTag: memUnit.resultTag,
            pushAddr: memUnit.resultAddr,
            pushSize: memUnit.resultSize,
            // Any commit frees the matching load entry (no-op if not a load).
            freeValid: rob.commitValid0,
            freeTag: rob.headPtr.slice(robTagBits - 1, 0),
            headIdx: rob.headPtr.slice(robTagBits - 1, 0),
            // A store, the cycle it resolves its address, checks for violations.
            camValid: memUnit.storeFillValid,
            camTag: memUnit.storeFillTag,
            camAddr: memUnit.storeFillAddr,
            camSize: memUnit.storeFillSize,
            depth: loadQueueDepth,
            xlen: mxlen.size,
            robTagBits: robTagBits,
          );
          lqCamViolationWire <= loadQueue.camViolation;
        } else {
          lqCamViolationWire <= Const(0);
        }

        // Background drain. SINGLE-OUTSTANDING. A level-driven memWrite.en
        // would glitch an extra write during the head-pop transition (the head
        // address mux moves while en is still high). Instead a `draining`
        // register holds exactly one write in flight: start when the head is
        // drainable, hold the address stable until the write acks, pop, repeat.
        final draining = Logic(name: 'sqDraining');
        Sequential(clk, [
          If(
            reset,
            then: [draining < 0],
            orElse: [
              If(
                draining,
                then: [
                  If(memWrite.done, then: [draining < 0]),
                ],
                orElse: [
                  If(storeQueue.headDrainable, then: [draining < 1]),
                ],
              ),
            ],
          ),
        ]);
        // The head entry is stable while draining (it pops only on done).
        drainDone <= draining & memWrite.done;
        memWrite.en <= draining;
        memWrite.addr <= storeQueue.headAddr;
        memWrite.data <=
            [storeQueue.headSize.zeroExtend(7), storeQueue.headData].swizzle();
        // In LSQ mode the MemoryUnit never drives a store bus cycle; ack only
        // its load reads.
        memWbAck <= memLoadReq & memExecRead.valid;
      } else {
        sqFullWire <= Const(0);
        sqEmptyWire <= Const(1);
        sqFwdHitWire <= Const(0);
        sqFwdDataWire <= Const(0, width: mxlen.size);
        sqFwdStallWire <= Const(0);
        lqCamViolationWire <= Const(0);
        memWrite.en <= memStoreReq;
        memWrite.addr <= memUnit.wbAdr;
        memWrite.data <=
            [memUnit.wbSize.zeroExtend(7), memUnit.wbDatMosi].swizzle();
        // Ack the MemoryUnit when the store/load completes *successfully*
        // (done & valid). A faulting access is done & ~valid -> no ack -> it
        // routes to memFaultWire and traps instead of completing as success.
        memWbAck <=
            (memStoreReq & memWrite.done & memWrite.valid) |
                (memLoadReq & memExecRead.valid);
      }

      // -----------------------------------------------------------------------
      // Result broadcast → ROB complete + IQ wakeup
      // -----------------------------------------------------------------------

      // Complete port 0: ALU0 or MemoryUnit → ROB. Only one is valid in any
      // cycle (single-issue: one instruction in flight, dispatched to exactly
      // one FU), so muxing on memUnit.resultValid is safe.
      final memWins = memUnit.resultValid;
      robCompleteValid0 <= alu0.resultValid | memWins;
      robCompleteTag0 <= mux(memWins, memUnit.resultTag, alu0.resultTag);
      robCompleteResult0 <= mux(memWins, memUnit.resultData, alu0.resultData);
      robCompleteException0 <=
          mux(memWins, memUnit.resultException, alu0.resultException);
      robCompleteCause0 <= mux(memWins, memUnit.resultCause, alu0.resultCause);

      // Complete port 1: ALU1
      robCompleteValid1 <= alu1.resultValid;
      robCompleteTag1 <= alu1.resultTag;
      robCompleteResult1 <= alu1.resultData;
      robCompleteException1 <= alu1.resultException;
      robCompleteCause1 <= alu1.resultCause;

      // Wakeup broadcasts to IQ. The wakeup TAG is the producer's physical
      // register (translated from the completing ROB tag), so it matches the
      // waiting entries' psrc. Three dedicated ports, one per writeback source:
      // port 0 = ALU0/Mem, port 1 = ALU1, port 2 = branch/CSR. Dedicated ports
      // mean two FUs completing the same cycle can never drop a wakeup (the
      // collision that deadlocked long dual-dispatch loop bodies).
      final port0Tag = muxArr(
        tagToPdst,
        mux(memWins, memUnit.resultTag, alu0.resultTag),
      );
      iqWakeupValid0 <= alu0.resultValid | memWins;
      iqWakeupTag0 <= port0Tag;
      iqWakeupValue0 <= mux(memWins, memUnit.resultData, alu0.resultData);

      // Port 1: ALU1 only.
      final p2Valid = robCompleteValid2;
      iqWakeupValid1 <= alu1.resultValid;
      iqWakeupTag1 <= muxArr(tagToPdst, alu1.resultTag);
      iqWakeupValue1 <= alu1.resultData;
      // Port 2: branch/CSR completion (dedicated, no longer shares with ALU1).
      iqWakeupValid2 <= p2Valid;
      iqWakeupTag2 <= muxArr(tagToPdst, robCompleteTag2);
      iqWakeupValue2 <= robCompleteResult2;

      // --------------------------------------------------------------------
      // PRF / scoreboard update
      // --------------------------------------------------------------------
      // Allocation records tag→pdst/writesRd and marks the new physreg busy.
      // Each FU writeback writes the PRF and clears busy. A flush clears all
      // busy bits: the redirect is at commit, so everything older has written
      // back (busy already 0) and everything younger is squashed.
      final wb0Wr =
          (alu0.resultValid | memWins) &
          muxArr(tagWritesRd, mux(memWins, memUnit.resultTag, alu0.resultTag));
      final wb0Pdst = port0Tag;
      final wb0Data = mux(memWins, memUnit.resultData, alu0.resultData);
      final wb1Wr = alu1.resultValid & muxArr(tagWritesRd, alu1.resultTag);
      final wb1Pdst = muxArr(tagToPdst, alu1.resultTag);
      final wb1Data = alu1.resultData;
      final wb2Wr = p2Valid & muxArr(tagWritesRd, robCompleteTag2);
      final wb2Pdst = muxArr(tagToPdst, robCompleteTag2);
      final wb2Data = robCompleteResult2;

      Sequential(clk, [
        If(
          reset,
          then: [
            ...List.generate(numPhysRegs, (i) => prf[i] < 0),
            ...List.generate(numPhysRegs, (i) => prfBusy[i] < 0),
            ...List.generate(robDepth, (i) => tagToPdst[i] < 0),
            ...List.generate(robDepth, (i) => tagWritesRd[i] < 0),
          ],
          orElse: [
            // Record translation at allocation (both lanes).
            ...List.generate(
              robDepth,
              (t) => [
                If(
                  doAlloc & rob.allocTag0.eq(t),
                  then: [
                    tagToPdst[t] < renameTable.pdst0.zeroExtend(7),
                    tagWritesRd[t] < renameNode[kWritesRd],
                  ],
                ),
                if (dualDispatch)
                  If(
                    doAlloc1 & rob.allocTag1.eq(t),
                    then: [
                      tagToPdst[t] < renameTable.pdst1.zeroExtend(7),
                      tagWritesRd[t] < r1WritesRd,
                    ],
                  ),
              ],
            ).expand((e) => e),
            // PRF write + busy update, per physreg.
            ...List.generate(numPhysRegs, (p) {
              final allocSet =
                  (doAlloc &
                      renameNode[kWritesRd] &
                      renameTable.pdst0.zeroExtend(7).eq(p)) |
                  (doAlloc1 &
                      r1WritesRd &
                      renameTable.pdst1.zeroExtend(7).eq(p));
              final wbClear =
                  (wb0Wr & wb0Pdst.eq(p)) |
                  (wb1Wr & wb1Pdst.eq(p)) |
                  (wb2Wr & wb2Pdst.eq(p));
              // Normal writeback into prf[p].
              final Conditional prfWb = If(
                wb0Wr & wb0Pdst.eq(p),
                then: [prf[p] < wb0Data],
                orElse: [
                  If(
                    wb1Wr & wb1Pdst.eq(p),
                    then: [prf[p] < wb1Data],
                    orElse: [
                      If(wb2Wr & wb2Pdst.eq(p), then: [prf[p] < wb2Data]),
                    ],
                  ),
                ],
              );
              return [
                // Backdoor seed (only physregs 0..31, the identity-mapped arch
                // regs) takes priority while prfSeedEn; otherwise normal
                // writeback. prfSeedEn is 0 in all non-seed operation.
                if (p < 32)
                  If(
                    prfSeedEnIn & prfSeedAddrIn.eq(Const(p, width: 5)),
                    then: [prf[p] < prfSeedDataIn],
                    orElse: [prfWb],
                  )
                else
                  prfWb,
                If(
                  flushOrRedirect,
                  then: [prfBusy[p] < 0],
                  orElse: [
                    If(
                      wbClear,
                      then: [prfBusy[p] < 0],
                      orElse: [
                        If(allocSet, then: [prfBusy[p] < 1]),
                      ],
                    ),
                  ],
                ),
              ];
            }).expand((e) => e),
          ],
        ),
      ]);

      // -----------------------------------------------------------------------
      // Commit logic
      // -----------------------------------------------------------------------

      // Commit: write results back to the architectural register file. Slot 0
      // is the ROB head (the oldest committer); the register file's write
      // arbiter always accepts the oldest write, so slot 0 retires whenever it
      // is valid.
      // A store retires as soon as it reaches the head; its memory write drains
      // in the background from the store queue (in-order store visibility is
      // enforced by loads waiting for the queue to empty, not by stalling
      // commit). So commit acks normally for stores and everything else.
      robCommitAck0 <= rob.commitValid0;
      rdWrite.en <= rob.commitValid0 & rob.commitWritesRd0;
      rdWrite.addr <= rob.commitRd0;
      rdWrite.data <= fitWidth(rob.commitResult0, mxlen.size);

      // Drive register file reads for source operands
      rs1Read.en <= renameNode.isFiring;
      rs1Read.addr <= renameNode[kRs1].slice(4, 0);
      rs2Read.en <= renameNode.isFiring;
      rs2Read.addr <= renameNode[kRs2].slice(4, 0);

      // (memExecRead/memWrite are now driven by the MemoryUnit bridge above.)

      // Slot-0 free-list + committed-RAT updates. The slot-1 *address*/pdst
      // wires are always driven (their data is don't-care unless slot 1
      // actually retires, gated below).
      freeValid0Wire <= rob.commitValid0 & rob.commitWritesRd0;
      freeReg0Wire <= rob.commitPdstOld0;
      freeReg1Wire <= rob.commitPdstOld1;
      commitValid0Wire <= rob.commitValid0 & rob.commitWritesRd0;
      commitRd0Wire <= rob.commitRd0;
      commitPdst0Wire <= rob.commitPdst0;
      commitRd1Wire <= rob.commitRd1;
      commitPdst1Wire <= rob.commitPdst1;

      if (rdWrite1 == null) {
        // Single-commit: the register file has one write port, so slot 1 cannot
        // write back this cycle. The front-end is single-dispatch, so two
        // ready-to-commit head entries is rare; this preserves the historical
        // behaviour (slot 1 effectively never retires).
        robCommitAck1 <= Const(0);
        freeValid1Wire <= rob.commitValid1 & rob.commitWritesRd1;
        commitValid1Wire <= rob.commitValid1 & rob.commitWritesRd1;
      } else {
        // Dual-commit: retire slot 1 through the second write port.
        //  - A second write to the *same* arch reg in the same cycle (WAW) is
        //    deferred to next cycle (slot 1 becomes the head), avoiding a
        //    commit-time RAT/free-list hazard.
        //  - A same-bank collision on a *different* reg is back-pressured by the
        //    arbiter (wr1Ready=0) and likewise retried next cycle.
        // Either way slot 0 still retires, so the head advances and forward
        // progress is guaranteed.
        final w1Writes = rob.commitWritesRd1;
        final sameRd =
            (rob.commitWritesRd0 & w1Writes & rob.commitRd0.eq(rob.commitRd1))
                .named('commitSameRd');
        final wr1Present = (rob.commitValid1 & w1Writes & ~sameRd).named(
          'wr1Present',
        );
        rdWrite1.en <= wr1Present;
        rdWrite1.addr <= rob.commitRd1;
        rdWrite1.data <= fitWidth(rob.commitResult1, mxlen.size);
        // Slot 1 retires iff valid AND (it writes no reg, or its write landed
        // and is not a same-reg WAW). A slot-1 STORE no longer needs throttling:
        // the store queue advances its commit pointer by the number of stores
        // retiring this cycle (0/1/2), so a store pair commits together without
        // under-counting. See project_hdl_frontend_perf.
        final commit1 = (rob.commitValid1 & (~w1Writes | (wr1Ready! & ~sameRd)))
            .named('commit1');
        robCommitAck1 <= commit1;
        freeValid1Wire <= commit1 & w1Writes;
        commitValid1Wire <= commit1 & w1Writes;
      }

      // -----------------------------------------------------------------------
      // Pipeline outputs
      // -----------------------------------------------------------------------

      // Redirect is carried in the committing ROB entry (set by the branch
      // unit at completion via port 2), so it is correct even when the branch
      // resolved many cycles before it reaches the head (speculative mode).
      final commitRedirect = (rob.commitValid0 & rob.commitRedirects0).named(
        'commitRedirect',
      );

      Sequential(clk, [
        If(
          reset,
          then: [
            done < 0,
            valid < 0,
            nextSp < 0,
            nextPc < 0,
            nextMode < 0,
            trap < 0,
            trapCause < 0,
            trapInterrupt < 0,
            trapTval < 0,
            trapEpc < 0,
            isReturn < 0,
            returnLevel < 0,
            fence < 0,
            interruptHold < 0,
            counter < 0,
          ],
          orElse: [
            // Commit: signal done when the ROB commits, or when the front end
            // takes a fetch fault (nothing reached the ROB to commit).
            done < rob.commitValid0 | frontEndFault,
            valid < rob.commitValid0 & ~rob.commitException0,

            // PC update: a trap redirects to the trap vector (highest
            // priority); else a branch/jump redirects to its target;
            // otherwise advance past the committed instruction.
            If(
              anyTrap,
              then: [nextPc < trapVecPc],
              orElse: [
                If(
                  commitRedirect,
                  then: [nextPc < rob.commitTarget0],
                  orElse: [
                    If(
                      rob.commitValid0,
                      then: [
                        nextPc < (rob.commitPc0 + Const(4, width: mxlen.size)),
                      ],
                      orElse: [nextPc < currentPc],
                    ),
                  ],
                ),
              ],
            ),

            nextSp < currentSp,
            nextMode < mux(anyTrap, trapTargetMode, currentMode),

            // Trap from ROB commit, or from a front-end fetch fault.
            trap < ((rob.commitValid0 & rob.commitException0) | frontEndFault),
            trapCause < trapCauseSel,
            // OoO path takes no async interrupts yet; ROB commits only
            // synchronous exceptions.
            trapInterrupt < 0,
            trapTval < Const(0, width: mxlen.size),
            // The fetch fault belongs to the PC the fetcher could not read,
            // which the ROB never saw.
            trapEpc < mux(frontEndFault, fetchOutPc, rob.commitPc0),
            // Privileged return (mret/sret): core.dart restores pc<-{m,s}epc and
            // mode<-{m,s}status.xPP and pops the status stack. The fetcher was
            // already redirected to retVecPc + flushed via specFlush above.
            isReturn < commitReturn,
            returnLevel <
                mux(commitReturn, commitReturnLevel3, Const(0, width: 3)),

            fence < Const(0),
            interruptHold < Const(0),

            If(enable, then: [counter < (counter + 1)]),
          ],
        ),
      ]);

      // OoO does not support HLV/HSV guest accesses yet.
      output('memGuest') <= Const(0);
    } // end useOoO else
  }
}
