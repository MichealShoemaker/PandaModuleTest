#!/usr/bin/env bash
# Build the MT7610U (mt76x0u) driver stack against one WSL kernel release.
#
# Usage: build.sh <kernel-source-dir> <wsl-version> <output-dir>
#   e.g. build.sh kernel 6.6.87.2 out
#
# Produces:
#   <out>/mt7610u-<krel>.tar.gz          modules, firmware, load-order.txt, manifest.json
#   <out>/mt7610u-<krel>.tar.gz.sha256
set -euo pipefail

KSRC="$(realpath "$1")"
VERSION="$2"
OUT="$(realpath -m "$3")"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

KREL="${VERSION}-microsoft-standard-WSL2"   # must equal `uname -r` on users' machines
PKG="mt7610u-${KREL}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# LOCALVERSION= (set but empty) stops scripts/setlocalversion appending "+" for a git tree.
MAKE=(make -C "$KSRC" -j"$(nproc)" LOCALVERSION=)

mkdir -p "$OUT"

# 1. Start from Microsoft's own config for this release.
cfg=""
for c in arch/x86/configs/config-wsl Microsoft/config-wsl; do
  if [ -f "$KSRC/$c" ]; then cfg="$KSRC/$c"; break; fi
done
[ -n "$cfg" ] || { echo "ERROR: config-wsl not found in $KSRC" >&2; exit 1; }
cp "$cfg" "$KSRC/.config"
"${MAKE[@]}" olddefconfig
cp "$KSRC/.config" "$STAGE/config.stock"

# 2. ABI precondition. If the stock kernel has no cfg80211 at all, enabling it here
#    can change core structures (e.g. struct net_device), so the modules would not
#    match the kernel users actually run. Compare with how your current manual build
#    handles this before overriding.
if ! grep -Eq '^CONFIG_CFG80211=(y|m)$' "$STAGE/config.stock"; then
  echo "WARNING: stock WSL $VERSION config does not enable CFG80211 (ABI risk)." >&2
  [ "${ALLOW_CFG80211_ABI_RISK:-0}" = 1 ] || exit 2
fi

# 3. Add the wireless stack, as modules only.
#    Debug info is dropped to speed up the build; it does not affect module ABI.
(
  cd "$KSRC"
  ./scripts/config \
    --enable WIRELESS --enable WLAN --enable WLAN_VENDOR_MEDIATEK \
    --module CFG80211 --disable CFG80211_WEXT \
    --module MAC80211 \
    --module MT76x0U \
    --disable DEBUG_INFO --enable DEBUG_INFO_NONE --disable DEBUG_INFO_BTF
)
"${MAKE[@]}" olddefconfig
grep -q '^CONFIG_MT76x0U=m$' "$KSRC/.config" \
  || { echo "ERROR: MT76x0U not enabled after olddefconfig (missing dependency?)" >&2; exit 1; }

# 4. Gate: apart from wireless/debug options, no built-in (=y) option may change,
#    otherwise the kernel we build against differs from the one users run.
builtin_opts() { grep -E '^CONFIG_[A-Za-z0-9_]+=y$' "$1" | sort; }
changed="$(diff <(builtin_opts "$STAGE/config.stock") <(builtin_opts "$KSRC/.config") \
  | grep -E '^[<>]' \
  | grep -Ev 'CONFIG_(WIRELESS|WLAN|WLAN_VENDOR_[A-Z0-9_]+|CFG80211_[A-Z0-9_]+|MAC80211_[A-Z0-9_]+|MT76[A-Za-z0-9_]*|DEBUG_INFO[A-Z0-9_]*|PAHOLE_[A-Z0-9_]+)=y$' \
  || true)"
if [ -n "$changed" ]; then
  echo "ERROR: enabling the driver changed built-in kernel options:" >&2
  echo "$changed" >&2
  exit 3
fi

# 5. Full build: Module.symvers is only correct after a complete build.
"${MAKE[@]}"
"${MAKE[@]}" modules_install INSTALL_MOD_PATH="$STAGE/root" INSTALL_MOD_STRIP=1

actual="$(make -s --no-print-directory -C "$KSRC" LOCALVERSION= kernelrelease)"
[ "$actual" = "$KREL" ] || { echo "ERROR: kernelrelease '$actual' != '$KREL'" >&2; exit 4; }

# 6. Collect mt76x0u plus everything it depends on, in load order.
PKGDIR="$OUT/$PKG"
rm -rf "$PKGDIR"
mkdir -p "$PKGDIR/modules" "$PKGDIR/firmware/mediatek"

modprobe -d "$STAGE/root" -S "$KREL" --show-depends mt76x0u \
  | awk '$1 == "insmod" { print $2 }' > "$STAGE/deps.txt"
[ -s "$STAGE/deps.txt" ] || { echo "ERROR: could not resolve mt76x0u dependencies" >&2; exit 5; }

while read -r ko; do
  vermagic="$(modinfo -F vermagic "$ko" | awk '{print $1}')"
  [ "$vermagic" = "$KREL" ] || { echo "ERROR: $ko vermagic '$vermagic' != '$KREL'" >&2; exit 6; }
  cp "$ko" "$PKGDIR/modules/"
  basename "$ko" >> "$PKGDIR/load-order.txt"
done < "$STAGE/deps.txt"

# 7. Firmware, vendored in this repo from linux-firmware together with its licence file.
cp "$REPO_ROOT/firmware/mediatek/mt7610u.bin" "$PKGDIR/firmware/mediatek/"
cp "$REPO_ROOT"/firmware/LICENCE* "$PKGDIR/firmware/" 2>/dev/null || true

cat > "$PKGDIR/manifest.json" <<EOF
{
  "kernel_release": "$KREL",
  "source_tag": "linux-msft-wsl-$VERSION",
  "source_commit": "$(git -C "$KSRC" rev-parse HEAD)",
  "builder_commit": "${GITHUB_SHA:-local}",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

tar -C "$OUT" -czf "$OUT/$PKG.tar.gz" "$PKG"
(cd "$OUT" && sha256sum "$PKG.tar.gz" > "$PKG.tar.gz.sha256")
echo "Built $OUT/$PKG.tar.gz"
