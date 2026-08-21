# agent-skills

One collection, one harness. Requires [yq](https://github.com/mikefarah/yq) (`brew install yq`).

```
collection.yaml     agents + skills + mcp
pony.harness.sh     install entrypoint
```

## Usage

```bash
./pony.harness.sh --agents [--dry-run]
./pony.harness.sh skills add owner/repo [skill] [--install path] [--no-save]
./pony.harness.sh mcp add owner/repo [--no-save] [--dry-run]
```

`add` writes to `collection.yaml` then installs. `--no-save` skips the manifest write.

## Manifest


| Key      | Meaning                                                              |
| -------- | -------------------------------------------------------------------- |
| `agents` | Flag string for `npx skills add -g`                                  |
| `skills` | bare = all, list = named, `{ install: script }` = run script instead |
| `mcp`    | Smithery server IDs                                                  |


Skill frontmatter `name:` must be kebab-case for Pi (`/skill:name`); multi-word names break first-space expand.

Agents adding skills or MCP: see [AGENTS.md](AGENTS.md).

Never use `npx skills add … --all`.

Adding to `collection.yaml` alone does not install skills. Run:

```bash
./pony.harness.sh --agents          # install everything in the manifest
./pony.harness.sh skills add …      # add one skill (writes manifest + installs)
```

Skills land in `~/.agents/skills/` and are symlinked into `~/.cursor/skills/`. **Start a new Cursor chat** after installing — the skill list is loaded at session start.

## Design skills

| Skill | Source |
|-------|--------|
| `frontend-design` | [anthropics/skills](https://github.com/anthropics/skills) |
| `ui-ux-pro-max` | [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) |

Also in the collection: `modern-web-guidance`, `shadcn`, `next-best-practices`, `storybook-story-writing`.

## Vercel skills

| Skill | Source |
|-------|--------|
| `vercel-composition-patterns` | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) |
| `vercel-react-best-practices` | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) |
| `web-design-guidelines` | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) |

