import 'package:river/river.dart';

import '../cache.dart';
import 'csr_plugin.dart';
import 'mmu_plugin.dart';

class CachePlugin extends FiberPlugin {
  final RiverCoreConfig config;

  Cache? l1i;
  Cache? l1d;

  @override
  String get name => 'cache';

  @override
  Set<Type> get dependencies => {MmuPlugin, CsrPlugin};

  CachePlugin(this.config);

  void bind(MmuPlugin mmuPlugin, CsrPlugin csrPlugin) {
    final mmu = mmuPlugin.mmu;

    l1i = config.l1cache?.i != null
        ? Cache(
            config.l1cache!.i!,
            fill: (addr, size) async {
              return await mmu.readBlock(addr, size, pageTranslate: false);
            },
            writeback: (_, _, _) async {},
          )
        : null;

    l1d = config.l1cache?.d != null
        ? Cache(
            config.l1cache!.d!,
            fill: (addr, size) async {
              return await mmu.readBlock(addr, size, pageTranslate: false);
            },
            writeback: (addr, value, size) async {
              await mmu.write(addr, value, size, pageTranslate: false);
            },
          )
        : null;
  }

  void reset() {
    l1i?.reset();
    l1d?.reset();
  }

  @override
  void init() {
    during.build(() async {
      bind(host.apply<MmuPlugin>(), host.apply<CsrPlugin>());
    });
  }

  @override
  Map<String, dynamic> toJson() => {'name': name};
}
