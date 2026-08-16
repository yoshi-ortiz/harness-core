#!/usr/bin/env bash
# sync-skills.sh — fan ~/.agents/skills/* out to agents the `skills` CLI misses.
#
# `npx skills add` writes the canonical copy to ~/.agents/skills and populates
# some agent dirs itself (Claude Code, Pi, …). It reports success for Codex and
# Antigravity CLI but does not actually write their skill dirs, so we symlink
# those ourselves. A target is only synced if its home dir already exists —
# agents you don't have installed are silently skipped.
set -euo pipefail

AGENTS_DIR="${HOME}/.agents/skills"
[[ -d "$AGENTS_DIR" ]] || exit 0

# label|guard dir (must exist)|destination skills dir
TARGETS=(
  "cursor|${HOME}/.cursor|${HOME}/.cursor/skills"
  "agy|${HOME}/.gemini|${HOME}/.gemini/config/skills"
  "codex|${HOME}/.codex|${HOME}/.codex/skills"
)

link_into() {
  local label=$1 dest=$2
  local linked=0 name target link current

  mkdir -p "$dest"
  for skill in "$AGENTS_DIR"/*/; do
    [[ -d "$skill" ]] || continue
    name="$(basename "$skill")"
    target="${AGENTS_DIR}/${name}"
    link="${dest}/${name}"

    if [[ -L "$link" ]]; then
      current="$(readlink "$link")"
      [[ "$current" == "$target" ]] && continue
      rm "$link"
    elif [[ -e "$link" ]]; then
      continue  # a real dir the agent owns — never clobber
    fi

    ln -s "$target" "$link"
    linked=$((linked + 1))
  done

  if [[ "$linked" -gt 0 ]]; then
    echo "✓ ${label}: linked ${linked} skill(s) → ${dest}"
  else
    echo "✓ ${label}: up to date (${dest})"
  fi
}

for entry in "${TARGETS[@]}"; do
  IFS='|' read -r label guard dest <<< "$entry"
  if [[ -d "$guard" ]]; then
    link_into "$label" "$dest"
  else
    echo "· ${label}: not installed, skipped"
  fi
done
