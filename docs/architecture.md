# Architecture

How the accelerator works and why it is built this way. `docs/spec.md` is the normative
definition (interfaces, bit widths, formats); this document explains the design behind it.
Design choices and their alternatives are recorded in `docs/decisions.md` (D-0xx below).

## 1. What it computes

A small int8 CNN for MNIST (spec §1): two 3×3 convolutions with ReLU, two 2×2 max pools, a fully
connected layer to 10 int32 logits, and an argmax. Training is in PyTorch; everything the
hardware sees is integers produced offline (`model/quantize.py`): int8 weights, int32 biases, and
per-output-channel requantization constants `M` (16-bit) and `S` (shift), so that

    q8 = clamp((y · M + 2^(S−1)) >>> S, −128, 127),   y = Σ a·w + bias

reproduces the float network's scale. `model/golden.py` implements exactly this arithmetic in
NumPy, and the RTL is checked against it bit for bit (spec §3).

## 2. One engine for convolutions and the FC layer

Every CONV and FC layer is turned into a matrix product `C = A · B` (spec §4):

- **CONV:** `A` is the im2col matrix (one row per output pixel, one column per kernel tap and
  input channel), `B` the reshaped weights, so `M = H_out · W_out`, `K = 9 · C_in`,
  `Ncols = C_out`. conv1 is 676 × 9 × 8, conv2 121 × 72 × 16.
- **FC:** `M = 1`, `K = 400`, `Ncols = 10`.

One GEMM engine runs both, which keeps the datapath small: the network's whole weight set is 953
64-bit words.

### Output-stationary systolic array (D-017)

The engine computes `C` in `N × N` output tiles (`N = 8`) on an output-stationary systolic array:
each processing element owns one output `C[i][j]` and accumulates `A[i][k] · B[k][j]` over the
reduction steps `k`. A-values enter from the left (one row per array row), B-values from the top,
skewed so that row `i` sees its operands `i` cycles late; each element passes them on to its right
and lower neighbours. After the last step the tile is drained row by row.

Why output-stationary for this network: the outputs are int32 and stay in place for all of `K`,
so each result is written exactly once, and both operands are int8 streams. The interface is
defined at the level of a tile (stream steps, then drain; spec §11.2), so a weight-stationary
array can replace it (Milestone 3, D-015).

### Feeding the array: the bandwidth problem (spec §5)

The array takes N A-values and N B-values per cycle.

- **B** is packed offline so that one 64-bit WGT word holds the 8 B-values of one step: one WGT
  read per step.
- **A** is the im2col gather, which is not contiguous in memory. The activation buffers are byte
  wide, so the A loader reads one byte per cycle into N staging banks (one per tile row), then all
  N banks are read in parallel while streaming. Staging costs `N · Kc` cycles for `Kc` cycles of
  streaming.

This is the main reason the array is busy only about 8 % of the time: one inference takes 47,259
cycles, of which 3,869 present a reduction step (`testbench/reports/perf_counters.md`). Milestone
1 is correctness first; double-buffered staging or banked activation buffers are the obvious next
step (D-020).

### Engine structure (D-023, D-026)

Three small FSMs linked by handshakes: the sequencer walks row tiles, column tiles and K chunks
(`K_TILE = 128`; the FC layer needs 4 chunks); the A-load block stages a chunk; the stream block
presents the steps. The drain reads finished rows into a row register and feeds post-processing
one element at a time. Padded rows (the last row tile of conv1 has 4 valid rows) are forced to zero
at the array input, and columns beyond `C_out` are never written.

### Post-processing (spec §3.1, D-019)

Bias add, a 32 × 17-bit signed multiply, rounding and an arithmetic shift, saturation and ReLU,
in a four-stage valid/ready pipeline. The signedness details (zero-extending `M` into a signed
operand, shifting a signed value) are where integer pipelines usually go wrong; they are stated in
the spec and checked by directed tests at every rounding tie and both saturation limits. FC skips
requantization and writes the int32 sum to the LOGIT registers.

## 3. Pool and argmax

The pool unit reuses the address-generator idea: `agen_pool` emits the four source addresses of
each 2×2 window (channel fastest), and a running signed maximum writes one byte per window. The
argmax unit reads the 10 logits one per cycle and keeps the first maximum (strict `>`), which
matches NumPy's tie rule (D-028).

## 4. Control: descriptors and ownership

The network is data, not hardware: a table of 4-word layer descriptors (spec §8) gives each
layer's op, source and destination buffer, base addresses, shape and weight/parameter bases. The
layer sequencer (D-031) reads a descriptor into registers, checks it (spec §9: illegal
combinations such as a CONV writing the image buffer stop the run with `ERROR`), gives the buffer
ports to the unit that runs it, starts the unit and waits for its done pulse. About 7 cycles per
layer are sequencer overhead (43 per inference).

**Buffer ownership.** Every buffer has one read and one write port, and a layer never reads and
writes the same buffer, so a one-hot owner vector per buffer is enough: the memory port while
idle, otherwise the unit named by the current descriptor. Requests from a non-owner never reach a
buffer, and assertions check that ownership only changes while every unit is idle.

**Ping-pong.** Layers alternate between ACT0 and ACT1; the input images live in their own buffer
(16 images), so images run back to back by changing only `IMG_SEL`.

## 5. Host interface

A small CSR bus (ID, CONFIG, CTRL, STATUS, IMG_SEL, RESULT, performance counters, per-layer cycle
counts, logits, the descriptor table) and a memory port that loads or reads back any buffer while
idle (spec §10). Both use a valid/ready request with a hold rule (spec §10.1, §10.3), asserted
at the top level. Performance counters register their inputs before the saturating adds so they
stay off the critical path (D-024).

## 6. FPGA demo (spec §12, D-035)

- `fpga_core`: `accel_top` with the weights, parameters, descriptors and 16 test images
  preloaded from init files, a demo controller that turns a button press into two CSR writes
  (IMG_SEL, START), and a register stage on each host path.
- `de10lite_top`: the DE10-Lite pins, a power-on reset OR'd with KEY[1], 2-FF synchronizers on every
  switch and key (6 chains; the Timing Analyzer's worst-case MTBF is over 10^9 years,
  `fpga/de10lite/reports/mtbf.rpt`), a debounced start button, and the displays (predicted digit,
  true label, cycle count).

The full design uses 8,322 logic elements (17 %), 68 of the 288 9-bit multipliers and 20 % of the
memory bits of the MAX 10, and closes timing at 50 MHz in all three timing corners: worst setup
slack +4.813 ns (slow 85 °C; Fmax 65.85 MHz), worst hold slack +0.095 ns (fast corner)
(`fpga/de10lite/reports/timing_corners.rpt`). The critical path is the post-processing
round-and-shift.

## 7. How correctness is established

- **Golden model** (`model/golden.py`): every primitive checked against a naive reference;
  integer accuracy 0.9865 against 0.9867 for float on the 10,000 test images
  (`model/reports/quantize.json`).
- **Unit tests** for every block against Python models, on Icarus and Verilator, with
  constrained-random stimulus and fixed seeds.
- **System tests:** the quick subset (50 images) and the 4 images that saturate run through
  `accel_top` with every assertion bound; every logit must match. The whole MNIST test set
  (10,000 images) matches bit for bit (`testbench/reports/full_run.md`).
- **Assertions** on every handshake, ownership, legal FSM states; **formal proofs** of the MAC
  cell, argmax and the post-processing pipeline (`testbench/formal/`).
- **Coverage** sampled from the design (`testbench/reports/coverage.md`) and **mutation testing**
  (`testbench/reports/mutation.md`): every injected bug is caught.
