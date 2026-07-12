#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${LLM_USAGE_INSTALL_DIR:-$HOME/bin}"

cd "$ROOT_DIR"
swift build -c release --product llm-usage
bin_dir="$(swift build -c release --show-bin-path)"
resource_dir="$bin_dir/LLMUsageBar_LLMUsageCore.resources"

if [ ! -x "$bin_dir/llm-usage" ]; then
  echo "Built llm-usage executable not found: $bin_dir/llm-usage" >&2
  exit 1
fi
if [ ! -d "$resource_dir" ]; then
  echo "Core resource directory not found: $resource_dir" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
install -m 0755 "$bin_dir/llm-usage" "$INSTALL_DIR/llm-usage"
rm -rf "$INSTALL_DIR/LLMUsageBar_LLMUsageCore.resources"
cp -R "$resource_dir" "$INSTALL_DIR/LLMUsageBar_LLMUsageCore.resources"

echo "Installed llm-usage to $INSTALL_DIR/llm-usage"
echo "Installed resources to $INSTALL_DIR/LLMUsageBar_LLMUsageCore.resources"
