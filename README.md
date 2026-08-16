# agent-skills

One collection, one harness. Requires [yq](https://github.com/mikefarah/yq) (`brew install yq`).

```
collection.yaml         agents + skills + mcp
pony.harness.sh         install entrypoint
scripts/sync-skills.sh  fan ~/.agents/skills out to agents the CLI misses
```

MCP installs additionally need [smithery](https://smithery.ai)
(`npm install -g smithery@latest`); without it the mcp section is skipped with a
warning rather than failing the run.

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


Never use `npx skills add … --all`.

Adding to `collection.yaml` alone does not install skills. Run:

```bash
./pony.harness.sh --agents          # install everything in the manifest
./pony.harness.sh skills add …      # add one skill (writes manifest + installs)
```

## Where skills land

`npx skills add` writes the canonical copy to `~/.agents/skills/`, then symlinks
it into a per-agent dir for Claude Code and Pi. Everything else it calls
"universal" — it assumes those agents discover `~/.agents/skills` on their own
and writes nothing further. agy doesn't: its global customization root is
`~/.gemini/config/`, and it only reads an `.agents/` dir when that dir sits in
the workspace you launched it from. So "universal" agents silently see nothing.

`scripts/sync-skills.sh` closes that gap, symlinking each skill into the dirs
those agents actually read. It runs automatically after every install. Targets
whose home dir doesn't exist are skipped.

| Agent | Skills dir | Populated by |
| --- | --- | --- |
| Claude Code (CLI, and inside the Claude desktop app) | `~/.claude/skills/` | `skills` CLI |
| Pi | `~/.pi/agent/skills/` | `skills` CLI |
| agy (Antigravity CLI) | `~/.gemini/config/skills/` | `sync-skills.sh` |
| Codex | `~/.codex/skills/` | `sync-skills.sh` |
| Cursor | `~/.cursor/skills/` | `sync-skills.sh` |

**Start a new session** in the agent after installing — skill lists are read at
session start.

### Claude desktop and ChatGPT

Neither is a valid `-a` target for the `skills` CLI (`skills add -a bogus`
prints the full list; there is no `claude-desktop` or `chatgpt`), and neither
app reads a local skills directory.

* **Claude desktop** — skills for the chat app are account-level: add them under
  Settings → Capabilities on claude.ai and they sync to the desktop app. The
  Claude Code / Cowork panes inside the desktop app *do* read `~/.claude/skills`,
  so everything in this collection is already available there.
* **ChatGPT** — the app itself has no skills setting, but its local agent runs
  out of `~/.codex/` (same dir Codex CLI uses), and reads skills from
  `~/.codex/skills/` — built-ins live alongside them in `~/.codex/skills/.system/`.
  `sync-skills.sh` fills that dir.

## Design skills

| Skill | Source |
|-------|--------|
| `frontend-design` | [anthropics/skills](https://github.com/anthropics/skills) |
| `ui-ux-pro-max` | [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) |

Also in the collection: `modern-web-guidance`, `shadcn`, `storybook-story-writing`.

## Vercel skills

| Skill | Source |
|-------|--------|
| `vercel-composition-patterns` | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) |
| `vercel-react-best-practices` | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) |
| `web-design-guidelines` | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) |

