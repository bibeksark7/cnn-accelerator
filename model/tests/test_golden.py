"""Golden model and artifact tests (NumPy only; run in CI).

Each arithmetic primitive is checked against an independent, deliberately naive reference
(Python integers and nested loops), and the committed artifacts are checked for consistency.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from model import golden, hwmap, net

ARTIFACTS = Path(golden.__file__).resolve().parent / "artifacts"
REPORTS = Path(golden.__file__).resolve().parent / "reports"
SEED = 20261117


@pytest.fixture(scope="module")
def params() -> golden.QuantParams:
    return golden.QuantParams.load()


@pytest.fixture(scope="module")
def quick() -> dict[str, np.ndarray]:
    with np.load(ARTIFACTS / "quick_subset.npz") as f:
        return {k: f[k] for k in f.files}


# ----------------------------------------------------------------------------- references


def ref_requant(y: int, m: int, s: int, relu_en: bool = False) -> int:
    """Python big-int reference: sat8(floor((y*M + 2**(S-1)) / 2**S)), then optional ReLU."""
    r = (y * m + (1 << (s - 1))) >> s  # Python >> on int is floor division by 2**s
    r = max(-128, min(127, r))
    return max(r, 0) if relu_en else r


def ref_conv(act: np.ndarray, w: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Direct convolution with nested loops. act [H, W, C_in], w [C_out, 3, 3, C_in] -> int y."""
    h, wd, cin = act.shape
    cout = w.shape[0]
    out = np.zeros((h - 2, wd - 2, cout), dtype=np.int64)
    for oy in range(h - 2):
        for ox in range(wd - 2):
            for co in range(cout):
                acc = int(b[co])
                for ky in range(3):
                    for kx in range(3):
                        for ci in range(cin):
                            acc += int(act[oy + ky, ox + kx, ci]) * int(w[co, ky, kx, ci])
                out[oy, ox, co] = acc
    return out


# ----------------------------------------------------------------------------- artifacts


def test_params_valid(params):
    params.validate()
    assert params.conv1_w.shape == (net.CONV1_COUT, 3, 3, 1)
    assert params.conv2_w.shape == (net.CONV2_COUT, 3, 3, net.CONV1_COUT)
    assert params.fc_w.shape == (net.NUM_CLASSES, net.FC_IN)


def test_quick_subset_logits_bit_exact(params, quick):
    """The golden model reproduces the committed expected logits exactly."""
    out = golden.infer(params, quick["q"])
    np.testing.assert_array_equal(out["logits"], quick["logits"])
    np.testing.assert_array_equal(out["pred"], quick["pred"])


def test_quick_subset_inputs(quick):
    assert len(quick["q"]) == 50
    np.testing.assert_array_equal(quick["q"], golden.preprocess(quick["pixels"]))
    assert quick["q"].min() >= 0 and quick["q"].max() <= 127
    assert np.all(np.bincount(quick["label"], minlength=10) == 5)
    assert np.all(np.diff(quick["test_index"]) > 0)


def test_accuracy_report_within_one_percent():
    r = json.loads((REPORTS / "quantize.json").read_text())
    assert r["test_images"] == 10000
    assert r["float_test_accuracy"] >= 0.97
    assert r["float_test_accuracy"] - r["int_test_accuracy"] <= 0.01


def test_memory_image_matches_params(params):
    """Committed hex files equal the image rebuilt from params.npz, and decode back to it."""
    mem = hwmap.build_memory_image(params)
    mem_dir = ARTIFACTS / "mem"

    def read_hex(name):
        return np.array([int(x, 16) for x in (mem_dir / name).read_text().split()], dtype=np.uint64)

    np.testing.assert_array_equal(read_hex("wgt.hex"), mem.wgt)
    np.testing.assert_array_equal(read_hex("param.hex"), mem.param)
    np.testing.assert_array_equal(read_hex("desc.hex"), mem.desc.astype(np.uint64))

    layout = mem.layout
    for name, w, b, m, s in (
        ("conv1", params.conv1_w, params.conv1_b, params.conv1_m, params.conv1_s),
        ("conv2", params.conv2_w, params.conv2_b, params.conv2_m, params.conv2_s),
    ):
        e = layout[name]
        bmat = golden.conv_weights_as_b(w)
        words = mem.wgt[e["wgt_base"] : e["wgt_base"] + e["wgt_words"]]
        np.testing.assert_array_equal(hwmap.unpack_b(words, *bmat.shape), bmat)
        pb, pm, ps = hwmap.unpack_params(
            mem.param[e["param_base"] : e["param_base"] + e["param_words"]]
        )
        np.testing.assert_array_equal(pb, b)
        np.testing.assert_array_equal(pm, m)
        np.testing.assert_array_equal(ps, s)
    e = layout["fc"]
    words = mem.wgt[e["wgt_base"] : e["wgt_base"] + e["wgt_words"]]
    np.testing.assert_array_equal(hwmap.unpack_b(words, net.FC_IN, net.NUM_CLASSES), params.fc_w.T)
    pb, _, _ = hwmap.unpack_params(mem.param[e["param_base"] : e["param_base"] + e["param_words"]])
    np.testing.assert_array_equal(pb, params.fc_b)


def test_descriptor_table_ping_pong(params):
    """Layers chain IMG -> ACT0 -> ACT1 -> ACT0 -> ACT1 -> LOGIT, and only the last is marked."""
    mem = hwmap.build_memory_image(params)
    ds = [hwmap.Descriptor.decode(mem.desc[i * 4 : i * 4 + 4]) for i in range(len(net.LAYERS))]
    assert ds == mem.descriptors
    chain = [(d.src, d.dst) for d in ds[:5]]
    B = hwmap
    assert chain == [
        (B.BUF_IMG, B.BUF_ACT0),
        (B.BUF_ACT0, B.BUF_ACT1),
        (B.BUF_ACT1, B.BUF_ACT0),
        (B.BUF_ACT0, B.BUF_ACT1),
        (B.BUF_ACT1, B.BUF_LOGIT),
    ]
    assert [d.last for d in ds] == [0, 0, 0, 0, 0, 1]
    assert ds[5].op == hwmap.OP_ARGMAX and ds[5].src == hwmap.BUF_LOGIT
    assert not np.any(mem.desc[len(ds) * 4 :]), "unused descriptor slots must be zero"


# ----------------------------------------------------------------------------- primitives


def test_requantize_matches_bigint_reference():
    rng = np.random.default_rng(SEED)
    y = np.concatenate(
        [
            rng.integers(golden.INT32_MIN, golden.INT32_MAX, 4000, endpoint=True),
            [golden.INT32_MIN, golden.INT32_MAX, 0, 1, -1],
        ]
    ).astype(np.int64)
    m = rng.integers(golden.M_MIN, golden.M_MAX, len(y), endpoint=True)
    s = rng.integers(golden.S_MIN, golden.S_MAX, len(y), endpoint=True)
    m[-5:], s[-5:] = golden.M_MAX, golden.S_MIN  # extreme products
    got = golden.requantize(y, m, s)
    want = [ref_requant(int(a), int(b), int(c)) for a, b, c in zip(y, m, s, strict=True)]
    np.testing.assert_array_equal(got, want)


@pytest.mark.parametrize(
    ("y", "m", "s", "want"),
    [
        (5, 1 << 15, 16, 3),  # 2.5 rounds half up to 3
        (-5, 1 << 15, 16, -2),  # -2.5 rounds half up (toward +inf) to -2
        (3, 1 << 15, 16, 2),  # 1.5 -> 2
        (-3, 1 << 15, 16, -1),  # -1.5 -> -1
        (1, 1 << 15, 16, 1),  # 0.5 -> 1
        (-1, 1 << 15, 16, 0),  # -0.5 -> 0
        (256, 1 << 15, 15, 127),  # 256 saturates high
        (-256, 1 << 15, 15, -128),  # -256 saturates low
        (127, 1 << 15, 15, 127),  # exact, no saturation
        (-128, 1 << 15, 15, -128),
    ],
)
def test_requantize_rounding_and_saturation(y, m, s, want):
    assert int(golden.requantize(np.array([y]), m, s)[0]) == want
    assert ref_requant(y, m, s) == want


def test_requantize_rejects_int32_overflow():
    with pytest.raises(golden.OverflowError32):
        golden.requantize(np.array([golden.INT32_MAX + 1]), golden.M_MIN, 20)


def test_conv_matches_direct_loops():
    rng = np.random.default_rng(SEED + 1)
    act = rng.integers(-128, 127, (7, 6, 3), endpoint=True).astype(np.int8)
    w = rng.integers(-127, 127, (5, 3, 3, 3), endpoint=True).astype(np.int8)
    b = rng.integers(-10000, 10000, 5).astype(np.int32)
    y = golden.gemm_bias(golden.im2col(act[None]), golden.conv_weights_as_b(w), b)[0]
    np.testing.assert_array_equal(y.reshape(5, 4, 5), ref_conv(act, w, b))


def test_conv_layer_requant_relu_matches_reference():
    rng = np.random.default_rng(SEED + 2)
    act = rng.integers(0, 127, (6, 6, 2), endpoint=True).astype(np.int8)
    w = rng.integers(-127, 127, (3, 3, 3, 2), endpoint=True).astype(np.int8)
    b = rng.integers(-5000, 5000, 3).astype(np.int32)
    m = rng.integers(golden.M_MIN, golden.M_MAX, 3, endpoint=True).astype(np.uint16)
    s = np.array([20, 22, 24], dtype=np.uint8)
    got = golden.conv_layer(act[None], w, b, m, s, relu_en=True)[0]
    y = ref_conv(act, w, b)
    want = np.vectorize(lambda v, c: ref_requant(int(v), int(m[c]), int(s[c]), relu_en=True))(
        y, np.arange(3)[None, None, :]
    )
    np.testing.assert_array_equal(got, want)


def test_gemm_overflow_detected():
    a = np.full((1, 1, 200_000), 127, dtype=np.int8)  # 200000 * 127 * 127 > 2**31
    b = np.full((200_000, 1), 127, dtype=np.int8)
    with pytest.raises(golden.OverflowError32):
        golden.gemm_bias(a, b, np.zeros(1, dtype=np.int32))


def test_gemm_bound_is_order_independent():
    """Mixed signs that cancel overall still trip the bound if any partial sum could overflow."""
    k = 140_000  # 140000 * 127 * 127 = 2.26e9 > 2**31 - 1, total sum is 0
    a = np.full((1, 1, k), 127, dtype=np.int8)
    b = np.ones((k, 1), dtype=np.int8) * 127
    b[k // 2 :] = -127
    with pytest.raises(golden.OverflowError32):
        golden.gemm_bias(a, b, np.zeros(1, dtype=np.int32))


def test_maxpool_floor_and_values():
    rng = np.random.default_rng(SEED + 3)
    act = rng.integers(-128, 127, (1, 5, 7, 2), endpoint=True).astype(np.int8)
    got = golden.maxpool2(act)
    assert got.shape == (1, 2, 3, 2)
    for y in range(2):
        for x in range(3):
            for c in range(2):
                win = act[0, 2 * y : 2 * y + 2, 2 * x : 2 * x + 2, c]
                assert got[0, y, x, c] == win.max()


@pytest.mark.parametrize(
    ("logits", "want"),
    [
        ([5, 9, 9, 1, 0, 0, 0, 0, 0, 0], 1),  # tie -> lowest index
        ([-3, -3, -3, -3, -3, -3, -3, -3, -3, -3], 0),  # all equal -> 0
        ([0, 0, 0, 0, 0, 0, 0, 0, 0, 7], 9),
        ([golden.INT32_MIN] * 9 + [golden.INT32_MIN + 1], 9),
        ([golden.INT32_MAX, golden.INT32_MAX] + [0] * 8, 0),
    ],
)
def test_argmax_ties_lowest_index(logits, want):
    assert int(golden.argmax(np.array(logits, dtype=np.int32))) == want


def test_fc_uses_hwc_flatten(params):
    """fc_layer reads activations in HWC order: one-hot inputs select the matching weight column."""
    act = np.zeros((1, 5, 5, 16), dtype=np.int8)
    y, x, c = 3, 1, 9
    act[0, y, x, c] = 1
    logits = golden.fc_layer(act, params.fc_w, params.fc_b)[0]
    np.testing.assert_array_equal(
        logits, params.fc_w[:, (y * 5 + x) * 16 + c].astype(np.int32) + params.fc_b
    )


def test_pack_unpack_roundtrip_ragged_columns():
    rng = np.random.default_rng(SEED + 4)
    for k_len, ncols in ((1, 1), (9, 8), (72, 16), (400, 10), (5, 13)):
        b = rng.integers(-128, 127, (k_len, ncols), endpoint=True).astype(np.int8)
        words = hwmap.pack_b(b)
        assert len(words) == -(-ncols // hwmap.N) * k_len
        np.testing.assert_array_equal(hwmap.unpack_b(words, k_len, ncols), b)


def test_descriptor_encode_decode_roundtrip():
    rng = np.random.default_rng(SEED + 5)
    for _ in range(200):
        d = hwmap.Descriptor(
            op=int(rng.integers(0, 8)),
            relu_en=int(rng.integers(0, 2)),
            requant_en=int(rng.integers(0, 2)),
            last=int(rng.integers(0, 2)),
            src=int(rng.integers(0, 4)),
            dst=int(rng.integers(0, 4)),
            src_base=int(rng.integers(0, 1 << 16)),
            dst_base=int(rng.integers(0, 1 << 16)),
            h_in=int(rng.integers(0, 256)),
            w_in=int(rng.integers(0, 256)),
            c_in=int(rng.integers(0, 256)),
            c_out=int(rng.integers(0, 256)),
            wgt_base=int(rng.integers(0, 1 << 16)),
            param_base=int(rng.integers(0, 256)),
        )
        words = d.encode()
        assert all(0 <= w < 2**32 for w in words)
        assert hwmap.Descriptor.decode(words) == d
