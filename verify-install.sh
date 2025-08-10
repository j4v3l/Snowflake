#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[VERIFY]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

HOSTNAME_ARG=${1:-}
HOSTNAME_FILE="/etc/hostname"
TARGET_HOSTNAME="$HOSTNAME_ARG"

if [[ -z "$TARGET_HOSTNAME" && -f "$HOSTNAME_FILE" ]]; then
  TARGET_HOSTNAME=$(cat "$HOSTNAME_FILE" | tr -d '\r\n' || true)
fi

log "Starting post-install verification..."

# 1) Check flake presence
if [[ -f /etc/nixos/flake.nix ]]; then
  success "Found /etc/nixos/flake.nix"
else
  warn "/etc/nixos/flake.nix not found (system may use legacy configuration)"
fi

# 2) Check kernel (expect xanmod per configs)
KERNEL=$(uname -r)
log "Kernel: $KERNEL"
if echo "$KERNEL" | grep -qi xanmod; then
  success "Xanmod kernel active"
else
  warn "Xanmod kernel not active yet (may require reboot)"
fi

# 3) Hostname
CUR_HOST=$(hostname)
if [[ -n "$TARGET_HOSTNAME" ]]; then
  if [[ "$CUR_HOST" == "$TARGET_HOSTNAME" ]]; then
    success "Hostname is '$CUR_HOST'"
  else
    warn "Hostname mismatch. Current: '$CUR_HOST' Expected: '$TARGET_HOSTNAME'"
  fi
else
  success "Hostname is '$CUR_HOST'"
fi

# 4) Generations
if command -v nixos-rebuild >/dev/null 2>&1; then
  log "Recent generations:" && nixos-rebuild list-generations | tail -3 || true
fi
if command -v nix-env >/dev/null 2>&1; then
  log "Profile generations:" && sudo nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -3 || true
fi

# 5) Flake outputs contain our host (best-effort)
if command -v nix >/dev/null 2>&1 && [[ -n "$TARGET_HOSTNAME" ]]; then
  if (cd /etc/nixos && nix flake show 2>/dev/null | grep -q "nixosConfigurations.$TARGET_HOSTNAME"); then
    success "Flake contains host '$TARGET_HOSTNAME'"
  else
    warn "Flake does not list host '$TARGET_HOSTNAME' (or evaluation failed)"
  fi
fi

success "Verification completed"
