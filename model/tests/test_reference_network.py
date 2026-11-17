"""End-to-end check: golden.infer vs a naive nested-loop implementation of the whole network.

The reference below uses only Python integers and loops. It shares no code with model/golden.py
(no im2col, no NumPy arithmetic, no vectorized requantization), so an error in golden's
vectorization, layouts or broadcasting would show up as a mismatch.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from model import golden

ARTIFACTS = Path(golden.__file__).resolve().parent / "artifacts"
IMAGES = (0, 1, 2)  # quick-subset positions: test images 0-2, digits 7, 2, 1


def naive_conv_requant_relu(act, w, b, m, s):
    """act[y][x][c] (lists), w [C_out, 3, 3, C_in] -> requantized, ReLU'd int8 activations."""
    h, wd, cin = len(act), len(act[0]), len(act[0][0])
    cout = len(b)
    out = [[[0] * cout for _ in range(wd - 2)] for _ in range(h - 2)]
    for oy in range(h - 2):
        for ox in range(wd - 2):
            for co in range(cout):
                acc = 0
                for ky in range(3):
                    for kx in range(3):
                        for ci in range(cin):
                            acc += act[oy + ky][ox + kx][ci] * int(w[co][ky][kx][ci])
                y = acc + int(b[co])
                assert -(2**31) <= y < 2**31
                r = (y * int(m[co]) + (1 << (int(s[co]) - 1))) >> int(s[co])
                r = max(-128, min(127, r))
                out[oy][ox][co] = max(r, 0)
    return out


def naive_maxpool(act):
    h, wd, c = len(act), len(act[0]), len(act[0][0])
    return [
        [
            [
                max(act[2 * y + dy][2 * x + dx][ch] for dy in (0, 1) for dx in (0, 1))
                for ch in range(c)
            ]
            for x in range(wd // 2)
        ]
        for y in range(h // 2)
    ]


def naive_fc(act, w, b):
    flat = [
        act[y][x][c]
        for y in range(len(act))
        for x in range(len(act[0]))
        for c in range(len(act[0][0]))
    ]
    logits = []
    for n in range(len(b)):
        acc = sum(flat[k] * int(w[n][k]) for k in range(len(flat))) + int(b[n])
        assert -(2**31) <= acc < 2**31
        logits.append(acc)
    return logits


def naive_argmax(logits):
    best = 0
    for i in range(1, len(logits)):
        if logits[i] > logits[best]:  # strict: ties keep the lowest index
            best = i
    return best


def naive_network(p: golden.QuantParams, pixels: np.ndarray) -> tuple[list[int], int]:
    img = [[[int(pixels[y][x]) >> 1] for x in range(28)] for y in range(28)]
    a1 = naive_conv_requant_relu(img, p.conv1_w, p.conv1_b, p.conv1_m, p.conv1_s)
    a2 = naive_conv_requant_relu(naive_maxpool(a1), p.conv2_w, p.conv2_b, p.conv2_m, p.conv2_s)
    logits = naive_fc(naive_maxpool(a2), p.fc_w, p.fc_b)
    return logits, naive_argmax(logits)


@pytest.mark.parametrize("pos", IMAGES)
def test_golden_matches_naive_network(pos):
    params = golden.QuantParams.load()
    with np.load(ARTIFACTS / "quick_subset.npz") as f:
        pixels, expected = f["pixels"][pos], f["logits"][pos]
    logits, pred = naive_network(params, pixels)
    out = golden.infer(params, golden.preprocess(pixels))
    assert out["logits"][0].tolist() == logits
    assert int(out["pred"][0]) == pred
    assert expected.tolist() == logits
