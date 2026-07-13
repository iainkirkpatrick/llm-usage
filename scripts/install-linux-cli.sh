#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${LLM_USAGE_INSTALL_DIR:-$HOME/bin}"
cd "$ROOT_DIR"
npm ci
npm run build
mkdir -p "$INSTALL_DIR"
install -m 0644 dist-node/llm-usage.mjs "$INSTALL_DIR/llm-usage.mjs"
install -m 0644 node/runtime-package.json "$INSTALL_DIR/package.json"
cat > "$INSTALL_DIR/llm-usage" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
home="${HOME:-$(eval echo ~)}"
for candidate in "${LLM_BAR_NODE_PATH:-}" "$home/bin/node" "$home/.volta/bin/node" /usr/local/bin/node /usr/bin/node; do
  candidate="${candidate/#\~/$home}"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then exec "$candidate" "$(dirname "$0")/llm-usage.mjs" "$@"; fi
done
node="$(command -v node 2>/dev/null || true)"
[ -n "$node" ] || { echo "Node.js executable not found" >&2; exit 1; }
exec "$node" "$(dirname "$0")/llm-usage.mjs" "$@"
LAUNCHER
chmod 0755 "$INSTALL_DIR/llm-usage"
echo "Installed Node Codex CLI to $INSTALL_DIR/llm-usage"
