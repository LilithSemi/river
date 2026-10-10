import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

class _Memory extends DeviceAccessor {
  final bytes = <int, int>{};
  int reads = 0, writes = 0;

  void putWord(int address, int value) {
    for (var i = 0; i < 4; i++) {
      bytes[address + i] = (value >> (8 * i)) & 255;
    }
  }

  @override
  Future<int> read(int addr, int width) async {
    reads++;
    var value = 0;
    for (var i = 0; i < width; i++) {
      value |= (bytes[addr + i] ?? 0) << (8 * i);
    }
    return value;
  }

  @override
  Future<void> write(int addr, int value, int width) async {
    writes++;
    for (var i = 0; i < width; i++) {
      bytes[addr + i] = (value >> (8 * i)) & 255;
    }
  }
}

void main() {
  test(
    'emulator instruction-only cache retains fetches but not RAM data',
    () async {
      final memory = _Memory()
        ..putWord(0, 0x13)
        ..putWord(0x100, 0x1111);
      final core = RiverCore(
        RiverCoreConfigV1.micro(
          mmu: HarborMmuConfig(
            mxlen: RiscVMxlen.rv32,
            pagingModes: const [RiscVPagingMode.bare],
            tlbLevels: const [],
            pmp: HarborPmpConfig.none,
          ),
          interrupts: [],
          clock: const HarborClockConfig(
            name: 'test',
            rate: HarborFixedClockRate(100000000),
          ),
          l1cache: const HarborL1CacheConfig.instructionOnly(
            HarborL1iCacheConfig(size: 64, ways: 1, lineSize: 16),
          ),
        ),
        memDevices: {const BusAddressRange(0, 4096): memory},
      );
      core.reset();
      expect(core.l1i, isNotNull);
      expect(core.l1d, isNull);
      expect(await core.fetch(0), 0x13);
      final coldReads = memory.reads;
      memory.putWord(0, 0x00100093);
      expect(await core.fetch(0), 0x13);
      expect(memory.reads, coldReads);
      expect(await core.read(0x100, 4), 0x1111);
      memory.putWord(0x100, 0x2222);
      expect(await core.read(0x100, 4), 0x2222);
      expect(memory.reads, coldReads + 2);
      await core.write(0x104, 0x3333, 4);
      expect(memory.writes, 1);
      expect(await core.read(0x104, 4), 0x3333);
      core.reset();
      expect(await core.fetch(0), 0x00100093);
    },
  );
}
