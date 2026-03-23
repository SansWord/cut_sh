#!/usr/bin/env bash
# ── invoke_cut.sh ─────────────────────────────────────────────
# Wrapper for cut.sh intended for use by AI agents.
# Handles dependency checks, locates cut.sh, and invokes it.
#
# Usage:
#   ./invoke_cut.sh <source> <start> <end> [output] [--sequential]
#
# All arguments are passed directly to cut.sh.
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── Colours for agent-readable output ────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[invoke_cut]${NC} $*"; }
warn()    { echo -e "${YELLOW}[invoke_cut] WARN:${NC} $*" >&2; }
error()   { echo -e "${RED}[invoke_cut] ERROR:${NC} $*" >&2; }

# ── Step 1: Check dependencies ────────────────────────────────
info "Checking dependencies..."

MISSING=()
for cmd in ffmpeg ffprobe bc; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING+=("$cmd")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  error "Missing required tools: ${MISSING[*]}"
  error "Please install them before proceeding:"
  for cmd in "${MISSING[@]}"; do
    case "$cmd" in
      ffmpeg|ffprobe) echo "  brew install ffmpeg   # macOS" ;;
      bc)             echo "  brew install bc       # macOS" ;;
    esac
  done
  exit 1
fi

info "All dependencies found: ffmpeg, ffprobe, bc"

# ── Step 2: Locate cut.sh ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUT_SH=""

# Search order: same dir as this wrapper, current dir, PATH
for candidate in \
  "$SCRIPT_DIR/cut.sh" \
  "./cut.sh" \
  "$(command -v cut.sh 2>/dev/null || true)"; do
  if [[ -f "$candidate" ]]; then
    CUT_SH="$candidate"
    break
  fi
done

if [[ -z "$CUT_SH" ]]; then
  error "cut.sh not found. Expected locations:"
  error "  $SCRIPT_DIR/cut.sh"
  error "  ./cut.sh"
  error "Place cut.sh in the same directory as invoke_cut.sh and try again."
  exit 1
fi

# Ensure it's executable
if [[ ! -x "$CUT_SH" ]]; then
  info "Making cut.sh executable..."
  chmod +x "$CUT_SH"
fi

info "Found cut.sh at: $CUT_SH"

# ── Step 3: Validate arguments before passing ─────────────────
if [[ $# -lt 3 ]]; then
  error "Not enough arguments. Expected: <source> <start> <end> [output] [--sequential]"
  exit 1
fi

SOURCE="$1"
START="$2"
END="$3"

# Check source file exists
if [[ ! -f "$SOURCE" ]]; then
  error "Source file not found: $SOURCE"
  error "Please verify the file path and try again."
  exit 1
fi

# Check timestamp format
validate_ts() {
  [[ "$1" =~ ^[0-9]{1,2}:[0-9]{2}:[0-9]{2}$ ]] || {
    error "Invalid timestamp format: '$1'"
    error "Expected format: h:mm:ss or hh:mm:ss (e.g. 0:13:38 or 01:06:50)"
    exit 1
  }
}
validate_ts "$START"
validate_ts "$END"

info "Source : $SOURCE"
info "Start  : $START"
info "End    : $END"
[[ -n "${4:-}" && "${4:-}" != "--sequential" ]] && info "Output : $4"
[[ "$*" == *"--sequential"* ]] && info "Mode   : sequential" || info "Mode   : parallel"

# ── Step 4: Invoke cut.sh ─────────────────────────────────────
info "Invoking cut.sh..."
echo

"$CUT_SH" "$@"
EXIT_CODE=$?

echo
if [[ $EXIT_CODE -eq 0 ]]; then
  info "cut.sh completed successfully."
else
  error "cut.sh exited with code $EXIT_CODE."
  exit $EXIT_CODE
fi
