/// Enable FP architecturally without relocating existing test code or data.
/// x31 is scratch during boot and restored to its original reset value.
const fpResetVector = 0x1000;

String withFpBoot(String program) {
  const offset = -(fpResetVector + 12);
  const jump =
      (((offset >> 20) & 1) << 31) |
      (((offset >> 1) & 0x3ff) << 21) |
      (((offset >> 11) & 1) << 20) |
      (((offset >> 12) & 0xff) << 12) |
      0x6f;
  final image = StringBuffer('$program\n@${fpResetVector.toRadixString(16)}\n');
  for (final word in [
    0x00002fb7, // lui x31, 2
    0x300f9073, // csrrw x0, mstatus, x31: FS Initial
    0x00000f93, // restore x31
    jump,
  ]) {
    for (var i = 0; i < 4; i++) {
      image.write(
        '${((word >> (8 * i)) & 255).toRadixString(16).padLeft(2, '0')} ',
      );
    }
  }
  return '$image\n';
}
