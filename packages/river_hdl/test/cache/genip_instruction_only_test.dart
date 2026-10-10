import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

import '../mmu/instruction_only_stage_test.dart' as stage;

final clock = HarborClockConfig(
  name: 'sys',
  rate: HarborFixedClockRate(48000000),
);

RiverGenIpConfig config(
  String model, {
  bool enabled = false,
  List<Device>? devices,
}) => RiverGenIpConfig(
  name: 'cache_selection',
  cores: [model],
  instructionOnlyCache: enabled,
  devices:
      devices ??
      [
        Device.parse('sram:0x10000:64K'),
        Device.parse('uart:0x10000000'),
        Device.parse('flash:0x20000000:1M'),
      ],
);

void main() {
  for (final model in ['rc1-n', 'rc1-mi', 'rc1-s', 'rc1-f', 'rc1-m']) {
    test('$model default cache configuration unchanged', () {
      final core = config(model).buildCoreConfig(clock, model);
      if (model == 'rc1-n' || model == 'rc1-mi') {
        expect(core.l1cache, isNull);
      } else {
        expect(core.l1cache!.i!.size, 64);
        expect(core.l1cache!.d!.size, 256);
        expect(core.l1cache!.i!.lineSize, 8);
      }
      expect(core.mmu.pma.regions, isEmpty);
    });
  }
  for (final model in ['rc1-n', 'rc1-mi', 'rc1-s', 'rc1-f']) {
    test('$model explicitly selects instruction-only cache', () {
      final core = config(model, enabled: true).buildCoreConfig(clock, model);
      expect(core.l1cache!.i!.size, 64);
      expect(core.l1cache!.i!.lineSize, 8);
      expect(core.l1cache!.d, isNull);
      if (core.mmu.hasPaging) {
        final region = core.mmu.pma.regions.single;
        expect(region.start, 0x10000);
        expect(region.size, 0x10000);
        expect(region.accessWidths, [8]);
        expect(region.misalignedSupport, isFalse);
        expect(region.atomicSupport, isFalse);
      } else {
        expect(core.mmu.pma.regions, isEmpty);
      }
    });
  }
  test('reject unsupported OoO profile', () {
    expect(
      () => config('rc1-m', enabled: true).buildCoreConfig(clock, 'rc1-m'),
      throwsArgumentError,
    );
  });
  test('reject RAM overlapping MMIO', () {
    expect(
      () => config(
        'rc1-s',
        enabled: true,
        devices: [
          Device.parse('sram:0x10000:64K'),
          Device.parse('uart:0x18000'),
        ],
      ).buildCoreConfig(clock, 'rc1-s'),
      throwsArgumentError,
    );
  });
  test('reject mixed-XLEN instruction-only SoC', () {
    expect(
      () => RiverGenIpConfig(
        name: 'mixed',
        cores: ['rc1-s', 'rc1-mi'],
        instructionOnlyCache: true,
      ).buildCoreConfig(clock, 'rc1-s'),
      throwsArgumentError,
    );
  });
  group('genip-generated physical configuration', () {
    final core = config('rc1-s', enabled: true).buildCoreConfig(clock, 'rc1-s');
    stage.instructionOnlyStageTests(
      config: core.l1cache,
      pma: core.mmu.pma,
      widths: const [64],
    );
  });
}
