#!/usr/bin/env bash
# install-pstack.sh — skills → all agents, plus Cursor local plugin for /poteto-mode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COLLECTION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="https://github.com/cursor/plugins/tree/main/pstack"
PLUGIN_DIR="${HOME}/.cursor/plugins/local/pstack"

# Pi /skill:NAME splits on first space; Agent Skills require ^[a-z0-9-]+$
normalize_poteto_skill_name() {
  local skill_md=$1
  [[ -f "$skill_md" ]] || return 0
  grep -q '^name: Poteto Mode$' "$skill_md" || return 0
  sed -i.bak 's/^name: Poteto Mode$/name: poteto-mode/' "$skill_md"
  rm -f "${skill_md}.bak"
}

cd "$COLLECTION_DIR"
agents=$(yq -r '.agents' collection.yaml)
# shellcheck disable=SC2086
npx skills add "$SOURCE" -g ${agents} --skill '*' -y </dev/null
normalize_poteto_skill_name "${HOME}/.agents/skills/poteto-mode/SKILL.md"

# Cursor slash commands / modes / agents come from the plugin, not ~/.cursor/skills alone
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git clone --depth 1 --filter=blob:none --sparse https://github.com/cursor/plugins.git "$TMP/plugins"
git -C "$TMP/plugins" sparse-checkout set pstack
mkdir -p "$(dirname "$PLUGIN_DIR")"
rm -rf "$PLUGIN_DIR"
cp -R "$TMP/plugins/pstack" "$PLUGIN_DIR"
normalize_poteto_skill_name "${PLUGIN_DIR}/skills/poteto-mode/SKILL.md"
echo "✓ cursor plugin: ${PLUGIN_DIR}"
echo "  Reload Window (or restart Cursor), then use /poteto-mode"
