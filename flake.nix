{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    flakever.url = "github:numinit/flakever";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    asix = {
      url = "git+https://git.lilithsemi.com/LilithSemi/asix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    openxc7.url = "github:openXC7/toolchain-nix";
    weir = {
      url = "git+https://git.lilithsemi.com/LilithSemi/weir";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
        flakever.follows = "flakever";
        treefmt-nix.follows = "treefmt-nix";
      };
    };
    harbor = {
      url = "git+https://git.lilithsemi.com/LilithSemi/harbor";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flakever.follows = "flakever";
        treefmt-nix.follows = "treefmt-nix";
      };
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-parts,
      flakever,
      treefmt-nix,
      weir,
      harbor,
      ...
    }@inputs:
    let
      flakeverConfig = flakever.lib.mkFlakever {
        inherit inputs;

        digits = [
          0
          1
          0
        ];
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
        inputs.treefmt-nix.flakeModule
      ];

      flake = {
        versionTemplate = "1.1pre-<lastModifiedDate>-<rev>";
        nixosModules.default = ./nix/module.nix;
      };

      systems = [
        "aarch64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        {
          system,
          pkgs,
          inputs',
          ...
        }:
        let
          inherit (pkgs) lib;

          inherit (pkgs) buildDartApplication;

          inherit (import ./nix/common-dart.nix lib)
            pubspecLock
            gitHashes
            ;

          buildDartTest =
            args:
            (buildDartApplication (
              args
              // {
                pname = "${args.pname}-tests";

                nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
                  pkgs.lcov
                ];

                buildPhase = ''
                  runHook preBuild
                  mkdir -p $out $out/coverage

                  dart --old_gen_heap_size=40960 --packages=.dart_tool/package_config.json --pause-isolates-on-exit --disable-service-auth-codes --enable-vm-service=8181 $(packagePath test)/bin/test.dart $packageRoot --file-reporter=json:$out/report.json -r expanded &

                  packageRun coverage -e collect_coverage --wait-paused --uri=http://127.0.0.1:8181/ -o $out/coverage/report.json --resume-isolates --scope-output=${args.pname}
                  packageRun coverage -e format_coverage --packages=.dart_tool/package_config.json --lcov -i $out/coverage/report.json -o $out/coverage/lcov.info

                  if [[ -s $out/coverage/lcov.info ]]; then
                    genhtml -o $out/coverage/html $out/coverage/lcov.info
                  fi

                  runHook postBuild
                '';

                dontInstall = true;
              }
            )).overrideAttrs
              { outputs = [ "out" ]; };
        in
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [
              inputs.asix.overlays.default
              inputs.weir.overlays.default
              inputs.harbor.overlays.default
              self.overlays.default
            ];
          };

          treefmt.programs = {
            dart-format.enable = true;
            nixfmt.enable = true;
          };

          # PDKs (sky130-pdk, gf180mcu-pdk) come from asix's overlay, applied
          # above in _module.args.pkgs.
          overlayAttrs = {
            flakever = flakeverConfig;
            river-hdl = pkgs.callPackage ./pkgs/river-hdl {
              # openXC7 Xilinx toolchain: mkFpga uses it for spartan7 targets.
              # The chipdb/nextpnr/prjxray come from the flake's per-system
              # packages; the python deps for prjxray's fasm2frames come from
              # openXC7's own pinned nixpkgs (a consistent 3.12 set).
              openxc7 = inputs'.openxc7.packages;
              openxc7Nixpkgs = inputs.openxc7.inputs.nixpkgs.legacyPackages.${system};
            };
          };

          checks = {
            formatting = (inputs.treefmt-nix.lib.evalModule pkgs ./treefmt.nix).config.build.check self;
          }
          // lib.mapAttrs' (name: lib.nameValuePair "${name}-tests") (
            lib.genAttrs
              [
                "bintools"
                "river"
                "river_adl"
                "river_emulator"
                "river_hdl"
              ]
              (
                pname:
                buildDartTest {
                  inherit
                    pname
                    pubspecLock
                    gitHashes
                    ;
                  inherit (pkgs.flakever) version;

                  src = ./.;
                  packageRoot = "packages/${pname}";
                }
              )
          );

          packages =
            let
              devices = import ./devices.nix {
                inherit (pkgs) river-hdl;
                sky130-pdk = pkgs.sky130-pdk or null;
                gf180mcu-pdk = pkgs.gf180mcu-pdk or null;
              };

              fpgaVendors = [
                "ecp5"
                "ice40"
                "spartan7"
              ];
              asicVendors = [
                "sky130"
                "gf180mcu"
              ];

              targetVendor =
                ip:
                let
                  parts = lib.splitString ":" (ip.target or "");
                in
                if parts != [ ] then builtins.head parts else null;

              isFpga = ip: builtins.elem (targetVendor ip) fpgaVendors;
              isAsic = ip: builtins.elem (targetVendor ip) asicVendors;

              # NixOS-capable: stock riscv64 userspace is rv64gc (lp64d), so the
              # SoC needs a hardware-FPU core. The in-order rc1-f "full" core and
              # the out-of-order rc1-ma "macro" (rc1-f-class ISA, OoO) both have
              # F/D; creek's rc1-s / stream's rc1-n SIGILL in userspace.
              nixosCores = [
                "rc1-f"
                "rc1-ma"
              ];
              isNixosCapable = ip: lib.any (c: builtins.elem c nixosCores) (ip.cores or [ ]);

              # A GPT+ESP+ext4 SD image of a NixOS system for this SoC, boot-through
              # Weir (see nix/nixos-sdcard.nix). Cross-compiled to riscv64 from the
              # build host. The hardware.river module supplies the firmware + the
              # harbor-kmod driver package.
              mkNixosSdcard =
                name: ip:
                (inputs.nixpkgs.lib.nixosSystem {
                  modules = [
                    ./nix/module.nix
                    ./nix/nixos-sdcard.nix
                    {
                      hardware.river = {
                        enable = true;
                        ipPackage = ip;
                      };
                      nixpkgs.hostPlatform = "riscv64-linux";
                      nixpkgs.buildPlatform = system;
                      # module.nix needs the Weir firmware + harbor-kmod driver.
                      nixpkgs.overlays = [
                        inputs.harbor.overlays.default
                        inputs.weir.overlays.default
                      ];
                    }
                  ];
                }).config.system.build.image;

              mkDevicePackages =
                name: cfg:
                let
                  inherit (cfg) ip;
                  tapeout = pkgs.asix.mkTapeout {
                    name = "${name}-tapeout";
                    inherit ip;
                    inherit (cfg) topCell pdk clockPeriodNs;
                  };
                in
                {
                  "${name}" = ip;
                }
                // lib.optionalAttrs (isFpga ip) {
                  "${name}-bitstream" = pkgs.river-hdl.mkFpga {
                    inherit ip;
                    placer = cfg.placer or "heap";
                    seed = cfg.seed or 2;
                  };
                }
                // lib.optionalAttrs (isFpga ip && isNixosCapable ip) {
                  "${name}-nixos-sdcard" = mkNixosSdcard name ip;
                }
                // lib.optionalAttrs (isAsic ip) {
                  "${name}-tapeout" = tapeout;
                  "${name}-verify" = pkgs.asix.mkVerify {
                    name = "${name}-verify";
                    inherit tapeout;
                  };
                };
            in
            {
              default = pkgs.river-hdl;
              hdl = pkgs.river-hdl;
              emulator = buildDartApplication {
                pname = "river-emulator";
                inherit pubspecLock gitHashes;
                inherit (pkgs.flakever) version;

                src = ./.;
                packageRoot = "packages/river_emulator";

                dartEntryPoints."bin/river-emulator" = "packages/river_emulator/bin/river_emulator.dart";

                preBuild = ''
                  mkdir -p bin
                '';
              };

              # The HDL simulator, exposing the core over an OpenOCD
              # remote_bitbang JTAG server (`--remote-bitbang`) so Heimdall can
              # drive the real RTL the same way it drives silicon. `jtag-probe`
              # is a lightweight bitbang client for smoke-testing the server.
              sim = buildDartApplication {
                pname = "river-sim";
                inherit pubspecLock gitHashes;
                inherit (pkgs.flakever) version;

                src = ./.;
                packageRoot = "packages/river_hdl";

                dartEntryPoints = {
                  "bin/river-sim" = "packages/river_hdl/bin/river_sim.dart";
                };

                preBuild = ''
                  mkdir -p bin
                '';
              };
            }
            // lib.foldl' (acc: name: acc // mkDevicePackages name devices.${name}) { } (
              builtins.attrNames devices
            );

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              yq
              dart
              yosys
              nextpnr
              surfer
              # Logic-analyzer capture for the DSLogic U3Pro32 (tier-3 DDR LA).
              # sigrok-cli = headless/scriptable on aarch64; pulseview = GUI.
              # DSLogic uses libsigrok's dreamsourcelab-dslogic driver.
              sigrok-cli
              pulseview
              pkgsCross.riscv32-embedded.stdenv.cc
              pkgsCross.riscv64-embedded.stdenv.cc
            ];
          };

          legacyPackages = pkgs;
        };
    };
}
