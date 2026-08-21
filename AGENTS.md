# Agent notes

One `collection.yaml`, one `pony.harness.sh`. Editing the yaml alone does not install anything.

## Add a skill or MCP

Prefer the harness:

```bash
./pony.harness.sh skills add owner/repo [skill] [--install path]
./pony.harness.sh mcp add owner/repo
```

Or install everything already listed: `./pony.harness.sh --agents`.

## Manifest shapes (`skills:`)

| Shape | Install behavior |
|-------|------------------|
| bare / null | all skills via `--skill '*'` |
| list | named skills via `-s` each |
| `{ install: path }` | run that script instead |

`install` paths may be relative to the collection root (e.g. `scripts/foo.sh`). Tilde paths still work.

Never `npx skills add … --all`.

## Skill `name:` frontmatter

Must be kebab-case (`^[a-z0-9-]+$`) for Pi `/skill:name`. Multi-word names break Pi's first-space expand. Cursor `/poteto-mode` comes from the plugin folder + mode, not the display name.

## Custom install scripts

Keep them under `scripts/` and idempotent. `scripts/install-pstack.sh` also installs the Cursor local plugin and normalizes poteto's frontmatter `name` to `poteto-mode`.

## After install

Skills land in `~/.agents/skills/` (bridged into Cursor). Start a **new Cursor chat** so the skill list reloads.

Keep this project minimal: no new abstractions without need.
