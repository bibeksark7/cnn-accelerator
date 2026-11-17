"""Train the float MNIST CNN on exactly the dequantized hardware input.

Usage: python -m model.train [--epochs N] [--seed S]

Input: x = (pixel >> 1) / 127.0, no mean/std normalization (matches the hardware).
The model flattens pool2's output in HWC order, so the FC weight columns are already in the
order the hardware reads activations; no permutation is needed at export.

Outputs (committed):
  model/artifacts/float_weights.npz   float32 weights in hardware-friendly layouts
  model/reports/train.json            training config and float accuracies
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

from model import net
from model.data import VAL_SIZE, load_mnist, train_val_split

ARTIFACTS = Path(__file__).resolve().parent / "artifacts"
REPORTS = Path(__file__).resolve().parent / "reports"


class MnistCnn(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(1, net.CONV1_COUT, net.KSIZE)
        self.conv2 = nn.Conv2d(net.CONV1_COUT, net.CONV2_COUT, net.KSIZE)
        self.fc = nn.Linear(net.FC_IN, net.NUM_CLASSES)

    def features(self, x: torch.Tensor) -> dict[str, torch.Tensor]:
        """Post-ReLU activations of each conv layer (used for calibration)."""
        a1 = F.relu(self.conv1(x))
        p1 = F.max_pool2d(a1, 2)
        a2 = F.relu(self.conv2(p1))
        p2 = F.max_pool2d(a2, 2)  # floor: 11 -> 5
        return {"conv1": a1, "conv2": a2, "pool2": p2}

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        p2 = self.features(x)["pool2"]
        flat = p2.permute(0, 2, 3, 1).flatten(1)  # HWC flatten, matches hardware layout
        return self.fc(flat)


def preprocess(pixels: np.ndarray) -> torch.Tensor:
    """uint8 [N, 28, 28] -> float [N, 1, 28, 28] equal to the dequantized hardware input."""
    q = (pixels.astype(np.uint8) >> net.INPUT_SHIFT).astype(np.float32)
    return torch.from_numpy(q / 127.0).unsqueeze(1)


@torch.no_grad()
def accuracy(model: nn.Module, x: torch.Tensor, y: torch.Tensor, batch: int = 2000) -> float:
    model.eval()
    correct = 0
    for i in range(0, len(x), batch):
        correct += (model(x[i : i + batch]).argmax(1) == y[i : i + batch]).sum().item()
    return correct / len(x)


def export_float_weights(model: MnistCnn, path: Path) -> None:
    """Store weights in the layouts the quantizer and hardware use.

    conv weights: [C_out, KSIZE, KSIZE, C_in]  (so flattening the last three axes gives the
                  im2col index k = (ky * 3 + kx) * C_in + ci)
    fc weights:   [C_out, 400] with columns in HWC order.
    """
    sd = {k: v.detach().cpu().numpy().astype(np.float32) for k, v in model.state_dict().items()}
    np.savez(
        path,
        conv1_w=sd["conv1.weight"].transpose(0, 2, 3, 1),
        conv1_b=sd["conv1.bias"],
        conv2_w=sd["conv2.weight"].transpose(0, 2, 3, 1),
        conv2_b=sd["conv2.bias"],
        fc_w=sd["fc.weight"],
        fc_b=sd["fc.bias"],
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epochs", type=int, default=10)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--lr", type=float, default=2e-3)
    parser.add_argument("--batch", type=int, default=64)
    args = parser.parse_args()

    torch.manual_seed(args.seed)
    data = load_mnist()
    tr_idx, val_idx = train_val_split(len(data["train_x"]), args.seed)
    x_tr, y_tr = preprocess(data["train_x"][tr_idx]), torch.from_numpy(data["train_y"][tr_idx])
    x_va, y_va = preprocess(data["train_x"][val_idx]), torch.from_numpy(data["train_y"][val_idx])
    x_te, y_te = preprocess(data["test_x"]), torch.from_numpy(data["test_y"])

    model = MnistCnn()
    opt = torch.optim.Adam(model.parameters(), lr=args.lr)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)
    t0 = time.time()
    history = []
    for epoch in range(args.epochs):
        model.train()
        order = torch.randperm(len(x_tr))
        for i in range(0, len(x_tr), args.batch):
            idx = order[i : i + args.batch]
            loss = F.cross_entropy(model(x_tr[idx]), y_tr[idx])
            opt.zero_grad()
            loss.backward()
            opt.step()
        sched.step()
        va = accuracy(model, x_va, y_va)
        history.append({"epoch": epoch + 1, "val_acc": va})
        print(f"epoch {epoch + 1:2d}  val_acc {va:.4f}  ({time.time() - t0:.0f}s)")

    test_acc = accuracy(model, x_te, y_te)
    n_params = sum(p.numel() for p in model.parameters())
    print(f"float test accuracy {test_acc:.4f}, {n_params} parameters")

    ARTIFACTS.mkdir(exist_ok=True)
    REPORTS.mkdir(exist_ok=True)
    export_float_weights(model, ARTIFACTS / "float_weights.npz")
    report = {
        "script": "model/train.py",
        "torch_version": torch.__version__,
        "seed": args.seed,
        "epochs": args.epochs,
        "lr": args.lr,
        "batch": args.batch,
        "optimizer": "Adam + cosine LR",
        "val_size": VAL_SIZE,
        "parameters": n_params,
        "history": history,
        "float_val_accuracy": history[-1]["val_acc"],
        "float_test_accuracy": test_acc,
        "test_images": len(x_te),
    }
    (REPORTS / "train.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
