#!/usr/bin/env bash
# Git tree hash of the Milestone 1 RTL: rtl/ at <rev> without the SoC-only directories rtl/axi and
# rtl/soc (docs/decisions.md D-045). Before those directories existed this is exactly
# `git rev-parse <rev>:rtl`, so the provenance recorded by the full run and the DE10-Lite build
# keeps identifying the RTL they used. Writes the subset tree object into the repository.
# Usage: scripts/m1_rtl_tree.sh [rev]   (default HEAD)
set -euo pipefail
rev="${1:-HEAD}"
git ls-tree "$rev:rtl" | grep -vP '\t(axi|soc)$' | git mktree
