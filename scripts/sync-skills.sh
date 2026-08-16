#!/usr/bin/env bash
# sync-skills.sh — fan ~/.agents/skills/* out to agents the `skills` CLI misses.
#
# `npx skills add` writes the canonical copy to ~/.agents/skills and populates
# some agent dirs itself (Claude Code, Pi, …). It reports success for Codex and
# Antigravity CLI but does not actually write their skill dirs, so we symlink
# those ourselves. A target is only synced if its home dir already exists —
# agents you don't have installed are silently skipped.
#
# Agents installed under a different OS on another partition are synced too:
# skills are copied into that install's own ~/.agents/skills, then linked into
# its agent dirs with *relative* symlinks. Relative links resolve correctly
# from here and from the other OS once it boots and the mount points change;
# absolute ones would not. Set HARNESS_CROSS_VOLUME=0 to keep the sync local.
set -euo pipefail

AGENTS_REL=".agents/skills"
AGENTS_DIR="${HOME}/${AGENTS_REL}"
if [[ ! -d "$AGENTS_DIR" ]]; then
  # nothing installed on the running system yet; propagating now would only
  # push emptiness onto other installs
  echo "· ${AGENTS_DIR} missing — run 'harness sync' first, nothing to fan out"
  exit 0
fi

CROSS_VOLUME="${HARNESS_CROSS_VOLUME:-1}"
MARKER=".harness-managed"

# label|guard dir (must exist)|destination skills dir — both paths relative to a home
TARGETS=(
  "cursor|.cursor|.cursor/skills"
  "agy|.gemini|.gemini/config/skills"
  "codex|.codex|.codex/skills"
)
# the `skills` CLI fills these on the running system, but has never touched a
# foreign install, so they need filling over there
FOREIGN_TARGETS=(
  "claude-code|.claude|.claude/skills"
  "pi|.pi|.pi/agent/skills"
)

# dev:inode identity — one volume can surface at several mount points (an APFS
# system volume and its firmlinked data volume, the booted disk re-exposed
# under /Volumes), and each would otherwise be treated as a separate install.
ident() {
  stat -f '%d:%i' "$1" 2>/dev/null || stat -c '%d:%i' "$1" 2>/dev/null
}

# ../.. back out of a relative dest, so links stay valid under either OS
updots() {
  local rel=$1 out="" part
  local IFS=/
  for part in $rel; do [[ -n "$part" ]] && out+="../"; done
  printf '%s' "$out"
}

# link_into <label> <dest> <target-prefix>
# target-prefix is "" for absolute links into $AGENTS_DIR, or a ../.. chain.
link_into() {
  local label=$1 dest=$2 prefix=${3:-}
  local linked=0 name target link current

  mkdir -p "$dest"
  for skill in "$AGENTS_DIR"/*/; do
    [[ -d "$skill" ]] || continue
    name="$(basename "$skill")"
    if [[ -n "$prefix" ]]; then target="${prefix}${AGENTS_REL}/${name}"
    else target="${AGENTS_DIR}/${name}"; fi
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
    echo "✓ ${label}: linked ${linked} skill(s)"
  else
    echo "✓ ${label}: up to date"
  fi
}

# mirror the canonical skills into another install's own ~/.agents/skills
mirror_agents_dir() {
  local dest=$1
  local copied=0 kept=0 name src dst

  mkdir -p "$dest"
  for skill in "$AGENTS_DIR"/*/; do
    [[ -d "$skill" ]] || continue
    name="$(basename "$skill")"
    src="${AGENTS_DIR}/${name}"
    dst="${dest}/${name}"

    # -e is false for a dangling symlink, so test -L too, or we would try to
    # rsync straight onto a link the other install owns
    if [[ -e "$dst" || -L "$dst" ]] && [[ ! -e "${dst}/${MARKER}" ]]; then
      # That install's own copy. Taking it over is what "sync" arguably means,
      # but it would overwrite data this harness never wrote, so it is opt-in.
      if [[ "${HARNESS_ADOPT:-0}" != 1 ]]; then
        kept=$((kept + 1))
        continue
      fi
      rm -rf "$dst"
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
  if [[ $kept -gt 0 ]]; then
    echo "✓ .agents/skills: copied ${copied}, left ${kept} owned by that install (HARNESS_ADOPT=1 to replace)"
  else
    echo "✓ .agents/skills: copied ${copied} skill(s)"
  fi
}

# --- local system -------------------------------------------------------
for entry in "${TARGETS[@]}"; do
  IFS='|' read -r label guard dest <<< "$entry"
  if [[ -d "${HOME}/${guard}" ]]; then
    link_into "$label" "${HOME}/${dest}"
  else
    echo "· ${label}: not installed, skipped"
  fi
done

# --- other partitions ---------------------------------------------------
[[ "$CROSS_VOLUME" == "0" ]] && exit 0

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
  mirror_agents_dir "${home}/${AGENTS_REL}"
  for entry in "${TARGETS[@]}" "${FOREIGN_TARGETS[@]}"; do
    IFS='|' read -r label guard dest <<< "$entry"
    [[ -d "${home}/${guard}" ]] || continue
    link_into "  ${label}" "${home}/${dest}" "$(updots "$dest")"
  done
  found=$((found + 1))
done < <(candidate_homes)

[[ "$found" -gt 0 ]] && echo "✓ synced ${found} foreign install(s)"
exit 0
