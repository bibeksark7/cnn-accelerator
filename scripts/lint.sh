#!/usr/bin/env bash
# Lint every RTL file:
#   Verilator --lint-only -Wall   (any warning fails; waivers are inline and commented)
#   Icarus parse/elaborate        (any output, including warnings and "sorry" messages, fails)
#   Yosys synth with the file's module as top (errors fail; warnings are printed)
#   Quartus Prime Lite 22.1 compatibility (Quartus cannot run in CI, see BUG-005):
#     - no inline genvar declarations: `for (genvar ...)`
#     - named generate blocks (`begin : g_...`) only inside explicit generate/endgenerate
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
  if grep -nE 'for[[:space:]]*\([[:space:]]*genvar' "$f"; then
    echo "FAIL (quartus compat: inline genvar declaration)"; fail=1; continue
  fi
  if grep -qE 'begin[[:space:]]*:[[:space:]]*g_' "$f" \
     && { ! grep -qE '^[[:space:]]*generate\b' "$f" || ! grep -qE '^[[:space:]]*endgenerate\b' "$f"; }; then
    echo "FAIL (quartus compat: generate block without generate/endgenerate)"; fail=1; continue
  fi
  if ! out=$(verilator --lint-only -Wall --top-module "$top" "${lib[@]}" "${waivers[@]}" "$f" 2>&1); then
    echo "FAIL (verilator)"; echo "$out"; fail=1; continue
  fi
  out=$(iverilog -g2012 -Y .sv "${lib[@]}" -s "$top" -o /dev/null "$f" 2>&1) || true
  if [ -n "$out" ]; then
    echo "FAIL (iverilog output)"; echo "$out"; fail=1; continue
  fi
  if ! out=$(yosys -q -p "read_verilog -sv ${all_rtl[*]}; synth -top $top" 2>&1); then
    echo "FAIL (yosys synth)"; echo "$out"; fail=1; continue
  fi
  echo "ok"
  [ -n "$out" ] && echo "$out" | sed 's/^/    yosys: /'
done

exit "$fail"
