#!/usr/bin/env bash
set -euo pipefail

# Build a minimal KubeView.app bundle around the SPM-built binary.
# Usage: ./scripts/bundle.sh [release|debug]   (default: release)

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/KubeView"
APP="$ROOT/build/KubeView.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN" "$CONTENTS/MacOS/KubeView"
chmod +x "$CONTENTS/MacOS/KubeView"

# The scaling analysis lives in a separate Go binary. Bundling it means a
# released .app needs nothing installed; skipping it is fine too — the app
# falls back to a Homebrew install and says so when neither is present.
# ponytail: host arch only, matching the SPM binary above. Make both universal
# together if the cask ever ships to Intel.
LGTM_SRC="${LGTM_SRC:-$ROOT/../kubectl-lgtm}"
if [ -d "$LGTM_SRC" ] && command -v go >/dev/null 2>&1; then
  echo "Building kubectl-lgtm…"
  (cd "$LGTM_SRC" && go build -o "$CONTENTS/MacOS/kubectl-lgtm" ./cmd/kubectl-lgtm)
  chmod +x "$CONTENTS/MacOS/kubectl-lgtm"
else
  echo "Skipping kubectl-lgtm (no checkout at $LGTM_SRC, or no go toolchain)."
fi

# Regenerate the icon if missing, then copy into the bundle.
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
  "$ROOT/scripts/make_icon.swift"
fi
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>KubeView</string>
    <key>CFBundleDisplayName</key><string>KubeView</string>
    <key>CFBundleIdentifier</key><string>com.ondrej.kubeview</string>
    <key>CFBundleVersion</key><string>0.1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>KubeView</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Built $APP"
echo "Run with:  open '$APP'"
