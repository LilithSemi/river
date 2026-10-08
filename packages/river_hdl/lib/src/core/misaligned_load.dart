import 'package:rohd/rohd.dart';

/// Serial full-beat reads for one misaligned integer load. Addresses remain
/// virtual: the MMU translates and checks each beat independently. The caller
/// must restrict these reads to explicitly permitted, idempotent physical RAM.
/// Aligned loads retain their original address, size and response convention.
class MisalignedLoad extends Module {
  Logic get readEnable => output('readEnable');
  Logic get readAddress => output('readAddress');
  Logic get restricted => output('restricted');
  Logic get done => output('done');
  Logic get valid => output('valid');
  Logic get data => output('data');
  Logic get accessFault => output('accessFault');
  Logic get faultAddress => output('faultAddress');

  MisalignedLoad(
    Logic clk,
    Logic reset,
    Logic enable,
    Logic address,
    Logic size,
    Logic misaligned,
    Logic readDone,
    Logic readValid,
    Logic readData,
    Logic pageFault, {
    super.name = 'misaligned_load',
  }) {
    final width = address.width;
    if (width != 32 && width != 64) {
      throw ArgumentError('XLEN must be 32 or 64');
    }
    final bytes = width ~/ 8;
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    enable = addInput('enable', enable);
    address = addInput('address', address, width: width);
    size = addInput('size', size, width: 3);
    misaligned = addInput('misaligned', misaligned);
    readDone = addInput('readDone', readDone);
    readValid = addInput('readValid', readValid);
    readData = addInput('readData', readData, width: width);
    pageFault = addInput('pageFault', pageFault);
    addOutput('readEnable');
    addOutput('readAddress', width: width);
    addOutput('restricted');
    addOutput('done');
    addOutput('valid');
    addOutput('data', width: width);
    addOutput('accessFault');
    addOutput('faultAddress', width: width);

    // idle, first request, response gap, second request, completion, drain gap.
    final state = Logic(name: 'state', width: 3);
    final original = Logic(name: 'original', width: width);
    final base = Logic(name: 'base', width: width);
    final offset = Logic(name: 'offset', width: width);
    final split = Logic(name: 'split');
    final first = Logic(name: 'first', width: width);
    final result = Logic(name: 'result', width: width);
    final success = Logic(name: 'success');
    final access = Logic(name: 'access');
    final fault = Logic(name: 'fault', width: width);
    final cancelled = Logic(name: 'cancelled');
    final nextAddress = base + Const(bytes, width: width);
    final bypass = state.eq(0) & ~misaligned;
    final active = state.eq(1) | state.eq(3);
    readEnable <= mux(bypass, enable, active);
    readAddress <= mux(bypass, address, mux(state.eq(3), nextAddress, base));
    restricted <= active;
    done <= mux(bypass, readDone, state.eq(4) & enable & ~cancelled);
    valid <=
        mux(bypass, readValid, state.eq(4) & enable & success & ~cancelled);
    data <= mux(bypass, readData, result);
    accessFault <=
        mux(
          bypass,
          readDone & ~readValid & ~pageFault,
          state.eq(4) & enable & access & ~cancelled,
        );
    faultAddress <= fault;
    final count = Const(1, width: width + 1) << size;
    final end =
        address.zeroExtend(width + 1) + count - Const(1, width: width + 1);
    final off = address & Const(bytes - 1, width: width);

    Sequential(clk, [
      If(
        reset,
        then: [
          state < 0,
          original < 0,
          base < 0,
          offset < 0,
          split < 0,
          first < 0,
          result < 0,
          success < 0,
          access < 0,
          fault < 0,
          cancelled < 0,
        ],
        orElse: [
          If(active & ~enable, then: [cancelled < 1]),
          Case(state, [
            CaseItem(Const(0, width: 3), [
              If(
                enable & misaligned,
                then: [
                  original < address, fault < address,
                  base < (address & ~Const(bytes - 1, width: width)),
                  offset < off, first < 0, result < 0, success < 0,
                  cancelled < 0, access < 0,
                  split < (off.zeroExtend(width + 1) + count).gt(bytes),
                  // Do not silently wrap a second virtual request to address zero.
                  If(
                    end[width] | count.gt(bytes),
                    then: [state < 4, access < 1],
                    orElse: [state < 1],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(1, width: 3), [
              If(
                readDone,
                then: [
                  If(
                    cancelled | ~enable,
                    then: [state < 5],
                    orElse: [
                      If(
                        ~readValid,
                        then: [
                          state < 4,
                          access < ~pageFault,
                          fault < original,
                        ],
                        orElse: [
                          first <
                              (readData >>> (offset * Const(8, width: width))),
                          If(
                            split,
                            then: [state < 2],
                            orElse: [
                              result <
                                  (readData >>>
                                      (offset * Const(8, width: width))),
                              success < 1,
                              state < 4,
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(2, width: 3), [
              If(
                ~enable,
                then: [state < 5],
                orElse: [
                  If(~readDone, then: [state < 3]),
                ],
              ),
            ]),
            CaseItem(Const(3, width: 3), [
              If(
                readDone,
                then: [
                  If(
                    cancelled | ~enable,
                    then: [state < 5],
                    orElse: [
                      state < 4,
                      success < readValid,
                      access < (~readValid & ~pageFault),
                      fault < nextAddress,
                      result <
                          (first |
                              (readData <<
                                  ((Const(bytes, width: width) - offset) *
                                      Const(8, width: width)))),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(4, width: 3), [
              If(~enable, then: [state < 5]),
            ]),
            CaseItem(Const(5, width: 3), [
              If(~readDone, then: [state < 0]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
