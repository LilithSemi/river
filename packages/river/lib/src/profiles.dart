import 'package:harbor/harbor.dart';


/// RISC-V application-processor profile extension sets (RVA22 / RVA23).
///
/// These are the canonical mandatory-extension lists used to build River core
/// configs and to check profile completeness. They live here, not in a core
/// tier file, because they describe the ISA profile, not any one core.

/// RVA22U64 mandatory extension set (user-mode application profile).
///
/// RV64GC base + counters, hint, bit-manip, and cache-management extensions.
/// The platform-integration extensions (Zic64b, Za64rs, Zicc*) carry no
/// instructions, they constrain the memory system and are satisfied by
/// construction; they are listed so the profile is explicit and checkable.
final List<RiscVExtension> kRva22U64Extensions = [
  rv32i,
  rv64i,
  rvM,
  rvA,
  rvF,
  rvD,
  rvC,
  // c.fld/c.fsd/c.fldsp/c.fsdsp, which belong to C only with D present.
  rvZcd,
  rvZicsr,
  rvZifencei,
  rvZicntr,
  rvZihpm,
  rvZihintpause,
  rvZba,
  rvZbb,
  rvZbs,
  rvZicbom,
  rvZicbop,
  rvZicboz,
  rvZic64b,
  rvZa64rs,
  rvZiccif,
  rvZiccrse,
  rvZiccamoa,
  rvZicclsm,
];

/// RVA22S64 mandatory extension set = [kRva22U64Extensions] + supervisor mode
/// and the Sv* address-translation extensions (Sv39 paging is selected via the
/// MMU config, not an extension object).
final List<RiscVExtension> kRva22S64Extensions = [
  ...kRva22U64Extensions,
  rvPriv,
  rvSvbare,
  rvSvade,
  rvSvinval,
  rvSvnapot,
  rvSvpbmt,
];

/// RVA23U64 mandatory extension set = RVA22U64 + vector, conditional-ops,
/// may-be-ops, additional compressed/FP, wait-on-reservation, and the
/// non-temporal/crypto hints.
///
/// (Zacas, Svadu, and the state-enable extensions are now defined in Harbor; the
/// S-mode ones live in [kRva23S64Extensions].)
final List<RiscVExtension> kRva23U64Extensions = [
  ...kRva22U64Extensions,
  rvZfhmin,
  rvZicond,
  rvZimop,
  rvZcmop,
  rvZcb,
  rvZacas,
  rvZfa,
  rvZawrs,
  rvZihintntl,
  rvZkt,
  rvV,
  rvZvfhmin,
  rvZvbb,
  rvZvkt,
];

/// RVA23S64 mandatory extension set = RVA23U64 + supervisor, with the RVA23
/// supervisor additions Sstc (supervisor timer compare), Sscofpmf (counter
/// overflow), Svadu (hardware A/D update, which the MMU performs), and the
/// state-enable CSRs (Smstateen/Ssstateen).
final List<RiscVExtension> kRva23S64Extensions = [
  ...kRva23U64Extensions,
  rvPriv,
  rvSvbare,
  rvSvade,
  rvSvadu,
  rvSvinval,
  rvSvnapot,
  rvSvpbmt,
  rvSstc,
  rvSscofpmf,
  rvSmstateen,
  rvSsstateen,
  rvH, // Hypervisor is mandatory in RVA23S64.
];

/// RVA23S64 minus the compressed (C) extension, used by the non-compressed
/// dual-issue tier, whose fixed-width fetch alignment requires 4-byte
/// instructions. (Not a standard RVA23 profile; a microarchitecture variant.)
final List<RiscVExtension> kRva23S64ExtensionsNoC = kRva23S64Extensions
    .where((e) => e.name != 'C')
    .toList();
