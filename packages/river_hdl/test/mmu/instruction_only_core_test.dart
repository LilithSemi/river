import 'package:river/river.dart';
import 'package:test/test.dart';

import 'physical_alias_test.dart' as alias;
import 'physical_l1_flush_test.dart' as flush;

void main() {
  const config = HarborL1CacheConfig.instructionOnly(
    HarborL1iCacheConfig(size: 64, ways: 1, lineSize: 16),
  );
  group('instruction-only', () {
    alias.physicalAliasTests(cacheConfig: config, uncachedData: true);
    flush.physicalFlushTests(config: config);
  });
}
