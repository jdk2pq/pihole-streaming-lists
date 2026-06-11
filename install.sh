#!/usr/bin/env bash
# install.sh — Clone the pihole-streaming-lists repo and import all lists.
#
# One-liner (installs everything):
#   curl -sSL https://raw.githubusercontent.com/jdk2pq/pihole-streaming-lists/main/install.sh | sudo bash
#
# One-liner (specific platforms only):
#   curl -sSL https://raw.githubusercontent.com/jdk2pq/pihole-streaming-lists/main/install.sh | sudo bash -s -- roku peacock
#
# Prefer to inspect before running? Download first:
#   curl -sSL https://raw.githubusercontent.com/jdk2pq/pihole-streaming-lists/main/install.sh -o install.sh
#   less install.sh       # read it
#   sudo bash install.sh  # run it when satisfied
#
# Dry-run (preview what would be added, no changes made):
#   sudo bash install.sh --dry-run
#
# Available platforms: roku  peacock  paramount-plus  disney-plus  nbc
# Default (no args): all platforms
#
# What this script does:
#   1. Clones github.com/jdk2pq/pihole-streaming-lists to /opt/pihole-streaming-lists
#   2. Runs update.sh, which backs up gravity.db, then inserts domains and regex
#      patterns using INSERT OR IGNORE (never removes or modifies existing entries)
#   3. Reloads Pi-hole DNS if anything was added
#
# Nothing outside of /opt/pihole-streaming-lists and /etc/pihole/gravity.db
# is created or modified.
#
# After install, update any time with:
#   sudo /opt/pihole-streaming-lists/update.sh [platform ...]

set -euo pipefail

REPO_URL="https://github.com/jdk2pq/pihole-streaming-lists.git"
INSTALL_DIR="/opt/pihole-streaming-lists"

# ── Colours ───────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; RESET=''
fi

info()  { echo -e "${GREEN}[+]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[~]${RESET} $*"; }
error() { echo -e "${RED}[!]${RESET} $*" >&2; }

# ── Preflight ─────────────────────────────────────────────────────────────────

if [[ "$EUID" -ne 0 ]]; then
  error "Run as root or with sudo."
  exit 1
fi

for cmd in git sqlite3 pihole; do
  if ! command -v "$cmd" &>/dev/null; then
    error "Required command not found: $cmd"
    if [[ "$cmd" == sqlite3 ]]; then error "  Install with: sudo apt install sqlite3"; fi
    exit 1
  fi
done

# ── Clone or hand off if already installed ────────────────────────────────────

if [[ -d "$INSTALL_DIR/.git" ]]; then
  warn "Repo already exists at $INSTALL_DIR — running update instead."
  exec "$INSTALL_DIR/update.sh" "$@"
fi

info "Cloning into $INSTALL_DIR..."
git clone "$REPO_URL" "$INSTALL_DIR"

# ── Hand off to update.sh (all import logic lives there) ─────────────────────

exec "$INSTALL_DIR/update.sh" "$@"
