#!/usr/bin/env bash
# Phase checkpoint: scripts/checkpoint.sh <phase>
# Exits 0 only if every check for that phase passes. Checks are cumulative where noted.
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh

REPORT_DIR=sim_build/checkpoint
mkdir -p "$REPORT_DIR"

failures=0
pass() { printf '  [PASS] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; failures=$((failures + 1)); }
skip() { printf '  [SKIP] %s\n' "$1"; }
check() { # check "<description>" <command...>
  local desc="$1"; shift
  if "$@" >"$REPORT_DIR/last.log" 2>&1; then pass "$desc"; else fail "$desc"; sed 's/^/         /' "$REPORT_DIR/last.log" | tail -25; fi
}

# ---------------------------------------------------------------- helpers
version_ge() { # version_ge <have> <need>
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

check_tool_versions() {
  local py iv vl
  py="$(python -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  [ "$py" = "3.14" ] || { echo "python is $py, need 3.14"; return 1; }
  [ "$(command -v python)" = "$PWD/.venv/bin/python" ] || { echo "python is $(command -v python), want .venv"; return 1; }
  iv="$(iverilog -V 2>&1 | head -1)"
  [[ "$iv" == "Icarus Verilog version 12."* ]] || { echo "iverilog: $iv"; return 1; }
  vl="$(verilator --version | awk '{print $2}')"
  version_ge "$vl" 5.036 || { echo "verilator $vl < 5.036"; return 1; }
  yosys -V >/dev/null && sby --help >/dev/null
  echo "python $py, $iv, verilator $vl, $(yosys -V)"
}

check_pytest() { # check_pytest <name> <min_tests> <pytest args...>
  local name="$1" min="$2"; shift 2
  local xml="$REPORT_DIR/$name.xml"
  pytest -q --junitxml="$xml" "$@" && python scripts/check_junit.py "$xml" --min-tests "$min"
}

check_ruff() { ruff format --check . && ruff check .; }

# Optional local repository checks: every file in <git-dir>/local-checks/ is run, in name order.
LOCAL_CHECKS_DIR="$(git rev-parse --git-dir)/local-checks"

run_local_checks() { # run_local_checks "<description>"
  local f found=0
  for f in "$LOCAL_CHECKS_DIR"/*; do
    [ -f "$f" ] || continue
    found=1
    if [ -x "$f" ]; then
      check "$1: $(basename "$f")" "$f"
    else
      fail "$1: $(basename "$f") is not executable"
    fi
  done
  [ "$found" -eq 1 ] || skip "$1 (none in this clone)"
}

check_ci_green_on_head() {
  local head json status conclusion sha
  head="$(git rev-parse HEAD)"
  [ -z "$(git status --porcelain)" ] || { echo "uncommitted or untracked changes:"; git status --short; return 1; }
  [ "$(git rev-parse '@{u}' 2>/dev/null)" = "$head" ] || { echo "HEAD is not pushed to its upstream"; return 1; }
  json="$(gh run list --branch main --limit 1 --json status,conclusion,headSha,url)" || return 1
  status="$(echo "$json" | python -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["status"] if r else "")')"
  conclusion="$(echo "$json" | python -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["conclusion"] if r else "")')"
  sha="$(echo "$json" | python -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["headSha"] if r else "")')"
  echo "$json"
  [ "$sha" = "$head" ] || { echo "latest CI run on main is for $sha, not HEAD $head"; return 1; }
  [ "$status" = "completed" ] && [ "$conclusion" = "success" ] || { echo "CI status=$status conclusion=$conclusion"; return 1; }
}

check_accuracy_report() {
  python - <<'PY'
import json, sys
r = json.load(open("model/reports/quantize.json"))
f, i, n = r["float_test_accuracy"], r["int_test_accuracy"], r["test_images"]
print(f"float {f:.4f}  int {i:.4f}  gap {f - i:+.4f}  on {n} test images")
ok = n == 10000 and f >= 0.97 and (f - i) <= 0.01
sys.exit(0 if ok else 1)
PY
}

check_docs_exist() {
  local f ok=0
  for f in "$@"; do [ -s "$f" ] || { echo "missing or empty: $f"; ok=1; }; done
  return "$ok"
}

# Regenerates params, report and exported artifacts from the committed float weights into a
# temporary directory and checks they are byte-identical to the committed files. Never writes
# into model/. Needs the MNIST cache in data/.
check_artifacts_reproducible() {
  local tmp f rc=0
  tmp="$(mktemp -d)"
  if ! python -m model.quantize --out "$tmp" >/dev/null \
     || ! python -m model.export --params "$tmp/artifacts/params.npz" --out "$tmp" >/dev/null; then
    rm -rf "$tmp"; return 1
  fi
  for f in artifacts/params.npz artifacts/quick_subset.npz artifacts/mem/wgt.hex \
           artifacts/mem/param.hex artifacts/mem/desc.hex artifacts/mem/layout.json \
           reports/quantize.json; do
    cmp -s "model/$f" "$tmp/$f" || { echo "regenerated $f differs from model/$f"; rc=1; }
  done
  rm -rf "$tmp"
  return "$rc"
}

run_artifact_regen() {
  if [ -f data/mnist.npz ]; then
    check "artifacts regenerate byte-identically (quantize + export)" check_artifacts_reproducible
  else
    skip "artifacts regenerate byte-identically (no MNIST cache in data/)"
  fi
}

# ---------------------------------------------------------------- phases
phase_0() {
  echo "Phase 0: toolchain"
  check "tool versions (python 3.14 venv, icarus 12, verilator >= 5.036, yosys, sby)" check_tool_versions
  check "counter test passes on icarus and verilator" check_pytest counter 2 testbench/unit/test_counter.py
  check "RTL lint (verilator -Wall, iverilog, yosys)" scripts/lint.sh
  check "ruff format + ruff check clean" check_ruff
  run_local_checks "optional local repository checks"
  check "latest CI run on main is green for HEAD" check_ci_green_on_head
}

phase_1() {
  echo "Phase 1: model and spec"
  check "integer accuracy within 1% of float on the full test set (model/reports/quantize.json)" check_accuracy_report
  check "golden model tests (quick-subset logits bit-exact, primitives, artifacts)" check_pytest model 20 model/tests
  run_artifact_regen
  check "spec.md and verification_plan.md present" check_docs_exist docs/spec.md docs/verification_plan.md
  check "ruff format + ruff check clean" check_ruff
  run_local_checks "optional local repository checks"
  check "latest CI run on main is green for HEAD" check_ci_green_on_head
}

phase="${1:-}"
case "$phase" in
  0) phase_0 ;;
  1) phase_1 ;;
  *) echo "usage: $0 <phase>   (implemented: 0, 1)" >&2; exit 2 ;;
esac

echo
if [ "$failures" -eq 0 ]; then
  echo "CHECKPOINT $phase: PASS"
  exit 0
fi
echo "CHECKPOINT $phase: FAIL ($failures check(s) failed)"
exit 1
