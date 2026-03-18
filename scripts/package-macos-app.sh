#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-${VERSION:-0.1.0}}"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="LLM Usage.app"
BUNDLE_NAME="LLMUsageBar_LLMUsageBar.bundle"
ARCHIVE_NAME="LLM-Usage-macos.tar.gz"

cd "$ROOT_DIR"
swift build -c release

built_bin="$(find "$BUILD_DIR" -type f -name LLMUsageBar -path '*/release/*' | head -n 1)"
built_bundle="$(find "$BUILD_DIR" -type d -name "$BUNDLE_NAME" -path '*/release/*' | head -n 1)"

if [ -z "$built_bin" ] || [ ! -f "$built_bin" ]; then
  echo "Built LLMUsageBar binary not found" >&2
  exit 1
fi

if [ -z "$built_bundle" ] || [ ! -d "$built_bundle" ]; then
  echo "Built LLMUsageBar resource bundle not found" >&2
  exit 1
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/$APP_NAME/Contents/MacOS" "$DIST_DIR/$APP_NAME/Contents/Resources"

cp -f "$built_bin" "$DIST_DIR/$APP_NAME/Contents/MacOS/LLMUsageBar"
chmod +x "$DIST_DIR/$APP_NAME/Contents/MacOS/LLMUsageBar"
cp -R "$built_bundle" "$DIST_DIR/$APP_NAME/$BUNDLE_NAME"

cat > "$DIST_DIR/$APP_NAME/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>LLMUsageBar</string>
  <key>CFBundleIdentifier</key>
  <string>com.iainkirkpatrick.llmusagebar</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>LLM Usage</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

rm -f "$DIST_DIR/$ARCHIVE_NAME"
(
  cd "$DIST_DIR"
  tar -czf "$ARCHIVE_NAME" "$APP_NAME"
  shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)

echo "Created $DIST_DIR/$ARCHIVE_NAME"
echo "Created $DIST_DIR/$ARCHIVE_NAME.sha256"
