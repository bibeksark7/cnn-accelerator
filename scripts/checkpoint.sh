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
pass_note=""
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

# The full CI job (.github/workflows/full.yml: every test, formal included) passed for HEAD: the
# most recent full.yml run of HEAD whose "Full regression" job ran is completed and green. The
# fast workflow (ci.yml) runs a subset on every push and is not enough for a checkpoint. Trigger
# a run with: gh workflow run full.yml --ref main
check_ci_green_on_head() {
  local head
  head="$(git rev-parse HEAD)"
  [ -z "$(git status --porcelain)" ] || { echo "uncommitted or untracked changes:"; git status --short; return 1; }
  [ "$(git rev-parse '@{u}' 2>/dev/null)" = "$head" ] || { echo "HEAD is not pushed to its upstream"; return 1; }
  HEAD_SHA="$head" python - <<'PY'
import json, os, subprocess, sys
head = os.environ["HEAD_SHA"]
def gh(*args):
    return json.loads(subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout)
runs = gh("run", "list", "--workflow", "full.yml", "--branch", "main", "--commit", head, "--limit", "20",
          "--json", "databaseId,status,conclusion,url,createdAt,event")
for r in sorted(runs, key=lambda r: r["createdAt"], reverse=True):
    jobs = [j for j in gh("run", "view", str(r["databaseId"]), "--json", "jobs")["jobs"]
            if j["name"] == "Full regression"]
    if not jobs or jobs[0]["conclusion"] == "skipped":
        continue  # a nightly run skipped because this commit already had a green full run
    j = jobs[0]
    print(f"full.yml run for HEAD {head[:12]} ({r['event']}): {r['url']}  job {j['status']}/{j['conclusion']}")
    sys.exit(0 if j["status"] == "completed" and j["conclusion"] == "success" else 1)
print(f"no full.yml run with the full job for HEAD {head[:12]} (gh workflow run full.yml --ref main)")
sys.exit(1)
PY
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
  for f in artifacts/params.npz artifacts/quick_subset.npz artifacts/saturation_subset.npz \
           artifacts/mem/wgt.hex \
           artifacts/mem/param.hex artifacts/mem/desc.hex artifacts/mem/layout.json \
           artifacts/mem/img.hex artifacts/mem/label.hex artifacts/mem/demo.json \
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
# and evidence for this tree: the recorded RTL tree is the M1 RTL tree (scripts/m1_rtl_tree.sh:
# HEAD:rtl without the SoC-only rtl/axi and rtl/soc, D-045), the init files are unchanged,
# the run started from a clean tree, and both reports carry the same provenance.
check_full_run_report() {
  RTL_TREE="$(scripts/m1_rtl_tree.sh)" python - <<'PY'
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
    problems.append(f"RTL tree {prov.get('rtl_tree')} != M1 RTL tree {os.environ['RTL_TREE']}")
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
  check "full CI job (full.yml) green for HEAD" check_ci_green_on_head
}

phase_1() {
  echo "Phase 1: model and spec"
  check "integer accuracy within 1% of float on the full test set (model/reports/quantize.json)" check_accuracy_report
  check "golden model tests (quick-subset logits bit-exact, primitives, artifacts)" check_pytest model 20 model/tests
  run_artifact_regen
  check "spec.md and verification_plan.md present" check_docs_exist docs/spec.md docs/verification_plan.md
  check "ruff format + ruff check clean" check_ruff
  run_local_checks "optional local repository checks"
  check "full CI job (full.yml) green for HEAD" check_ci_green_on_head
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
  check "full CI job (full.yml) green for HEAD" check_ci_green_on_head
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
  check "formal proofs pass, and fail on their mutants (testbench/formal)" check_pytest formal 17 testbench/formal
  check "every mutant killed (scripts/run_mutants.py; committed report complete)" check_mutants
  check "script tests pass (lint fixtures, Quartus compatibility checker, mutant patches)" check_pytest scripts 10 scripts/tests
  check "golden model tests" check_pytest model 20 model/tests
  check "no RTL mutant applied to the working tree (git apply -R --check fails for every patch)" check_no_mutant_applied
  check "RTL lint (Quartus compat, Verilator -Wall, Icarus, Yosys check)" scripts/lint.sh
  check "ruff format + ruff check clean" check_ruff
  run_quartus_probes
  run_local_checks "optional local repository checks"
  check "full CI job (full.yml) green for HEAD" check_ci_green_on_head
}

# A DE10-Lite build closes timing at 50 MHz with every path constrained, and its reports are
# evidence for this tree. check_fpga_build <build dir> <project> <synchronizer chains> <provenance>
# where <provenance> is a JSON object of build_info.json fields that must have these values.
# Phase 4: fpga/de10lite, the M1 RTL tree (scripts/m1_rtl_tree.sh), 6 chains (SW[3:0], KEY[1:0]).
# Phase 5: fpga/de10lite_soc, HEAD:rtl + the PicoRV32 commit, 12 chains (SW[9:0], KEY[1:0]); its
# firmware image is checked by check_soc_firmware_image.
check_fpga_build() {
  FPGA_DIR="$1" PROJECT="$2" CHAINS="$3" EXPECT="$4" python - <<'PY'
import hashlib, json, os, re, sys
d = os.environ["FPGA_DIR"] + "/reports"
info = json.load(open(f"{d}/build_info.json"))
sta = open(f"{d}/{os.environ['PROJECT']}.sta.summary").read()
slacks = {m.group(1): float(m.group(2)) for m in
          re.finditer(r"Type\s*:\s*(.+?)\nSlack\s*:\s*(-?[\d.]+)", sta)}
# Every operating condition (corner): the minimum slack over all of them must be positive.
CORNERS = {"Slow 1200mV 85C Model", "Slow 1200mV 0C Model", "Fast 1200mV 0C Model"}
setup = {k.split(" Setup")[0]: v for k, v in slacks.items() if "Setup 'clk50'" in k}
hold = {k.split(" Hold")[0]: v for k, v in slacks.items() if "Hold 'clk50'" in k}
ucp = open(f"{d}/unconstrained_paths.rpt").read()
counts = [int(x) for x in re.findall(r";\s*Unconstrained[^;]*;\s*(\d+)\s*;\s*(\d+)", ucp) for x in x]
problems = []
if set(setup) != CORNERS or set(hold) != CORNERS:
    problems.append(f"corners in the .sta.summary: setup {sorted(setup)}, hold {sorted(hold)}")
if not setup or min(setup.values()) <= 0: problems.append(f"setup slack {setup}")
if not hold or min(hold.values()) <= 0: problems.append(f"hold slack {hold}")
# sta_reports.tcl's per-corner table must agree with the Quartus summary.
rows = [l.split(";") for l in open(f"{d}/timing_corners.rpt").read().splitlines()
        if l and not l.startswith(("#", "corner;"))]
per_corner = {r[0]: (float(r[1]), float(r[2])) for r in rows}
if set(per_corner) != CORNERS:
    problems.append(f"corners in timing_corners.rpt: {sorted(per_corner)}")
for c, (s, h) in per_corner.items():
    if abs(s - setup.get(c, 1e9)) > 5e-4 or abs(h - hold.get(c, 1e9)) > 5e-4:
        problems.append(f"{c}: timing_corners.rpt {s}/{h} differs from the .sta.summary")
# Synchronizers: CHAINS chains of 2 registers each, MTBF known, every corner.
mtbf = open(f"{d}/mtbf.rpt").read()
chains = re.findall(r"Number of Synchronizer Chains Found: (\d+)", mtbf)
shortest = re.findall(r"Shortest Synchronizer Chain: (\d+) Registers", mtbf)
unknown = re.findall(r"Fraction of Chains for which MTBFs Could Not be Calculated: ([\d.]+)", mtbf)
design_mtbf = re.findall(r"Worst-Case MTBF of Design is (\S+) years", mtbf)
if not (len(chains) == len(CORNERS) and set(chains) == {os.environ["CHAINS"]} and set(shortest) == {"2"}
        and unknown and all(float(u) == 0 for u in unknown)):
    problems.append(f"mtbf.rpt: chains {chains}, shortest {shortest}, unknown {unknown}")
if not counts or any(counts): problems.append(f"unconstrained paths: {counts}")
if "Illegal Clocks" not in ucp: problems.append("unconstrained-paths report incomplete")
for k, v in json.loads(os.environ["EXPECT"]).items():
    if info.get(k) != v: problems.append(f"build_info {k} {info.get(k)} != {v}")
if not info.get("tree_clean"): problems.append("build did not start from a clean tree")
for f, h in info.get("init_files_sha256", {}).items():
    if hashlib.sha256(open(f"model/artifacts/mem/{f}", "rb").read()).hexdigest() != h:
        problems.append(f"{f} changed since the build")
print(f"worst setup {min(setup.values(), default=0):+.3f} ns, worst hold {min(hold.values(), default=0):+.3f} ns "
      f"(minimum over {len(setup)} corners), unconstrained paths {sum(counts)}, "
      f"build of commit {info.get('commit', '?')[:12]}")
for c in sorted(CORNERS):
    print(f"  {c}: setup {setup.get(c, float('nan')):+.3f} ns, hold {hold.get(c, float('nan')):+.3f} ns")
print(f"  synchronizers: {chains[0] if chains else '?'} chains, shortest {shortest[0] if shortest else '?'} "
      f"registers, worst-case design MTBF {min(design_mtbf, key=float, default='?')} years")
for p in problems: print("  ", p)
sys.exit(1 if problems else 0)
PY
}

# The README's results table links every number to a committed report.
check_readme_results() {
  python - <<'PY'
import re, subprocess, sys
text = open("README.md").read()
m = re.search(r"\n## Results\n(.*?)(\n## |\Z)", text, re.S)
if not m:
    print("README.md has no '## Results' section"); sys.exit(1)
rows = [l for l in m.group(1).splitlines() if l.startswith("|") and not set(l) <= set("|-: ")][1:]
tracked = set(subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.split())
bad = []
for row in rows:
    links = re.findall(r"\]\(([^)#]+)", row)
    if not links or not all(l in tracked for l in links):
        bad.append(row)
print(f"{len(rows)} result rows; rows without a committed report link: {len(bad)}")
for b in bad: print("  ", b)
sys.exit(1 if bad or not rows else 0)
PY
}

phase_4() {
  echo "Phase 4: FPGA demo"
  check "unit tests pass (testbench/unit, incl. the board I/O blocks)" check_pytest unit 10 testbench/unit
  check "system tests pass (accel_top, fpga_core bring-up and demo runs, de10lite_top)" check_pytest system 7 testbench/system
  check "formal proofs pass, and fail on their mutants (testbench/formal)" check_pytest formal 17 testbench/formal
  check "script and golden model tests" check_pytest scripts_model 30 scripts/tests model/tests
  check "RTL lint (Quartus compat, Verilator -Wall, Icarus, Yosys check)" scripts/lint.sh
  check "ruff format + ruff check clean" check_ruff
  check "DE10-Lite build: positive setup and hold slack at 50 MHz in every corner, no unconstrained paths, synchronizer MTBF, reports of the M1 RTL tree" check_fpga_build fpga/de10lite de10lite 6 "{\"rtl_tree\": \"$(scripts/m1_rtl_tree.sh)\"}"
  check "DE10-Lite build: every Quartus warning listed in fpga/de10lite/expected_warnings.txt" python scripts/check_quartus_warnings.py
  check "README results table: every row links a committed report" check_readme_results
  check "README and architecture FPGA numbers (Fmax, slack, LEs, resources) match the committed build reports" python scripts/check_fpga_numbers.py
  check "README badges match the committed coverage and mutation reports" python scripts/readme_badges.py --check
  run_local_checks "optional local repository checks"
  check "full CI job (full.yml) green for HEAD" check_ci_green_on_head
  if [ -f fpga/de10lite/demo.md ]; then
    echo "  [BOARD] demo confirmed on the board: fpga/de10lite/demo.md"
  else
    echo "  [BOARD] demo not yet confirmed on the board (fpga/de10lite/demo.md does not exist)"
    pass_note=" (board confirmation pending)"
  fi
}

# Phase 5: the SoC tests of this checkpoint's system run passed (by name, so a skipped or
# deselected one cannot count).
check_soc_tests() {
  python - <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse("sim_build/checkpoint/system.xml").getroot()
want = ["test_accel_axil", "test_soc[smoke]", "test_soc[quick]", "test_soc[demo]", "test_soc_demo_timeout",
        "test_soc_bench", "test_de10lite_soc_top",
        "test_soc_bus_check_fires[buserr-a_no_write_error]", "test_soc_bus_check_fires[trap-a_no_trap]"]
cases = {c.get("name"): c for c in root.iter("testcase")}
bad = [n for n in want if n not in cases or any(ch.tag in ("failure", "error", "skipped") for ch in cases[n])]
print(f"{len(want) - len(bad)}/{len(want)} SoC tests passed: " + ", ".join(n for n in want if n not in bad))
for n in bad: print(f"  missing or not passed: {n}")
sys.exit(1 if bad else 0)
PY
}

# Phase 5: the speedup report (scripts/soc_speedup.py) is evidence for this tree: at least 4
# images, measured on HEAD's RTL, firmware and PicoRV32 from a clean tree, and its speedups follow
# from its own cycle counts.
check_speedup_report() {
  RTL="$(git rev-parse HEAD:rtl)" FW="$(git rev-parse HEAD:firmware)" \
  CPU="$(git rev-parse HEAD:third_party/picorv32)" python - <<'PY'
import json, os, sys
r = json.load(open("testbench/reports/soc_speedup.json"))
s, prov, rows = r["summary"], r["provenance"], r["per_image"]
problems = []
if s["images"] < 4 or len(rows) != s["images"]: problems.append(f"{s['images']} images (need >= 4)")
for k, env in (("rtl_tree", "RTL"), ("firmware_tree", "FW"), ("picorv32_commit", "CPU")):
    if prov.get(k) != os.environ[env]: problems.append(f"{k} {prov.get(k)} != HEAD's {os.environ[env]}")
if not prov.get("tree_clean"): problems.append("measured from a dirty tree")
m = s["mean_cycles"]
if abs(s["speedup_end_to_end"] - m["software"] / m["end_to_end"]) > 1e-9: problems.append("speedup inconsistent")
if abs(s["speedup_with_upload"] - m["software"] / (m["upload"] + m["end_to_end"])) > 1e-9: problems.append("speedup with upload inconsistent")
# Instruction-count bound: speedup against an ideal one-instruction-per-cycle core, same clock.
if abs(s.get("ipc1_bound_end_to_end", 0) - m["software_instret"] / m["end_to_end"]) > 1e-9: problems.append("instruction-count bound (end to end) missing or inconsistent")
if abs(s.get("ipc1_bound_with_upload", 0) - m["software_instret"] / (m["upload"] + m["end_to_end"])) > 1e-9: problems.append("instruction-count bound (with upload) missing or inconsistent")
md = open("testbench/reports/soc_speedup.md").read()
for k in ("ipc1_bound_end_to_end", "ipc1_bound_with_upload"):
    if k in s and f"{s[k]:.1f}x" not in md: problems.append(f"soc_speedup.md does not state {k} {s[k]:.1f}x")
# README: every speedup figure ("375.0×") is one of the report's four, and all four are stated.
import re
readme = open("README.md").read()
allowed = {f"{s[k]:.1f}" for k in ("speedup_end_to_end", "speedup_with_upload", "ipc1_bound_end_to_end", "ipc1_bound_with_upload") if k in s}
quoted = re.findall(r"\b(\d+(?:\.\d+)?)\s?[×x](?=\W)", readme)
quoted = [q for q in quoted if "." in q]  # "8×8" is the array size, not a speedup
problems += [f"README speedup {q}x not in the report ({sorted(allowed)})" for q in quoted if q not in allowed]
problems += [f"README does not state the {a}x speedup" for a in sorted(allowed) if a not in quoted]
print(f"{s['images']} images: software {m['software']:,.0f} cycles, end to end {m['end_to_end']:,.0f}, "
      f"speedup {s['speedup_end_to_end']:.1f}x ({s['speedup_with_upload']:.1f}x with upload); "
      f"ideal 1-IPC core: {s.get('ipc1_bound_end_to_end', 0):.1f}x ({s.get('ipc1_bound_with_upload', 0):.1f}x with upload); "
      f"{r['firmware_compiler']}")
for p in problems: print("  ", p)
sys.exit(1 if problems else 0)
PY
}

# Phase 5: the SoC RAM is block RAM (BUG-015): axil_ram holds all 64 KB in M9K memory bits.
check_soc_ram_in_block_ram() {
  python - <<'PY'
import re, sys
rows = open("fpga/de10lite_soc/reports/resources_by_entity.rpt").read().splitlines()
row = next((r for r in rows if "|axil_ram:u_axil_ram|" in r), None)
if row is None:
    print("no axil_ram row in resources_by_entity.rpt"); sys.exit(1)
cols = [c.strip() for c in row.split(";")]
lcs, mem_bits, m9k = cols[2], int(cols[5]), int(cols[6])
print(f"axil_ram: {lcs} logic cells, {mem_bits:,} memory bits in {m9k} M9K blocks")
sys.exit(0 if mem_bits == 65536 * 8 and m9k > 0 else 1)
PY
}

# Phase 5: the SoC build's RAM image is the demo firmware of HEAD: rebuilt from HEAD with the
# same compiler, its image equals the one the build used (byte for byte, sha256). This holds even
# when other apps under firmware/ change after the build.
check_soc_firmware_image() {
  local out=sim_build/checkpoint/demo_fw
  rm -rf "$out"
  make -s -C firmware APP=demo OUT="$PWD/$out" PYTHON="$(command -v python)" >/dev/null || return 1
  OUT="$out" python - <<'PY'
import hashlib, json, os, sys
info = json.load(open("fpga/de10lite_soc/reports/build_info.json"))
out = os.environ["OUT"]
cc = open(f"{out}/toolchain.txt").read().strip()
h = hashlib.sha256(open(f"{out}/demo.hex", "rb").read()).hexdigest()
print(f"demo firmware from HEAD: sha256 {h[:16]}…, {cc}; build used {info['firmware_hex_sha256'][:16]}…")
if cc != info["firmware_compiler"]:
    print(f"  compiler differs from the build's ({info['firmware_compiler']})"); sys.exit(1)
sys.exit(0 if h == info["firmware_hex_sha256"] else 1)
PY
}

phase_5() {
  echo "Phase 5: RISC-V SoC with AXI4-Lite"
  check "unit tests pass (testbench/unit, incl. the AXI4-Lite blocks)" check_pytest unit 15 testbench/unit
  check "system tests pass (accel_top, FPGA tops, accelerator AXI slave, SoC firmware, SoC board top)" check_pytest system 15 testbench/system
  check "SoC: accelerator slave, firmware quick subset (50 images bit-exact), smoke, bench, board demo, demo timeout, board top, bus check live" check_soc_tests
  check "formal proofs pass, and fail on their mutants (testbench/formal)" check_pytest formal 17 testbench/formal
  check "script and golden model tests (incl. the software CNN against the golden model)" check_pytest scripts_model 30 scripts/tests model/tests
  check "RTL lint (Quartus compat, Verilator -Wall, Icarus, Yosys check)" scripts/lint.sh
  check "ruff format + ruff check clean" check_ruff
  check "speedup report (testbench/reports/soc_speedup.json) measured on HEAD's RTL, firmware and CPU; README speedups match it" check_speedup_report
  check "every mutant killed, accelerator and SoC blocks (scripts/run_mutants.py; committed report complete)" check_mutants
  check "README and architecture FPGA numbers match the committed build reports (M1, and the marked SoC region)" python scripts/check_fpga_numbers.py
  check "README badges match the committed coverage and mutation reports" python scripts/readme_badges.py --check
  check "SoC build: positive setup and hold slack at 50 MHz in every corner, no unconstrained paths, synchronizer MTBF, reports of HEAD's RTL and PicoRV32" check_fpga_build fpga/de10lite_soc de10lite_soc 12 "{\"rtl_tree\": \"$(git rev-parse HEAD:rtl)\", \"picorv32_commit\": \"$(git rev-parse HEAD:third_party/picorv32)\"}"
  check "SoC build: its RAM image is HEAD's demo firmware (rebuilt, same compiler, same sha256)" check_soc_firmware_image
  check "SoC build: the 64 KB RAM is block RAM (BUG-015)" check_soc_ram_in_block_ram
  check "SoC build: every Quartus warning listed in fpga/de10lite_soc/expected_warnings.txt" python scripts/check_quartus_warnings.py --reports fpga/de10lite_soc/reports --expected fpga/de10lite_soc/expected_warnings.txt
  check "Milestone 1 evidence still valid: full run report of the M1 RTL tree" check_full_run_report
  check "Milestone 1 evidence still valid: DE10-Lite build of the M1 RTL tree" check_fpga_build fpga/de10lite de10lite 6 "{\"rtl_tree\": \"$(scripts/m1_rtl_tree.sh)\"}"
  run_local_checks "optional local repository checks"
  check "full CI job (full.yml) green for HEAD" check_ci_green_on_head
  if [ -f fpga/de10lite_soc/demo.md ]; then
    echo "  [BOARD] SoC demo confirmed on the board: fpga/de10lite_soc/demo.md"
  else
    echo "  [BOARD] SoC demo not yet confirmed on the board (fpga/de10lite_soc/demo.md does not exist)"
    pass_note=" (board confirmation pending)"
  fi
}

# Phase 6: the UVM tests of this checkpoint's run passed, by name (a deselected one cannot count).
check_uvm_tests() {
  python - <<'PY'
import sys, xml.etree.ElementTree as ET
sys.path[:0] = ["testbench", "testbench/uvm"]
root = ET.parse("sim_build/checkpoint/uvm.xml").getroot()
import test_uvm
want = [f"test_uvm[{t}]" for t in test_uvm.TESTS]
want += [f"test_uvm_violation[{c}]" for c in test_uvm.VIOLATIONS] + ["test_uvm_coverage"]
cases = {c.get("name"): c for c in root.iter("testcase")}
bad = [n for n in want if n not in cases or any(ch.tag in ("failure", "error", "skipped") for ch in cases[n])]
print(f"{len(want) - len(bad)}/{len(want)} UVM tests passed: " + ", ".join(n for n in want if n not in bad))
for n in bad: print(f"  missing or not passed: {n}")
sys.exit(1 if bad else 0)
PY
}

# Phase 6: the committed UVM coverage report is this tree's: same result as this checkpoint's run,
# generated from a clean tree of HEAD's RTL, bench and uvm-core, goal met.
check_uvm_coverage_report() {
  RTL="$(git rev-parse HEAD:rtl)" UVM="$(git rev-parse HEAD:testbench/uvm)" \
  CORE="$(git rev-parse HEAD:third_party/uvm-core)" python - <<'PY'
import os, re, sys
committed = open("testbench/reports/uvm_coverage.md").read()
fresh = open("sim_build/uvm/uvm_coverage.md").read()
res = lambda t: re.search(r"^- Result: \*\*(.*)\*\*$", t, re.M).group(1)
problems = []
if res(committed) != res(fresh): problems.append(f"committed result '{res(committed)}' != this run's '{res(fresh)}'")
if "goal NOT met" in res(committed): problems.append("goal not met")
if "(tree clean)" not in committed: problems.append("generated from a dirty tree")
for k, env in (("RTL tree", "RTL"), ("UVM bench tree", "UVM"), ("uvm-core", "CORE")):
    m = re.search(rf"{k}: `([0-9a-f]+)`", committed)
    if not m or m.group(1) != os.environ[env]: problems.append(f"{k} {m and m.group(1)} != HEAD's {os.environ[env]}")
print(f"committed: {res(committed)}")
for p in problems: print("  " + p)
sys.exit(1 if problems else 0)
PY
}

# Phase 6: the committed per-run check counts (testbench/reports/uvm_checks.md) are this run's (the
# fixed seeds make them deterministic), from a clean tree, with no mismatch.
check_uvm_checks_report() {
  python - <<'PY'
import re, sys
rows = lambda t: [l for l in t.splitlines() if l.startswith("| `accel_") or l.startswith("| **all**")]
committed = open("testbench/reports/uvm_checks.md").read()
fresh = open("sim_build/uvm/uvm_checks.md").read()
problems = []
if rows(committed) != rows(fresh): problems.append("committed rows differ from this run's (sim_build/uvm/uvm_checks.md)")
if "(tree clean)" not in committed: problems.append("generated from a dirty tree")
if any(not l.rstrip().endswith("| 0 |") for l in rows(committed) if l.startswith("| `")): problems.append("a run with mismatches")
print(f"committed: {len(rows(committed)) - 1} runs; this run: {len(rows(fresh)) - 1} runs")
for p in problems: print("  " + p)
sys.exit(1 if problems else 0)
PY
}

# Phase 6: the committed seed-sweep report (testbench/reports/uvm_seed_sweep.md, generated with
# UVM_SEEDS=10) is for HEAD's RTL, bench and uvm-core, from a clean tree, every run passed and the
# coverage goal met over the sweep. The nightly full.yml job reruns a sweep with new seeds.
check_uvm_sweep_report() {
  RTL="$(git rev-parse HEAD:rtl)" UVM="$(git rev-parse HEAD:testbench/uvm)" \
  CORE="$(git rev-parse HEAD:third_party/uvm-core)" python - <<'PY'
import os, re, sys
t = open("testbench/reports/uvm_seed_sweep.md").read()
problems = []
res = re.search(r"^- Result: \*\*(.*)\*\*$", t, re.M)
seeds = re.search(r"^- Seeds: (\d+) random seeds per test .*?, (\d+) runs$", t, re.M)
runs = [l for l in t.splitlines() if l.startswith("| `accel_")]
if not res or "goal NOT met" in res.group(1): problems.append("coverage goal not met")
if not seeds or int(seeds.group(1)) < 10: problems.append("fewer than 10 seeds per test")
elif len(runs) != int(seeds.group(2)): problems.append(f"{len(runs)} run rows, header says {seeds.group(2)}")
if any(not l.rstrip().endswith("| 0 |") for l in runs): problems.append("a run with mismatches")
if "(tree clean)" not in t: problems.append("generated from a dirty tree")
for k, env in (("RTL tree", "RTL"), ("UVM bench tree", "UVM"), ("uvm-core", "CORE")):
    m = re.search(rf"{k}: `([0-9a-f]+)`", t)
    if not m or m.group(1) != os.environ[env]: problems.append(f"{k} {m and m.group(1)} != HEAD's {os.environ[env]}")
print(f"sweep: {res and res.group(1)}; {seeds and seeds.group(0)[2:]}")
for p in problems: print("  " + p)
sys.exit(1 if problems else 0)
PY
}

# Phase 6: every mutant of testbench/uvm/mutants.md killed by the UVM bench in a fresh run (one at
# a time: each rebuilds the bench), and the committed report lists every row, all killed.
check_uvm_mutants() {
  local n killed
  python scripts/run_mutants.py --table testbench/uvm/mutants.md -j 1 --report "$REPORT_DIR/uvm_mutation.md" || return 1
  n="$(grep -c '^| `m[0-9]' testbench/uvm/mutants.md)"
  killed="$(grep -c '| KILLED |' testbench/reports/uvm_mutation.md)"
  echo "committed report: $killed KILLED rows for $n mutants in the table"
  [ "$killed" -eq "$n" ]
}

# Phase 6: the README's UVM row quotes the committed UVM coverage, seed-sweep and mutation reports.
check_uvm_readme() {
  python - <<'PY'
import re, sys
row = [l for l in open("README.md").read().splitlines() if l.startswith("| UVM testbench")]
cov = re.search(r"Result: \*\*(\d+) bins, (\d+) met", open("testbench/reports/uvm_coverage.md").read())
sweep = open("testbench/reports/uvm_seed_sweep.md").read()
swc = re.search(r"Result: \*\*(\d+) bins, (\d+) met", sweep)
sws = re.search(r"^- Seeds: (\d+) random seeds per test .*?, (\d+) runs$", sweep, re.M)
mut = re.search(r"\*\*(\d+) / (\d+) mutants killed", open("testbench/reports/uvm_mutation.md").read())
want = [f"{cov[2]} / {cov[1]} coverage bins", f"{mut[1]} / {mut[2]} injected bugs caught",
        f"{sws[1]} random seeds per test", f"{swc[2]} / {swc[1]} bins over {sws[2]} runs"]
if len(row) != 1:
    print(f"README: {len(row)} UVM rows in the results table"); sys.exit(1)
missing = [w for w in want if w not in row[0]]
print(f"README UVM row states: {', '.join(w for w in want if w not in missing)}")
for w in missing: print(f"  README does not state '{w}' (from the reports)")
sys.exit(1 if missing else 0)
PY
}

check_uvm_core_pin() {
  local want=78c06547a2a0a29b3dc9dcafae62b75b2ff61544 have
  have="$(git rev-parse HEAD:third_party/uvm-core)"
  echo "third_party/uvm-core at $have (tag 2020.3.1 is $want)"
  [ "$have" = "$want" ] && [ "$(git -C third_party/uvm-core rev-parse HEAD)" = "$want" ]
}

phase_6() {
  echo "Phase 6: UVM testbench (accelerator AXI4-Lite slave)"
  check "uvm-core submodule pinned at 2020.3.1 and checked out (D-051)" check_uvm_core_pin
  check "UVM regression passes (testbench/uvm: 7 tests, 3 protocol-violation tests, coverage)" check_pytest uvm 11 testbench/uvm
  check "UVM: every test by name, incl. each deliberate violation failing through its channel's assertion" check_uvm_tests
  check "UVM coverage: goal met; committed report (testbench/reports/uvm_coverage.md) is this tree's and matches this run" check_uvm_coverage_report
  check "UVM scoreboard check counts: committed report (testbench/reports/uvm_checks.md) matches this run" check_uvm_checks_report
  check "UVM seed sweep: committed report (testbench/reports/uvm_seed_sweep.md) is this tree's, all runs passed, goal met" check_uvm_sweep_report
  check "UVM: every mutant in testbench/uvm/mutants.md killed (fresh run; committed report complete)" check_uvm_mutants
  check "README's UVM row matches the committed UVM coverage, seed-sweep and mutation reports" check_uvm_readme
  check "no RTL mutant applied to the working tree" check_no_mutant_applied
  check "unit tests pass (testbench/unit)" check_pytest unit 15 testbench/unit
  check "system tests pass (testbench/system)" check_pytest system 15 testbench/system
  check "formal proofs pass, and fail on their mutants (testbench/formal)" check_pytest formal 17 testbench/formal
  check "script and golden model tests (incl. the mutant tables)" check_pytest scripts_model 30 scripts/tests model/tests
  check "RTL lint (Quartus compat, Verilator -Wall, Icarus, Yosys check)" scripts/lint.sh
  check "ruff format + ruff check clean" check_ruff
  check "README badges match the committed coverage and mutation reports" python scripts/readme_badges.py --check
  check "README and architecture FPGA numbers match the committed build reports" python scripts/check_fpga_numbers.py
  check "docs present (spec, verification plan, decisions, bug log)" check_docs_exist docs/spec.md docs/verification_plan.md docs/decisions.md docs/bug_log.md
  run_local_checks "optional local repository checks"
  check "full CI job (full.yml, UVM included) green for HEAD" check_ci_green_on_head
}

phase="${1:-}"
case "$phase" in
  0) phase_0 ;;
  1) phase_1 ;;
  2) phase_2 ;;
  3) phase_3 ;;
  4) phase_4 ;;
  5) phase_5 ;;
  6) phase_6 ;;
  *) echo "usage: $0 <phase>   (implemented: 0, 1, 2, 3, 4, 5, 6)" >&2; exit 2 ;;
esac

echo
if [ "$failures" -eq 0 ]; then
  echo "CHECKPOINT $phase: PASS${pass_note:-}"
  exit 0
fi
echo "CHECKPOINT $phase: FAIL ($failures check(s) failed)"
exit 1
