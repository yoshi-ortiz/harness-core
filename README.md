# harness-core

A curated set of agent skills, installed once and synced to every agent on the
box — including agents living on another OS partition.

`harness` is `npx skills` plus the two things it doesn't do: **sync** (one
install reaches every agent, on every partition) and **curation** (a reviewed,
categorised set that stays deterministic, not a pile of whatever is trending).

## Quickstart

macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/yoshi-ortiz/harness-core/main/install.sh | bash
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/yoshi-ortiz/harness-core/main/install.ps1 | iex
```

It installs the deps (Homebrew or winget, git, yq, nvm, Node, smithery), puts
`harness` on your PATH, then walks you through onboarding:

```
Agents found on this machine
 ❯ ◉ Claude Code
   ◉ Codex / ChatGPT
   ◉ Cursor
   space toggle · a all · n none · ↵ confirm

Skill categories — install none, some, or all
 ❯ ◉ research  Knowledge graphs, docs lookup, multi-agent review (5)
   ◯ coding    Workflow, planning, and language-agnostic practice (5)
   ◯ web       React, Next, Vite, and browser-platform guidance (3)
```

Only the agents you actually have are offered. Categories start unchecked —
pick none, some, or all. Then one line per repo, quiet unless something breaks:

```
research (5)
  ✓ safishamsi/graphify (4s)
  ✓ upstash/context7 (3s)

✓ 25 installed
```

**Then start a new agent session** — skill lists are read at session start.

## Commands

| Command | Does |
| --- | --- |
| `harness onboard` | Pick agents + categories, then install |
| `harness sync` | Install what's selected |
| `harness status` | What's selected, detected, installed |
| `harness upgrade` | Pull, refresh tools, reinstall at latest |
| `harness add <owner/repo> [skill]` | Add a skill — manifest + install + sync |
| `harness mcp add <server>` | Add an MCP server |

`harness add` and `harness skills add` are the same command, and both are
`npx skills add` with the manifest entry and the cross-agent sync added.

Flags: `--dry-run` prints commands instead of running them, `--no-save` installs
without touching the manifest, `--category <name>` files a new skill, `--all`
clears the selection so everything installs.

Upgrading is just re-running: `skills add` and `smithery mcp add` are idempotent
re-fetches, so `harness upgrade` pulls the manifest, refreshes yq and smithery,
and reinstalls every selected entry at its latest version.

## collection.yaml

```yaml
agents: "-a claude-code -a codex …"   # flag string; `onboard` rewrites this
selected: [research, design]          # categories to install; absent = all
categories:
  research: One-line pitch shown in the picker
skills:
  research:                           # skills nest under a category
    owner/repo:                       #   bare  → every skill in the repo
    owner/repo: [one, two]            #   list  → just those
    owner/repo:
      install: scripts/custom.sh      #   map   → run this instead
mcp:
  server-id:                          # Smithery IDs, verified installable
```

Editing the file installs nothing — run `harness sync`.
Never use `npx skills add … --all`.

## Where skills land

`npx skills add` writes the canonical copy to `~/.agents/skills/`, then symlinks
it into a per-agent dir for Claude Code and Pi. Everything else it calls
"universal", assuming those agents find `~/.agents/skills` themselves. agy
doesn't: its global root is `~/.gemini/config/`, and it only reads an `.agents/`
dir sitting in the workspace you launched from — so "universal" agents silently
see nothing. `scripts/sync-skills.sh` closes that gap and runs after every
install. Agents whose home dir doesn't exist are skipped.

| Agent | Skills dir | Populated by |
| --- | --- | --- |
| Claude Code (CLI + desktop app panes) | `~/.claude/skills/` | `skills` CLI |
| Pi | `~/.pi/agent/skills/` | `skills` CLI |
| agy (Antigravity CLI) | `~/.gemini/config/skills/` | `sync-skills.sh` |
| Codex, and the ChatGPT app's local agent | `~/.codex/skills/` | `sync-skills.sh` |
| Cursor | `~/.cursor/skills/` | `sync-skills.sh` |

## Agents on another OS partition

Dual-boot installs are synced too. `sync-skills.sh` scans mounted volumes
(`/Volumes`, `/mnt`, `/media`, Git Bash drive letters) for homes containing
agent config, copies the skills into **that install's own `~/.agents/skills`**,
and links them into its agent dirs.

* **Relative symlinks.** `../../.agents/skills/<name>` resolves both from here
  and from the other OS once it boots and the mount points change. An absolute
  link would dangle — and it's the same form that install already uses.
* **Nothing is clobbered.** Copies carry a `.harness-managed` marker; a dir or
  symlink without one belongs to that install and is left alone. Counted in the
  output; `HARNESS_ADOPT=1` takes them over.
* **Deduplicated by device+inode, not path.** One volume commonly surfaces at
  several mount points — an APFS system volume and its firmlinked data volume,
  or the booted disk re-exposed under `/Volumes`.

Read-only mounts are skipped. `HARNESS_CROSS_VOLUME=0` keeps the sync local.
The source of truth is always `~/.agents/skills` **on the running system**, so
install from the OS you keep current.

## Layout

```
install.sh              bootstrap: deps + clone + shim + onboarding
install.ps1             Windows entry — winget + Git Bash, then install.sh
pony.harness.sh         the CLI behind `harness`
collection.yaml         agents + categories + skills + mcp
scripts/ui.sh           spinner, status lines, checkbox picker
scripts/onboard.sh      agent detection + selection
scripts/sync-skills.sh  fan out, locally and across partitions
scripts/test-ui.sh      drives the pickers headlessly
```

Env: `HARNESS_DIR` (default `~/.harness-core`), `HARNESS_BIN` (default
`~/.local/bin`), `HARNESS_REPO`, `HARNESS_NODE_VERSION`, `HARNESS_CROSS_VOLUME`,
`HARNESS_ADOPT`, `NO_COLOR`.

Scripts target **bash 3.2** — macOS still ships it, so no `${var,,}` and no
fractional `read -t`. `scripts/test-ui.sh` guards both.

## Notes

* **Claude desktop** — chat-app skills are account-level: add them under
  Settings → Capabilities on claude.ai. The Claude Code / Cowork panes inside
  the app read `~/.claude/skills`, so this collection is already there.
* **ChatGPT** — no skills setting in the app, but its local agent runs out of
  `~/.codex/` and reads `~/.codex/skills/` (built-ins in `.system/`).
* Some MCP servers aren't on Smithery and can't be installed from the manifest
  (playwright, figma, shadcn) — `collection.yaml` lists how to add each.
* Without smithery the `mcp` section is skipped with a warning rather than
  failing the run. One failing repo never kills the rest of a sync; failures are
  listed at the end with the log path.
