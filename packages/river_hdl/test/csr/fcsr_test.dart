import 'dart:async';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);
  for (final xlen in [RiscVMxlen.rv32, RiscVMxlen.rv64]) {
    group(xlen.name, () {
      for (final mode in [3, 1, 0]) {
        test(
          'FP aliases in mode $mode',
          () => _check(xlen, (h) async {
            await h.write(0x300, 1 << 13);
            h.mode.inject(mode);
            expect(await h.read(3), 0);
            await h.write(3, 0xa5);
            expect(await h.read(1), 5);
            expect(await h.read(2), 5);
            await h.write(1, 0xff);
            expect(await h.read(3), 0xbf);
            await h.write(2, 0xfa);
            expect(await h.read(3), 0x5f);
            await h.write(3, 0x3e7);
            expect(await h.read(3), 0xe7);
            for (var rm = 0; rm < 8; rm++) {
              await h.write(2, rm);
              expect(await h.read(2), rm);
              expect(await h.read(1), 7);
            }
          }),
        );
      }
      test(
        'FS Off rejects reads and writes without changing state',
        () => _check(xlen, (h) async {
          for (final mode in [3, 1, 0]) {
            h.mode.inject(mode);
            for (final addr in [1, 2, 3]) {
              await h.read(addr, legal: false);
              await h.write(addr, 0xff, legal: false);
            }
          }
          h.mode.inject(3);
          await h.write(0x300, 1 << 13);
          expect(await h.read(3), 0);
          await h.write(3, 0x49);
          await h.write(0x300, 0);
          await h.write(3, 0xff, legal: false);
          await h.write(0x300, 1 << 13);
          expect(await h.read(3), 0x49);
        }),
      );
      test(
        'flags accrue; software writes replace only their field',
        () => _check(xlen, (h) async {
          await h.write(0x300, 1 << 13);
          await h.write(3, 0x61);
          await h.flags(0x10);
          await h.flags(0x04);
          expect(await h.read(3), 0x75);
          await h.write(1, 0);
          expect(await h.read(3), 0x60);
          h.flagsIn.inject(0x1f);
          h.flagsValid.inject(1);
          await h.write(3, 0x42);
          h.flagsValid.inject(0);
          expect(
            await h.read(3),
            0x42,
            reason: 'serialized software write takes precedence',
          );
        }),
      );
      test(
        'FP CSR writes and flag updates set FS/SD; reads do not',
        () => _check(xlen, (h) async {
          await h.write(0x300, 2 << 13);
          await h.read(3);
          expect((await h.read(0x300) >> 13) & 3, 2);
          await h.write(2, 1);
          var status = await h.read(0x300);
          expect((status >> 13) & 3, 3);
          expect((status >> (xlen.size - 1)) & 1, 1);
          await h.write(0x100, 2 << 13);
          expect((await h.read(0x300) >> 13) & 3, 2);
          await h.flags(0);
          expect((await h.read(0x100) >> 13) & 3, 2);
          await h.flags(1);
          expect((await h.read(0x100) >> 13) & 3, 3);
        }),
      );
      test(
        'no F/D means no FP CSRs',
        () => _check(xlen, (h) async {
          await h.write(0x300, 3 << 13);
          for (final addr in [1, 2, 3]) {
            await h.read(addr, legal: false);
            await h.write(addr, 0xff, legal: false);
          }
        }, fp: false),
      );
      if (xlen == RiscVMxlen.rv64) {
        test(
          'H retains its existing unsupported FP CSR behavior',
          () => _check(xlen, (h) async {
            await h.write(0x300, 3 << 13);
            for (final addr in [1, 2, 3]) {
              await h.read(addr, legal: false);
              await h.write(addr, 0xff, legal: false);
            }
          }, hypervisor: true),
        );
      }
    });
  }
}

Future<void> _check(
  RiscVMxlen xlen,
  Future<void> Function(_Fixture) body, {
  bool fp = true,
  bool hypervisor = false,
}) async {
  final h = _Fixture();
  final reset = Logic();
  h.mode.inject(3);
  h.flagsIn.inject(0);
  h.flagsValid.inject(0);
  h.rd = DataPortInterface(xlen.size, 12);
  h.wr = DataPortInterface(xlen.size, 12);
  h.rd.en.inject(0);
  h.rd.addr.inject(0);
  h.wr.en.inject(0);
  h.wr.addr.inject(0);
  h.wr.data.inject(0);
  final csrs = RiscVCsrFile(
    h.clk,
    reset,
    h.mode,
    mxlen: xlen,
    misa: xlen.misa | (fp ? (1 << 5) | (1 << 3) : 0),
    hasSupervisor: true,
    hasUser: true,
    hasHypervisor: hypervisor,
    fpFlagsValid: h.flagsValid,
    fpFlags: h.flagsIn,
    csrRead: h.rd,
    csrWrite: h.wr,
  );
  await csrs.build();
  reset.inject(1);
  Simulator.setMaxSimTime(100000);
  unawaited(Simulator.run());
  try {
    await h.clk.nextNegedge;
    await h.clk.nextNegedge;
    reset.inject(0);
    await h.clk.nextNegedge;
    await body(h);
  } finally {
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }
}

class _Fixture {
  final clk = SimpleClockGenerator(10).clk;
  final mode = Logic(width: 3);
  final flagsIn = Logic(width: 5);
  final flagsValid = Logic();
  late DataPortInterface rd, wr;

  Future<int> read(int addr, {bool legal = true}) async {
    rd.addr.inject(addr);
    rd.en.inject(1);
    await clk.nextNegedge;
    expect(rd.done.value.toBool(), isTrue);
    expect(
      rd.valid.value.toBool(),
      legal,
      reason: 'read CSR 0x${addr.toRadixString(16)}',
    );
    final value = legal ? rd.data.value.toInt() : 0;
    rd.en.inject(0);
    return value;
  }

  Future<void> write(int addr, int value, {bool legal = true}) async {
    wr.addr.inject(addr);
    wr.data.inject(value);
    wr.en.inject(1);
    await clk.nextNegedge;
    expect(wr.done.value.toBool(), isTrue);
    expect(
      wr.valid.value.toBool(),
      legal,
      reason: 'write CSR 0x${addr.toRadixString(16)}',
    );
    wr.en.inject(0);
  }

  Future<void> flags(int value) async {
    flagsIn.inject(value);
    flagsValid.inject(1);
    await clk.nextNegedge;
    flagsValid.inject(0);
  }
}
