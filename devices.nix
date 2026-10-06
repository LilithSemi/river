# Declarative SoC definitions.
# Each device has a base config and a set of targets (FPGA or ASIC).
{
  river-hdl,
  sky130-pdk ? null,
  gf180mcu-pdk ? null,
}:
let
  creek-v1-base = {
    socName = "creek_v1";
    cores = [ "rc1-s" ];
    interconnect = "wishbone";
    clockFreq = 48000000;
    memories = [
      "0x20000000:16M:flash"
      "0x80000000:128M:dram"
    ];
    devices = [
      "clint:0x02000000"
      "plic:0x04000000"
      "uart:0x10000000:ns16550a"
    ];
  };

  stream-v1-base = {
    socName = "stream_v1";
    cores = [ "rc1-n" ];
    interconnect = "wishbone";
    clockFreq = 12000000;
    memories = [
      "0x20000000:16M:flash"
      "0x80000000:1M:sram"
    ];
    devices = [
      "clint:0x02000000"
      "plic:0x04000000"
      "uart:0x10000000:ns16550a"
    ];
  };

  # Delta: the SoC family above Creek. It carries the River Core V1 Full core
  # (rc1-f), whose F/D FPU makes it NixOS-capable (a stock rv64gc/lp64d distro
  # needs hardware float, which the creek rc1-s core lacks). Delta sits between
  # Creek and the future Oceanic family. This is scaffold: the base and the first
  # bring-up target below track creek's structure, retuned as the family fills in.
  delta-v1-base = {
    socName = "delta_v1";
    cores = [ "rc1-f" ];
    interconnect = "wishbone";
    clockFreq = 48000000;
    memories = [
      "0x20000000:16M:flash"
      "0x80000000:128M:dram"
    ];
    devices = [
      "clint:0x02000000"
      "plic:0x04000000"
      "uart:0x10000000:ns16550a"
    ];
  };
in
{
  creek-v1-orangecrab = {
    ip = river-hdl.mkSoC (
      creek-v1-base
      // {
        target = "ecp5:lfe5u-25f:CSFBGA285";
        clockFreq = 48000000;
        oscFreq = 48000000;
        memories = [
          "0x20000000:16M:flash:orangecrab"
          "0x80000000:64K:sram"
          "0x90000000:128M:dram:orangecrab"
        ];
        bootProgram = "monitor";
        pins = [
          "clk=A9"
          "uart_tx=uart@tx:N17"
          "uart_rx=uart@rx:M18"
        ];
      }
    );
  };

  # Digilent Arty S7-50 (xc7s50, csga324, 100MHz osc), Xilinx via the openXC7
  # flow. The DDR3 is the silicon-proven ddr3v2 stack (the harbor-native ROHD
  # port of UberDDR3): full x16 256MB (MT41K128M16) at 300MHz CK. This PHY runs
  # its OWN calibration in hardware, so the host does not need a training pass.
  # cmdslot=2 sets the command slot and wrshift=-1 sets the write launch. Add
  # train=runtime to the dram params to expose the FSBL knob-ABI window instead
  # (per controller, optional).
  #
  # FSBL-from-SRAM boot (the DDR bootstrap decouple): a 64K on-chip BRAM at
  # 0x08000000 holds the FSBL stack, .data and .bss (its console struct
  # included), so the FSBL runs, prints and can drive the DDR WITHOUT a working
  # DRAM read first. The maskrom xipboot runs the FSBL in place from flash XIP.
  # The FSBL scratch lives in the SRAM (weir tools/fdt_ld.zig routes it there
  # when the tree has an mmio-sram node), then it copies main Weir into DRAM.
  # DRAM stays at 0x80000000 so Weir and Ferrite link there unchanged.
  #
  # clk MUST be SSTL135: R2 is on the 1.35V DDR bank, so `clk=R2` alone
  # (defaults to LVCMOS33) yields a dead SoC, the clock is never received.
  creek-v1-arty = {
    ip = river-hdl.mkSoC (
      creek-v1-base
      // {
        target = "spartan7:xc7s50:csga324";
        # Board catalog: supplies the Pmod connector pin map so the SD-in-SPI
        # device below resolves `iface=pmod@ja` to the JA header sites. The
        # explicit target/pins above still win, so the DDR-proven build is
        # unchanged.
        board = "arty-s7-50";
        # Driven at 33.33 MHz, the proven rate the deployed firmware targets
        # (project-river-40mhz). The old 25 MHz value was a conservative
        # placeholder that mis-framed the UART and skewed the timebase.
        clockFreq = 33333333;
        oscFreq = 100000000;
        memories = [
          "0x20000000:16M:flash:arty-s7"
          "0x08000000:64K:sram"
          "0x80000000:256M:dram:arty-s7:ddr3v2=true,clockfreq=300000000,cmdslot=2,wrshift=-1,trainable=true"
        ];
        # PmodSD (SD card in SPI mode) on Pmod JA. `iface=pmod@ja` binds
        # cs/mosi/miso/sck to JA1..JA4 via the board's connector catalog. Weir
        # discovers the harbor,spi node and probes for a card (conduit sd_spi).
        devices = creek-v1-base.devices ++ [
          "spi:0x10001000:iface=pmod@ja,sdcard=true"
          "debug-jtag"
        ];
        bootProgram = "xipboot";
        pins = [
          "clk=R2 SSTL135"
          "uart_tx=uart@tx:R12"
          "uart_rx=uart@rx:V12"
          # Arty S7 RESET button (ck_rst, active-low, shared with the FTDI SRST).
          # Adds an external reset ORed into the power-on reset so a press (or an
          # FTDI reset) restarts the SoC without a full FPGA reconfig.
          "reset_n=C18"
        ];
      }
    );
  };

  delta-v1-arty = {
    ip = river-hdl.mkSoC (
      delta-v1-base
      // {
        target = "spartan7:xc7s50:csga324";
        board = "arty-s7-50";
        clockFreq = 33333333;
        oscFreq = 100000000;
        memories = [
          "0x20000000:16M:flash:arty-s7"
          "0x08000000:64K:sram"
          "0x80000000:256M:dram:arty-s7:ddr3v2=true,clockfreq=300000000,cmdslot=2,wrshift=-1,trainable=true"
        ];
        # Native 4-bit SDIO host (4x the 1-bit SPI throughput) with an ADMA engine on
        # the fabric. dmashared puts the ADMA on the PRIMARY channel (no separate
        # channel + converge crossbar), which de-congests the DDR CDC and lifts the
        # ddr_clk route from ~67 to ~80 MHz on this dense xc7s50.
        devices = delta-v1-base.devices ++ [
          "sdio:0x10001000:dma=true,samplefall=true"
          "debug-jtag:triggers=4"
        ];
        bootProgram = "xipboot";
        pins = [
          "clk=R2 SSTL135"
          "uart_tx=uart@tx:R12"
          "uart_rx=uart@rx:V12"
          "reset_n=C18"
          # Native SDIO on the Arty S7 PmodSD header (iface= is spi-only, so the SD
          # pads bind by explicit pin). LVCMOS33 is the default I/O standard.
          "sdio_sd_clk=N14"
          "sdio_sd_cmd=L18"
          "sdio_sd_dat0=M14"
          "sdio_sd_dat1=M16"
          "sdio_sd_dat2=M17"
          "sdio_sd_dat3=L17"
          "sdio_sd_cd=M18"
        ];
      }
    );
  };

  creek-v1-sky130 = {
    ip = river-hdl.mkSoC (
      creek-v1-base
      // {
        target = "sky130:hd";
        pdkRoot = "${sky130-pdk}/${sky130-pdk.pdkPath}";
      }
    );
    # asix.mkTapeout metadata: topCell matches the genip SoC name, and the
    # clock period is derived from the device's target frequency.
    topCell = creek-v1-base.socName;
    clockPeriodNs = 1.0e9 / creek-v1-base.clockFreq;
    pdk = sky130-pdk;
  };

  creek-v1-gf180mcu = {
    ip = river-hdl.mkSoC (
      creek-v1-base
      // {
        target = "gf180mcu:3v3";
        pdkRoot = "${gf180mcu-pdk}/${gf180mcu-pdk.pdkPath}";
      }
    );
    topCell = creek-v1-base.socName;
    clockPeriodNs = 1.0e9 / creek-v1-base.clockFreq;
    pdk = gf180mcu-pdk;
  };

  # iCESugar v1.5 (iCE40UP5K-SG48, 12MHz). The up5k holds only ~128KB on-chip,
  # so the shared 16M-flash/1M-sram base map does not fit. Override it with a
  # single 64KB on-chip data SRAM and drop the external regions.
  stream-v1-ice40 = {
    ip = river-hdl.mkSoC (
      stream-v1-base
      // {
        target = "ice40:up5k:sg48";
        memories = [
          "0x20000000:16M:flash"
          "0x80000000:128K:sram"
        ];
        # No PLIC: this board has no routed interrupt sources and the unused
        # 32-source arbiter costs ~900 cells of the up5k. The CLINT covers the
        # timer. External IRQs can return with a slimmer controller if needed.
        devices = [
          "clint:0x02000000"
          "uart:0x10000000:ns16550a"
        ];
        # Serial boot monitor in the boot ROM (no cache-as-RAM): prints a banner
        # then loads checksummed payloads into the SRAM over the UART.
        bootProgram = "monitor";
        # Board UART (iCELink USB-CDC bridge): FPGA tx=6, rx=4 per the official
        # iCESugar pcf. Pins 14/15 are SPI-flash lines, not the UART.
        pins = [
          "clk=35"
          "uart_tx=uart@tx:6"
          "uart_rx=uart@rx:4"
        ];
      }
    );
  };

  # OrangeCrab r0.2 (LFE5U-25F, csfbga285, 48MHz osc). Pins proven on this
  # board by the NixVegas SoC (clk=A9, uart on feather N17/M18 via an
  # external USB-TTL adapter; the USB-C port is raw, no onboard bridge).
  # Same monitor profile as the iCESugar: rc1-n + 64KB byte-masked EBR SRAM.
  stream-v1-orangecrab = {
    ip = river-hdl.mkSoC (
      stream-v1-base
      // {
        target = "ecp5:lfe5u-25f:CSFBGA285";
        clockFreq = 48000000;
        # The OrangeCrab oscillator is 48MHz (not the 12MHz default): with
        # the default the system PLL multiplies x4 and the whole SoC would
        # run at 192MHz on hardware.
        oscFreq = 48000000;
        # DDR3 (MT41K64M16, 128MB, hardware-verified) sits beside the SRAM
        # boot path; promoting it to main RAM at 0x80000000 is a follow-up.
        # The dram region pulls the board's full sdram_* pad constraint set
        # with it.
        memories = [
          "0x20000000:16M:flash:orangecrab"
          "0x80000000:64K:sram"
          "0x90000000:128M:dram:orangecrab"
        ];
        bootProgram = "monitor";
        pins = [
          "clk=A9"
          "uart_tx=uart@tx:N17"
          "uart_rx=uart@rx:M18"
        ];
      }
    );
  };

  stream-v1-gf180mcu = {
    ip = river-hdl.mkSoC (
      stream-v1-base
      // {
        target = "gf180mcu:3v3";
        pdkRoot = "${gf180mcu-pdk}/${gf180mcu-pdk.pdkPath}";
      }
    );
    topCell = stream-v1-base.socName;
    clockPeriodNs = 1.0e9 / stream-v1-base.clockFreq;
    pdk = gf180mcu-pdk;
  };
}
