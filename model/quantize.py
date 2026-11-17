"""Post-training quantization of the float CNN to the integer format in docs/spec.md.

Usage: python -m model.quantize [--seed S] [--out DIR]

Inputs:  model/artifacts/float_weights.npz (from model/train.py), MNIST (data/ cache)
Outputs (committed):
  model/artifacts/params.npz      integer weights, biases, M, S (+ the float scales, for reference)
  model/reports/quantize.json     scales, M/S, calibration choice, float vs integer accuracy
With --out DIR, the outputs go to DIR/artifacts/ and DIR/reports/ instead (inputs are unchanged).

Scheme (symmetric, zero-point 0 everywhere):
  conv weights  per-output-channel  s_w[c] = max|w[c]| / 127, q = round(w / s_w[c]) in [-127, 127]
  fc weights    per-tensor          s_w    = max|w|    / 127
  activations   s_a = calib(post-ReLU activation) / 127, calibrated on training images
  bias          round(b / (s_x * s_w))           (s_x = the layer's input activation scale)
  requantize    m = s_x * s_w[c] / s_out = M * 2**-S,  M in [2**15, 2**16-1], S in [1, 47]

The calibration statistic (max or a high percentile) is chosen by integer accuracy on the
validation split; the test set is only used for the final reported numbers.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np

from model import golden, net
from model.data import load_mnist, train_val_split

ARTIFACTS = Path(__file__).resolve().parent / "artifacts"
REPORTS = Path(__file__).resolve().parent / "reports"
CALIB_IMAGES = 10000
CALIB_CANDIDATES = (100.0, 99.999, 99.99, 99.9)  # percentiles; 100 = max


def compute_m_s(m_real: float) -> tuple[int, int]:
    """Express a positive real multiplier as M * 2**-S with M in [2**15, 2**16-1], S in [1, 47]."""
    assert m_real > 0, m_real
    s = 15 - math.floor(math.log2(m_real))  # puts m_real * 2**s in [2**15, 2**16)
    m = round(m_real * 2**s)
    if m == 2**16:  # rounding carried out of range
        m //= 2
        s -= 1
    assert golden.M_MIN <= m <= golden.M_MAX, (m_real, m, s)
    assert golden.S_MIN <= s <= golden.S_MAX, (m_real, m, s)
    return m, s


def quantize_weights(w: np.ndarray, per_channel: bool) -> tuple[np.ndarray, np.ndarray]:
    """Symmetric int8 quantization; returns (q int8, scale float64 [C_out] or [1])."""
    w = w.astype(np.float64)
    flat = w.reshape(w.shape[0], -1)
    amax = np.abs(flat).max(axis=1) if per_channel else np.array([np.abs(flat).max()])
    scale = np.where(amax > 0, amax / 127.0, 1.0)
    bshape = (-1,) + (1,) * (w.ndim - 1) if per_channel else (1,) * w.ndim
    q = np.clip(np.round(w / scale.reshape(bshape)), -127, 127).astype(np.int8)
    return q, scale


def quantize_bias(b: np.ndarray, s_x: float, s_w: np.ndarray) -> np.ndarray:
    q = np.round(b.astype(np.float64) / (s_x * s_w))
    assert np.all(np.abs(q) <= golden.INT32_MAX), "bias overflows int32"
    return q.astype(np.int32)


# ----------------------------------------------------------------------------- float reference


def float_forward(fw: dict[str, np.ndarray], q_images: np.ndarray) -> dict[str, np.ndarray]:
    """Float forward pass in NumPy (HWC), on the dequantized hardware input."""
    x = q_images.astype(np.float64)[..., None] / 127.0

    def conv(a, w, b):
        bsz, h, wd, _ = a.shape
        y = golden.im2col(a) @ golden.conv_weights_as_b(w.astype(np.float64)) + b
        return y.reshape(bsz, h - 2, wd - 2, w.shape[0])

    a1 = np.maximum(conv(x, fw["conv1_w"], fw["conv1_b"]), 0)
    a2 = np.maximum(conv(golden.maxpool2(a1), fw["conv2_w"], fw["conv2_b"]), 0)
    p2 = golden.maxpool2(a2)
    logits = p2.reshape(len(p2), -1) @ fw["fc_w"].T.astype(np.float64) + fw["fc_b"]
    return {"conv1": a1, "conv2": a2, "logits": logits}


def float_logits(fw, q_images, chunk: int = 1000) -> np.ndarray:
    return np.concatenate(
        [
            float_forward(fw, q_images[i : i + chunk])["logits"]
            for i in range(0, len(q_images), chunk)
        ]
    )


# ----------------------------------------------------------------------------- quantization


def build_params(
    fw: dict[str, np.ndarray], amax1: float, amax2: float
) -> tuple[golden.QuantParams, dict]:
    s_a1 = amax1 / 127.0  # conv1 output = conv2 input scale
    s_a2 = amax2 / 127.0  # conv2 output = pool2 = fc input scale

    w1, sw1 = quantize_weights(fw["conv1_w"], per_channel=True)
    w2, sw2 = quantize_weights(fw["conv2_w"], per_channel=True)
    wf, swf = quantize_weights(fw["fc_w"], per_channel=False)

    b1 = quantize_bias(fw["conv1_b"], net.S_IN, sw1)
    b2 = quantize_bias(fw["conv2_b"], s_a1, sw2)
    bf = quantize_bias(fw["fc_b"], s_a2, np.full(net.NUM_CLASSES, swf[0]))

    ms1 = [compute_m_s(net.S_IN * sw / s_a1) for sw in sw1]
    ms2 = [compute_m_s(s_a1 * sw / s_a2) for sw in sw2]

    params = golden.QuantParams(
        conv1_w=w1,
        conv1_b=b1,
        conv1_m=np.array([m for m, _ in ms1], dtype=np.uint16),
        conv1_s=np.array([s for _, s in ms1], dtype=np.uint8),
        conv2_w=w2,
        conv2_b=b2,
        conv2_m=np.array([m for m, _ in ms2], dtype=np.uint16),
        conv2_s=np.array([s for _, s in ms2], dtype=np.uint8),
        fc_w=wf,
        fc_b=bf,
    )
    params.validate()
    scales = {
        "s_in": net.S_IN,
        "s_a1": s_a1,
        "s_a2": s_a2,
        "s_w_conv1": sw1.tolist(),
        "s_w_conv2": sw2.tolist(),
        "s_w_fc": float(swf[0]),
    }
    return params, scales


def save_params(params: golden.QuantParams, scales: dict, path: Path) -> None:
    arrays = {name: getattr(params, name) for name in golden.QuantParams.__dataclass_fields__}
    np.savez(
        path,
        **arrays,
        s_a1=np.float64(scales["s_a1"]),
        s_a2=np.float64(scales["s_a2"]),
        s_w_conv1=np.array(scales["s_w_conv1"]),
        s_w_conv2=np.array(scales["s_w_conv2"]),
        s_w_fc=np.float64(scales["s_w_fc"]),
    )


def accuracy(pred: np.ndarray, labels: np.ndarray) -> float:
    return float(np.mean(pred == labels))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=1, help="must match model/train.py")
    parser.add_argument("--out", type=Path, help="write outputs under this directory instead")
    args = parser.parse_args()
    out_artifacts = args.out / "artifacts" if args.out else ARTIFACTS
    out_reports = args.out / "reports" if args.out else REPORTS

    with np.load(ARTIFACTS / "float_weights.npz") as f:
        fw = {k: f[k] for k in f.files}
    data = load_mnist()
    tr_idx, val_idx = train_val_split(len(data["train_x"]), args.seed)
    calib_q = golden.preprocess(data["train_x"][tr_idx[:CALIB_IMAGES]])
    val_q, val_y = golden.preprocess(data["train_x"][val_idx]), data["train_y"][val_idx]
    test_q, test_y = golden.preprocess(data["test_x"]), data["test_y"]

    acts = [float_forward(fw, calib_q[i : i + 1000]) for i in range(0, len(calib_q), 1000)]
    conv1_act = np.concatenate([a["conv1"].ravel() for a in acts])
    conv2_act = np.concatenate([a["conv2"].ravel() for a in acts])

    candidates = []
    for pct in CALIB_CANDIDATES:
        amax1 = float(np.percentile(conv1_act, pct))
        amax2 = float(np.percentile(conv2_act, pct))
        params, _ = build_params(fw, amax1, amax2)
        val_acc = accuracy(golden.argmax(golden.infer_batched(params, val_q)), val_y)
        candidates.append(
            {"percentile": pct, "amax_conv1": amax1, "amax_conv2": amax2, "val_acc": val_acc}
        )
        print(f"calib p{pct:<7} amax1 {amax1:.4f} amax2 {amax2:.4f}  int val acc {val_acc:.4f}")
    # Highest validation accuracy; ties go to the larger percentile (less clipping).
    best = max(candidates, key=lambda c: (c["val_acc"], c["percentile"]))
    params, scales = build_params(fw, best["amax_conv1"], best["amax_conv2"])

    test_logits_int = golden.infer_batched(params, test_q)
    int_pred = golden.argmax(test_logits_int)
    float_pred = np.argmax(float_logits(fw, test_q), axis=1)
    float_acc, int_acc = accuracy(float_pred, test_y), accuracy(int_pred, test_y)
    torch_float_acc = json.loads((REPORTS / "train.json").read_text())["float_test_accuracy"]
    agreement = float(np.mean(int_pred == float_pred))
    gap = float_acc - int_acc
    print(
        f"test: float {float_acc:.4f} (torch {torch_float_acc:.4f})  "
        f"int {int_acc:.4f}  gap {gap:+.4f}"
    )
    print(f"int/float prediction agreement {agreement:.4f}")

    out_artifacts.mkdir(parents=True, exist_ok=True)
    out_reports.mkdir(parents=True, exist_ok=True)
    save_params(params, scales, out_artifacts / "params.npz")
    report = {
        "script": "model/quantize.py",
        "calibration_images": CALIB_IMAGES,
        "calibration_candidates": candidates,
        "calibration_choice_percentile": best["percentile"],
        "scales": scales,
        "conv1_M": params.conv1_m.tolist(),
        "conv1_S": params.conv1_s.tolist(),
        "conv2_M": params.conv2_m.tolist(),
        "conv2_S": params.conv2_s.tolist(),
        "test_images": len(test_y),
        "float_test_accuracy": float_acc,
        "float_test_accuracy_torch": torch_float_acc,
        "int_test_accuracy": int_acc,
        "accuracy_gap": gap,
        "int_float_prediction_agreement": agreement,
        "max_abs_logit": int(np.abs(test_logits_int).max()),
    }
    (out_reports / "quantize.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
