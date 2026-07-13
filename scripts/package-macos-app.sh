#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-${VERSION:-0.1.0}}"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="LLM Usage.app"
ARCHIVE_NAME="LLM-Usage-macos.tar.gz"
cd "$ROOT_DIR"

npm ci
npm run build
swift build -c release --product LLMUsageBar
bin_dir="$(swift build -c release --show-bin-path)"
built_bin="$bin_dir/LLMUsageBar"
built_app_bundle="$bin_dir/LLMUsageBar_LLMUsageBar.bundle"
[ -x "$built_bin" ] || { echo "Built LLMUsageBar binary not found" >&2; exit 1; }
[ -d "$built_app_bundle" ] || { echo "Built LLMUsageBar resource bundle not found" >&2; exit 1; }
[ -f "$ROOT_DIR/dist-node/llm-usage.mjs" ] || { echo "Node bundle not found" >&2; exit 1; }

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/$APP_NAME/Contents/MacOS" "$DIST_DIR/$APP_NAME/Contents/Resources"
cp "$built_bin" "$DIST_DIR/$APP_NAME/Contents/MacOS/LLMUsageBar"
cp -R "$built_app_bundle" "$DIST_DIR/$APP_NAME/Contents/Resources/LLMUsageBar_LLMUsageBar.bundle"
cp "$ROOT_DIR/dist-node/llm-usage.mjs" "$DIST_DIR/$APP_NAME/Contents/Resources/llm-usage.mjs"
cp "$ROOT_DIR/node/runtime-package.json" "$DIST_DIR/$APP_NAME/Contents/Resources/package.json"
cp "$ROOT_DIR/Assets/AppIcon.icns" "$DIST_DIR/$APP_NAME/Contents/Resources/AppIcon.icns"
cat > "$DIST_DIR/$APP_NAME/Contents/MacOS/llm-usage" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
home="${HOME:-$(eval echo ~)}"
find_node() {
  local candidate
  for candidate in "${LLM_BAR_NODE_PATH:-}" "$home/bin/node" "$home/.volta/bin/node" /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    if [ -n "$candidate" ] && [ -x "${candidate/#\~/$home}" ]; then echo "${candidate/#\~/$home}"; return 0; fi
  done
  command -v node 2>/dev/null && return 0
  for shell in /bin/zsh /bin/bash; do [ -x "$shell" ] && { "$shell" -lc 'command -v node' 2>/dev/null && return 0; }; done
  return 1
}
node="$(find_node)" || { echo "Node.js executable not found" >&2; exit 1; }
exec "$node" "$root/Resources/llm-usage.mjs" "$@"
LAUNCHER
chmod +x "$DIST_DIR/$APP_NAME/Contents/MacOS/llm-usage" "$DIST_DIR/$APP_NAME/Contents/MacOS/LLMUsageBar"
cat > "$DIST_DIR/$APP_NAME/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LLMUsageBar</string><key>CFBundleIdentifier</key><string>com.iainkirkpatrick.llmusagebar</string>
<key>CFBundleName</key><string>LLM Usage</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string><key>CFBundleVersion</key><string>${VERSION}</string>
<key>CFBundleIconFile</key><string>AppIcon</string><key>LSUIElement</key><true/><key>NSHighResolutionCapable</key><true/>
</dict></plist>
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
(cd "$DIST_DIR" && tar -czf "$ARCHIVE_NAME" "$APP_NAME" && shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")
echo "Created $DIST_DIR/$ARCHIVE_NAME"
