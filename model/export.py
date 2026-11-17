"""Export the committed test vectors and hardware memory images.

Usage: python -m model.export

Inputs:  model/artifacts/params.npz, MNIST (data/ cache)
Outputs (committed, under model/artifacts/):
  quick_subset.npz   50 test images (first 5 of each class in test-set order): raw pixels, hardware
                     input bytes, labels, expected int32 logits and predicted class
  mem/wgt.hex        weight buffer image, one 64-bit word per line ($readmemh)
  mem/param.hex      parameter buffer image (bias, M, S), one 64-bit word per line
  mem/desc.hex       layer descriptor table, one 32-bit word per line
  mem/layout.json    per-layer bases, sizes and decoded descriptors
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from model import golden, hwmap, net
from model.data import load_mnist

ARTIFACTS = Path(__file__).resolve().parent / "artifacts"
MEM_DIR = ARTIFACTS / "mem"
QUICK_PER_CLASS = 5


def quick_subset_indices(labels: np.ndarray, per_class: int = QUICK_PER_CLASS) -> np.ndarray:
    """First `per_class` test images of each class, returned in test-set order."""
    picks = [np.flatnonzero(labels == c)[:per_class] for c in range(net.NUM_CLASSES)]
    return np.sort(np.concatenate(picks))


def write_hex(path: Path, words: np.ndarray, digits: int) -> None:
    path.write_text("".join(f"{int(w):0{digits}x}\n" for w in words))


def main() -> None:
    params = golden.QuantParams.load()
    params.validate()
    data = load_mnist()

    idx = quick_subset_indices(data["test_y"])
    pixels = data["test_x"][idx]
    q = golden.preprocess(pixels)
    out = golden.infer(params, q)
    np.savez(
        ARTIFACTS / "quick_subset.npz",
        test_index=idx.astype(np.int32),
        pixels=pixels,
        q=q,
        label=data["test_y"][idx].astype(np.int8),
        logits=out["logits"],
        pred=out["pred"].astype(np.int8),
    )
    correct = int(np.sum(out["pred"] == data["test_y"][idx]))
    print(f"quick subset: {len(idx)} images, golden correct {correct}/{len(idx)}")

    mem = hwmap.build_memory_image(params)
    MEM_DIR.mkdir(parents=True, exist_ok=True)
    write_hex(MEM_DIR / "wgt.hex", mem.wgt, 16)
    write_hex(MEM_DIR / "param.hex", mem.param, 16)
    write_hex(MEM_DIR / "desc.hex", mem.desc, 8)
    (MEM_DIR / "layout.json").write_text(json.dumps(mem.layout, indent=2) + "\n")
    t = mem.layout["_totals"]
    print(
        f"memory image: {t['wgt_words']} weight words, {t['param_words']} param words, "
        f"{t['layers']} layers"
    )


if __name__ == "__main__":
    main()
