"""Export the committed test vectors and hardware memory images.

Usage: python -m model.export [--params FILE] [--out DIR]

Inputs:  model/artifacts/params.npz, MNIST (data/ cache)
Outputs (committed, under model/artifacts/):
  quick_subset.npz   50 test images (first 5 of each class in test-set order): raw pixels, hardware
                     input bytes, labels, expected int32 logits and predicted class
  mem/wgt.hex        weight buffer image, one 64-bit word per line ($readmemh)
  mem/param.hex      parameter buffer image (bias, M, S), one 64-bit word per line
  mem/desc.hex       layer descriptor table, one 32-bit word per line
  mem/layout.json    per-layer bases, sizes and decoded descriptors
  mem/img.hex        IMG buffer image for the FPGA demo: 16 quick-subset images (the first of
                     each class, then the second of classes 0-5), 784 bytes each, one byte per line,
                     zero-filled to the buffer depth
  mem/label.hex      their true labels, one per line (the demo shows it on HEX1)
  mem/demo.json      which quick-subset images are in img.hex, their labels and golden classes
With --out DIR, the outputs go to DIR/artifacts/ instead; --params selects another params.npz.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from model import golden, hwmap, net
from model.data import load_mnist

ARTIFACTS = Path(__file__).resolve().parent / "artifacts"
QUICK_PER_CLASS = 5


def quick_subset_indices(labels: np.ndarray, per_class: int = QUICK_PER_CLASS) -> np.ndarray:
    """First `per_class` test images of each class, returned in test-set order."""
    picks = [np.flatnonzero(labels == c)[:per_class] for c in range(net.NUM_CLASSES)]
    return np.sort(np.concatenate(picks))


def demo_positions(labels: np.ndarray) -> list[int]:
    """Quick-subset positions of the 16 FPGA demo images: the first image of each class, then the
    second of classes 0-5, so every digit appears."""
    first = [int(np.flatnonzero(labels == c)[0]) for c in range(net.NUM_CLASSES)]
    second = [
        int(np.flatnonzero(labels == c)[1]) for c in range(hwmap.NUM_IMAGES - net.NUM_CLASSES)
    ]
    return first + second


def write_hex(path: Path, words: np.ndarray, digits: int) -> None:
    path.write_text("".join(f"{int(w):0{digits}x}\n" for w in words))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--params", type=Path, default=golden.PARAMS_FILE)
    parser.add_argument("--out", type=Path, help="write outputs under this directory instead")
    args = parser.parse_args()
    out_artifacts = args.out / "artifacts" if args.out else ARTIFACTS
    mem_dir = out_artifacts / "mem"
    out_artifacts.mkdir(parents=True, exist_ok=True)

    params = golden.QuantParams.load(args.params)
    params.validate()
    data = load_mnist()

    idx = quick_subset_indices(data["test_y"])
    pixels = data["test_x"][idx]
    q = golden.preprocess(pixels)
    out = golden.infer(params, q)
    np.savez(
        out_artifacts / "quick_subset.npz",
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
    mem_dir.mkdir(parents=True, exist_ok=True)
    write_hex(mem_dir / "wgt.hex", mem.wgt, 16)
    write_hex(mem_dir / "param.hex", mem.param, 16)
    write_hex(mem_dir / "desc.hex", mem.desc, 8)
    (mem_dir / "layout.json").write_text(json.dumps(mem.layout, indent=2) + "\n")

    labels = data["test_y"][idx]
    demo = demo_positions(labels)
    img = np.zeros(hwmap.IMG_DEPTH, dtype=np.uint8)  # the whole buffer: no unset words
    img[: len(demo) * net.IMG_SIZE] = np.concatenate([q[i].reshape(-1) for i in demo])
    write_hex(mem_dir / "img.hex", img, 2)
    write_hex(mem_dir / "label.hex", labels[demo].astype(np.uint8), 1)
    demo_info = {
        "quick_subset_positions": demo,
        "test_index": [int(idx[i]) for i in demo],
        "label": [int(labels[i]) for i in demo],
        "golden_class": [int(out["pred"][i]) for i in demo],
    }
    (mem_dir / "demo.json").write_text(json.dumps(demo_info, indent=2) + "\n")
    t = mem.layout["_totals"]
    print(
        f"memory image: {t['wgt_words']} weight words, {t['param_words']} param words, "
        f"{t['layers']} layers"
    )


if __name__ == "__main__":
    main()
