#!/usr/bin/env bash
# sync-agy-skills.sh — bridge ~/.agents/skills/* → ~/.gemini/config/plugins/
# Each skill becomes its own plugin: skills/<name>/SKILL.md (uppercased)
set -euo pipefail

SKILLS_DIR="${HOME}/.agents/skills"
PLUGINS_DIR="${HOME}/.gemini/config/plugins"
PLUGIN_NAME="agent-skills-bridge"
PLUGIN_DIR="${PLUGINS_DIR}/${PLUGIN_NAME}"
SKILLS_OUT="${PLUGIN_DIR}/skills"

mkdir -p "${SKILLS_OUT}"

# Write plugin.json once
cat > "${PLUGIN_DIR}/plugin.json" <<'JSON'
{
  "name": "agent-skills-bridge",
  "version": "1.0.0",
  "description": "Auto-bridged skills from ~/.agents/skills via pony.harness",
  "author": { "name": "local" }
}
JSON

count=0
skipped=0

for skill_dir in "${SKILLS_DIR}"/*/; do
  skill_name="$(basename "${skill_dir}")"

  # Find the canonical skill markdown file (skill.md or SKILL.md)
  src=""
  for candidate in "${skill_dir}skill.md" "${skill_dir}SKILL.md"; do
    [[ -f "${candidate}" ]] && { src="${candidate}"; break; }
  done

  if [[ -z "${src}" ]]; then
    ((skipped++)) || true
    continue
  fi

  dest_dir="${SKILLS_OUT}/${skill_name}"
  dest="${dest_dir}/SKILL.md"
  mkdir -p "${dest_dir}"

  # Symlink instead of copy so updates in ~/.agents/skills are reflected immediately
  if [[ ! -L "${dest}" && ! -f "${dest}" ]]; then
    ln -s "${src}" "${dest}"
    ((count++)) || true
  elif [[ -L "${dest}" ]]; then
    # already linked — ensure it points to the right place
    current_target="$(readlink "${dest}")"
    if [[ "${current_target}" != "${src}" ]]; then
      ln -sf "${src}" "${dest}"
    fi
    ((count++)) || true
  fi
done

echo "✓ agent-skills-bridge: ${count} skills linked, ${skipped} skipped (no skill.md)"
echo "  Plugin: ${PLUGIN_DIR}"
