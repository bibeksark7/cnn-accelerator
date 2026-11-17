#!/usr/bin/env bash
# Lint every RTL file:
#   Quartus compatibility  scripts/check_quartus_compat.py (Quartus cannot run in CI; BUG-005)
#   Verilator              --lint-only -Wall (any warning fails; waivers are inline and commented)
#   Icarus                 parse/elaborate (any output, including warnings and "sorry", fails)
#   Yosys                  hierarchy -check; proc; opt; memory -nomap; check -assert
#                          with the file's module as top: conflicting drivers between cells,
#                          combinational loops and used-but-undriven wires fail (a plain
#                          double `assign` alias is caught by Verilator's MULTIDRIVEN instead)
# Usage: scripts/lint.sh [file.sv ...]   (default: all of rtl/**/*.sv)
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh

mapfile -t all_rtl < <(find rtl -name '*.sv' | sort)
if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=("${all_rtl[@]}")
fi
if [ "${#files[@]}" -eq 0 ]; then
  echo "lint: no RTL files found" >&2
  exit 1
fi

# Library search paths so a module's submodules resolve from any rtl/ subfolder.
mapfile -t rtl_dirs < <(find rtl -type d | sort)
lib=()
for d in "${rtl_dirs[@]}"; do
  lib+=(-y "$d")
done
waivers=()
[ -f rtl/lint_waivers.vlt ] && waivers=(rtl/lint_waivers.vlt)

fail=0
for f in "${files[@]}"; do
  top="$(basename "$f" .sv)"
  printf 'lint %-40s ' "$f"
  if ! out=$(python scripts/check_quartus_compat.py "$f" 2>&1); then
    echo "FAIL (quartus compat)"; echo "$out"; fail=1; continue
  fi
  if ! out=$(verilator --lint-only -Wall --top-module "$top" "${lib[@]}" "${waivers[@]}" "$f" 2>&1); then
    echo "FAIL (verilator)"; echo "$out"; fail=1; continue
  fi
  out=$(iverilog -g2012 -Y .sv "${lib[@]}" -s "$top" -o /dev/null "$f" 2>&1) || true
  if [ -n "$out" ]; then
    echo "FAIL (iverilog output)"; echo "$out"; fail=1; continue
  fi
  # Read the file under test plus every RTL file (for submodules), without duplicates.
  mapfile -t ys_src < <(printf '%s\n' "$f" "${all_rtl[@]}" | awk '!seen[$0]++')
  if ! out=$(yosys -q -p "read_verilog -sv ${ys_src[*]}; hierarchy -check -top $top; proc; opt; memory -nomap; check -assert" 2>&1); then
    echo "FAIL (yosys check)"; echo "$out"; fail=1; continue
  fi
  echo "ok"
  [ -n "$out" ] && echo "$out" | sed 's/^/    yosys: /'
done

exit "$fail"
