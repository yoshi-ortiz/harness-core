#!/usr/bin/env bash
# Symlink ~/.agents/skills/* into ~/.cursor/skills so Cursor picks them up.
set -euo pipefail

AGENTS_DIR="${HOME}/.agents/skills"
CURSOR_DIR="${HOME}/.cursor/skills"

[[ -d "$AGENTS_DIR" ]] || exit 0
mkdir -p "$CURSOR_DIR"

linked=0
for skill in "$AGENTS_DIR"/*/; do
  [[ -d "$skill" ]] || continue
  name="$(basename "$skill")"
  target="${AGENTS_DIR}/${name}"
  link="${CURSOR_DIR}/${name}"

  if [[ -L "$link" ]]; then
    current="$(readlink "$link")"
    [[ "$current" == "$target" || "$current" == "../../.agents/skills/${name}" ]] && continue
    rm "$link"
  elif [[ -e "$link" ]]; then
    continue
  fi

  ln -s "../../.agents/skills/${name}" "$link"
  echo "→ cursor: ${name}"
  linked=$((linked + 1))
done

[[ "$linked" -eq 0 ]] || echo "✓ synced ${linked} skill(s) to ~/.cursor/skills"

# Also bridge into Antigravity (agy) plugin directory
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGY_SYNC="${SELF_DIR}/sync-agy-skills.sh"
[[ -x "$AGY_SYNC" ]] && bash "$AGY_SYNC"
