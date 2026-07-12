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

if [ -f package.json ]; then
  npm install
  npm run build:pi-helper
fi

swift build -c release

release_products_dir="$(swift build -c release --show-bin-path)"
built_bin="$release_products_dir/LLMUsageBar"
built_bundle="$release_products_dir/$BUNDLE_NAME"

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
cp -R "$built_bundle" "$DIST_DIR/$APP_NAME/Contents/Resources/$BUNDLE_NAME"
cp -f "$ROOT_DIR/Assets/AppIcon.icns" "$DIST_DIR/$APP_NAME/Contents/Resources/AppIcon.icns"

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
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
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

CODE_SIGN_IDENTITY="${LLM_USAGE_CODESIGN_IDENTITY:-}"
if [ -z "$CODE_SIGN_IDENTITY" ] && command -v security >/dev/null 2>&1; then
  CODE_SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)"
fi

if [ -n "$CODE_SIGN_IDENTITY" ]; then
  codesign --force --deep --sign "$CODE_SIGN_IDENTITY" "$DIST_DIR/$APP_NAME"
  codesign --verify --deep --strict "$DIST_DIR/$APP_NAME"
  echo "Signed $APP_NAME with $CODE_SIGN_IDENTITY"
else
  echo "Warning: no Apple Development signing identity found; notification support will be unavailable." >&2
fi

rm -f "$DIST_DIR/$ARCHIVE_NAME"
(
  cd "$DIST_DIR"
  tar -czf "$ARCHIVE_NAME" "$APP_NAME"
  shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)

echo "Created $DIST_DIR/$ARCHIVE_NAME"
echo "Created $DIST_DIR/$ARCHIVE_NAME.sha256"
