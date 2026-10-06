# A NixOS system for a River SoC that boots from an SD card through Weir.
#
# Weir is the platform UEFI firmware: it looks for a GPT ESP and loads
# \EFI\BOOT\BOOTRISCV64.EFI. We put systemd-boot there, which then boots NixOS
# (kernel + initrd + loader entry off the same ESP), and the initrd mounts the
# ext4 root from the SD (harbor_spi + mmc_spi).
#
# The image comes from the NixOS `image.repart` module: build-host systemd-repart
# under fakeroot assembles a GPT image with no VM and no target execution, so it
# cross-compiles to riscv64 from an x86_64/aarch64 host with no qemu/binfmt. GPT
# matters here - Weir does gpt.findEsp() and, failing that, reads the WHOLE disk
# at LBA 0 as one FAT. It never scans MBR partitions, so the MBR layout from
# sd-image.nix would be invisible to it.
#
# The flake sets hardware.river.ipPackage, nixpkgs.hostPlatform (riscv64-linux)
# and nixpkgs.buildPlatform (the build host, for cross).
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  # Force a kernel option off, overriding the NixOS common-config default, and
  # tolerate kconfig keeping it on if something still selects it (so a stray
  # dependency never fails the build).
  off = lib.mkForce (lib.kernel.option lib.kernel.no);

  # systemd-boot EFI binary for the target arch, and the EFI removable-media
  # fallback name Weir's boot manager loads.
  efiArch = "riscv64";
  sdbootEfi = "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";

  kernelPath = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
  initrdPath = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
  toplevel = config.system.build.toplevel;

  rootPartLabel = "nixos";

  # The systemd-boot loader entry. Root is mounted from the initrd's baked-in
  # fileSystems config; init= points at this generation's stage-2.
  loaderEntry = pkgs.writeText "nixos.conf" ''
    title NixOS
    linux /EFI/nixos/kernel.efi
    initrd /EFI/nixos/initrd
    options init=${toplevel}/init ${lib.concatStringsSep " " config.boot.kernelParams}
  '';
  loaderConf = pkgs.writeText "loader.conf" ''
    default nixos
    timeout 3
  '';
in
{
  imports = [
    # minimal, not base: base is the installer/rescue profile (testdisk, vim,
    # pciutils, usbutils, nvme-cli, cryptsetup, w3m, ...) and enables btrfs/zfs/
    # xfs/ntfs/cifs support, dragging in those tools AND kernel modules. minimal
    # strips all of it: empty default packages, docs off, extra services off.
    "${modulesPath}/profiles/minimal.nix"
    "${modulesPath}/image/repart.nix"
  ];

  # This board boots to a serial root login off the SD and does nothing else, so
  # strip the kernel to that. Disable the big subsystems it has no hardware or use
  # for: display, sound, USB, wireless/Bluetooth, media, virtualisation, RDMA. The
  # RISC-V core + PLIC/CLINT timer + ns16550a serial + SPI + MMC/SD + ext4 +
  # initramfs (kept by the modules below and the in-tree defaults) still build.
  # NET core stays (systemd needs AF_UNIX/loopback); only the driver bloat goes.
  boot.kernelPatches = [
    {
      name = "delta-minimal";
      patch = null;
      structuredExtraConfig = {
        DRM = off; # no display of any kind (serial console only)
        FB = off;
        SOUND = off; # no audio hardware
        USB_SUPPORT = off; # no USB on the delta bring-up
        WLAN = off; # no radios
        BT = off;
        NFC = off;
        MEDIA_SUPPORT = off; # no capture/tuner hardware
        VIRTUALIZATION = off; # not a hypervisor or KVM guest
        INFINIBAND = off; # no RDMA fabric
        CAN = off; # niche buses this board lacks
        HAMRADIO = off;
        # Drop DWARF debug info: it bloats every module (and the vmlinux), which
        # inflates the initrd and the on-SD closure. No effect on the stripped
        # Image, but a big cut to /lib/modules. Switch the debug-info CHOICE to
        # "none" (DEBUG_INFO is selected by it, so setting DEBUG_INFO=n alone
        # would be forced back on).
        DEBUG_INFO_NONE = lib.mkForce lib.kernel.yes;
        # River RC1 cores do NO unaligned access in hardware: every misaligned
        # load/store/AMO traps and is emulated (Weir in M-mode). The default
        # RISCV_PROBE_UNALIGNED_ACCESS benchmarks unaligned speed at boot by
        # hammering unaligned copies (check_unaligned_access), which on this core
        # is thousands of trap-and-emulate round trips and takes HOURS. Assume
        # emulated and skip the boot probe entirely.
        RISCV_EMULATED_UNALIGNED_ACCESS = lib.mkForce lib.kernel.yes;
        RISCV_PROBE_UNALIGNED_ACCESS = off;
        # Timer tick rate. The default 250 Hz gives the whole timer path 4 ms.
        # On this core that is far too little: the path is an interrupt entry, an
        # SBI round trip into M-mode firmware and back, timer processing,
        # softirqs and irqtime accounting, on an in-order core with no branch
        # prediction and a 256-byte L1 D-cache. Measured on hardware at 20 MHz,
        # mtimecmp fell 16 ms behind mtime and the kernel livelocked in a timer
        # interrupt storm, servicing ticks and never making forward progress.
        # 100 Hz gives 10 ms, which is 2.5x the budget for no hardware change.
        HZ_250 = off;
        HZ_100 = lib.mkForce lib.kernel.yes;
        HZ = lib.mkForce (lib.kernel.freeform "100");
        # Full dynticks does considerably more work per tick than NO_HZ_IDLE and
        # targets many-core low-latency systems. This is a single hart.
        NO_HZ_FULL = off;
        NO_HZ_IDLE = lib.mkForce lib.kernel.yes;
      };
    }
  ];

  # Serial console on the ns16550a; no framebuffer on this SoC.
  #
  # Raise the device-unit timeout. serial-getty@ttyS0 waits for
  # dev-ttyS0.device, which systemd plugs when udev processes the tty. On this
  # slow SoC (and under emulation) udev can take longer than the 90 s default to
  # reach the port behind the other coldplug events, so the getty fails its
  # dependency and no login appears. 5 minutes gives udev room to catch up.
  boot.kernelParams = [
    # Route the earliest kernel output (before the ns16550 driver binds) through
    # the SBI console, i.e. Weir's ecall putchar. Without it a panic during early
    # boot writes to a console that does not exist yet and looks like a silent
    # hang. keep_bootcon leaves it active through the ttyS0 handoff.
    "earlycon=sbi"
    "keep_bootcon"
    "console=ttyS0,115200n8"
    "systemd.default_device_timeout_sec=300"
  ];
  boot.consoleLogLevel = lib.mkDefault 7;

  # We lay systemd-boot down as image contents (see image.repart below), so no
  # activation-time bootloader installer runs.
  boot.loader.grub.enable = false;

  # Don't pull NixOS's default initrd module set (USB HID, ehci/ohci/xhci, ahci,
  # ata_piix, floppy, common NICs, ...). This board is serial + SD-over-SPI only,
  # none of that hardware exists, and several of those modules no longer build
  # once the kernel strip above disables USB/etc. (a requested-but-missing module
  # fails modules-shrunk). We list exactly what stage-1 needs below.
  boot.initrd.includeDefaultModules = false;

  # Stage-1 must reach the SD to mount root: the Harbor SPI controller driver
  # (out-of-tree, via hardware.river's harbor-kmod) plus the in-tree SD-over-SPI
  # + block + ext4 stack.
  boot.initrd.kernelModules = [
    "harbor_spi"
    "harbor_sdio"
    "mmc_spi"
    "mmc_block"
    "ext4"
  ];
  boot.initrd.availableKernelModules = [
    "harbor_spi"
    "harbor_sdio"
    "mmc_spi"
    "mmc_block"
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/${rootPartLabel}";
    fsType = "ext4";
  };

  # Keep the closure small for a 256 MiB board bring-up.
  documentation.enable = lib.mkDefault false;
  documentation.nixos.enable = lib.mkDefault false;
  system.stateVersion = lib.mkDefault "24.11";

  # A root login on the serial console so we can see it came up.
  users.users.root.initialPassword = lib.mkDefault "root";
  services.getty.autologinUser = lib.mkDefault "root";

  # GPT image: a FAT ESP (systemd-boot + kernel + initrd + entry) and an ext4
  # root holding the system closure. `Type = "linux-generic"` (not "root") keeps
  # the partition type arch-neutral - "root" would tag it for the BUILD host's
  # arch when cross-compiling. Root is found by its GPT partition label.
  image.repart = {
    name = "${config.system.name}-nixos-sdcard";
    partitions = {
      "esp" = {
        contents = {
          "/EFI/BOOT/BOOTRISCV64.EFI".source = sdbootEfi;
          "/EFI/systemd/systemd-boot${efiArch}.efi".source = sdbootEfi;
          "/EFI/nixos/kernel.efi".source = kernelPath;
          "/EFI/nixos/initrd".source = initrdPath;
          "/loader/loader.conf".source = loaderConf;
          "/loader/entries/nixos.conf".source = loaderEntry;
        };
        repartConfig = {
          Type = "esp";
          Format = "vfat";
          SizeMinBytes = "256M";
        };
      };
      "root" = {
        storePaths = [ toplevel ];
        repartConfig = {
          Type = "linux-generic";
          Format = "ext4";
          Label = rootPartLabel;
          Minimize = "guess";
        };
      };
    };
  };
}
