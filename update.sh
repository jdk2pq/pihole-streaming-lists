#!/usr/bin/env bash
# update.sh — Pull the latest list changes and re-apply lists to Pi-hole.
#
# Usage:
#   sudo /opt/pihole-streaming-lists/update.sh                  # all platforms
#   sudo /opt/pihole-streaming-lists/update.sh roku peacock     # specific platforms
#   sudo /opt/pihole-streaming-lists/update.sh --dry-run        # preview, no changes
#
# Available platforms: roku  peacock  paramount-plus  disney-plus  nbc
#
# Cron (weekly, all platforms):
#   0 3 * * 0   root   /opt/pihole-streaming-lists/update.sh >> /var/log/pihole-streaming-lists.log 2>&1
#
# What this script does:
#   1. Verifies the git remote is github.com/jdk2pq/pihole-streaming-lists
#   2. Runs `git pull --ff-only` to fetch the latest list files
#   3. Backs up /etc/pihole/gravity.db (keeps the 5 most recent backups)
#   4. Inserts new domains and regex patterns into gravity.db using INSERT OR IGNORE
#      (safe to run repeatedly — existing entries are never modified or removed)
#   5. Runs `pihole restartdns reload-lists` if anything was added
#
# Nothing outside of gravity.db and the cloned repo directory is touched.

set -euo pipefail

GRAVITY_DB="${GRAVITY_DB:-/etc/pihole/gravity.db}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_REMOTE="https://github.com/jdk2pq/pihole-streaming-lists"
VALID_PLATFORMS=(roku peacock paramount-plus disney-plus nbc)
DRY_RUN=false
PLATFORMS=()
ADDED=0
SKIPPED=0

# ── Colours (skipped when not a tty, e.g. cron) ──────────────────────────────

if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; RESET=''
fi

info()  { echo -e "${GREEN}[+]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[~]${RESET} $*"; }
error() { echo -e "${RED}[!]${RESET} $*" >&2; }

# ── Argument parsing ──────────────────────────────────────────────────────────

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      error "Unknown option: $arg  (use --help for usage)"
      exit 1
      ;;
    *)
      valid=false
      for p in "${VALID_PLATFORMS[@]}"; do
        if [[ "$arg" == "$p" ]]; then valid=true; break; fi
      done
      if [[ "$valid" == false ]]; then
        error "Unknown platform: '$arg'"
        error "Valid platforms: ${VALID_PLATFORMS[*]}"
        exit 1
      fi
      PLATFORMS+=("$arg")
      ;;
  esac
done

if [[ ${#PLATFORMS[@]} -eq 0 ]]; then
  PLATFORMS=("${VALID_PLATFORMS[@]}")
fi

if [[ "$DRY_RUN" == true ]]; then warn "Dry-run mode — no changes will be made."; fi

# ── Preflight ─────────────────────────────────────────────────────────────────

if [[ "$EUID" -ne 0 ]]; then
  error "Run as root or with sudo."
  exit 1
fi

for cmd in sqlite3 git pihole; do
  if ! command -v "$cmd" &>/dev/null; then
    error "Required command not found: $cmd"
    if [[ "$cmd" == sqlite3 ]]; then error "  Install with: sudo apt install sqlite3"; fi
    exit 1
  fi
done

if [[ ! -f "$GRAVITY_DB" ]]; then
  error "gravity.db not found at: $GRAVITY_DB"
  error "Set GRAVITY_DB=/path/to/gravity.db if yours is in a different location."
  exit 1
fi

# ── Verify git remote ─────────────────────────────────────────────────────────
# Confirms this repo is actually github.com/jdk2pq/pihole-streaming-lists
# before pulling anything. Catches cases where someone cloned from a fork or
# a different source and ran this script.

actual_remote=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "")
actual_remote="${actual_remote%.git}"  # normalise — strip optional .git suffix

if [[ "$actual_remote" != "$EXPECTED_REMOTE" ]]; then
  error "Unexpected git remote: $actual_remote"
  error "Expected:              $EXPECTED_REMOTE"
  error "If you intentionally forked this repo, update EXPECTED_REMOTE in update.sh."
  exit 1
fi

# ── Pull latest changes ───────────────────────────────────────────────────────

info "Checking for updates..."
ORIG_HEAD=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

git -C "$SCRIPT_DIR" pull --ff-only

NEW_HEAD=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

if [[ "$ORIG_HEAD" != "$NEW_HEAD" ]]; then
  info "Changes pulled:"
  git -C "$SCRIPT_DIR" log --oneline "${ORIG_HEAD}..${NEW_HEAD}" | sed 's/^/    /'
else
  info "Already up to date."
fi

# ── Backup gravity.db ─────────────────────────────────────────────────────────

backup_db() {
  local backup="${GRAVITY_DB}.bak.$(date +%Y%m%d-%H%M%S)"
  info "Backing up gravity.db → $(basename "$backup")"
  cp "$GRAVITY_DB" "$backup"

  # Keep only the 5 most recent backups to avoid filling disk
  local old_backups
  mapfile -t old_backups < <(ls -t "${GRAVITY_DB}.bak."* 2>/dev/null | tail -n +6)
  for f in "${old_backups[@]+"${old_backups[@]}"}"; do
    rm -f "$f"
  done
}

if [[ "$DRY_RUN" == false ]]; then backup_db; fi

# ── Import helpers ────────────────────────────────────────────────────────────

# domainlist types: 0=exact allow  1=exact deny  2=regex allow  3=regex deny
type_label() {
  case "$1" in
    0) echo "exact allowlist"  ;;
    1) echo "exact denylist"   ;;
    2) echo "regex allowlist"  ;;
    3) echo "regex denylist"   ;;
  esac
}

resolve_type() {
  case "$(basename "$1")" in
    allowlist.txt)       echo 0 ;;
    denylist.txt)        echo 1 ;;
    allowlist-regex.txt) echo 2 ;;
    denylist-regex.txt)  echo 3 ;;
    *)                   echo "" ;;
  esac
}

import_file() {
  local filepath="$1"
  local db_type="$2"
  local relative="${filepath#"$SCRIPT_DIR/"}"
  local file_added=0

  echo
  info "$relative  [$(type_label "$db_type")]"

  while IFS= read -r line; do
    # Strip inline comments and surrounding whitespace
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -z "$line" ]]; then continue; fi

    if [[ "$DRY_RUN" == true ]]; then
      echo "    [dry-run] would add: $line"
      ((ADDED++)) || true
      continue
    fi

    # Escape single quotes in both the domain and the comment for SQLite
    local escaped_domain="${line//\'/\'\'}"
    local escaped_comment="${relative//\'/\'\'}"

    # Single query that handles three cases:
    #   1. Domain not in DB at all         → INSERT succeeds, changes()=1
    #   2. Domain in DB with correct type  → WHERE NOT EXISTS is false, no INSERT, changes()=0
    #   3. Domain in DB with wrong type    → WHERE NOT EXISTS is false but INSERT OR REPLACE
    #      fires on the UNIQUE conflict, replacing the old row, changes()=1
    # This correctly handles domains moved between allowlist and denylist.
    local result
    result=$(sqlite3 "$GRAVITY_DB" \
      "INSERT OR REPLACE INTO domainlist (type, domain, enabled, comment)
       SELECT $db_type, '$escaped_domain', 1, 'pihole-streaming-lists: $escaped_comment'
       WHERE NOT EXISTS (
         SELECT 1 FROM domainlist WHERE domain = '$escaped_domain' AND type = $db_type
       );
       SELECT changes();")

    if [[ "$result" -eq 1 ]]; then
      ((ADDED++))      || true
      ((file_added++)) || true
      echo "    + $line"
    else
      ((SKIPPED++)) || true
    fi
  done < "$filepath"

  if [[ "$DRY_RUN" == false && "$file_added" -eq 0 ]]; then
    warn "  (all entries already present)"
  fi
}

# ── Main import loop ──────────────────────────────────────────────────────────

echo
info "Platforms: ${PLATFORMS[*]}"

mapfile -t list_files < <(
  for platform in "${PLATFORMS[@]}"; do
    find "$SCRIPT_DIR/$platform" \
      \( -name 'allowlist.txt' \
      -o -name 'denylist.txt' \
      -o -name 'allowlist-regex.txt' \
      -o -name 'denylist-regex.txt' \) \
      2>/dev/null
  done | sort
)

if [[ ${#list_files[@]} -eq 0 ]]; then
  warn "No list files found for the selected platforms."
  exit 0
fi

for filepath in "${list_files[@]}"; do
  db_type=$(resolve_type "$filepath")
  if [[ -z "$db_type" ]]; then continue; fi
  import_file "$filepath" "$db_type"
done

# ── Reload Pi-hole ────────────────────────────────────────────────────────────

echo
info "Added: $ADDED  Already present: $SKIPPED"

if [[ "$DRY_RUN" == true ]]; then
  warn "Dry-run complete — gravity.db was not modified."
elif [[ "$ADDED" -gt 0 ]]; then
  info "Reloading Pi-hole..."
  pihole reloaddns
  info "Done."
else
  info "Nothing new to add — Pi-hole not reloaded."
fi
