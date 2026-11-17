"""Tests for scripts/check_quartus_compat.py: each rule fires on a minimal bad example and stays
quiet on the accepted form; every committed RTL file passes."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("qc", ROOT / "scripts" / "check_quartus_compat.py")
qc = importlib.util.module_from_spec(_spec)
sys.modules["qc"] = qc  # dataclasses look the defining module up in sys.modules
_spec.loader.exec_module(qc)


def rules(src: str) -> list[str]:
    return [v.rule for v in qc.check_source("t.sv", src)]


GOOD = """
module m #(parameter int N = 4, parameter INIT = "") (input logic clk, output logic [N-1:0] o);
  localparam logic signed [7:0] MINV = -128;   // typed localparam, not -N'(x)
  genvar gi;
  generate
    for (gi = 0; gi < N; gi = gi + 1) begin : g_bit
      if (gi == 0) begin : g_first
        assign o[gi] = 1'b0;
      end else begin : g_rest
        assign o[gi] = 1'b1;
      end
    end
    if (INIT != "") begin : g_init
      initial begin
        $display("if (x) for (y) begin : g_z -8'(1)");  // strings are ignored
      end
    end
  endgenerate
  always_ff @(posedge clk) begin
    for (int s = 0; s < N; s++) begin
      if (s == 1) begin : named_proc_block
      end
    end
  end
  always_comb begin
    if (N > 2) begin end
  end
  function automatic int f(input int x);
    if (x > 0) return 1;
    return 0;
  endfunction
endmodule
"""


def test_good_module_passes():
    assert rules(GOOD) == []


@pytest.mark.parametrize(
    ("src", "rule"),
    [
        ("module m; if (1) begin : g_x end endmodule", "QC1"),
        ("module m; if (1) begin : g_x end endmodule", "QC2"),
        ("module m; genvar i; for (i = 0; i < 2; i = i + 1) begin : g_l end endmodule", "QC2"),
        (
            "module m; generate for (genvar i = 0; i < 2; i++) begin : g_l end endgenerate"
            " endmodule",
            "QC4",
        ),
        ("module m; localparam int A = 5; wire [7:0] w = -A'(3); endmodule", "QC3"),
        ("module m(input clk); logic q; always_ff @(posedge clk) q <= 1; endmodule", "QC5"),
    ],
)
def test_rule_fires(src, rule):
    assert rule in rules(src)


def test_comments_are_ignored():
    assert rules("module m; // if (1) begin : g_x end\n /* for (genvar i */ endmodule") == []


def test_all_rtl_files_pass():
    files = sorted((ROOT / "rtl").rglob("*.sv"))
    assert files
    for f in files:
        assert qc.check_source(str(f), f.read_text()) == [], f
