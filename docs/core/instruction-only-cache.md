# Instruction-only L1 builds

Select instruction-only caching through the existing SoC derivation:

```nix
river-hdl.mkSoC {
  socName = "instruction_only_soc";
  cores = [ "rc1-s" ];
  memories = [ "0x80000000:4K:sram" ];
  instructionOnlyCache = true;
}
```

The option passes `--instruction-only-cache` to `river-genip`. Direct CLI use:

```sh
river-genip --core rc1-s --device sram:0x80000000:4K \
  --instruction-only-cache --output output
```

It selects a 64-byte, direct-mapped I-cache with 8-byte lines and **no D-cache**.
All data accesses bypass the cache. Omitting the option (or setting it to false
in Nix) preserves the selected tier's existing defaults; it does not select an
uncached CPU.

The switch applies to all harts. Supported profiles are `rc1-n`, `rc1-mi`,
`rc1-s`, and `rc1-f`, with the same XLEN throughout the SoC. The out-of-order
`rc1-m` profile is rejected for this option.

For the RV64 physical-cache path, only explicitly declared `sram` and `dram`
windows are eligible for instruction caching. The existing physical stage
requires the complete refill line to fit in a RAM PMA after translation and
permission checks. MMIO, flash, PSRAM, generated boot ROM and other unlisted
addresses bypass this path. RAM overlapping another declared bus device is
rejected. These PMAs do not advertise atomics or misaligned access support.
The legacy bare instruction-cache path retains its existing behavior.

This option does not change cache sizes on existing builds, enable cached
misaligned loads, change core ISA/pipeline profiles, or change board defaults.
It is not a timing or FPGA-boot guarantee.
