"""Per-layer saturation counts of the integer network on the MNIST test set.

For each requantized layer (conv1, conv2), over every output element of every image: how many
requantized values r = (y * M + 2^(S-1)) >>> S fall above 127 or below -128 (and are clamped by
the int8 saturation), and how many negative values ReLU sets to 0. The images run in chunks
through the same functions as model/golden.py.

Usage: python -m model.saturation [--images N]   (needs the MNIST cache in data/)
Writes model/reports/saturation.json.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from model import data, golden

REPORT = Path(__file__).resolve().parent / "reports" / "saturation.json"


def layer_counts(act: np.ndarray, w, b, m, s) -> tuple[dict[str, int], np.ndarray]:
    """Counts for one conv layer and its int8 output (with ReLU), as golden.conv_layer."""
    bsz, h, wd, _ = act.shape
    y = golden.gemm_bias(golden.im2col(act), golden.conv_weights_as_b(w), b)
    r = golden.requantize_unclamped(y, m, s)
    q = golden.sat8(r)
    sat = ((r > golden.INT8_MAX) | (r < golden.INT8_MIN)).reshape(bsz, -1).any(axis=1)
    counts = {
        "outputs": int(r.size),
        "above_127": int((r > golden.INT8_MAX).sum()),
        "below_minus_128": int((r < golden.INT8_MIN).sum()),
        "relu_zeroed": int((q < 0).sum()),
        "images_with_saturation": [int(i) for i in np.flatnonzero(sat)],
    }
    out = golden.relu(q).astype(np.int8).reshape(bsz, h - 2, wd - 2, w.shape[0])
    return counts, out


def saturation(params: golden.QuantParams, q_images: np.ndarray, chunk: int = 500) -> dict:
    keys = ("outputs", "above_127", "below_minus_128", "relu_zeroed")
    total = {name: {**dict.fromkeys(keys, 0), "images_with_saturation": []}
             for name in ("conv1", "conv2")}  # fmt: skip
    for i in range(0, len(q_images), chunk):
        x = np.asarray(q_images[i : i + chunk], dtype=np.int8)[..., None]
        c1, a1 = layer_counts(x, params.conv1_w, params.conv1_b, params.conv1_m, params.conv1_s)
        p1 = golden.maxpool2(a1)
        c2, _ = layer_counts(p1, params.conv2_w, params.conv2_b, params.conv2_m, params.conv2_s)
        for name, c in (("conv1", c1), ("conv2", c2)):
            for k in keys:
                total[name][k] += c[k]
            total[name]["images_with_saturation"] += [i + j for j in c["images_with_saturation"]]
    return total


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--images", type=int, default=10000)
    args = ap.parse_args()
    mnist = data.load_mnist()
    q = data.to_hw_input(mnist["test_x"][: args.images])
    params = golden.QuantParams.load()
    layers = saturation(params, q)
    report = {"script": "model/saturation.py", "images": len(q), "layers": layers}
    REPORT.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
