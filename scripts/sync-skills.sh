#!/usr/bin/env bash
# sync-skills.sh — fan ~/.agents/skills/* out to agents the `skills` CLI misses.
#
# `npx skills add` writes the canonical copy to ~/.agents/skills and populates
# some agent dirs itself (Claude Code, Pi, …). It reports success for Codex and
# Antigravity CLI but does not actually write their skill dirs, so we symlink
# those ourselves. A target is only synced if its home dir already exists —
# agents you don't have installed are silently skipped.
#
# Agents installed under a *different* OS on another partition are also synced,
# but by copy rather than symlink: a symlink into this volume's home would
# dangle once that OS boots and the mount points change. Set
# HARNESS_CROSS_VOLUME=0 to keep the sync local to the running system.
set -euo pipefail

AGENTS_DIR="${HOME}/.agents/skills"
if [[ ! -d "$AGENTS_DIR" ]]; then
  # nothing installed on the running system yet; propagating now would only
  # push emptiness onto other installs
  echo "· ${AGENTS_DIR} missing — run ./pony.harness.sh --agents first, nothing to sync"
  exit 0
fi

CROSS_VOLUME="${HARNESS_CROSS_VOLUME:-1}"
MARKER=".harness-managed"

# label|relative guard dir (must exist)|relative destination skills dir
TARGETS=(
  "cursor|.cursor|.cursor/skills"
  "agy|.gemini|.gemini/config/skills"
  "codex|.codex|.codex/skills"
)
# these the `skills` CLI populates itself on the local system, but a foreign
# install has never been touched by it, so they need filling there too
FOREIGN_TARGETS=(
  "claude-code|.claude|.claude/skills"
  "pi|.pi|.pi/agent/skills"
)

# dev:inode identity — the same volume can surface at several mount points
# (an APFS system volume and its firmlinked data volume, the booted disk
# re-exposed under /Volumes), and each would otherwise be synced again.
ident() {
  stat -f '%d:%i' "$1" 2>/dev/null || stat -c '%d:%i' "$1" 2>/dev/null
}

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

copy_into() {
  local label=$1 dest=$2
  local copied=0 name src dst

  mkdir -p "$dest"
  for skill in "$AGENTS_DIR"/*/; do
    [[ -d "$skill" ]] || continue
    name="$(basename "$skill")"
    src="${AGENTS_DIR}/${name}"
    dst="${dest}/${name}"

    # only ever replace a copy we made ourselves
    if [[ -e "$dst" && ! -e "${dst}/${MARKER}" ]]; then
      continue
    fi

    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete --exclude "$MARKER" "${src}/" "${dst}/"
    else
      rm -rf "$dst"
      mkdir -p "$dst"
      cp -R "${src}/." "${dst}/"
    fi
    : >"${dst}/${MARKER}"
    copied=$((copied + 1))
  done

  echo "✓ ${label}: copied ${copied} skill(s) → ${dest}"
}

# sync_home <home> <link|copy> <prefix> [extra targets…]
sync_home() {
  local home=$1 mode=$2 prefix=$3
  shift 3
  local entry label guard dest
  local -a list=("${TARGETS[@]}" "$@")

  for entry in "${list[@]}"; do
    IFS='|' read -r label guard dest <<< "$entry"
    if [[ -d "${home}/${guard}" ]]; then
      "${mode}_into" "${prefix}${label}" "${home}/${dest}"
    elif [[ -z "$prefix" ]]; then
      echo "· ${label}: not installed, skipped"
    fi
  done
}

# --- local system -------------------------------------------------------
sync_home "$HOME" link ""

# --- other partitions ---------------------------------------------------
[[ "$CROSS_VOLUME" == "0" ]] && exit 0

# mounted volumes worth scanning: macOS /Volumes, Linux/WSL /mnt and /media,
# Git Bash drive letters (/c, /d, …)
candidate_homes() {
  local root
  for root in /Volumes/* /mnt/* /media/* /media/*/* /[a-z]; do
    [[ -d "$root/Users" ]] && printf '%s\n' "$root"/Users/*/
    [[ -d "$root/home" ]] && printf '%s\n' "$root"/home/*/
  done 2>/dev/null
}

seen="$(ident "$HOME")"
found=0

while IFS= read -r home; do
  home="${home%/}"
  [[ -d "$home" ]] || continue

  id="$(ident "$home")"
  [[ -n "$id" ]] || continue
  case ":${seen}:" in *":${id}:"*) continue ;; esac
  seen="${seen}:${id}"

  # does anything agent-shaped live here at all?
  has=0
  for entry in "${TARGETS[@]}" "${FOREIGN_TARGETS[@]}"; do
    IFS='|' read -r _ guard _ <<< "$entry"
    [[ -d "${home}/${guard}" ]] && { has=1; break; }
  done
  [[ "$has" == 1 ]] || continue

  if [[ ! -w "$home" ]]; then
    echo "· ${home}: read-only, skipped" >&2
    continue
  fi

  echo "· foreign install: ${home}"
  sync_home "$home" copy "  " "${FOREIGN_TARGETS[@]}"
  found=$((found + 1))
done < <(candidate_homes)

[[ "$found" -gt 0 ]] && echo "✓ synced ${found} foreign install(s) by copy"
exit 0
