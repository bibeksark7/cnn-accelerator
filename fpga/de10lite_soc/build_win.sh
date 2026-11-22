#!/usr/bin/env bash
# Build the RISC-V SoC for the DE10-Lite with Windows Quartus Prime Lite from WSL (spec §13.7).
#
# Builds the demo firmware (firmware/apps/demo) into the RAM image demo.hex, copies the RTL
# (flat), PicoRV32, the FPGA files and the init files to a Windows build directory, runs
# build.tcl (full compile) and the Milestone 1 build's sta_reports.tcl for this project, and copies
# the reports back to fpga/de10lite_soc/reports/, with every Quartus warning in warnings.txt
# (checked against fpga/de10lite_soc/expected_warnings.txt by scripts/check_quartus_warnings.py).
# The programming files stay in the build directory: de10lite_soc.sof (SRAM) and
# de10lite_soc.pof (internal flash). The board is programmed from Windows.
#
# Environment:
#   QUARTUS_ROOT  Quartus install (default /mnt/c/intelFPGA_lite/22.1std/quartus)
#   BUILD_DIR     Windows-side build directory (default: <Windows profile>/fpga_build/de10lite_soc)
#   PYTHON        Python with NumPy, for the firmware's data generators (default: python3)
# Exit status: 0 success, 1 a step failed, 2 Quartus not available.
set -euo pipefail

QUARTUS_ROOT="${QUARTUS_ROOT:-/mnt/c/intelFPGA_lite/22.1std/quartus}"
QSH="$QUARTUS_ROOT/bin64/quartus_sh.exe"
QSTA="$QUARTUS_ROOT/bin64/quartus_sta.exe"
PYTHON="${PYTHON:-python3}"
[ -f "$QSH" ] || { echo "build_win: Quartus not found at $QSH" >&2; exit 2; }

repo="$(cd "$(dirname "$0")/../.." && pwd)"
here="$repo/fpga/de10lite_soc"
if [ -z "${BUILD_DIR:-}" ]; then
  win_profile="$(cd /mnt/c && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')"
  BUILD_DIR="$(wslpath "$win_profile")/fpga_build/de10lite_soc"
fi
fw_out="$repo/sim_build/firmware/demo_fpga"
rm -rf "$BUILD_DIR" "$fw_out"
mkdir -p "$BUILD_DIR" "$here/reports"
make -s -C "$repo/firmware" APP=demo OUT="$fw_out" PYTHON="$PYTHON"

# Provenance of this build, written to a temporary file first (the clean-tree check must not see
# it in the tree).
info_tmp="$(mktemp)"
python3 - "$repo" "$QSH" "$fw_out" > "$info_tmp" <<'PY'
import hashlib, json, subprocess, sys
repo, qsh, fw = sys.argv[1], sys.argv[2], sys.argv[3]
git = lambda *a: subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True).stdout.strip()
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
mem = f"{repo}/model/artifacts/mem"
version = subprocess.run([qsh, "--version"], capture_output=True, text=True).stdout
print(json.dumps({
    "script": "fpga/de10lite_soc/build_win.sh",
    "commit": git("rev-parse", "HEAD"),
    "rtl_tree": git("rev-parse", "HEAD:rtl"),
    "firmware_tree": git("rev-parse", "HEAD:firmware"),
    "picorv32_commit": git("rev-parse", "HEAD:third_party/picorv32"),
    "tree_clean": git("status", "--porcelain") == "",
    "init_files_sha256": {f"{n}.hex": sha(f"{mem}/{n}.hex") for n in ("img", "wgt", "param", "desc")},
    "firmware_hex_sha256": sha(f"{fw}/demo.hex"),
    "firmware_compiler": open(f"{fw}/toolchain.txt").read().strip(),
    "quartus": next((l.strip() for l in version.splitlines() if "Version" in l), "?"),
}, indent=2))
PY
mv "$info_tmp" "$here/reports/build_info.json"
find "$repo/rtl" -name '*.sv' -exec cp {} "$BUILD_DIR/" \;
cp "$repo/third_party/picorv32/picorv32.v" "$BUILD_DIR/"
cp "$here/build.tcl" "$here/de10lite_soc.sdc" "$BUILD_DIR/"
cp "$repo/fpga/de10lite/pins.tcl" "$repo/fpga/de10lite/sta_reports.tcl" "$BUILD_DIR/"
for f in img wgt param desc; do
  cp "$repo/model/artifacts/mem/$f.hex" "$BUILD_DIR/"
done
cp "$fw_out/demo.hex" "$BUILD_DIR/"

status=0
(cd "$BUILD_DIR" && "$QSH" -t build.tcl > quartus_sh.log 2>&1) || status=1
if [ "$status" -eq 0 ]; then
  (cd "$BUILD_DIR" && "$QSTA" -t sta_reports.tcl de10lite_soc > quartus_sta.log 2>&1) || status=1
fi

for f in de10lite_soc.sof de10lite_soc.pof; do
  [ -f "$BUILD_DIR/$f" ] || { echo "build_win: $f was not generated" >&2; status=1; }
done

for f in de10lite_soc.map.summary de10lite_soc.fit.summary de10lite_soc.sta.summary \
         timing_corners.rpt timing_setup_worst.rpt timing_hold_worst.rpt timing_summary_setup.rpt \
         timing_summary_hold.rpt fmax.rpt unconstrained_paths.rpt mtbf.rpt; do
  [ -f "$BUILD_DIR/$f" ] && cp "$BUILD_DIR/$f" "$here/reports/"
done
# Resource use by entity (CPU, accelerator, bus, RAM): the fitter's hierarchy table.
if [ -f "$BUILD_DIR/de10lite_soc.fit.rpt" ]; then
  python3 - "$BUILD_DIR/de10lite_soc.fit.rpt" > "$here/reports/resources_by_entity.rpt" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="latin-1").read()
start = text.index("; Fitter Resource Utilization by Entity")
end = text.index("\n\n", start)
print(text[start:end])
for key in ("; M9Ks ", "; Total block memory bits", "; Embedded Multiplier 9-bit elements"):
    m = re.search(re.escape(key) + r"[^\n]*", text)
    if m:
        print(m.group(0))
PY
fi
logs=("$BUILD_DIR/quartus_sh.log")
[ -f "$BUILD_DIR/quartus_sta.log" ] && logs+=("$BUILD_DIR/quartus_sta.log")
grep -hE "^(Error|Critical Warning|Warning) \(" "${logs[@]}" | sed 's/ File: .*//' \
  > "$here/reports/messages.txt" || true
grep -hE "was (un)?successful" "${logs[@]}" >> "$here/reports/messages.txt" || true
grep -hE "^ *(Error|Critical Warning|Warning) \(" "${logs[@]}" | sed -E 's/ File: .*//; s/^ +//' \
  > "$here/reports/warnings.txt" || true
echo "build_win: $( [ "$status" -eq 0 ] && echo success || echo FAILED ) ($BUILD_DIR/de10lite_soc.sof, $BUILD_DIR/de10lite_soc.pof)"
exit "$status"
