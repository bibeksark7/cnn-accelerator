"""MNIST loading for training and evaluation (needs torchvision; never used by CI).

Downloads into the git-ignored data/ directory and caches uint8 arrays in data/mnist.npz.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = REPO_ROOT / "data"
CACHE = DATA_DIR / "mnist.npz"


def load_mnist() -> dict[str, np.ndarray]:
    """Return {"train_x", "train_y", "test_x", "test_y"}; images are uint8 [N, 28, 28]."""
    if CACHE.exists():
        with np.load(CACHE) as f:
            return {k: f[k] for k in f.files}
    from torchvision.datasets import MNIST  # imported lazily: dev-only dependency

    DATA_DIR.mkdir(exist_ok=True)
    out: dict[str, np.ndarray] = {}
    for split, train in (("train", True), ("test", False)):
        ds = MNIST(root=str(DATA_DIR), train=train, download=True)
        out[f"{split}_x"] = ds.data.numpy().astype(np.uint8)
        out[f"{split}_y"] = ds.targets.numpy().astype(np.int64)
    np.savez_compressed(CACHE, **out)
    return out


def to_hw_input(pixels: np.ndarray) -> np.ndarray:
    """Hardware input bytes: q = pixel >> 1, range 0..127 (int8-safe)."""
    return (pixels.astype(np.uint8) >> 1).astype(np.int8)


VAL_SIZE = 5000  # held out from the training set; the test set is only used for final numbers


def train_val_split(n_train: int, seed: int) -> tuple[np.ndarray, np.ndarray]:
    """Deterministic (train_idx, val_idx) split of the MNIST training set."""
    perm = np.random.default_rng(seed).permutation(n_train)
    return perm[VAL_SIZE:], perm[:VAL_SIZE]
