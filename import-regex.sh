#!/usr/bin/env bash
# import-regex.sh — Bulk-import regex allowlist/denylist entries into Pi-hole
#
# Pi-hole 5+ stores all domain rules in /etc/pihole/gravity.db (SQLite).
# This script reads every *-regex.txt file in the repo and inserts them
# directly into the database, then reloads Pi-hole's DNS.
#
# Usage:
#   sudo ./import-regex.sh            # import everything
#   sudo ./import-regex.sh --dry-run  # preview without changing anything
#   sudo ./import-regex.sh roku       # import only files matching "roku"
#
# domainlist types in gravity.db:
#   0 = exact allowlist   1 = exact denylist
#   2 = regex allowlist   3 = regex denylist

set -euo pipefail

GRAVITY_DB="${GRAVITY_DB:-/etc/pihole/gravity.db}"
DRY_RUN=false
FILTER=""
ADDED=0
SKIPPED=0

# ── Argument parsing ──────────────────────────────────────────────────────────

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --help)
      sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "Unknown option: $arg"; exit 1 ;;
    *)  FILTER="$arg" ;;
  esac
done

# ── Preflight checks ──────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == false && "$EUID" -ne 0 ]]; then
  echo "ERROR: Run as root or with sudo (needed to write to gravity.db)."
  echo "       Use --dry-run to preview without root."
  exit 1
fi

if [[ ! -f "$GRAVITY_DB" ]]; then
  echo "ERROR: gravity.db not found at: $GRAVITY_DB"
  echo "       Set GRAVITY_DB=/path/to/gravity.db if yours is elsewhere."
  exit 1
fi

if ! command -v sqlite3 &>/dev/null; then
  echo "ERROR: sqlite3 is not installed. Install it with:"
  echo "       sudo apt install sqlite3"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Helpers ───────────────────────────────────────────────────────────────────

insert_pattern() {
  local pattern="$1"
  local type="$2"    # 2 = regex allowlist, 3 = regex denylist
  local source="$3"  # stored as a comment in the DB

  if [[ "$DRY_RUN" == true ]]; then
    local type_label
    type_label=$(type_name "$type")
    echo "  [dry-run] would add ($type_label): $pattern"
    ((ADDED++)) || true
    return
  fi

  local result
  result=$(sqlite3 "$GRAVITY_DB" \
    "INSERT OR IGNORE INTO domainlist (type, domain, enabled, comment)
     VALUES ($type, '$pattern', 1, 'imported from $source');
     SELECT changes();" 2>&1) || {
    echo "  WARNING: sqlite3 error for pattern '$pattern': $result"
    return
  }

  if [[ "$result" -eq 1 ]]; then
    ((ADDED++)) || true
    echo "  + $pattern"
  else
    ((SKIPPED++)) || true
    echo "  ~ already exists: $pattern"
  fi
}

type_name() {
  case "$1" in
    2) echo "regex allowlist" ;;
    3) echo "regex denylist"  ;;
  esac
}

resolve_type() {
  local filepath="$1"
  local filename
  filename="$(basename "$filepath")"

  if [[ "$filename" == allowlist-regex.txt ]]; then
    echo 2
  elif [[ "$filename" == denylist-regex.txt ]]; then
    echo 3
  else
    echo ""
  fi
}

# ── Main import loop ──────────────────────────────────────────────────────────

mapfile -t regex_files < <(
  find "$SCRIPT_DIR" -name '*-regex.txt' | sort
)

if [[ "${#regex_files[@]}" -eq 0 ]]; then
  echo "No *-regex.txt files found under $SCRIPT_DIR."
  exit 0
fi

for filepath in "${regex_files[@]}"; do
  relative="${filepath#"$SCRIPT_DIR/"}"

  # Apply optional filter argument (e.g. "roku", "peacock")
  if [[ -n "$FILTER" && "$relative" != *"$FILTER"* ]]; then
    continue
  fi

  db_type=$(resolve_type "$filepath")
  if [[ -z "$db_type" ]]; then
    echo "SKIP (unrecognised filename pattern): $relative"
    continue
  fi

  echo
  echo "── $relative  [$(type_name "$db_type")] ──"

  while IFS= read -r line; do
    # Strip comments and blank lines
    line="${line%%#*}"        # remove inline comments
    line="${line#"${line%%[![:space:]]*}"}"  # ltrim
    line="${line%"${line##*[![:space:]]}"}"  # rtrim
    [[ -z "$line" ]] && continue

    insert_pattern "$line" "$db_type" "$relative"
  done < "$filepath"
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo "Done. Added: $ADDED  Already present: $SKIPPED"

if [[ "$DRY_RUN" == false && "$ADDED" -gt 0 ]]; then
  echo "Reloading Pi-hole..."
  pihole restartdns reload-lists
  echo "Reload complete."
fi
