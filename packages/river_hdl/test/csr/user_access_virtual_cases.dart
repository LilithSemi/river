import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'user_access_cases.dart';

// This is a compatibility boundary, NOT a claim of H-mode conformance. VU CSR
// access was rejected before this PR and must remain so until hcounteren,
// shared supervisor CSRs, time virtualization and cause-22 selection are fixed
// together. In particular, the current illegal trap is intentionally preserved
// even when a conforming implementation would permit the access or use cause 22.
void runVirtualBoundaryTests(bool microcoded) {
  tearDown(Simulator.reset);
  final engine = microcoded ? 'microcoded' : 'static';

  test('$engine H-enabled ordinary U-mode can read time', () async {
    await runCase(
      microcoded,
      RiscVMxlen.rv64,
      [csr(0xc01, 0, 2, 20)],
      {Register.x20: 0x12345678},
      hypervisor: true,
      hc: 0, // hcounteren must not gate V=0.
    );
  });

  for (final hc in [0, 2]) {
    test('$engine retains VU time rejection with hcounteren=$hc', () async {
      await runCase(
        microcoded,
        RiscVMxlen.rv64,
        [csr(0xc01, 0, 2, 20)],
        {Register.x20: 0x77},
        hypervisor: true,
        virtual: true,
        hc: hc,
        illegalIndex: 0,
      );
    });
  }

  test('$engine retains VU write-only CSR rejection', () async {
    await runCase(
      microcoded,
      RiscVMxlen.rv64,
      [csr(0x040, 15, 1, 0)], // CSRRW rd=x0 to an otherwise writable user CSR.
      {Register.x20: 0x77},
      hypervisor: true,
      virtual: true,
      hc: 2,
      illegalIndex: 0,
    );
  });
}
