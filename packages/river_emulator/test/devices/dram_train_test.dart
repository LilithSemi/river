import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

/// The emulator DRAM model for the new Harbor DDR3 stack's two calibration
/// modes. `train=hw` is a clean array with no control window. `train=runtime`
/// keeps the wb2 knob-ABI register window above the array (mirrors
/// Ddr3Controller._buildWb2Knobs), and the array is correct, per byte lane,
/// only once that lane's IDELAY read tap sits inside its eye.
void main() {
  const arraySize = 0x1000;
  const ctrlSize = Dram.trainCtrlSize; // 0x1000

  // Control-window register offsets (relative to the device base).
  const wlevel = arraySize + 0x00;
  const odelay = arraySize + 0x08;
  const idelay = arraySize + 0x10;
  const bitslip = arraySize + 0x18;
  const ctl = arraySize + 0x20;
  const status = arraySize + 0x28;
  const cap = arraySize + 0x30;
  const setBit = 0x1, applyBit = 0x2;

  int ctlLane(int lane) => (lane & 0xF) << 8;

  Dram makeTrainable({int lanes = 2, List<int>? eyeLo, List<int>? eyeHi}) =>
      Dram(
        const RiverDevice(
          name: 'dram',
          compatible: 'river,dram',
          range: BusAddressRange(0x80000000, arraySize + ctrlSize),
        ),
        trainable: true,
        lanes: lanes,
        eyeLo: eyeLo,
        eyeHi: eyeHi,
      );

  group('train=hw', () {
    test('has no control window and is correct from reset', () async {
      final d = Dram(
        const RiverDevice(
          name: 'dram',
          compatible: 'river,dram',
          range: BusAddressRange(0x80000000, arraySize),
        ),
      );
      final acc = d.memAccessor!;
      await acc.write(0x40, 0x99887766, 4);
      expect(await acc.read(0x40, 4), 0x99887766);
      expect(d.trained, isTrue);
    });

    test('Dram.create with no train option builds a plain array', () {
      final d = Dram.create(
        const RiverDevice(
          name: 'dram',
          compatible: 'river,dram',
          range: BusAddressRange(0x80000000, arraySize),
        ),
        const {},
        RiverSoC(const RiverSoCConfig()),
      ) as Dram;
      expect(d.trainable, isFalse);
    });
  });

  group('train=runtime', () {
    test('Dram.create with train=runtime builds the wb2 window', () {
      final d = Dram.create(
        const RiverDevice(
          name: 'dram',
          compatible: 'river,dram',
          range: BusAddressRange(0x80000000, arraySize + ctrlSize),
        ),
        const {'train': 'runtime'},
        RiverSoC(const RiverSoCConfig()),
      ) as Dram;
      expect(d.trainable, isTrue);
    });

    test(
      'untrained array reads return garbage; the right IDELAY tap fixes it',
      () async {
        final d = makeTrainable(eyeLo: [8, 8], eyeHi: [20, 20]);
        final acc = d.memAccessor!;

        // Write a pattern (writes always land, even untrained).
        await acc.write(0x100, 0xDEADBEEF, 4);

        // Untrained (tap 0, below the eye): read is corrupted.
        expect(await acc.read(0x100, 4), isNot(0xDEADBEEF));

        // Train both lanes: write IDELAY, select each lane, APPLY.
        for (var lane = 0; lane < 2; lane++) {
          await acc.write(idelay, 12, 4);
          await acc.write(ctl, setBit | ctlLane(lane), 4);
          await acc.write(ctl, applyBit | ctlLane(lane), 4);
        }

        expect(await acc.read(0x100, 4), 0xDEADBEEF);
      },
    );

    test('a tap outside the eye corrupts reads again', () async {
      final d = makeTrainable(eyeLo: [8, 8], eyeHi: [20, 20]);
      final acc = d.memAccessor!;
      await acc.write(0x200, 0xCAFEF00D, 4);

      for (var lane = 0; lane < 2; lane++) {
        await acc.write(idelay, 20, 4);
        await acc.write(ctl, setBit | ctlLane(lane), 4);
        await acc.write(ctl, applyBit | ctlLane(lane), 4);
      }
      expect(await acc.read(0x200, 4), 0xCAFEF00D);

      for (var lane = 0; lane < 2; lane++) {
        await acc.write(idelay, 21, 4);
        await acc.write(ctl, setBit | ctlLane(lane), 4);
        await acc.write(ctl, applyBit | ctlLane(lane), 4);
      }
      expect(await acc.read(0x200, 4), isNot(0xCAFEF00D));
    });

    test('each lane trains independently', () async {
      // Lane 0 (even bytes) has eye [8,20]. Lane 1 (odd bytes) has eye
      // [10,14], which excludes the reset tap (0) on both lanes.
      final d = makeTrainable(eyeLo: [8, 10], eyeHi: [20, 14]);
      final acc = d.memAccessor!;
      await acc.write(0x300, 0x11223344, 4);
      expect(await acc.read(0x300, 4), isNot(0x11223344)); // neither trained

      // Only lane 0 trained: lane 1's bytes are still corrupted.
      await acc.write(idelay, 12, 4);
      await acc.write(ctl, setBit | ctlLane(0), 4);
      await acc.write(ctl, applyBit | ctlLane(0), 4);
      expect(await acc.read(0x300, 4), isNot(0x11223344));

      // Train lane 1 too: now the whole word is correct.
      await acc.write(idelay, 12, 4);
      await acc.write(ctl, setBit | ctlLane(1), 4);
      await acc.write(ctl, applyBit | ctlLane(1), 4);
      expect(await acc.read(0x300, 4), 0x11223344);
    });

    test(
      'WLEVEL, ODELAY and BITSLIP round-trip through the control window',
      () async {
        final d = makeTrainable();
        final acc = d.memAccessor!;

        await acc.write(wlevel, 1, 4);
        await acc.write(ctl, setBit | ctlLane(0), 4);
        await acc.write(ctl, applyBit | ctlLane(0), 4);
        expect(await acc.read(wlevel, 4), 1);

        await acc.write(odelay, 9, 4);
        await acc.write(ctl, setBit | ctlLane(0), 4);
        await acc.write(ctl, applyBit | ctlLane(0), 4);
        expect(await acc.read(odelay, 4), 9);

        await acc.write(bitslip, 1, 4);
        await acc.write(ctl, setBit | ctlLane(0), 4);
        await acc.write(ctl, applyBit | ctlLane(0), 4);
        expect(await acc.read(bitslip, 4), 1);
      },
    );

    test('STATUS is always clear and CAP reports lanes and tapMax', () async {
      final d = makeTrainable(lanes: 2);
      final acc = d.memAccessor!;

      expect(await acc.read(status, 4), 0);
      expect(await acc.read(cap, 4) & 0x1, 0); // not active before any APPLY

      await acc.write(idelay, 5, 4);
      await acc.write(ctl, setBit | ctlLane(0), 4);
      await acc.write(ctl, applyBit | ctlLane(0), 4);

      expect(await acc.read(status, 4), 0);
      final capVal = await acc.read(cap, 4);
      expect(capVal & 0x1, 1); // active
      expect((capVal >> 4) & 0xF, 2); // lanes
      expect((capVal >> 8) & 0xFF, 31); // tapMax
    });

    test('a per-lane sweep finds the eye (the Weir FSBL algorithm)', () async {
      final d = makeTrainable(lanes: 1, eyeLo: [8], eyeHi: [20]);
      final acc = d.memAccessor!;
      const probe = 0xA5A5A5A5;
      await acc.write(0x000, probe, 4);

      final good = <int>[];
      for (var tap = 0; tap < 32; tap++) {
        await acc.write(idelay, tap, 4);
        await acc.write(ctl, setBit, 4);
        await acc.write(ctl, applyBit, 4);
        if (await acc.read(0x000, 4) == probe) good.add(tap);
      }

      expect(good.first, 8);
      expect(good.last, 20);
      expect(good.length, 20 - 8 + 1);
    });
  });
}
