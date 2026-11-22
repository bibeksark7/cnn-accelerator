"""firmware/common/cnn_sw.c (the software CNN of the speedup measurement, D-044) compiled for the
host and compared with the golden model: every logit and the class equal model/golden.py's on the
quick subset, the saturation subset (conv2 saturates low) and 500 random int8 images (the full
input range, including -128)."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[2]
FW = ROOT / "firmware"
sys.path.insert(0, str(ROOT))
from model import golden  # noqa: E402

HARNESS = r"""
#include <stdio.h>
#include <stdint.h>
#include "cnn_sw.h"
int main(void) {
  int8_t img[CNN_IMG_BYTES];
  int32_t logits[CNN_NUM_LOGITS];
  while (fread(img, 1, sizeof img, stdin) == sizeof img) {
    uint32_t cls = cnn_sw_infer(img, logits);
    for (unsigned i = 0; i < CNN_NUM_LOGITS; i++) printf("%d ", (int)logits[i]);
    printf("%u\n", (unsigned)cls);
  }
  return 0;
}
"""

CC = shutil.which("cc") or shutil.which("gcc")


@pytest.fixture(scope="module")
def host_cnn(tmp_path_factory) -> Path:
    if CC is None:
        pytest.skip("no host C compiler")
    out = tmp_path_factory.mktemp("cnn_sw")
    subprocess.run(
        [sys.executable, str(FW / "tools" / "gen_data.py"), "params", str(out)], check=True
    )
    (out / "harness.c").write_text(HARNESS)
    exe = out / "cnn_sw"
    subprocess.run(
        [CC, "-O2", "-std=c11", "-Wall", "-Wextra", "-Werror", f"-I{FW / 'common'}", f"-I{out}",
         str(FW / "common" / "cnn_sw.c"), str(out / "net_params.c"), str(out / "harness.c"),
         "-o", str(exe)],
        check=True,
    )  # fmt: skip
    return exe


def run(exe: Path, q: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    out = subprocess.run(
        [str(exe)], input=q.astype(np.int8).tobytes(), capture_output=True, check=True
    ).stdout
    rows = np.array([[int(x) for x in line.split()] for line in out.decode().splitlines()])
    return rows[:, :10], rows[:, 10]


@pytest.mark.parametrize("subset", ["quick_subset", "saturation_subset"])
def test_matches_golden_on_subsets(host_cnn: Path, subset: str) -> None:
    with np.load(golden.ARTIFACTS / f"{subset}.npz") as f:
        q, logits, pred = f["q"], f["logits"], f["pred"]
    got_logits, got_pred = run(host_cnn, q)
    np.testing.assert_array_equal(got_logits, logits)
    np.testing.assert_array_equal(got_pred, pred)


def test_matches_golden_on_random_inputs(host_cnn: Path) -> None:
    rng = np.random.default_rng(20261121)
    q = rng.integers(-128, 128, size=(500, 28, 28), dtype=np.int8)
    want = golden.infer(golden.QuantParams.load(), q)
    got_logits, got_pred = run(host_cnn, q)
    np.testing.assert_array_equal(got_logits, want["logits"])
    np.testing.assert_array_equal(got_pred, want["pred"])
