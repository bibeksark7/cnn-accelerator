"""Bit-exact integer golden model of the accelerator (NumPy only, no PyTorch).

Every function mirrors the hardware arithmetic defined in docs/spec.md:

  acc   = sum_k A[m, k] * B[k, n]                 int32 accumulator (never overflows)
  y     = acc + bias[n]                           int32
  conv: p = y * M[n]                              48-bit signed product
        r = (p + 2**(S[n] - 1)) >>> S[n]          round half up, arithmetic shift
        q = sat8(r), then ReLU clamps to [0, 127]
  fc:   logits = y                                int32, no requantization
  pool: 2x2 max, stride 2, floor
  argmax over int32 logits, ties to the lowest index

Activations are HWC; the im2col index is k = (ky * 3 + kx) * C_in + ci (see model/net.py).
Functions take a leading batch axis so the full test set can be evaluated quickly.

Overflow: for every GEMM the model checks the order-independent bound
    sum_k |A[m, k] * B[k, n]| + |bias[n]| <= 2**31 - 1,
which guarantees that no partial sum, in any accumulation order, leaves int32.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np

from model import net

INT8_MIN, INT8_MAX = -128, 127
INT32_MIN, INT32_MAX = -(2**31), 2**31 - 1
M_MIN, M_MAX = 2**15, 2**16 - 1
S_MIN, S_MAX = 1, 47

ARTIFACTS = Path(__file__).resolve().parent / "artifacts"
PARAMS_FILE = ARTIFACTS / "params.npz"


class OverflowError32(AssertionError):
    """A GEMM could exceed the int32 accumulator range."""


@dataclass(frozen=True)
class QuantParams:
    """Integer network parameters (the contents of model/artifacts/params.npz)."""

    conv1_w: np.ndarray  # int8 [C_out, 3, 3, C_in]
    conv1_b: np.ndarray  # int32 [C_out]
    conv1_m: np.ndarray  # uint16 [C_out]
    conv1_s: np.ndarray  # uint8 [C_out]
    conv2_w: np.ndarray
    conv2_b: np.ndarray
    conv2_m: np.ndarray
    conv2_s: np.ndarray
    fc_w: np.ndarray  # int8 [10, 400], columns in HWC order
    fc_b: np.ndarray  # int32 [10]

    @classmethod
    def load(cls, path: Path = PARAMS_FILE) -> QuantParams:
        with np.load(path) as f:
            return cls(**{name: f[name] for name in cls.__dataclass_fields__})

    def validate(self) -> None:
        for layer in ("conv1", "conv2"):
            w, b = getattr(self, f"{layer}_w"), getattr(self, f"{layer}_b")
            m, s = getattr(self, f"{layer}_m"), getattr(self, f"{layer}_s")
            assert w.dtype == np.int8 and b.dtype == np.int32, layer
            assert w.min() >= -127, f"{layer}: weights must be symmetric (no -128)"
            assert np.all((m >= M_MIN) & (m <= M_MAX)), f"{layer}: M out of range"
            assert np.all((s >= S_MIN) & (s <= S_MAX)), f"{layer}: S out of range"
        assert self.fc_w.dtype == np.int8 and self.fc_b.dtype == np.int32
        assert self.fc_w.min() >= -127


# ----------------------------------------------------------------------------- primitives


def sat8(x: np.ndarray) -> np.ndarray:
    return np.clip(x, INT8_MIN, INT8_MAX)


def relu(x: np.ndarray) -> np.ndarray:
    return np.maximum(x, 0)


def requantize_unclamped(y: np.ndarray, m: np.ndarray, s: np.ndarray) -> np.ndarray:
    """int32 y -> int64 (y * M + 2**(S-1)) >>> S, before saturation. m, s broadcast over the
    last axis. requantize() is sat8 of this; it is also used to count saturation."""
    y = np.asarray(y, dtype=np.int64)
    if y.size and (y.min() < INT32_MIN or y.max() > INT32_MAX):
        raise OverflowError32("requantize input outside int32")
    m64 = np.asarray(m, dtype=np.int64)
    s64 = np.asarray(s, dtype=np.int64)
    p = y * m64  # |p| < 2**47: fits the 48-bit signed hardware product
    return (p + (np.int64(1) << (s64 - 1))) >> s64  # NumPy >> on int64 is arithmetic


def requantize(y: np.ndarray, m: np.ndarray, s: np.ndarray) -> np.ndarray:
    """int32 y -> int8: sat8((y * M + 2**(S-1)) >>> S). m, s broadcast over the last axis."""
    return sat8(requantize_unclamped(y, m, s)).astype(np.int8)


def gemm_bias(a: np.ndarray, b: np.ndarray, bias: np.ndarray) -> np.ndarray:
    """int8 a [..., M, K] @ int8 b [K, N] + int32 bias [N] -> int32, with the overflow bound."""
    a64 = a.astype(np.int64)
    b64 = b.astype(np.int64)
    bound = np.abs(a64) @ np.abs(b64) + np.abs(bias.astype(np.int64))
    if bound.size and bound.max() > INT32_MAX:
        raise OverflowError32(f"GEMM bound {int(bound.max())} exceeds int32")
    return (a64 @ b64 + bias.astype(np.int64)).astype(np.int32)


def im2col(act: np.ndarray, ksize: int = net.KSIZE) -> np.ndarray:
    """HWC activations [B, H, W, C] -> [B, H_out*W_out, ksize*ksize*C], k = (ky*ks+kx)*C + ci."""
    bsz, h, w, c = act.shape
    ho, wo = h - ksize + 1, w - ksize + 1
    cols = np.empty((bsz, ho, wo, ksize, ksize, c), dtype=act.dtype)
    for ky in range(ksize):
        for kx in range(ksize):
            cols[:, :, :, ky, kx, :] = act[:, ky : ky + ho, kx : kx + wo, :]
    return cols.reshape(bsz, ho * wo, ksize * ksize * c)


def conv_weights_as_b(w: np.ndarray) -> np.ndarray:
    """[C_out, ks, ks, C_in] -> GEMM B [K, C_out] in im2col order."""
    return w.reshape(w.shape[0], -1).T


# ----------------------------------------------------------------------------- layers


def conv_layer(act, w, b, m, s, relu_en: bool = True) -> np.ndarray:
    """int8 HWC [B, H, W, C_in] -> int8 HWC [B, H-2, W-2, C_out]."""
    bsz, h, wd, _ = act.shape
    y = gemm_bias(im2col(act), conv_weights_as_b(w), b)
    q = requantize(y, m, s)
    if relu_en:
        q = relu(q)
    return q.reshape(bsz, h - net.KSIZE + 1, wd - net.KSIZE + 1, w.shape[0]).astype(np.int8)


def maxpool2(act: np.ndarray) -> np.ndarray:
    """2x2 max pool, stride 2, floor (odd trailing row/column dropped). HWC [B, H, W, C]."""
    bsz, h, w, c = act.shape
    ho, wo = h // 2, w // 2
    v = act[:, : ho * 2, : wo * 2, :].reshape(bsz, ho, 2, wo, 2, c)
    return v.max(axis=(2, 4))


def fc_layer(act: np.ndarray, w: np.ndarray, b: np.ndarray) -> np.ndarray:
    """int8 HWC [B, H, W, C] flattened in HWC order -> int32 logits [B, C_out]."""
    x = act.reshape(act.shape[0], 1, -1)  # GEMM with M = 1
    return gemm_bias(x, w.T, b)[:, 0, :]


def argmax(logits: np.ndarray) -> np.ndarray:
    """Index of the largest int32 logit; ties go to the lowest index (np.argmax semantics)."""
    return np.argmax(logits, axis=-1)


# ----------------------------------------------------------------------------- network


def preprocess(pixels: np.ndarray) -> np.ndarray:
    """uint8 pixels [..., 28, 28] -> hardware input bytes q = pixel >> 1 (int8, 0..127)."""
    return (np.asarray(pixels, dtype=np.uint8) >> net.INPUT_SHIFT).astype(np.int8)


def infer(params: QuantParams, q_images: np.ndarray, keep: bool = False) -> dict[str, np.ndarray]:
    """Run the network on hardware input bytes q [B, 28, 28] (int8).

    Returns {"logits": int32 [B, 10], "pred": [B]} and, with keep=True, every intermediate
    activation in HWC layout (conv1, pool1, conv2, pool2).
    """
    q = np.asarray(q_images, dtype=np.int8)
    if q.ndim == 2:
        q = q[None]
    x = q[..., None]  # [B, 28, 28, 1]
    a1 = conv_layer(x, params.conv1_w, params.conv1_b, params.conv1_m, params.conv1_s)
    p1 = maxpool2(a1)
    a2 = conv_layer(p1, params.conv2_w, params.conv2_b, params.conv2_m, params.conv2_s)
    p2 = maxpool2(a2)
    logits = fc_layer(p2, params.fc_w, params.fc_b)
    out = {"logits": logits, "pred": argmax(logits)}
    if keep:
        out.update(conv1=a1, pool1=p1, conv2=a2, pool2=p2)
    return out


def infer_batched(params: QuantParams, q_images: np.ndarray, chunk: int = 1000) -> np.ndarray:
    """Logits for many images, processed in chunks to bound memory."""
    parts = [
        infer(params, q_images[i : i + chunk])["logits"] for i in range(0, len(q_images), chunk)
    ]
    return np.concatenate(parts, axis=0)
