#!/usr/bin/env bash
# Clamp skill frontmatter so Pi / Agent Skills validators stay quiet.
# Pi warns when description length > 1024; skills still load, but the banner is noise.
set -euo pipefail

MAX_DESC=1024
AGENTS_DIR="${HOME}/.agents/skills"

need_yq() {
  command -v yq >/dev/null 2>&1 || {
    echo "✗ needs yq (brew install yq)" >&2
    exit 1
  }
}

desc_len() {
  local file=$1
  yq --front-matter=extract -o=json '.description // ""' "$file" |
    python3 -c 'import json,sys; v=json.load(sys.stdin); print(len(v) if isinstance(v,str) else 0)'
}

need_yq
[[ -d "$AGENTS_DIR" ]] || exit 0

fixed=0
for skill in "$AGENTS_DIR"/*/; do
  [[ -d "$skill" ]] || continue
  skill_md="${skill}SKILL.md"
  [[ -f "$skill_md" ]] || continue
  yq --front-matter=extract '.description | type' "$skill_md" 2>/dev/null | grep -q '!!str' || continue
  len=$(desc_len "$skill_md")
  [[ "$len" -gt "$MAX_DESC" ]] || continue
  yq --front-matter=process ".description |= .[:${MAX_DESC}]" -i "$skill_md"
  echo "→ clamped description: $(basename "$skill") (${len}→${MAX_DESC})"
  fixed=$((fixed + 1))
done

[[ "$fixed" -eq 0 ]] || echo "✓ normalized ${fixed} skill description(s) for Pi"
