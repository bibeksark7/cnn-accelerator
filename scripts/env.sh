# Source this file (do not execute it) to set up the tool environment:
#   source scripts/env.sh
# Appends the OSS CAD Suite to the END of PATH so it can never shadow the
# system Icarus or the project venv, then activates the venv if present.

OSS_CAD_SUITE_BIN="${OSS_CAD_SUITE_BIN:-$HOME/tools/oss-cad-suite/bin}"
case ":$PATH:" in
  *":$OSS_CAD_SUITE_BIN:"*) ;;
  *) export PATH="$PATH:$OSS_CAD_SUITE_BIN" ;;
esac

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${VIRTUAL_ENV:-}" ] && [ -f "$_repo_root/.venv/bin/activate" ]; then
  # shellcheck disable=SC1091
  source "$_repo_root/.venv/bin/activate"
fi
unset _repo_root
