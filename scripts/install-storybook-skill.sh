#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COLLECTION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_PATH="${HOME}/.agents/skills/storybook-story-writing/SKILL.md"

cd "$COLLECTION_DIR"
agents=$(yq -r '.agents' collection.yaml)
# shellcheck disable=SC2086
npx skills add thebushidocollective/han -g ${agents} -s storybook-story-writing -y </dev/null

if [[ -f "$SKILL_PATH" ]]; then
  # not `sed -i ''` — that spelling is BSD-only and fails on GNU sed (Linux, Git Bash)
  tmp="$(mktemp)"
  sed '/^user-invocable: false$/d' "$SKILL_PATH" >"$tmp"
  mv "$tmp" "$SKILL_PATH"
else
  echo "✗ ${SKILL_PATH} missing after install" >&2
  exit 1
fi
