import 'dart:async';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() => physicalL1Tests();

void physicalL1Tests({int dSize = 128}) {
  tearDown(Simulator.reset);
  for (final lineSize in [16, 64]) {
    test(
      'physical L1 line=$lineSize checks permissions, aliases, lanes and walker writes',
      () async {
        final clk = SimpleClockGenerator(20).clk;
        final reset = Logic()..inject(1);
        final en = Logic()..inject(0);
        final addr = Logic(width: 64)..inject(0);
        final we = Logic()..inject(0);
        final data = Logic(width: 64)..inject(0);
        final size = Logic(width: 3)..inject(3);
        final priv = Logic(width: 3)..inject(1);
        final sum = Logic()..inject(0);
        final mxr = Logic()..inject(0);
        final fetchEn = Logic()..inject(0);
        final fetchAddr = Logic(width: 64)..inject(0);
        final busError = Logic()..inject(0);
        final flush = Logic()..inject(0);
        final ack = Logic()..inject(0);
        final miso = Logic(width: 64)..inject(0);
        final mmu = RiverMmu(
          clk,
          reset,
          fetchEn,
          fetchAddr,
          en,
          addr,
          we,
          data,
          size,
          ack,
          miso,
          mmuConfig: HarborMmuConfig(
            mxlen: RiscVMxlen.rv64,
            pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
            tlbLevels: const [],
            pmp: HarborPmpConfig.none,
            hasSupervisorUserMemory: true,
            hasMakeExecutableReadable: true,
            pma: const HarborPmaConfig(
              regions: [HarborPmaRegion.memory(start: 0x10000, size: 0x30000)],
            ),
          ),
          busConfig: WishboneConfig(
            addressWidth: 64,
            dataWidth: 64,
            selWidth: 8,
          ),
          satpMode: Const(8, width: 4),
          satpRoot: Const(0x10, width: 64),
          privMode: priv,
          sum: sum,
          mxr: mxr,
          wbErr: busError,
          translateFetch: true,
          tlbFlush: flush,
          cacheFlush: flush,
          physicalL1: HarborL1CacheConfig.split(
            iSize: 128,
            dSize: dSize,
            ways: 1,
            lineSize: lineSize,
          ),
        );
        await mmu.build();
        final memory = <int, BigInt>{
          0x10000: BigInt.from(0x4401),
          0x11000: BigInt.from(0x4801),
          0x12100: BigInt.from(0xc0cf), // VA 0x20000 -> PA 0x30000 RWXAD
          0x12108: BigInt.from(0xc0cf), // alias at 0x21000
          0x30000: BigInt.parse('8877665544332211', radix: 16),
          0x31000: BigInt.from(0xabcdef),
          0x31040: BigInt.from(0xabcdef),
        };
        var reads = 0;
        int? failingAddress;
        final subscription = clk.negedge.listen((_) {
          ack.inject(0);
          busError.inject(0);
          if (reset.value.toBool()) return;
          if (mmu.wbCyc.value.toBool() && mmu.wbStb.value.toBool()) {
            final a = mmu.wbAdr.value.toInt();
            if (a == failingAddress) {
              busError.inject(1);
              return;
            }
            if (mmu.wbWe.value.toBool()) {
              final lanes = mmu.wbSel.value.toInt();
              var mask = BigInt.zero;
              for (var i = 0; i < 8; i++) {
                if ((lanes & (1 << i)) != 0) {
                  mask |= BigInt.from(255) << (i * 8);
                }
              }
              memory[a] =
                  ((memory[a] ?? BigInt.zero) & ~mask) |
                  (mmu.wbDatMosi.value.toBigInt() & mask);
            } else {
              if (a >= 0x30000) reads++;
            }
            miso.inject(memory[a] ?? BigInt.zero);
            ack.inject(1);
          }
        });
        Simulator.setMaxSimTime(500000);
        unawaited(Simulator.run());
        Future<void> tick() async {
          await clk.nextPosedge;
          await clk.nextNegedge;
        }

        Future<BigInt?> access(
          int a, {
          bool store = false,
          int value = 0,
          int bytesLog = 3,
        }) async {
          addr.inject(a);
          we.inject(store);
          data.inject(value);
          size.inject(bytesLog);
          en.inject(1);
          for (var n = 0; n < 500; n++) {
            await tick();
            if (mmu.dportDone.value.toBool()) {
              final ok = mmu.dportValid.value.toBool();
              final result = mmu.dportRdata.value.toBigInt();
              if (!ok) {
                expect(mmu.dportFault.value.toBool(), failingAddress == null);
              }
              en.inject(0);
              await tick();
              await tick();
              return ok ? result : null;
            }
          }
          fail('timeout accessing ${a.toRadixString(16)}');
        }

        Future<void> fence() async {
          flush.inject(1);
          await tick();
          flush.inject(0);
          await tick();
        }

        Future<BigInt?> fetchWord(int a) async {
          fetchAddr.inject(a);
          fetchEn.inject(1);
          for (var n = 0; n < 500; n++) {
            await tick();
            if (mmu.ifetchDone.value.toBool()) {
              final result = mmu.ifetchValid.value.toBool()
                  ? mmu.ifetchRdata.value.toBigInt()
                  : null;
              if (result == null) {
                expect(mmu.ifetchFault.value.toBool(), failingAddress == null);
              }
              fetchEn.inject(0);
              await tick();
              await tick();
              return result;
            }
          }
          fail('fetch timeout');
        }

        try {
          await tick();
          reset.inject(0);
          await tick();
          expect(await access(0x20000), memory[0x30000]);
          final coldReads = reads;
          expect(coldReads, lineSize ~/ 8);
          expect(await access(0x21000), memory[0x30000]);
          expect(
            reads,
            coldReads,
            reason: 'VA alias should hit the same PA line',
          );
          expect(
            (await access(0x20005, bytesLog: 0))! & BigInt.from(255),
            BigInt.from(0x66),
          );
          // Warm physical data must not bypass the privilege check.
          priv.inject(0);
          expect(await access(0x20000), isNull);
          priv.inject(1);
          await access(0x20005, store: true, value: 0xab, bytesLog: 0);
          expect(
            (memory[0x30000]! >> 40) & BigInt.from(255),
            BigInt.from(0xab),
          );
          expect(
            (await access(0x21005, bytesLog: 0))! & BigInt.from(255),
            BigInt.from(0xab),
          );
          // Exercise every naturally aligned byte/halfword/word/doubleword lane.
          for (var log = 0; log <= 3; log++) {
            final bytes = 1 << log;
            final mask = (BigInt.one << (8 * bytes)) - BigInt.one;
            final value = (BigInt.parse('123456789abcdef', radix: 16) & mask)
                .toInt();
            for (var offset = 0; offset < 8; offset += bytes) {
              await access(
                0x20000 + offset,
                store: true,
                value: value,
                bytesLog: log,
              );
              expect(
                (await access(0x21000 + offset, bytesLog: log))! & mask,
                BigInt.from(value),
              );
            }
          }
          // Remap with SFENCE: physical tags must not return the previous PA.
          memory[0x12100] = BigInt.from(0xc4cf);
          await fence();
          expect(await access(0x20000), BigInt.from(0xabcdef));
          // Permission reduction with a warmed data line.
          memory[0x12100] = BigInt.from(0xc4d9); // user execute-only, AD
          await fence();
          expect(await access(0x20000), isNull);
          sum.inject(1);
          mxr.inject(1);
          expect(await access(0x20000), BigInt.from(0xabcdef));
          mxr.inject(0);
          expect(
            await access(0x20000),
            isNull,
            reason: 'MXR must be checked on a warm line',
          );
          mxr.inject(1);
          sum.inject(0);
          expect(
            await access(0x20000),
            isNull,
            reason: 'SUM must be checked on a warm line',
          );
          // Executable supervisor mapping: warm I-cache then deny U-mode access.
          memory[0x12100] = BigInt.from(0xc4cf);
          await fence();
          expect(await fetchWord(0x20000), BigInt.from(0xabcdef));
          memory[0x31000] = BigInt.from(0x10203);
          await fence();
          expect(
            await fetchWord(0x20000),
            BigInt.from(0x10203),
            reason: 'instruction-cache flush observes modified code',
          );
          memory[0x31000] = BigInt.from(0xabcdef);
          await fence();
          expect(await fetchWord(0x20000), BigInt.from(0xabcdef));
          priv.inject(0);
          expect(await fetchWord(0x20000), isNull);
          priv.inject(1);
          // Refill error on a later beat must not produce a successful fetch.
          memory[0x12100] = BigInt.from(0xc8cf); // PA 0x32000
          failingAddress = 0x32008;
          await fence();
          expect(await fetchWord(0x20000), isNull);
          failingAddress = null;
          // Change PA after the fault and verify the I-cache recovers.
          memory[0x12100] = BigInt.from(0xc4cf);
          await fence();
          expect(await fetchWord(0x20000), BigInt.from(0xabcdef));
          // Cache a PTE as ordinary M-mode data. A walker A-bit write must
          // invalidate that cached copy even though walker traffic bypasses L1.
          memory[0x12100] = BigInt.from(0xc40f);
          await fence();
          priv.inject(3);
          expect(await access(0x12100), BigInt.from(0xc40f));
          priv.inject(1);
          // Use a different cache index from the PTE. Otherwise data allocation
          // would evict the stale PTE even if walker-write invalidation were broken.
          expect(await access(0x20040), BigInt.from(0xabcdef));
          priv.inject(3);
          expect(await access(0x12100), BigInt.from(0xc44f));
        } finally {
          await subscription.cancel();
          await Simulator.endSimulation();
          await Simulator.simulationEnded;
        }
      },
    );
  }
}
