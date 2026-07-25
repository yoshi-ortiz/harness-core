#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
MANIFEST=collection.yaml
COLLECTION_DIR="$(pwd)"
DRY_RUN=false
NO_SAVE=false
AGENT_FLAGS=()

usage() {
  cat >&2 <<EOF
usage:
  pony.harness.sh --agents [--dry-run]
  pony.harness.sh skills add owner/repo [skill] [--install path] [--no-save] [--dry-run]
  pony.harness.sh mcp add owner/repo [--no-save] [--dry-run]
EOF
  exit 1
}

need_yq() {
  command -v yq >/dev/null 2>&1 || {
    echo "✗ needs yq (brew install yq)" >&2
    exit 1
  }
}

need_smithery() {
  $DRY_RUN || command -v smithery >/dev/null 2>&1 || {
    echo "✗ needs smithery (npm install -g smithery@latest)" >&2
    exit 1
  }
}

load_agents() {
  need_yq
  read -ra AGENT_FLAGS <<< "$(yq -r '.agents' "$MANIFEST")"
}

manifest_has() {
  local section=$1 key=$2
  KEY=$key yq -e ".${section} | has(strenv(KEY))" "$MANIFEST" >/dev/null 2>&1
}

save_skill() {
  local source=$1 named=${2:-} install_path=${3:-}
  need_yq
  manifest_has skills "$source" && return 0
  if $DRY_RUN; then
    if [[ -n "$install_path" ]]; then
      echo "yq -i '.skills[strenv(KEY)] = {\"install\": strenv(PATH)}' collection.yaml"
    elif [[ -n "$named" ]]; then
      echo "yq -i '.skills[strenv(KEY)] = [strenv(NAME)]' collection.yaml"
    else
      echo "yq -i '.skills[strenv(KEY)] = null' collection.yaml"
    fi
    return
  fi
  if [[ -n "$install_path" ]]; then
    KEY=$source PATH=$install_path yq -i '.skills[strenv(KEY)] = {"install": strenv(PATH)}' "$MANIFEST"
  elif [[ -n "$named" ]]; then
    KEY=$source NAME=$named yq -i '.skills[strenv(KEY)] = [strenv(NAME)]' "$MANIFEST"
  else
    KEY=$source yq -i '.skills[strenv(KEY)] = null' "$MANIFEST"
  fi
}

save_mcp() {
  local server=$1
  need_yq
  manifest_has mcp "$server" && return 0
  if $DRY_RUN; then
    echo "yq -i '.mcp[strenv(KEY)] = null' collection.yaml"
    return
  fi
  KEY=$server yq -i '.mcp[strenv(KEY)] = null' "$MANIFEST"
}

run_or_print() {
  if $DRY_RUN; then
    printf '%q ' "$@"
    echo
  else
    echo "→ $*"
    "$@"
  fi
}

install_skill() {
  local source=$1 named=${2:-}
  local install listed s
  local -a skill_flags=()

  need_yq
  install=$(KEY=$source yq -r '.skills[strenv(KEY)] | select(tag == "!!map") | .install // ""' "$MANIFEST")
  if [[ -n "$install" && -z "$named" ]]; then
    install="${install/#\~/$HOME}"
    if $DRY_RUN; then
      echo "bash $(printf '%q' "$install")"
      return
    fi
    [[ -x "$install" ]] || {
      echo "✗ ${source}: ${install} missing" >&2
      exit 1
    }
    echo "→ install ${source}"
    bash "$install"
    return
  fi

  load_agents
  if [[ -n "$named" ]]; then
    skill_flags=(-s "$named")
  else
    listed=$(KEY=$source yq -r '.skills[strenv(KEY)] | select(tag == "!!seq") | join(" ")' "$MANIFEST")
    if [[ -n "$listed" ]]; then
      for s in $listed; do skill_flags+=(-s "$s"); done
    else
      skill_flags=(--skill '*')
    fi
  fi

  local cmd=(npx skills add "$source" -g "${AGENT_FLAGS[@]}" "${skill_flags[@]}" -y)
  if $DRY_RUN; then
    printf '%q ' "${cmd[@]}"
    echo
  else
    echo "→ skills add ${source}"
    "${cmd[@]}" </dev/null
  fi
}

smithery_clients() {
  local -a clients=()
  local i agent
  load_agents
  for ((i = 0; i < ${#AGENT_FLAGS[@]}; i++)); do
    [[ "${AGENT_FLAGS[i]}" == -a ]] || continue
    agent="${AGENT_FLAGS[i + 1]:-}"
    case "$agent" in
      cursor) clients+=(cursor) ;;
      claude-code) clients+=(claude) ;;
      zed) clients+=(zed) ;;
    esac
  done
  printf '%s\n' "${clients[@]}"
}

install_mcp() {
  local server=$1 c
  need_smithery
  local -a clients=()
  while IFS= read -r c; do
    [[ -n "$c" ]] && clients+=("$c")
  done < <(smithery_clients)
  [[ ${#clients[@]} -gt 0 ]] || {
    echo "✗ no Smithery clients in agents string" >&2
    exit 1
  }
  for c in "${clients[@]}"; do
    run_or_print smithery mcp add "$server" --client "$c"
  done
}

sync_cursor_skills() {
  local script="${COLLECTION_DIR:-.}/scripts/sync-cursor-skills.sh"
  [[ -x "$script" ]] || return 0
  if $DRY_RUN; then
    echo "bash $(printf '%q' "$script")"
  else
    bash "$script"
  fi
}

sync_agents() {
  need_yq
  local source server
  while read -r source; do
    [[ -n "$source" ]] || continue
    install_skill "$source" || echo "✗ skipped failed source: $source" >&2  # ponytail: one bad repo shouldn't kill the rest
  done < <(yq -r '.skills | keys[]' "$MANIFEST")
  sync_cursor_skills
  if yq -e '.mcp' "$MANIFEST" >/dev/null 2>&1; then
    while read -r server; do
      [[ -n "$server" ]] || continue
      install_mcp "$server" || echo "✗ skipped failed mcp: $server" >&2
    done < <(yq -r '.mcp | keys[]' "$MANIFEST")
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --agents) ACTION=agents; shift ;;
    skills)
      shift
      [[ "${1:-}" == add && -n "${2:-}" ]] || usage
      ACTION=skill
      SKILL_REPO=$2
      shift 2
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run) DRY_RUN=true; shift ;;
          --no-save) NO_SAVE=true; shift ;;
          --install)
            shift
            [[ -n "${1:-}" ]] || usage
            INSTALL_PATH=$1
            shift
            ;;
          *) [[ -z "${SKILL_NAME:-}" ]] || usage; SKILL_NAME=$1; shift ;;
        esac
      done
      ;;
    mcp)
      shift
      [[ "${1:-}" == add && -n "${2:-}" ]] || usage
      ACTION=mcp
      MCP_REPO=$2
      shift 2
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run) DRY_RUN=true; shift ;;
          --no-save) NO_SAVE=true; shift ;;
          *) usage ;;
        esac
      done
      ;;
    *) usage ;;
  esac
done

case "${ACTION:-}" in
  agents) sync_agents ;;
  skill)
    $NO_SAVE || save_skill "$SKILL_REPO" "${SKILL_NAME:-}" "${INSTALL_PATH:-}"
    install_skill "$SKILL_REPO" "${SKILL_NAME:-}"
    sync_cursor_skills
    ;;
  mcp)
    $NO_SAVE || save_mcp "$MCP_REPO"
    install_mcp "$MCP_REPO"
    ;;
  *) usage ;;
esac
