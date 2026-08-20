#!/usr/bin/env bash
# =============================================================================
# Script Name: nas-health.sh
# Description: Verify NAS share mountpoints are mounted and readable; log a
#              journald error on any fault (dropped USB device, EIO, wedge).
# Author: Juan Garcia (arpatek)
# Created: 2026-08-17
# Version: 1.0
# =============================================================================

if ((BASH_VERSINFO[0] < 4)); then
  printf "nas-health.sh requires bash 4 or higher (detected: %s)\n" "$BASH_VERSION" >&2
  exit 1
fi

set -eo pipefail

# ──[ Configuration ]───────────────────────────────────────────────────────────

# Mountpoints to verify. Override by passing paths as arguments.
DEFAULT_MOUNTS=("/srv/shares/nas" "/srv/shares/stor")

# Seconds to allow a read probe before treating the mount as wedged.
readonly PROBE_TIMEOUT=10

# ──[ Logging ]─────────────────────────────────────────────────────────────────

# sd-daemon severity prefixes — journald maps <N> to a priority, so
# `journalctl -p err -u nas-health` surfaces only faults.
log_info() { printf '<6>%s\n' "$*"; }
log_err()  { printf '<3>%s\n' "$*" >&2; }

# ──[ Error handling ]──────────────────────────────────────────────────────────

trap 'log_err "nas-health.sh failed unexpectedly at line ${LINENO}"' ERR

# ──[ Usage ]───────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage: nas-health.sh [MOUNTPOINT...]

Verify each NAS share mountpoint is mounted and readable. With no arguments,
checks the defaults: /srv/shares/nas /srv/shares/stor

Exit status:
  0  all mounts healthy
  1  one or more mounts unhealthy
EOF
}

# ──[ Functions ]───────────────────────────────────────────────────────────────

# check_mount MOUNTPOINT — 0 if mounted and readable, 1 otherwise.
check_mount() {
  local mp="$1"
  local opts

  if ! findmnt -rn "$mp" >/dev/null 2>&1; then
    log_err "UNHEALTHY ${mp}: not mounted"
    return 1
  fi

  # A dropped USB device leaves the mount entry with a 'shutdown' flag while the
  # block device is gone — the exact failure seen on stor (2026-08-14).
  opts="$(findmnt -rn -o OPTIONS "$mp" 2>/dev/null || true)"
  if [[ "$opts" == *shutdown* ]]; then
    log_err "UNHEALTHY ${mp}: filesystem shut down (device dropped) — opts: ${opts}"
    return 1
  fi

  # Read probe — EIO on a dead device; timeout guards against a wedged mount.
  if ! timeout "$PROBE_TIMEOUT" ls -A "$mp" >/dev/null 2>&1; then
    log_err "UNHEALTHY ${mp}: read probe failed (I/O error or timeout)"
    return 1
  fi

  log_info "healthy ${mp}"
  return 0
}

# ──[ Main ]────────────────────────────────────────────────────────────────────

main() {
  local -a mounts
  local mp
  local failures=0

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  if (($# > 0)); then
    mounts=("$@")
  else
    mounts=("${DEFAULT_MOUNTS[@]}")
  fi

  for mp in "${mounts[@]}"; do
    check_mount "$mp" || failures=$((failures + 1))
  done

  if ((failures > 0)); then
    log_err "nas-health: ${failures} of ${#mounts[@]} mount(s) unhealthy"
    exit 1
  fi

  log_info "nas-health: all ${#mounts[@]} mount(s) healthy"
  exit 0
}

main "$@"
