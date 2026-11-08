import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

import '../../constants.dart';

void main() {
  cpuTests('Zicsr extension', (config) {
    late Sram sram;
    late RiverCore core;
    late int pc;

    setUp(() {
      sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0, 0xFFFF),
          clockFrequency: (config.clock.rate as HarborFixedClockRate).frequency,
        ),
      );

      core = RiverCore(config, memDevices: Map.fromEntries([sram.mem!]));
      pc = config.resetVector;
    });

    int read(CsrAddress csr) => core.csrs.read(csr.address, core);
    void write(CsrAddress csr, int v) => core.csrs.write(csr.address, v, core);

    test("csrrw: atomic swap (rd=old, CSR=new)", () async {
      write(CsrAddress.mscratch, 0xAAAA);
      core.xregs[Register.x5] = 0x1234;

      final csrrw = 0x34029373;
      final newPc = await core.cycle(pc, csrrw);

      expect(core.xregs[Register.x6], 0xAAAA);
      expect(read(CsrAddress.mscratch), 0x1234);
      expect(newPc, pc + 4);
    });

    test("csrrw with rd=x0 still writes CSR but suppresses rd write", () {
      write(CsrAddress.mscratch, 0x1111);
      core.xregs[Register.x5] = 0x2222;

      final csrrw = 0x34029073;

      core.cycle(pc, csrrw);

      expect(read(CsrAddress.mscratch), 0x2222);
      expect(core.xregs[Register.x0] ?? 0, 0);
    });

    test("csrrs: rd=old, CSR |= rs1", () {
      write(CsrAddress.mscratch, 0x100);
      core.xregs[Register.x5] = 0x0F;

      final csrrs = 0x3402A373;

      core.cycle(pc, csrrs);

      expect(core.xregs[Register.x6], 0x100);
      expect(read(CsrAddress.mscratch), 0x10F);
    });

    test("csrrs with rs1=x0 only reads CSR", () {
      write(CsrAddress.mstatus, 0xABCDE);

      final csrrs = 0x3000A073;

      core.cycle(pc, csrrs);

      expect(read(CsrAddress.mstatus), 0xABCDE);
    });

    test("csrrc: CSR &= ~rs1", () {
      write(CsrAddress.mstatus, 0xFF);
      core.xregs[Register.x5] = 0x0F;

      final csrrc = 0x3002B373;

      core.cycle(pc, csrrc);

      expect(core.xregs[Register.x6], 0xFF);
      expect(read(CsrAddress.mstatus), 0xF0);
    });

    test("csrrwi: CSR = imm, rd = old CSR", () {
      write(CsrAddress.mscratch, 0x7777);

      final csrrwi = 0x3402D373;

      core.cycle(pc, csrrwi);

      expect(core.xregs[Register.x6], 0x7777);
      expect(read(CsrAddress.mscratch), 5);
    });

    test("csrrsi: CSR |= imm", () {
      write(CsrAddress.mscratch, 0x10);

      final csrrsi = 0x3401E073;

      core.cycle(pc, csrrsi);

      expect(read(CsrAddress.mscratch), 0x13);
    });

    test("csrrci: CSR &= ~imm", () {
      write(CsrAddress.mscratch, 0xF);

      final csrrci = 0x3401F073;

      core.cycle(pc, csrrci);

      expect(read(CsrAddress.mscratch), 0xC);
    });

    test("Accessing an invalid CSR causes illegal instruction", () {
      const bogusCsr = 0xFFF;

      final instr = (bogusCsr << 20) | (2 << 15) | (1 << 7) | 0x1073;

      expect(() => core.cycle(pc, instr), throwsA(isA<TrapException>()));
    });

    test("User-mode attempting to write mstatus traps", () {
      core.mode = PrivilegeMode.user;

      final instr =
          (CsrAddress.mstatus.address << 20) | (2 << 15) | (1 << 7) | 0x1073;

      expect(() => core.cycle(pc, instr), throwsA(isA<TrapException>()));
    });

    test("Writing to read-only CSR (misa) traps", () {
      final instr =
          (CsrAddress.misa.address << 20) | (2 << 15) | (1 << 7) | 0x1073;
      expect(() => core.cycle(pc, instr), throwsA(isA<TrapException>()));
    });

    test("rpipelinectl resets to 0", () {
      expect(read(CsrAddress.rpipelinectl), 0);
    });

    test("rpipelinectl is WARL: only bits [3:0] are writable", () {
      write(CsrAddress.rpipelinectl, 0xFFFF);
      expect(read(CsrAddress.rpipelinectl), 0xF);
      write(CsrAddress.rpipelinectl, 0x5);
      expect(read(CsrAddress.rpipelinectl), 0x5);
    });

    test("rpipelinectl SSBD bit round-trips via csrrw", () async {
      // csrrw x6, rpipelinectl, x5 with x5 = 1 (SSBD set)
      core.xregs[Register.x5] = 0x1;
      final csrrw =
          (CsrAddress.rpipelinectl.address << 20) |
          (5 << 15) |
          (6 << 7) |
          0x1073;
      await core.cycle(pc, csrrw);
      expect(read(CsrAddress.rpipelinectl) & 0x1, 0x1);
    });

    test("User-mode writing rpipelinectl traps", () {
      core.mode = PrivilegeMode.user;
      final instr =
          (CsrAddress.rpipelinectl.address << 20) |
          (2 << 15) |
          (1 << 7) |
          0x1073;
      expect(() => core.cycle(pc, instr), throwsA(isA<TrapException>()));
    });

    test("rpipelinecap reads the config feature bitmap", () {
      expect(read(CsrAddress.rpipelinecap), config.rpipelineCap);
    });

    test("rpipelinecap read via csrrs instruction does not trap", () async {
      // csrrs x3, rpipelinecap, x0 (rs1=x0 -> pure read, no write attempt)
      final instr =
          (CsrAddress.rpipelinecap.address << 20) |
          (0 << 15) |
          (2 << 12) |
          (3 << 7) |
          0x73;
      final newPc = await core.cycle(pc, instr);
      expect(core.xregs[Register.x3], config.rpipelineCap);
      expect(newPc, pc + 4);
    });

    test("rpipelinecap is read-only: writing traps", () {
      // Write a value distinct from the cap so the emulator's no-op-write
      // skip (core.dart) doesn't elide the write before the RO trap fires.
      core.xregs[Register.x1] = 0xFF;
      // csrrw x2, rpipelinecap, x1
      final instr =
          (CsrAddress.rpipelinecap.address << 20) |
          (1 << 15) |
          (2 << 7) |
          0x1073;
      expect(() => core.cycle(pc, instr), throwsA(isA<TrapException>()));
    });
  }, condition: (config) => config.extensions.any((e) => e.name == 'Zicsr'));
}
