#!/usr/bin/env bash
# Lint every RTL file with Verilator (-Wall), Icarus (parse/elaborate) and Yosys (parse).
# Usage: scripts/lint.sh [file.sv ...]   (default: all of rtl/**/*.sv)
# Waivers, when needed, go in rtl/lint_waivers.vlt with a comment explaining each one.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  mapfile -t files < <(find rtl -name '*.sv' | sort)
fi
if [ "${#files[@]}" -eq 0 ]; then
  echo "lint: no RTL files found" >&2
  exit 1
fi

# Library search paths so a module's submodules resolve from any rtl/ subfolder.
mapfile -t rtl_dirs < <(find rtl -type d | sort)
vl_lib=()
iv_lib=()
for d in "${rtl_dirs[@]}"; do
  vl_lib+=(-y "$d")
  iv_lib+=(-y "$d")
done
waivers=()
[ -f rtl/lint_waivers.vlt ] && waivers=(rtl/lint_waivers.vlt)

fail=0
for f in "${files[@]}"; do
  top="$(basename "$f" .sv)"
  printf 'lint %-40s ' "$f"
  if ! out=$(verilator --lint-only -Wall --top-module "$top" "${vl_lib[@]}" "${waivers[@]}" "$f" 2>&1); then
    echo "FAIL (verilator)"; echo "$out"; fail=1; continue
  fi
  if ! out=$(iverilog -g2012 -Y .sv "${iv_lib[@]}" -s "$top" -o /dev/null "$f" 2>&1); then
    echo "FAIL (iverilog)"; echo "$out"; fail=1; continue
  fi
  if ! out=$(yosys -q -p "read_verilog -sv $f" 2>&1); then
    echo "FAIL (yosys)"; echo "$out"; fail=1; continue
  fi
  echo "ok"
done

exit "$fail"
