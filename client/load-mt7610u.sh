#!/usr/bin/env bash
# Load the MT7610U driver stack matching the running WSL kernel.
# Run as root inside the WSL distro, e.g. from /etc/wsl.conf ([boot] command=)
# or from your application's startup, before or after `usbipd attach`.
#
# Exit codes: 0 = loaded or already loaded
#             10 = no build published yet for this kernel (WSL just updated)
#             anything else = error
set -euo pipefail

REPO="${MT7610U_REPO:-your-org/wsl-mt7610u}"
CACHE="${MT7610U_CACHE:-/var/lib/mt7610u}"
FW_DIR=/lib/firmware

log() { echo "mt7610u: $*" >&2; }

[ "$(id -u)" -eq 0 ] || { log "must run as root"; exit 1; }

KREL="$(uname -r)"
case "$KREL" in
  *-microsoft-standard-WSL2) ;;
  *) log "kernel '$KREL' is not a stock WSL kernel"; exit 1 ;;
esac
VERSION="${KREL%%-*}"
PKG="mt7610u-${KREL}"
PKGDIR="$CACHE/$PKG"

if [ -d /sys/module/mt76x0u ]; then
  log "already loaded"
  exit 0
fi

# Download once per kernel version.
if [ ! -f "$PKGDIR/load-order.txt" ]; then
  base="https://github.com/${REPO}/releases/download/wsl-${VERSION}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  log "fetching modules for $KREL"
  if ! curl -fsSL --retry 3 -o "$tmp/$PKG.tar.gz" "$base/$PKG.tar.gz"; then
    log "no build published yet for kernel $KREL"
    exit 10
  fi
  curl -fsSL --retry 3 -o "$tmp/$PKG.tar.gz.sha256" "$base/$PKG.tar.gz.sha256"
  (cd "$tmp" && sha256sum -c --quiet "$PKG.tar.gz.sha256")

  mkdir -p "$CACHE"
  rm -rf "$PKGDIR"
  tar -C "$CACHE" -xzf "$tmp/$PKG.tar.gz"

  # Remove packages for kernels no longer running.
  find "$CACHE" -mindepth 1 -maxdepth 1 -type d -name 'mt7610u-*' ! -name "$PKG" -exec rm -rf {} +
fi

# Firmware
mkdir -p "$FW_DIR/mediatek"
install -m 0644 "$PKGDIR/firmware/mediatek/mt7610u.bin" "$FW_DIR/mediatek/mt7610u.bin"

# Modules, in dependency order; skip anything already present in the kernel.
while read -r ko; do
  [ -n "$ko" ] || continue
  name="$(modinfo -F name "$PKGDIR/modules/$ko")"
  [ -d "/sys/module/$name" ] && continue
  insmod "$PKGDIR/modules/$ko"
done < "$PKGDIR/load-order.txt"

log "loaded for $KREL"
