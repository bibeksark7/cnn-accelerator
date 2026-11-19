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

# No RTL mutant may be applied to the working tree: reversing a patch must fail for every patch.
check_no_mutant_applied() {
  local p rc=0 n=0
  for p in testbench/mutants/*.patch; do
    n=$((n + 1))
    if git apply -R --check "$p" >/dev/null 2>&1; then
      echo "mutant is applied to the working tree: $p"; rc=1
    fi
  done
  [ "$n" -gt 0 ] || { echo "no mutant patches found"; return 1; }
  [ "$rc" -ne 0 ] || echo "$n patches, none applied"
  return "$rc"
}

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

# Quartus Analysis & Synthesis probe of every RTL module as top (local only: Quartus is a
# Windows install). SKIPs when Quartus is not available (quartus_probe.sh exits 2).
run_quartus_probes() {
  local f top rc=0 status
  mapfile -t rtl_files < <(find rtl -name '*.sv' | sort)
  for f in "${rtl_files[@]}"; do
    top="$(basename "$f" .sv)"
    status=0
    scripts/quartus_probe.sh --out "sim_build/quartus/$top" "$top" "${rtl_files[@]}" \
      >"$REPORT_DIR/quartus_$top.log" 2>&1 || status=$?
    if [ "$status" -eq 2 ]; then
      skip "Quartus Analysis & Synthesis probes (Quartus not available)"
      return 0
    fi
    if [ "$status" -ne 0 ]; then
      echo "  quartus probe failed for $top:"; sed 's/^/    /' "sim_build/quartus/$top/messages.txt"
      rc=1
    fi
  done
  if [ "$rc" -eq 0 ]; then pass "Quartus Analysis & Synthesis probes (${#rtl_files[@]} modules)"; else fail "Quartus Analysis & Synthesis probes"; fi
}

# Phase 3 helpers.
# The quick subset passed bit-exact in this checkpoint's own system-test run: its JUnit file
# ($REPORT_DIR/system.xml) has the Verilator main node passing, and that node's cocotb results
# file, written during this checkpoint (newer than the phase stamp), has the network test passing.
check_quick_subset() {
  REPORT_DIR="$REPORT_DIR" python - <<'PY'
import glob, os, sys, xml.etree.ElementTree as ET
rd = os.environ["REPORT_DIR"]
node = "test_accel_top[verilator-main-50]"
cases = [tc for tc in ET.parse(f"{rd}/system.xml").iter("testcase") if tc.get("name") == node]
ok_node = len(cases) == 1 and all(cases[0].find(t) is None for t in ("failure", "error", "skipped"))
stamp = os.path.getmtime(f"{rd}/phase3.start")
files = [f for f in glob.glob("sim_build/accel_top_verilator_*/test_accel_top[[]verilator-main-50[]].result.xml")
         if os.path.getmtime(f) >= stamp]
ok_net = False
for f in files:
    for tc in ET.parse(f).iter("testcase"):
        if tc.get("name") == "test_network_quick_subset":
            ok_net = all(tc.find(t) is None for t in ("failure", "error", "skipped"))
print(f"{rd}/system.xml: {node} {'passed' if ok_node else 'NOT passed'}; "
      f"fresh cocotb results {files}: test_network_quick_subset {'passed' if ok_net else 'NOT passed'}")
sys.exit(0 if ok_node and ok_net else 1)
PY
}

# Full run report: at least 1,000 images, every logit bit-exact, every run DONE without error,
# and evidence for this tree: the recorded RTL tree is HEAD:rtl, the init files are unchanged,
# the run started from a clean tree, and both reports carry the same provenance.
check_full_run_report() {
  RTL_TREE="$(git rev-parse HEAD:rtl)" python - <<'PY'
import hashlib, json, os, sys
r = json.load(open("testbench/reports/full_run.json"))
perf = json.load(open("testbench/reports/perf_counters.json"))
n, prov = r["images"], r.get("provenance", {})
print(f"{n} images, {r['logits_bit_exact']} bit-exact, {r['status_done_no_error']} clean runs, "
      f"hardware accuracy {r['hardware_accuracy']:.4f}")
problems = []
if not (n >= 1000 and r["logits_bit_exact"] == n and r["status_done_no_error"] == n):
    problems.append("not every image bit-exact and clean")
if prov.get("rtl_tree") != os.environ["RTL_TREE"]:
    problems.append(f"RTL tree {prov.get('rtl_tree')} != HEAD:rtl {os.environ['RTL_TREE']}")
for f, h in prov.get("init_files_sha256", {"(none recorded)": ""}).items():
    path = os.path.join("model/artifacts/mem", f)
    if not os.path.exists(path) or hashlib.sha256(open(path, "rb").read()).hexdigest() != h:
        problems.append(f"init file {f} differs from the one the run used")
if not prov.get("tree_clean"):
    problems.append("the run did not start from a clean tree")
if perf.get("provenance") != prov:
    problems.append("perf_counters.json provenance differs from full_run.json")
print(f"provenance: commit {prov.get('commit', '?')[:12]}, rtl {prov.get('rtl_tree', '?')[:12]}, "
      f"{prov.get('verilator', '?')}")
for p in problems:
    print("  ", p)
sys.exit(1 if problems else 0)
PY
}

# Coverage: the files written by this checkpoint's own unit/system runs meet every goal or have a
# documented gap, and the committed report says the same (no missed bin).
check_coverage() {
  python scripts/coverage_report.py --check || return 1
  python - <<'PY'
import json, sys
r = json.load(open("testbench/reports/coverage.json"))
print(f"committed report: {r['bins']} bins, {r['met']} met, {r['documented_gaps']} documented gaps, "
      f"{r['missed']} missed")
sys.exit(0 if r["missed"] == 0 and r["met"] + r["documented_gaps"] == r["bins"] else 1)
PY
}

# Every mutant killed in a fresh run, and the committed report covers every patch, all killed.
check_mutants() {
  local n killed
  python scripts/run_mutants.py -j 4 --report "$REPORT_DIR/mutation.md" || return 1
  n="$(ls testbench/mutants/*.patch | wc -l)"
  killed="$(grep -c '| KILLED |' testbench/reports/mutation.md)"
  echo "committed report: $killed KILLED rows for $n patches"
  [ "$killed" -eq "$n" ]
}

# ---------------------------------------------------------------- phases
phase_0() {
  echo "Phase 0: toolchain"
  check "tool versions (python 3.14 venv, icarus 12, verilator >= 5.036, yosys, sby)" check_tool_versions
  check "unit tests pass on icarus and verilator (counter replaced by real RTL in Phase 2)" check_pytest unit 2 testbench/unit
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

phase_2() {
  echo "Phase 2: core RTL"
  check "unit tests pass (testbench/unit, Icarus and Verilator with SVA)" check_pytest unit 10 testbench/unit
  check "system tests pass (accel_top: quick subset bit-exact, CSR, memory port, errors, reset)" check_pytest system 3 testbench/system
  check "script tests pass (lint fixtures, Quartus compatibility checker)" check_pytest scripts 10 scripts/tests
  check "no RTL mutant applied to the working tree (git apply -R --check fails for every patch)" check_no_mutant_applied
  check "RTL lint (Quartus compat, Verilator -Wall, Icarus, Yosys check)" scripts/lint.sh
  check "ruff format + ruff check clean" check_ruff
  run_quartus_probes
  run_local_checks "optional local repository checks"
  check "latest CI run on main is green for HEAD" check_ci_green_on_head
}

phase_3() {
  echo "Phase 3: verification"
  rm -f sim_build/*/coverage.json  # coverage below comes from this run only
  touch "$REPORT_DIR/phase3.start"
  check "unit tests pass (testbench/unit, Icarus and Verilator with SVA)" check_pytest unit 10 testbench/unit
  check "system tests pass (accel_top: CSR, memory port, errors, reset, layer by layer, SVA fires)" check_pytest system 5 testbench/system
  check "quick subset (50 images) bit-exact on Verilator with every assertion bound" check_quick_subset
  check "full run report: >= 1,000 MNIST test images, 100% logit match (testbench/reports/full_run.json)" check_full_run_report
  check "functional coverage: goals met or gaps documented (scripts/coverage_report.py --check)" check_coverage
  check "formal proofs pass, and fail on their mutants (testbench/formal)" check_pytest formal 12 testbench/formal
  check "every mutant killed (scripts/run_mutants.py; committed report complete)" check_mutants
  check "script tests pass (lint fixtures, Quartus compatibility checker, mutant patches)" check_pytest scripts 10 scripts/tests
  check "golden model tests" check_pytest model 20 model/tests
  check "no RTL mutant applied to the working tree (git apply -R --check fails for every patch)" check_no_mutant_applied
  check "RTL lint (Quartus compat, Verilator -Wall, Icarus, Yosys check)" scripts/lint.sh
  check "ruff format + ruff check clean" check_ruff
  run_quartus_probes
  run_local_checks "optional local repository checks"
  check "latest CI run on main is green for HEAD" check_ci_green_on_head
}

phase="${1:-}"
case "$phase" in
  0) phase_0 ;;
  1) phase_1 ;;
  2) phase_2 ;;
  3) phase_3 ;;
  *) echo "usage: $0 <phase>   (implemented: 0, 1, 2, 3)" >&2; exit 2 ;;
esac

echo
if [ "$failures" -eq 0 ]; then
  echo "CHECKPOINT $phase: PASS"
  exit 0
fi
echo "CHECKPOINT $phase: FAIL ($failures check(s) failed)"
exit 1
