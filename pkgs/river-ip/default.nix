{
  lib,
  stdenvNoCC,
  mkShell,
  yosys,
  nextpnr,
  surfer,
  river-hdl,
}:

lib.extendMkDerivation {
  constructDrv = stdenvNoCC.mkDerivation;

  excludeDrvArgNames = [
    "socName"
    "cores"
    "instructionOnlyCache"
    "interconnect"
    "clockFreq"
    "oscFreq"
    "memories"
    "devices"
    "target"
    "pdkRoot"
    "pins"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      name ? "river-ip-${socName}",
      socName ? "river_soc",
      cores ? [ "rc1-s" ],
      instructionOnlyCache ? false,
      interconnect ? "wishbone",
      clockFreq ? 48000000,
      # The board's physical oscillator; the clock generator synthesizes
      # clockFreq from it, so a wrong value scales every clock on the chip.
      oscFreq ? 12000000,
      memories ? [ ],
      devices ? [ ],
      target ? null,
      # Optional Harbor board name (e.g. "arty-s7-50"): supplies the board's
      # connector catalog so a `spi:...:iface=pmod@ja` device resolves its pins.
      board ? null,
      pdkRoot ? null,
      pins ? [ ],
      bootProgram ? null,
      ...
    }@args:

    assert lib.assertMsg (builtins.all (
      c:
      builtins.elem c [
        "rc1-n"
        "rc1-mi"
        "rc1-s"
        "rc1-m"
        "rc1-f"
      ]
    ) cores) "river-ip: cores must each be one of [rc1-n, rc1-mi, rc1-s, rc1-m, rc1-f]";
    assert lib.assertMsg (builtins.isBool instructionOnlyCache)
      "river-ip: instructionOnlyCache must be a boolean";
    assert lib.assertMsg (
      !instructionOnlyCache || !(builtins.elem "rc1-m" cores)
    ) "river-ip: instructionOnlyCache requires scalar in-order cores";
    assert lib.assertMsg (builtins.elem interconnect [
      "wishbone"
      "axi"
      "tilelink"
    ]) "river-ip: interconnect must be one of [wishbone, axi, tilelink], got ${interconnect}";

    let
      cliArgs = lib.cli.toCommandLineShellGNU { } {
        name = socName;
        inherit interconnect;
        clock-freq = clockFreq;
        osc-freq = oscFreq;
      };

      coreFlags = lib.concatMapStringsSep " " (c: "--core ${c}") cores;
      cacheFlag = lib.optionalString instructionOnlyCache "--instruction-only-cache";
      # Memory regions are devices in the unified genip interface. Reorder the
      # declarative addr:size:type[:board][:params] form to the genip device
      # form type:addr:size[:board][:params] and pass each via --device.
      memoryFlags = lib.concatMapStringsSep " " (
        m:
        let
          p = lib.splitString ":" m;
        in
        "--device ${builtins.elemAt p 2}:${builtins.elemAt p 0}:${builtins.elemAt p 1}${
          lib.concatMapStrings (x: ":${x}") (lib.drop 3 p)
        }"
      ) memories;
      deviceFlags = lib.concatMapStringsSep " " (d: "--device ${d}") devices;
      targetFlag = lib.optionalString (target != null) "--target ${target}";
      boardFlag = lib.optionalString (board != null) "--board ${board}";
      pdkRootFlag = lib.optionalString (pdkRoot != null) "--pdk-root ${pdkRoot}";
      # Quote each pin: a spec may carry a space-separated IOSTANDARD/attr
      # (e.g. "clk=R2 SSTL135"), which must reach genip as ONE --pin argument.
      pinFlags = lib.concatMapStringsSep " " (p: "--pin '${p}'") pins;
      bootProgramFlag = lib.optionalString (bootProgram != null) "--boot-program ${bootProgram}";
    in
    builtins.removeAttrs args [
      "socName"
      "cores"
      "instructionOnlyCache"
      "interconnect"
      "clockFreq"
      "oscFreq"
      "memories"
      "devices"
      "target"
      "board"
      "pdkRoot"
      "pins"
      "bootProgram"
    ]
    // {
      inherit name;

      dontUnpack = true;
      dontConfigure = true;

      nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
        river-hdl
      ];

      buildPhase = ''
        runHook preBuild
        river-genip ${cliArgs} ${coreFlags} ${cacheFlag} ${memoryFlags} ${deviceFlags} ${targetFlag} ${boardFlag} ${pdkRootFlag} ${pinFlags} ${bootProgramFlag} --output "$out"
        runHook postBuild
      '';

      dontInstall = true;

      passthru = {
        inherit
          socName
          cores
          instructionOnlyCache
          interconnect
          clockFreq
          memories
          devices
          target
          pins
          ;
        shell = mkShell {
          name = "river-${socName}-shell";
          packages = [
            river-hdl
            yosys
            nextpnr
            surfer
          ];
        };
      }
      // (args.passthru or { });
    };
}
