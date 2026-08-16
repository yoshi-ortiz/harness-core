#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
MANIFEST=collection.yaml
COLLECTION_DIR="$(pwd)"
DRY_RUN=false
NO_SAVE=false
CATEGORY=""
AGENT_FLAGS=()

# shellcheck source=scripts/ui.sh
source "${COLLECTION_DIR}/scripts/ui.sh"

usage() {
  local code=${1:-1}
  # help is not an error: -h prints to stdout and exits clean
  [[ $code -eq 0 ]] && exec 3>&1 || exec 3>&2
  cat >&3 <<EOF
harness — curated agent skills, installed once and synced everywhere

  harness onboard                 pick agents + skill categories (interactive)
  harness sync                    install what's selected in collection.yaml
  harness upgrade                 pull, refresh tools, reinstall at latest
  harness status                  what's selected, detected, and installed
  harness version

  harness add <owner/repo> [skill]      add a skill   (alias: skills add)
  harness mcp add <server>              add an MCP server

flags: --dry-run  --no-save  --all  --category <name>  --install <path>

\`harness add\` is \`npx skills add\` plus the manifest and the cross-agent sync.
EOF
  exit "$code"
}

need_yq() {
  command -v yq >/dev/null 2>&1 || {
    echo "✗ needs yq (brew install yq)" >&2
    exit 1
  }
}

# nvm puts node on the PATH from a shell rc, which a non-login run of this
# script never reads — so `npx` goes missing under the `harness` shim, in cron,
# and from an editor. Source nvm ourselves when that happens.
NODE_LOADED=0
load_node() {
  [[ $NODE_LOADED == 1 ]] && return 0
  command -v npx >/dev/null 2>&1 && { NODE_LOADED=1; return 0; }
  local f
  for f in "${NVM_DIR:-$HOME/.nvm}/nvm.sh" "$(brew --prefix 2>/dev/null)/opt/nvm/nvm.sh"; do
    [[ -s "$f" ]] || continue
    set +u
    # shellcheck disable=SC1090
    . "$f"
    nvm use --lts >/dev/null 2>&1 || nvm use default >/dev/null 2>&1 || true
    set -u
    if command -v npx >/dev/null 2>&1; then NODE_LOADED=1; return 0; fi
  done
  echo "✗ node/npx not found — run the installer, or 'nvm use --lts'" >&2
  return 1
}

have_smithery() {
  $DRY_RUN && return 0
  command -v smithery >/dev/null 2>&1 && return 0
  load_node >/dev/null 2>&1 || true
  command -v smithery >/dev/null 2>&1
}

need_smithery() {
  have_smithery || {
    echo "✗ needs smithery (npm install -g smithery@latest)" >&2
    return 1
  }
}

load_agents() {
  need_yq
  read -ra AGENT_FLAGS <<< "$(yq -r '.agents' "$MANIFEST")"
}

# --- manifest queries (skills are nested one level under a category) -----
selected_categories() {
  need_yq
  # no `selected` key at all → everything; an explicit empty list → nothing
  if yq -e 'has("selected")' "$MANIFEST" >/dev/null 2>&1; then
    yq -r '.selected[]? // empty' "$MANIFEST"
  else
    yq -r '.skills | keys[]' "$MANIFEST"
  fi
}

selected_sources() {
  local cat
  while read -r cat; do
    [[ -n "$cat" ]] || continue
    CAT="$cat" yq -r '.skills[strenv(CAT)] // {} | keys[]' "$MANIFEST"
  done < <(selected_categories)
}

category_of() {
  SRC="$1" yq -r \
    '.skills | to_entries[] | select(.value | has(strenv(SRC))) | .key' "$MANIFEST" | head -1
}

# spec for one source, wherever it lives
source_spec() {
  SRC="$1" yq -r '[.skills[] | select(has(strenv(SRC))) | .[strenv(SRC)]][0]' "$MANIFEST"
}

manifest_has() {
  local section=$1 key=$2
  if [[ "$section" == skills ]]; then
    KEY=$key yq -e '[.skills[] | has(strenv(KEY))] | any' "$MANIFEST" >/dev/null 2>&1
  else
    KEY=$key yq -e ".${section} | has(strenv(KEY))" "$MANIFEST" >/dev/null 2>&1
  fi
}

save_skill() {
  local source=$1 named=${2:-} install_path=${3:-}
  local cat="${CATEGORY:-custom}"
  need_yq
  manifest_has skills "$source" && return 0
  if $DRY_RUN; then
    echo "yq -i '.skills.${cat}[\"${source}\"] = …' collection.yaml"
    return
  fi
  if [[ -n "$install_path" ]]; then
    CAT=$cat KEY=$source VAL=$install_path \
      yq -i '.skills[strenv(CAT)][strenv(KEY)] = {"install": strenv(VAL)}' "$MANIFEST"
  elif [[ -n "$named" ]]; then
    CAT=$cat KEY=$source NAME=$named \
      yq -i '.skills[strenv(CAT)][strenv(KEY)] = [strenv(NAME)]' "$MANIFEST"
  else
    CAT=$cat KEY=$source yq -i '.skills[strenv(CAT)][strenv(KEY)] = null' "$MANIFEST"
  fi
  # a brand-new category must join the selection, or sync would skip it
  if yq -e 'has("selected")' "$MANIFEST" >/dev/null 2>&1; then
    CAT=$cat yq -i '.selected = (.selected + [strenv(CAT)] | unique)' "$MANIFEST"
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
    "$@"
  fi
}

# --- install ------------------------------------------------------------
install_skill() {
  local source=$1 named=${2:-}
  local install listed s spec
  local -a skill_flags=()

  need_yq
  spec="$(source_spec "$source")"
  install=$(SRC="$source" yq -r \
    '[.skills[] | select(has(strenv(SRC))) | .[strenv(SRC)]][0] | select(tag == "!!map") | .install // ""' \
    "$MANIFEST")

  if [[ -n "$install" && -z "$named" ]]; then
    install="${install/#\~/$HOME}"
    # relative paths resolve against the collection, not the caller's cwd
    [[ "$install" == /* ]] || install="${COLLECTION_DIR}/${install}"
    if $DRY_RUN; then
      echo "bash $(printf '%q' "$install")"
      return
    fi
    [[ -x "$install" ]] || {
      echo "install script ${install} missing or not executable" >&2
      return 1
    }
    bash "$install"
    return
  fi

  load_agents
  if [[ -n "$named" ]]; then
    skill_flags=(-s "$named")
  else
    listed=$(SRC="$source" yq -r \
      '[.skills[] | select(has(strenv(SRC))) | .[strenv(SRC)]][0] | select(tag == "!!seq") | join(" ")' \
      "$MANIFEST")
    if [[ -n "$listed" ]]; then
      for s in $listed; do skill_flags+=(-s "$s"); done
    else
      skill_flags=(--skill '*')
    fi
  fi

  load_node || return 1
  local cmd=(npx skills add "$source" -g "${AGENT_FLAGS[@]}" "${skill_flags[@]}" -y)
  if $DRY_RUN; then
    printf '%q ' "${cmd[@]}"
    echo
  else
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
    echo "no Smithery clients in agents string" >&2
    return 1
  }
  for c in "${clients[@]}"; do
    run_or_print smithery mcp add "$server" --client "$c"
  done
}

sync_skills() {
  local script="${COLLECTION_DIR:-.}/scripts/sync-skills.sh"
  [[ -x "$script" ]] || return 0
  if $DRY_RUN; then
    echo "bash $(printf '%q' "$script")"
  else
    bash "$script"
  fi
}

short() { # trim the URL noise so the status column stays narrow
  local s=${1#https://github.com/}
  echo "${s#https://}"
}

sync_agents() {
  need_yq
  local source server cat count
  local -a cats=()
  while read -r cat; do [[ -n "$cat" ]] && cats+=("$cat"); done < <(selected_categories)

  if [[ ${#cats[@]} -eq 0 ]]; then
    ui_warn "no categories selected — run 'harness onboard'"
    return 0
  fi

  if $DRY_RUN; then
    while read -r source; do
      [[ -n "$source" ]] && install_skill "$source"
    done < <(selected_sources)
    sync_skills
    if yq -e '.mcp' "$MANIFEST" >/dev/null 2>&1 && have_smithery; then
      while read -r server; do
        [[ -n "$server" ]] && install_mcp "$server"
      done < <(yq -r '.mcp | keys[]' "$MANIFEST")
    fi
    return 0
  fi

  for cat in "${cats[@]}"; do
    count=$(CAT="$cat" yq -r '.skills[strenv(CAT)] // {} | keys | length' "$MANIFEST")
    [[ "$count" -gt 0 ]] || continue
    printf '\n%s%s%s %s(%s)%s\n' "$C_B" "$cat" "$C_R" "$C_DIM" "$count" "$C_R"
    while read -r source; do
      [[ -n "$source" ]] || continue
      ui_step "$(short "$source")" install_skill "$source"
    done < <(CAT="$cat" yq -r '.skills[strenv(CAT)] // {} | keys[]' "$MANIFEST")
  done

  printf '\n%s%s%s\n' "$C_B" "sync" "$C_R"
  ui_step "fan out to agent dirs" sync_skills

  if yq -e '.mcp' "$MANIFEST" >/dev/null 2>&1; then
    if have_smithery; then
      printf '\n%s%s%s\n' "$C_B" "mcp" "$C_R"
      while read -r server; do
        [[ -n "$server" ]] || continue
        ui_step "$(short "$server")" install_mcp "$server"
      done < <(yq -r '.mcp | keys[]' "$MANIFEST")
    else
      ui_warn "smithery not installed — skipping mcp (npm i -g smithery@latest)"
    fi
  fi

  ui_summary
  [[ $UI_FAIL -eq 0 ]]
}

status() {
  need_yq
  local cat sel
  ui_title "harness $(git -C "$COLLECTION_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "  collection: ${COLLECTION_DIR}"
  echo "  agents:     $(yq -r '.agents' "$MANIFEST")"
  echo "  skills dir: ${HOME}/.agents/skills"
  if [[ -d "${HOME}/.agents/skills" ]]; then
    echo "  installed:  $(find "${HOME}/.agents/skills" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ') skills"
  else
    echo "  installed:  none yet"
  fi
  printf '\n  %-10s %s\n' "CATEGORY" "REPOS"
  sel="$(selected_categories | tr '\n' ' ')"
  while read -r cat; do
    local n mark
    n=$(CAT="$cat" yq -r '.skills[strenv(CAT)] | keys | length' "$MANIFEST")
    case " $sel " in *" $cat "*) mark="${C_GRN}◉${C_R}" ;; *) mark="${C_DIM}◯${C_R}" ;; esac
    printf '  %b %-10s %s\n' "$mark" "$cat" "$n"
  done < <(yq -r '.skills | keys[]' "$MANIFEST")
}

version() {
  local rev
  rev="$(git -C "$COLLECTION_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "harness ${rev}"
  echo "  collection: ${COLLECTION_DIR}"
  echo "  skills:     ${HOME}/.agents/skills"
}

# upgrade = newest collection, newest tools, newest skills. `skills add` and
# `smithery mcp add` are both idempotent re-fetches, so sync doubles as upgrade.
upgrade() {
  if git -C "$COLLECTION_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    if $DRY_RUN; then
      echo "git -C $(printf '%q' "$COLLECTION_DIR") pull --ff-only"
    else
      ui_step "update collection" git -C "$COLLECTION_DIR" pull --ff-only
    fi
  fi
  if $DRY_RUN; then
    echo "brew upgrade yq"
    echo "npm install -g smithery@latest"
  else
    command -v brew >/dev/null 2>&1 && ui_step "refresh yq" brew upgrade yq
    command -v npm  >/dev/null 2>&1 && ui_step "refresh smithery" npm install -g smithery@latest
  fi
  sync_agents
}

onboard_cmd() {
  # shellcheck source=scripts/onboard.sh
  COLLECTION_DIR="$COLLECTION_DIR" MANIFEST="$MANIFEST" \
    source "${COLLECTION_DIR}/scripts/onboard.sh"
  onboard || return $?
  if ui_confirm "Install the selection now?" y; then
    sync_agents
  else
    ui_note "later: harness sync"
  fi
}

# --- args ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --all) ACTION=all; shift ;;
    --agents|sync) ACTION=agents; shift ;;
    onboard|init) ACTION=onboard; shift ;;
    status) ACTION=status; shift ;;
    upgrade|--upgrade) ACTION=upgrade; shift ;;
    version|--version|-v) ACTION=version; shift ;;
    -h|--help|help) usage 0 ;;
    add|skills)
      # `harness add x` and `harness skills add x` are the same thing
      [[ "$1" == skills ]] && shift
      [[ "${1:-}" == add ]] && shift
      [[ -n "${1:-}" ]] || usage
      ACTION=skill
      SKILL_REPO=$1
      shift
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run) DRY_RUN=true; shift ;;
          --no-save) NO_SAVE=true; shift ;;
          --category) shift; [[ -n "${1:-}" ]] || usage; CATEGORY=$1; shift ;;
          --install) shift; [[ -n "${1:-}" ]] || usage; INSTALL_PATH=$1; shift ;;
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
  all)
    need_yq
    yq -i 'del(.selected)' "$MANIFEST"
    sync_agents
    ;;
  onboard) onboard_cmd ;;
  status) status ;;
  upgrade) upgrade ;;
  version) version ;;
  skill)
    $NO_SAVE || save_skill "$SKILL_REPO" "${SKILL_NAME:-}" "${INSTALL_PATH:-}"
    # --dry-run prints commands on stdout; ui_step would capture them into the log
    if $DRY_RUN; then
      install_skill "$SKILL_REPO" "${SKILL_NAME:-}"
      sync_skills
    else
      ui_step "$(short "$SKILL_REPO")" install_skill "$SKILL_REPO" "${SKILL_NAME:-}"
      ui_step "fan out to agent dirs" sync_skills
      ui_summary
      [[ $UI_FAIL -eq 0 ]]
    fi
    ;;
  mcp)
    $NO_SAVE || save_mcp "$MCP_REPO"
    if $DRY_RUN; then
      install_mcp "$MCP_REPO"
    else
      ui_step "$(short "$MCP_REPO")" install_mcp "$MCP_REPO"
      ui_summary
      [[ $UI_FAIL -eq 0 ]]
    fi
    ;;
  *) usage ;;
esac
