import 'package:test/test.dart';

import 'physical_alias_test.dart' as alias;
import 'physical_l1_flush_test.dart' as flush;
import 'physical_l1_pma_test.dart' as pma;
import 'physical_l1_test.dart' as mmu;

void main() {
  for (final dSize in [4096, 8192, 16384]) {
    group('physical D-cache $dSize bytes', () {
      alias.physicalAliasTests(dSize: dSize);
      mmu.physicalL1Tests(dSize: dSize);
      pma.physicalPmaTests(dSize: dSize);
      flush.physicalFlushTests(dSize: dSize);
    });
  }
}
