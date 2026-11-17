# Bug log

Format: **symptom → how found → root cause → fix → regression test added.**
Every real bug found during the project is logged here, newest at the bottom.

---

## BUG-001 — Counter RTL does not compile in any tool (Phase 0)

- **Symptom.** `iverilog -g2012` stopped with `syntax error … Missing closing quote for string`;
  Verilator and Yosys reported `syntax error, unexpected STRING` at line 2.
- **How found.** First parse of `rtl/counter.sv` with all three tools while converting the counter
  test to the pytest runner flow.
- **Root cause.** A Python-style `"""…"""` docstring had been placed inside the module body.
  SystemVerilog has no docstrings; the quotes are read as string literals, and string literals
  may not span lines.
- **Fix.** Replaced it with a `//` header comment (purpose, ports, latency, per the coding rules);
  sized the increment constant (`8'd1`) so the file is also `verilator --lint-only -Wall` clean.
- **Regression test.** `scripts/lint.sh` (Verilator `-Wall`, Icarus, Yosys on every RTL file) now
  runs in CI on every push, and `testbench/unit/test_counter.py` runs the counter on both simulators.

## Phase 1 — model and golden model

No defects found. The golden model was checked against independent references (Python big-int
requantization, nested-loop convolution, pack/unpack round-trips) in `model/tests/test_golden.py`.
