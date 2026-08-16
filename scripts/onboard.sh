#!/usr/bin/env bash
# onboard.sh — detect the agents actually on this box, then pick skills.
# Writes `agents` and `selected` back into collection.yaml. Sourced by the
# harness; run directly it does the same thing.
set -euo pipefail

ONBOARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECTION_DIR="${COLLECTION_DIR:-$(cd "$ONBOARD_DIR/.." && pwd)}"
MANIFEST="${MANIFEST:-$COLLECTION_DIR/collection.yaml}"
# shellcheck source=scripts/ui.sh
source "$ONBOARD_DIR/ui.sh"

# `skills` CLI agent id | probe dir under $HOME | display name
KNOWN_AGENTS=(
  "claude-code|.claude|Claude Code"
  "codex|.codex|Codex / ChatGPT"
  "cursor|.cursor|Cursor"
  "antigravity-cli|.gemini|agy (Antigravity)"
  "pi|.pi|Pi"
  "zed|.zed|Zed"
)

detect_agents() {
  local entry id probe name
  DETECTED=()
  DETECTED_LABELS=()
  for entry in "${KNOWN_AGENTS[@]}"; do
    IFS='|' read -r id probe name <<< "$entry"
    if [[ -d "${HOME}/${probe}" ]]; then
      DETECTED+=("$id")
      DETECTED_LABELS+=("${id}"$'\t'"${name}")
    fi
  done
}

onboard() {
  local -a agent_ids=() cats=()
  local id cat desc n

  ui_title "harness-core"
  ui_note "curated, deterministic agent skills — installed once, synced everywhere"

  # No terminal to prompt on (CI, a pipe with no tty). Picking nothing here
  # would silently install nothing, so leave the manifest alone — an absent
  # `selected` key already means "every category".
  if ! ui_interactive; then
    ui_note "non-interactive — keeping the current selection"
    return 0
  fi

  # --- agents ---
  detect_agents
  if [[ ${#DETECTED[@]} -eq 0 ]]; then
    ui_warn "no agents detected under \$HOME — keeping the manifest's agent list"
  else
    ui_multiselect "Agents found on this machine" 1 "${DETECTED_LABELS[@]}" || return 130
    agent_ids=("${UI_PICKED[@]}")
    if [[ ${#agent_ids[@]} -eq 0 ]]; then
      ui_warn "no agents selected — nothing would be installed"
      return 1
    fi
  fi

  # --- categories ---
  local -a cat_items=()
  while IFS=$'\t' read -r cat desc; do
    n=$(CAT="$cat" yq -r '.skills[strenv(CAT)] | keys | length' "$MANIFEST")
    cat_items+=("${cat}"$'\t'"$(printf '%-9s %s (%s)' "$cat" "$desc" "$n")")
  done < <(yq -r '.categories | to_entries[] | .key + "\t" + .value' "$MANIFEST")

  ui_multiselect "Skill categories — install none, some, or all" 0 "${cat_items[@]}" || return 130
  cats=("${UI_PICKED[@]}")

  # --- write it back ---
  local agents_str=""
  for id in "${agent_ids[@]}"; do agents_str+="-a ${id} "; done
  agents_str="${agents_str% }"

  if [[ -n "$agents_str" ]]; then
    AG="$agents_str" yq -i '.agents = strenv(AG)' "$MANIFEST"
  fi
  # `selected` is what sync installs; absent means "everything"
  yq -i 'del(.selected)' "$MANIFEST"
  for cat in "${cats[@]}"; do
    CAT="$cat" yq -i '.selected += [strenv(CAT)]' "$MANIFEST"
  done

  printf '\n'
  ui_note "agents:     ${agents_str:-unchanged}"
  if [[ ${#cats[@]} -eq 0 ]]; then
    ui_note "categories: none — run 'harness onboard' again to pick some"
  else
    ui_note "categories: ${cats[*]}"
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  onboard
fi
