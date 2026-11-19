"""Hardware memory map and data formats (docs/spec.md, sections "Buffers" and "Layer descriptors").

Pure NumPy. Used by model/export.py to build the memory images and by the testbench to load
and check them, so the formats are defined in exactly one place in software.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

import numpy as np

from model import net
from model.golden import QuantParams, conv_weights_as_b

# ------------------------------------------------------------------ build-time parameters
N = 8  # systolic array size
DATA_W = 8
ACC_W = 32
K_TILE = 128  # A-staging depth: GEMMs with K > K_TILE are split into K chunks

NUM_IMAGES = 16
IMG_DEPTH = 16384  # bytes; image i at i * IMG_SIZE
ACT_DEPTH = 8192  # bytes per ping-pong activation buffer
WGT_DEPTH = 1024  # N*DATA_W-bit words
PARAM_DEPTH = 64  # 64-bit words, one per output channel
LOGIT_DEPTH = 16  # int32 entries
DESC_DEPTH = 8  # descriptors (layers)
DESC_WORDS = 4  # 32-bit words per descriptor

# ------------------------------------------------------------------ descriptor encodings
OP_CONV, OP_POOL, OP_FC, OP_ARGMAX = 0, 1, 2, 3
BUF_IMG, BUF_ACT0, BUF_ACT1, BUF_LOGIT = 0, 1, 2, 3


@dataclass(frozen=True)
class Descriptor:
    op: int
    relu_en: int
    requant_en: int
    last: int
    src: int
    dst: int
    src_base: int
    dst_base: int
    h_in: int
    w_in: int
    c_in: int
    c_out: int
    wgt_base: int = 0
    param_base: int = 0

    def encode(self) -> list[int]:
        """Four 32-bit words (see spec.md, "Layer descriptor format")."""
        fields = (
            (self.op, 3),
            (self.relu_en, 1),
            (self.requant_en, 1),
            (self.last, 1),
            (self.src, 2),
            (self.dst, 2),
            (self.src_base, 16),
            (self.dst_base, 16),
            (self.h_in, 8),
            (self.w_in, 8),
            (self.c_in, 8),
            (self.c_out, 8),
            (self.wgt_base, 16),
            (self.param_base, 8),
        )
        for value, width in fields:
            assert 0 <= value < (1 << width), (self, value, width)
        w0 = (
            self.op
            | self.relu_en << 3
            | self.requant_en << 4
            | self.last << 5
            | self.src << 8
            | self.dst << 12
        )
        w1 = self.src_base | self.dst_base << 16
        w2 = self.h_in | self.w_in << 8 | self.c_in << 16 | self.c_out << 24
        w3 = self.wgt_base | self.param_base << 16
        return [w0, w1, w2, w3]

    @classmethod
    def decode(cls, words: list[int]) -> Descriptor:
        w0, w1, w2, w3 = (int(w) for w in words)
        return cls(
            op=w0 & 0x7,
            relu_en=(w0 >> 3) & 1,
            requant_en=(w0 >> 4) & 1,
            last=(w0 >> 5) & 1,
            src=(w0 >> 8) & 0x3,
            dst=(w0 >> 12) & 0x3,
            src_base=w1 & 0xFFFF,
            dst_base=w1 >> 16,
            h_in=w2 & 0xFF,
            w_in=(w2 >> 8) & 0xFF,
            c_in=(w2 >> 16) & 0xFF,
            c_out=w2 >> 24,
            wgt_base=w3 & 0xFFFF,
            param_base=(w3 >> 16) & 0xFF,
        )


def descriptor_error(d: Descriptor) -> str | None:
    """The spec §9 error a descriptor triggers before its layer starts, or None if it is legal.

    LOGIT is written only by FC and read only by ARGMAX; CONV and POOL write a byte buffer.
    """
    if d.op > OP_ARGMAX:
        return "reserved op"
    if d.op == OP_ARGMAX:
        return None if d.src == BUF_LOGIT else "ARGMAX with src != LOGIT"
    if d.src == BUF_LOGIT:
        return "src = LOGIT"
    if d.op == OP_FC:
        return None if d.dst == BUF_LOGIT else "FC with dst != LOGIT"
    if d.dst == BUF_IMG:
        return "dst = IMG"
    if d.dst == BUF_LOGIT:
        return "dst = LOGIT"
    if d.src == d.dst:
        return "src = dst"
    return None


# ------------------------------------------------------------------ packing


def pack_b(b: np.ndarray, n: int = N) -> np.ndarray:
    """GEMM B [K, Ncols] int8 -> uint64 words, column tile major.

    Word (nt * K + k) holds B[k, nt*N + j] in byte j (bits 8j+7:8j); columns past Ncols are 0.
    """
    k_len, ncols = b.shape
    ntiles = -(-ncols // n)
    padded = np.zeros((k_len, ntiles * n), dtype=np.uint8)
    padded[:, :ncols] = b.astype(np.int8).view(np.uint8)
    words = np.zeros(ntiles * k_len, dtype=np.uint64)
    for nt in range(ntiles):
        tile = padded[:, nt * n : (nt + 1) * n].astype(np.uint64)
        for j in range(n):
            words[nt * k_len : (nt + 1) * k_len] |= tile[:, j] << np.uint64(8 * j)
    return words


def unpack_b(words: np.ndarray, k_len: int, ncols: int, n: int = N) -> np.ndarray:
    ntiles = -(-ncols // n)
    out = np.zeros((k_len, ntiles * n), dtype=np.int8)
    for nt in range(ntiles):
        chunk = words[nt * k_len : (nt + 1) * k_len].astype(np.uint64)
        for j in range(n):
            out[:, nt * n + j] = (
                ((chunk >> np.uint64(8 * j)) & np.uint64(0xFF)).astype(np.uint8).view(np.int8)
            )
    return out[:, :ncols]


def pack_params(
    bias: np.ndarray, m: np.ndarray | None = None, s: np.ndarray | None = None
) -> np.ndarray:
    """One 64-bit word per output channel: [31:0] bias, [47:32] M, [53:48] S (0 when unused)."""
    c = len(bias)
    m = np.zeros(c, dtype=np.uint16) if m is None else m
    s = np.zeros(c, dtype=np.uint8) if s is None else s
    b32 = bias.astype(np.int32).view(np.uint32).astype(np.uint64)
    return (
        b32
        | (m.astype(np.uint64) << np.uint64(32))
        | ((s.astype(np.uint64) & np.uint64(0x3F)) << np.uint64(48))
    )


def unpack_params(words: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    w = words.astype(np.uint64)
    bias = (w & np.uint64(0xFFFFFFFF)).astype(np.uint32).view(np.int32)
    m = ((w >> np.uint64(32)) & np.uint64(0xFFFF)).astype(np.uint16)
    s = ((w >> np.uint64(48)) & np.uint64(0x3F)).astype(np.uint8)
    return bias, m, s


# ------------------------------------------------------------------ network memory image


@dataclass
class MemoryImage:
    wgt: np.ndarray  # uint64 [WGT_DEPTH]
    param: np.ndarray  # uint64 [PARAM_DEPTH]
    desc: np.ndarray  # uint32 [DESC_DEPTH * DESC_WORDS]
    descriptors: list[Descriptor]
    layout: dict


def build_memory_image(params: QuantParams) -> MemoryImage:
    """Pack the network into weight/param/descriptor memory images, ping-ponging ACT0/ACT1."""
    b_mats = {
        "conv1": (
            conv_weights_as_b(params.conv1_w),
            params.conv1_b,
            params.conv1_m,
            params.conv1_s,
        ),
        "conv2": (
            conv_weights_as_b(params.conv2_w),
            params.conv2_b,
            params.conv2_m,
            params.conv2_s,
        ),
        "fc": (params.fc_w.T, params.fc_b, None, None),
    }
    wgt = np.zeros(WGT_DEPTH, dtype=np.uint64)
    param = np.zeros(PARAM_DEPTH, dtype=np.uint64)
    wgt_ptr = param_ptr = 0
    layout: dict[str, dict] = {}
    descriptors: list[Descriptor] = []
    src = BUF_IMG
    act_out = BUF_ACT0
    for i, layer in enumerate(net.LAYERS):
        last = int(i == len(net.LAYERS) - 1)
        entry: dict = {"index": i, "kind": layer.kind}
        if layer.name in b_mats:
            b, bias, m, s = b_mats[layer.name]
            words = pack_b(b)
            pwords = pack_params(bias, m, s)
            wgt[wgt_ptr : wgt_ptr + len(words)] = words
            param[param_ptr : param_ptr + len(pwords)] = pwords
            entry.update(
                wgt_base=wgt_ptr,
                wgt_words=len(words),
                param_base=param_ptr,
                param_words=len(pwords),
            )
            wgt_base, param_base = wgt_ptr, param_ptr
            wgt_ptr += len(words)
            param_ptr += len(pwords)
        else:
            wgt_base = param_base = 0

        if layer.kind == "fc":
            dst = BUF_LOGIT
        elif layer.kind == "argmax":
            dst = BUF_LOGIT  # unused: the result goes to the RESULT CSR
        else:
            dst = act_out
        op = {"conv": OP_CONV, "pool": OP_POOL, "fc": OP_FC, "argmax": OP_ARGMAX}[layer.kind]
        d = Descriptor(
            op=op,
            relu_en=int(layer.kind == "conv"),
            requant_en=int(layer.kind == "conv"),
            last=last,
            src=src,
            dst=dst,
            src_base=0,
            dst_base=0,
            h_in=layer.h_in,
            w_in=layer.w_in,
            c_in=layer.c_in,
            c_out=layer.c_out,
            wgt_base=wgt_base,
            param_base=param_base,
        )
        descriptors.append(d)
        entry.update(descriptor=asdict(d), out_elems=layer.out_elems)
        layout[layer.name] = entry
        if dst in (BUF_ACT0, BUF_ACT1):
            src, act_out = dst, (BUF_ACT1 if dst == BUF_ACT0 else BUF_ACT0)
        else:
            src = dst

    assert wgt_ptr <= WGT_DEPTH and param_ptr <= PARAM_DEPTH and len(descriptors) <= DESC_DEPTH
    assert all(descriptor_error(d) is None for d in descriptors), descriptors
    for layer in net.LAYERS:
        if layer.kind in ("conv", "pool"):
            assert layer.out_elems <= ACT_DEPTH, layer
    desc = np.zeros(DESC_DEPTH * DESC_WORDS, dtype=np.uint32)
    for i, d in enumerate(descriptors):
        desc[i * DESC_WORDS : (i + 1) * DESC_WORDS] = d.encode()
    layout["_totals"] = {"wgt_words": wgt_ptr, "param_words": param_ptr, "layers": len(descriptors)}
    return MemoryImage(wgt=wgt, param=param, desc=desc, descriptors=descriptors, layout=layout)
