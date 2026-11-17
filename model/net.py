"""Network definition shared by training, quantization, the golden model and export.

Pure Python (no NumPy/PyTorch) so every other module can import it.

Activation layout everywhere is HWC (channel-last): element (y, x, c) of an H x W x C tensor
lives at byte offset (y * W + x) * C + c. The im2col reduction index of a 3x3 convolution is
k = (ky * 3 + kx) * C_in + ci, which reads C_in consecutive bytes per kernel tap.
"""

from __future__ import annotations

from dataclasses import dataclass

IMG_H = 28
IMG_W = 28
IMG_SIZE = IMG_H * IMG_W  # bytes per input image (1 channel)
NUM_CLASSES = 10

# Input preprocessing: hardware input q = pixel >> 1 (0..127), scale s_in = 1/127.
INPUT_SHIFT = 1
S_IN = 1.0 / 127.0

CONV1_COUT = 8
CONV2_COUT = 16
KSIZE = 3


@dataclass(frozen=True)
class LayerShape:
    name: str
    kind: str  # "conv", "pool", "fc", "argmax"
    h_in: int
    w_in: int
    c_in: int
    c_out: int

    @property
    def h_out(self) -> int:
        if self.kind == "conv":
            return self.h_in - KSIZE + 1
        if self.kind == "pool":
            return self.h_in // 2
        return 1

    @property
    def w_out(self) -> int:
        if self.kind == "conv":
            return self.w_in - KSIZE + 1
        if self.kind == "pool":
            return self.w_in // 2
        return 1

    @property
    def gemm_m(self) -> int:
        """GEMM rows: output pixels (conv) or 1 (fc)."""
        return self.h_out * self.w_out if self.kind == "conv" else 1

    @property
    def gemm_k(self) -> int:
        """GEMM reduction length."""
        if self.kind == "conv":
            return KSIZE * KSIZE * self.c_in
        return self.h_in * self.w_in * self.c_in

    @property
    def out_elems(self) -> int:
        if self.kind == "argmax":
            return 1
        if self.kind == "fc":
            return self.c_out
        return self.h_out * self.w_out * self.c_out


LAYERS: tuple[LayerShape, ...] = (
    LayerShape("conv1", "conv", 28, 28, 1, CONV1_COUT),
    LayerShape("pool1", "pool", 26, 26, CONV1_COUT, CONV1_COUT),
    LayerShape("conv2", "conv", 13, 13, CONV1_COUT, CONV2_COUT),
    LayerShape("pool2", "pool", 11, 11, CONV2_COUT, CONV2_COUT),
    LayerShape("fc", "fc", 5, 5, CONV2_COUT, NUM_CLASSES),
    LayerShape("argmax", "argmax", 1, 1, NUM_CLASSES, 1),
)
LAYER_BY_NAME = {layer.name: layer for layer in LAYERS}
FC_IN = LAYER_BY_NAME["fc"].gemm_k  # 400
