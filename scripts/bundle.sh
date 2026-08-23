#!/usr/bin/env bash
set -euo pipefail

# Build a minimal <app-name>.app bundle around a SwiftPM-built executable.
# This is the single implementation shared by local dev builds and CI
# (.github/workflows/release.yml) - the two used to diverge on bundle id;
# see HANDOFF.md "Trap 5". The kubectl-lgtm analyser is a Homebrew
# prerequisite, not embedded here - LgtmService resolves it at runtime.
#
# Usage: ./scripts/bundle.sh [options] [release|debug]

usage() {
  cat <<'USAGE'
Usage: ./scripts/bundle.sh [options] [release|debug]

  --app-name NAME     App display/bundle name        (default: KubeView)
  --bundle-id ID      CFBundleIdentifier              (default: com.omaksi.kubeview)
  --product NAME      SwiftPM executable product      (default: KubeView)
  --icon PATH         .icns to embed into the bundle  (default: Resources/AppIcon.icns for
                                                         KubeView, Resources/LgtmView.icns for
                                                         LgtmView; regenerated via make_icon.swift
                                                         if missing at that default path)
  --bin PATH          Use this pre-built binary instead of running `swift build`
                       (CI already produces a universal binary via lipo)
  --out DIR           Output directory for the .app   (default: build)
  --version VERSION   CFBundleVersion / CFBundleShortVersionString (default: 0.1)
  -h, --help          Show this help and exit

  [release|debug]     swift build configuration, positional (default: release)
                       ignored when --bin is given.
USAGE
}

APP_NAME="KubeView"
BUNDLE_ID="com.omaksi.kubeview"
PRODUCT="KubeView"
ICON=""
BIN_OVERRIDE=""
OUT_DIR=""
VERSION="0.1"
CONFIG="release"

while [ $# -gt 0 ]; do
  case "$1" in
    --app-name) APP_NAME="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --product) PRODUCT="$2"; shift 2 ;;
    --icon) ICON="$2"; shift 2 ;;
    --bin) BIN_OVERRIDE="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    release|debug) CONFIG="$1"; shift ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT_DIR="${OUT_DIR:-$ROOT/build}"

# Each known app has its own icon; an --app-name outside this pair still
# defaults to AppIcon.icns (matching every version of this script before
# there were two apps). --icon always wins when given.
if [ -z "$ICON" ]; then
  case "$APP_NAME" in
    LgtmView) ICON="$ROOT/Resources/LgtmView.icns" ;;
    *)        ICON="$ROOT/Resources/AppIcon.icns" ;;
  esac
fi

if [ -z "$BIN_OVERRIDE" ]; then
  echo "Building $PRODUCT ($CONFIG)..."
  swift build -c "$CONFIG" --product "$PRODUCT"
  BIN="$ROOT/.build/$CONFIG/$PRODUCT"
else
  BIN="$BIN_OVERRIDE"
fi

if [ ! -f "$BIN" ]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

APP="$OUT_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN" "$CONTENTS/MacOS/$APP_NAME"
chmod +x "$CONTENTS/MacOS/$APP_NAME"

# Regenerate a default icon if missing - but only a default; an explicit
# --icon that's missing is always a hard error, never a silent fallback to
# whatever icon happens to already be on disk (an early LgtmView build
# bundled KubeView's icon this way, caught in review before it shipped).
if [ ! -f "$ICON" ]; then
  case "$ICON" in
    "$ROOT/Resources/AppIcon.icns")  "$ROOT/scripts/make_icon.swift" kubeview ;;
    "$ROOT/Resources/LgtmView.icns") "$ROOT/scripts/make_icon.swift" lgtmview ;;
    *)
      echo "error: icon not found at $ICON" >&2
      exit 1
      ;;
  esac
fi
cp "$ICON" "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Built $APP"
echo "Run with:  open '$APP'"
