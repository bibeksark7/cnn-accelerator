#!/usr/bin/env bash
# Build the DE10-Lite demo with Windows Quartus Prime Lite from WSL.
#
# Quartus handles \\wsl$ paths poorly, so this copies the RTL (flat), the FPGA files and the init
# files to a Windows build directory, runs build.tcl (full compile) and sta_reports.tcl there,
# and copies the reports back to fpga/de10lite/reports/, with every Quartus warning in
# warnings.txt (checked against fpga/de10lite/expected_warnings.txt by
# scripts/check_quartus_warnings.py). The programming files stay in the build directory:
# de10lite.sof (SRAM configuration, lost at power-off) and de10lite.pof (internal flash, kept
# across power cycles; the Assembler writes it for MAX 10). The board is programmed from Windows.
#
# Environment:
#   QUARTUS_ROOT  Quartus install (default /mnt/c/intelFPGA_lite/22.1std/quartus)
#   BUILD_DIR     Windows-side build directory (default: <Windows profile>/fpga_build/de10lite)
# Exit status: 0 success, 1 a Quartus step failed, 2 Quartus not available.
set -euo pipefail

QUARTUS_ROOT="${QUARTUS_ROOT:-/mnt/c/intelFPGA_lite/22.1std/quartus}"
QSH="$QUARTUS_ROOT/bin64/quartus_sh.exe"
QSTA="$QUARTUS_ROOT/bin64/quartus_sta.exe"
[ -f "$QSH" ] || { echo "build_win: Quartus not found at $QSH" >&2; exit 2; }

repo="$(cd "$(dirname "$0")/../.." && pwd)"
here="$repo/fpga/de10lite"
if [ -z "${BUILD_DIR:-}" ]; then
  win_profile="$(cd /mnt/c && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')"
  BUILD_DIR="$(wslpath "$win_profile")/fpga_build/de10lite"
fi
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$here/reports"

# Provenance of this build (checked by scripts/checkpoint.sh 4 against the current tree). Written
# to a temporary file first: creating it in the tree would make the clean-tree check see it.
info_tmp="$(mktemp)"
python3 - "$repo" "$QSH" > "$info_tmp" <<'PY'
import hashlib, json, subprocess, sys
repo, qsh = sys.argv[1], sys.argv[2]
git = lambda *a: subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True).stdout.strip()
mem = f"{repo}/model/artifacts/mem"
version = subprocess.run([qsh, "--version"], capture_output=True, text=True).stdout
print(json.dumps({
    "script": "fpga/de10lite/build_win.sh",
    "commit": git("rev-parse", "HEAD"),
    "rtl_tree": git("rev-parse", "HEAD:rtl"),
    "tree_clean": git("status", "--porcelain") == "",
    "init_files_sha256": {f"{n}.hex": hashlib.sha256(open(f"{mem}/{n}.hex", "rb").read()).hexdigest()
                          for n in ("img", "wgt", "param", "desc", "label")},
    "quartus": next((l.strip() for l in version.splitlines() if "Version" in l), "?"),
}, indent=2))
PY
mv "$info_tmp" "$here/reports/build_info.json"
find "$repo/rtl" -name '*.sv' -exec cp {} "$BUILD_DIR/" \;
cp "$here/build.tcl" "$here/sta_reports.tcl" "$here/pins.tcl" "$here/de10lite.sdc" "$BUILD_DIR/"
for f in img wgt param desc label; do
  cp "$repo/model/artifacts/mem/$f.hex" "$BUILD_DIR/"
done

status=0
(cd "$BUILD_DIR" && "$QSH" -t build.tcl > quartus_sh.log 2>&1) || status=1
if [ "$status" -eq 0 ]; then
  (cd "$BUILD_DIR" && "$QSTA" -t sta_reports.tcl > quartus_sta.log 2>&1) || status=1
fi

for f in de10lite.sof de10lite.pof; do
  [ -f "$BUILD_DIR/$f" ] || { echo "build_win: $f was not generated" >&2; status=1; }
done

for f in de10lite.map.summary de10lite.fit.summary de10lite.sta.summary timing_corners.rpt \
         timing_setup_worst.rpt timing_hold_worst.rpt timing_summary_setup.rpt \
         timing_summary_hold.rpt fmax.rpt unconstrained_paths.rpt mtbf.rpt; do
  [ -f "$BUILD_DIR/$f" ] && cp "$BUILD_DIR/$f" "$here/reports/"
done
logs=("$BUILD_DIR/quartus_sh.log")
[ -f "$BUILD_DIR/quartus_sta.log" ] && logs+=("$BUILD_DIR/quartus_sta.log")
# Top-level messages (summary), then every warning including the nested ones (the check list).
grep -hE "^(Error|Critical Warning|Warning) \(" "${logs[@]}" | sed 's/ File: .*//' \
  > "$here/reports/messages.txt" || true
grep -hE "was (un)?successful" "${logs[@]}" >> "$here/reports/messages.txt" || true
grep -hE "^ *(Error|Critical Warning|Warning) \(" "${logs[@]}" | sed -E 's/ File: .*//; s/^ +//' \
  > "$here/reports/warnings.txt" || true
echo "build_win: $( [ "$status" -eq 0 ] && echo success || echo FAILED ) ($BUILD_DIR/de10lite.sof, $BUILD_DIR/de10lite.pof)"
exit "$status"
