# harness-core

One manifest of skills and MCP servers, installed across every agent on the box
— including agents living on another OS partition.

## Quickstart

macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/yoshi-ortiz/harness-core/main/install.sh | bash
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/yoshi-ortiz/harness-core/main/install.ps1 | iex
```

Installs the deps (Homebrew or winget, git, yq, nvm, Node, smithery), clones to
`~/.harness-core`, puts `harness` on your PATH, and syncs everything.

**Then start a new agent session** — skill lists are read at session start.

## Commands

| Command | Does |
| --- | --- |
| `harness sync` | Install everything in `collection.yaml` |
| `harness upgrade` | Pull the collection, refresh tools, reinstall skills at latest |
| `harness version` | Commit + install paths |
| `harness skills add owner/repo [skill]` | Add one skill — writes the manifest, then installs |
| `harness mcp add server` | Add one MCP server |

Add `--dry-run` to any of them to print the commands instead of running them.
`--no-save` on an `add` installs without touching the manifest.

Upgrading is just re-running: `skills add` and `smithery mcp add` are
idempotent re-fetches, so `harness upgrade` pulls the manifest, refreshes yq and
smithery, and reinstalls every entry at its latest version. Re-running the curl
line does the same thing and also re-checks the system deps.

## collection.yaml

```yaml
agents: "-a claude-code -a codex -a cursor …"   # flag string for `npx skills add -g`
skills:
  owner/repo:                                   # bare  → every skill in the repo
  owner/repo: [one, two]                        # list  → just those
  owner/repo:
    install: scripts/custom.sh                  # map   → run this instead
mcp:
  server-id:                                    # Smithery server IDs
```

Editing `collection.yaml` does not install anything — run `harness sync`.
Never use `npx skills add … --all`.

## Where skills land

`npx skills add` writes the canonical copy to `~/.agents/skills/`, then symlinks
it into a per-agent dir for Claude Code and Pi. Everything else it calls
"universal", assuming those agents discover `~/.agents/skills` themselves.
agy doesn't: its global root is `~/.gemini/config/`, and it only reads an
`.agents/` dir sitting in the workspace you launched from — so "universal"
agents silently see nothing. `scripts/sync-skills.sh` closes that gap and runs
after every install. Targets whose home dir doesn't exist are skipped.

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
agent config and fills their skill dirs — including `~/.claude` and `~/.pi`,
which the CLI handles locally but has never touched on a foreign install.

* **Copies, not symlinks.** A symlink into the running system's home would
  dangle the moment the other OS boots and the mount points change.
* **Nothing is clobbered.** Copies carry a `.harness-managed` marker; a skill
  dir without one is never overwritten.
* **Deduplicated by device+inode, not path.** One volume often surfaces at
  several mount points — an APFS system volume and its firmlinked data volume,
  or the booted disk re-exposed under `/Volumes`.

Read-only mounts are skipped. `HARNESS_CROSS_VOLUME=0` keeps the sync local.

The source of truth is always `~/.agents/skills` **on the running system**, so
install from the OS you keep current.

## Layout

```
install.sh              bootstrap: deps + clone + shim + sync
install.ps1             Windows entry point — winget + Git Bash, then install.sh
pony.harness.sh         the CLI behind `harness`
collection.yaml         agents + skills + mcp
scripts/sync-skills.sh  fan ~/.agents/skills out to agents the CLI misses
```

Env: `HARNESS_DIR` (default `~/.harness-core`), `HARNESS_BIN` (default
`~/.local/bin`), `HARNESS_REPO`, `HARNESS_NODE_VERSION`, `HARNESS_CROSS_VOLUME`.

## Notes

* **Claude desktop** — chat-app skills are account-level: add them under
  Settings → Capabilities on claude.ai. The Claude Code / Cowork panes inside
  the app read `~/.claude/skills`, so this collection is already there.
* **ChatGPT** — no skills setting in the app, but its local agent runs out of
  `~/.codex/` and reads `~/.codex/skills/` (built-ins sit in `.system/`).
* Neither is a valid `-a` target for the `skills` CLI.
* Without smithery the `mcp` section is skipped with a warning rather than
  failing the run. One failing repo never kills the rest of a sync.
