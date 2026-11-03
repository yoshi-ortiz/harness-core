#!/usr/bin/env python3
"""Install the curated skill collection into every agent on this machine.

One file, standard library only. The manifest is TOML because `tomllib` reads
it with no dependency at all, where the YAML it replaced needed `yq` on the
PATH before the harness could answer its own `--help`.

    python3 ~/.harness-core/harness.py sync
    python3 ~/.harness-core/harness.py status
    python3 ~/.harness-core/harness.py add owner/repo [skill] --category coding

`npx skills add` is still the installer and `scripts/sync-skills.sh` still does
the cross-agent fan-out. This owns the manifest, the selection, and the order.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT / "collection.toml"
SKILLS_DIR = Path.home() / ".agents" / "skills"
FANOUT = ROOT / "scripts" / "sync-skills.sh"

# Smithery names its clients differently from `skills add` agent flags.
SMITHERY_CLIENTS = {"cursor": "cursor", "claude-code": "claude", "zed": "zed"}

# `npx skills add` scores every skill it installs and prints the table. This
# reads that table back, because a security assessment nothing acts on is a
# security assessment nobody made.
RISK_ROW = re.compile(
    r"^\s*(?:│\s*)?(.+?)\s{2,}"
    r"(Safe|Low Risk|Med Risk|High Risk|Critical Risk)\s{2,}"
    r"(\d+) alerts?\s{2,}(Low|Med|High|Critical) Risk",
    re.MULTILINE)
ANSI = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")

# Names a skill must not take, per app it fans out to; see cyber-skills B-036.
# Read from each app's own binary; update with the app, never ahead of it.
RESERVED = {
    # Claude Code 2.1.309: slash commands, then bundled skills.
    "claude-code": frozenset({
        "add-dir", "agents", "bug", "clear", "compact", "config", "context",
        "cost", "doctor", "exit", "export", "feedback", "help", "hooks", "ide",
        "init", "login", "logout", "mcp", "memory", "model", "output-style",
        "permissions", "plugin", "pr-comments", "release-notes", "resume",
        "review", "rewind", "sandbox", "security-review", "skills", "stats",
        "status", "statusline", "tasks", "terminal-setup", "theme", "todos",
        "upgrade", "usage", "vim",
        "claude-api", "code-review", "dataviz", "fewer-permission-prompts",
        "keybindings-help", "loop", "plugin-authoring", "run", "schedule",
        "simplify", "update-config",
    }),
    # Codex 0.163.0.
    "codex": frozenset({
        "app", "archive", "btw", "cd", "compact", "daemon", "debug-config",
        "export", "ide", "import", "init", "logout", "model", "new", "pets",
        "ps", "pwd", "raw", "recap", "rename", "review", "rollout",
        "setup-default-sandbox", "side", "statusline", "vim", "worktree",
    }),
    # cursor-agent, as installed at ~/.local/bin.
    "cursor": frozenset({
        "about", "ask", "auto-run", "btw", "changes", "clear", "commit",
        "compress", "config", "context", "copy-conversation-id",
        "copy-request-id", "exit", "feedback", "help", "logout", "max-mode",
        "mcp", "model", "plan", "plugin", "quit", "rename", "resume", "rewind",
        "sandbox", "setup-terminal", "shell", "skills", "usage", "vim",
    }),
}
BUILTIN_COMMANDS = frozenset().union(*RESERVED.values())
# `npx skills add <repo> -l` prints each skill name on its own indented line.
LISTED = re.compile(r"^│ {4}(\S+)\s*$", re.M)
CLAUDE_SETTINGS = Path.home() / ".claude" / "settings.json"
LOCK = Path.home() / ".agents" / ".skill-lock.json"
FRONTMATTER_NAME = re.compile(r"\A---\n(?:.*\n)*?name:\s*['\"]?([^'\"\n]+)", re.M)


class HarnessError(RuntimeError):
    pass


def load() -> dict:
    if not MANIFEST.is_file():
        raise HarnessError(f"no manifest at {MANIFEST}")
    with MANIFEST.open("rb") as handle:
        return tomllib.load(handle)


def categories(manifest: dict) -> list[str]:
    """Absent `selected` means every category. An empty list means none."""
    return list(manifest.get("selected", manifest.get("skills", {})))


def sources(manifest: dict) -> list[tuple[str, str, object]]:
    """(category, source, spec) in manifest order, selection applied."""
    skills = manifest.get("skills", {})
    return [(cat, src, spec)
            for cat in categories(manifest)
            for src, spec in skills.get(cat, {}).items()]


def agent_flags(manifest: dict) -> list[str]:
    return str(manifest.get("agents", "")).split()


# `dev` is where the work happens; `alpha` is its generated, fog-free
# publication and the branch actually listed. Asking for `dev` means "the
# unreleased channel", so it resolves there rather than matching nothing.
CHANNEL_ALIAS = {"dev": "alpha"}


def source_matches(source: str, only: str) -> bool:
    """Match repository names loosely, but branch names exactly."""
    only = CHANNEL_ALIAS.get(only, only)
    if only in {"main", "dev", "alpha"}:
        return source.rstrip("/").endswith("/" + only) or source.endswith(":" + only)
    return only in source


def node_ready() -> None:
    """nvm puts node on the PATH from a shell rc, which a non-login run never
    reads. Find it ourselves rather than failing under cron or an editor."""
    if shutil.which("npx"):
        return
    nvm = Path(os.environ.get("NVM_DIR") or Path.home() / ".nvm") / "versions" / "node"
    for bin_dir in sorted(nvm.glob("*/bin"), reverse=True):
        if (bin_dir / "npx").exists():
            os.environ["PATH"] = f"{bin_dir}{os.pathsep}{os.environ['PATH']}"
            return
    raise HarnessError("node/npx not found; run the installer, or `nvm use --lts`")


def run(argv: list[str], dry: bool, capture: bool = False,
        env: dict[str, str] | None = None) -> str:
    """Run it. With `capture`, stream the output live *and* return it.

    Streaming matters: a sync takes minutes and a silent one reads as hung.
    Capturing matters: the installer's risk table is on stdout and nowhere else.
    """
    if dry:
        print("  " + " ".join(argv))
        return ""
    if not capture:
        subprocess.run(argv, check=True, stdin=subprocess.DEVNULL, env=env)
        return ""
    seen: list[str] = []
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL, text=True, errors="replace",
                            env=env)
    assert proc.stdout is not None
    with proc.stdout:
        for line in proc.stdout:
            sys.stdout.write(line)
            seen.append(line)
    if proc.wait():
        raise subprocess.CalledProcessError(proc.returncode, argv)
    return "".join(seen)


def scan_risk(output: str) -> list[tuple[str, str, int, str]]:
    """Every scored row the installer printed: (skill, gen, alerts, snyk)."""
    return [(m[1], m[2], int(m[3]), m[4])
            for m in RISK_ROW.finditer(ANSI.sub("", output))]


def unclean(rows: list[tuple[str, str, int, str]]) -> list[tuple]:
    """Rows that are not a clean bill: any alert, any non-Safe generated
    verdict, or a High dependency risk. One bar, deliberately. Tiers here
    would be somebody deciding in code which findings are allowed to pass
    unread, which is the habit this whole check exists to break."""
    return [r for r in rows
            if r[1] != "Safe" or r[2] > 0 or r[3] in ("High", "Critical")]


def risk_warning(output: str) -> str | None:
    rows = scan_risk(output)
    if not rows:
        return None
    bad = unclean(rows)
    if not bad:
        return None
    return ", ".join(
        f"{name} (Gen {generated}, Socket {alerts}, Snyk {snyk})"
        for name, generated, alerts, snyk in bad)


def report_risk(output: str) -> None:
    warning = risk_warning(output)
    if warning:
        print(f"  WARN  security advisory: {warning}")


def install_skill(manifest: dict, source: str, spec: object, dry: bool) -> str:
    """A dict spec runs its own script. A list names skills; empty takes all."""
    if isinstance(spec, dict) and "install" in spec:
        script = Path(str(spec["install"])).expanduser()
        script = script if script.is_absolute() else ROOT / script
        if not dry and not script.is_file():
            raise HarnessError(f"install script missing: {script}")
        argv = ["bash", str(script)]
        if dry:
            return run(argv, True)
        output = run(argv, False, capture=True)
        report_risk(output)
        return output

    node_ready()
    # Refuse a built-in's name before `-y` can write it, not after.
    wanted = [str(skill) for skill in spec or []] or ([] if dry else listed(source))
    blocked = [name for name in wanted if name in BUILTIN_COMMANDS]
    for name in blocked:
        print(f"  SKIP  {name}: would take over a built-in command; see cyber-skills B-036")
    wanted = [name for name in wanted if name not in BUILTIN_COMMANDS]
    if blocked and not wanted:
        return ""
    named = ([flag for skill in wanted for flag in ("-s", skill)]
             if spec or blocked else [])
    # --full-depth or a monorepo hands out one skill. `npx skills add` stops at
    # the first root SKILL.md, so a repo that groups skills under directories
    # (first/aesthetic, kit/spanish/ora) silently installs only the root one and
    # still exits 0. Cheap on a flat repo, load-bearing on a nested one.
    argv = ["npx", "skills", "add", source, "-g", *agent_flags(manifest),
            *(named or ["--skill", "*"]), "--full-depth", "-y"]
    if dry:
        return run(argv, True)

    output = run(argv, False, capture=True)
    report_risk(output)
    return output


def listed(source: str) -> list[str]:
    """Skill names a source would install, read without installing any."""
    done = subprocess.run(["npx", "skills", "add", source, "-l", "--full-depth"],
                          capture_output=True, text=True, errors="replace",
                          stdin=subprocess.DEVNULL)
    return LISTED.findall(ANSI.sub("", done.stdout)) if done.returncode == 0 else []


def disabled_protected(manifest: dict) -> list[str]:
    """Skills from a `protected` source that Claude Code has switched off."""
    protected = manifest.get("protected", [])
    try:
        overrides = json.loads(CLAUDE_SETTINGS.read_text()).get("skillOverrides", {})
        lock = json.loads(LOCK.read_text()).get("skills", {})
    except (OSError, ValueError):
        return []
    return sorted(name for name, state in overrides.items()
                  if state == "off" and any(
                      p in lock.get(name, {}).get("source", "") for p in protected))


def installed(skills_dir: Path | None = None) -> list[str]:
    skills_dir = skills_dir or SKILLS_DIR
    if not skills_dir.is_dir():
        return []
    return sorted(p.name for p in skills_dir.iterdir() if p.is_dir())


def skill_name(folder: Path) -> str | None:
    try:
        found = FRONTMATTER_NAME.search((folder / "SKILL.md").read_text(errors="ignore"))
    except OSError:
        return None
    return found.group(1).strip() if found else None


def shadowed(names: list[str], skills_dir: Path | None = None) -> list[str]:
    """Installed skills whose folder or frontmatter name takes over a built-in."""
    skills_dir = skills_dir or SKILLS_DIR
    return [name for name in names
            if name in BUILTIN_COMMANDS
            or skill_name(skills_dir / name) in BUILTIN_COMMANDS]


def fan_out(dry: bool) -> list[str]:
    """Copy skills into every app, unless one would take over a built-in."""
    clashes = shadowed(installed())
    for name in clashes:
        print(f"  FAIL  {name}: shadows a built-in command; see cyber-skills B-036")
    if clashes:
        return [f"{name} shadows a built-in" for name in clashes]
    print("\nfan out to agent dirs")
    if FANOUT.is_file():
        try:
            run(["bash", str(FANOUT)], dry)
        except subprocess.CalledProcessError as exc:
            return [f"sync-skills.sh: {exc}"]
    return []


def mcp_clients(manifest: dict) -> list[str]:
    flags = agent_flags(manifest)
    agents = [flags[i + 1] for i, flag in enumerate(flags)
              if flag == "-a" and i + 1 < len(flags)]
    return [SMITHERY_CLIENTS[a] for a in agents if a in SMITHERY_CLIENTS]


def sync_mcp(manifest: dict, dry: bool) -> list[str]:
    """Every declared server, into every agent that has a Smithery client."""
    servers = list(manifest.get("mcp", {}))
    if not servers:
        return []
    if not dry and not shutil.which("smithery"):
        print("  smithery not installed, skipping mcp "
              "(npm install -g smithery@latest)")
        return []
    clients = mcp_clients(manifest)
    if not clients:
        print("  no Smithery client among the declared agents, skipping mcp")
        return []
    failed = []
    for server in servers:
        for client in clients:
            try:
                run(["smithery", "mcp", "add", server, "--client", client], dry)
            except (subprocess.CalledProcessError, HarnessError) as exc:
                failed.append(f"{server} -> {client}: {exc}")
    return failed


def sync(dry: bool = False, only: str = "", include_all: bool = False) -> int:
    """Re-arm every source, or just the ones whose name contains `only`.

    The filter exists because the full fan-out takes minutes over every repo,
    and the common case after editing one's own skills is re-arming that one
    repo. Substring, not a flag per source: `sync cyber-skills` is the whole
    interface, and it needs no entry in the manifest to keep in step.
    """
    manifest = load()
    # Naming a source is an explicit opt-in, even when its category is hidden.
    chosen = (list(manifest.get("skills", {}))
              if only or include_all else categories(manifest))
    if not chosen:
        print("no categories selected; run `harness.py onboard`")
        return 1

    failed: list[str] = []
    matched = 0
    for cat in chosen:
        entries = {source: spec
                   for source, spec in manifest.get("skills", {}).get(cat, {}).items()
                   if source_matches(source, only)}
        if not entries:
            continue
        matched += len(entries)
        print(f"\n{cat} ({len(entries)})")
        for source, spec in entries.items():
            try:
                install_skill(manifest, source, spec, dry)
                print(f"  ok    {source}")
            except (subprocess.CalledProcessError, HarnessError) as exc:
                print(f"  FAIL  {source}: {exc}")
                failed.append(source)

    if only and not matched:
        print(f"no source matches {only!r}; `harness.py status` lists them")
        return 1

    failed += fan_out(dry)

    # A filtered run named one repo. Re-arming every MCP server on the way past
    # is the fan-out the filter existed to avoid.
    if manifest.get("mcp") and not only:
        print("\nmcp")
        failed += sync_mcp(manifest, dry)

    total = matched
    print(f"\n{total - len(failed)}/{total} sources installed")
    if failed:
        print("failing: " + ", ".join(failed))
    return 1 if failed else 0


def status() -> int:
    manifest = load()
    chosen = set(categories(manifest))
    names = installed()
    print(f"harness {revision()}")
    print(f"  collection: {ROOT}")
    print(f"  manifest:   {MANIFEST.name}")
    print(f"  agents:     {manifest.get('agents', '')}")
    print(f"  skills dir: {SKILLS_DIR}  ({len(names)} installed)")
    print(f"  mcp:        {len(manifest.get('mcp', {}))} server(s)")
    print(f"\n  {'CATEGORY':<12}REPOS")
    for cat, entries in manifest.get("skills", {}).items():
        mark = "*" if cat in chosen else "-"
        print(f"  {mark} {cat:<10}{len(entries)}")
    clashes = shadowed(names)
    if clashes:
        print("\n  shadowing built-in commands: " + ", ".join(clashes))
    off = disabled_protected(manifest)
    if off:
        print("\n  protected skills switched off in Claude Code: " + ", ".join(off)
              + f"\n  remove them from skillOverrides in {CLAUDE_SETTINGS}")
    return 1 if clashes or off else 0


def revision() -> str:
    done = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
                          capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else "unknown"


def quote(value: object) -> str:
    if isinstance(value, dict):
        return "{ " + ", ".join(f'{k} = "{v}"' for k, v in value.items()) + " }"
    return "[" + ", ".join(f'"{s}"' for s in value) + "]"


def save(source: str, spec: object, category: str) -> None:
    """Append one line under its table, so the file's comments survive.

    A rewrite through a serializer would be shorter and would throw away the
    notes explaining why three servers are not on Smithery.
    """
    text = MANIFEST.read_text(encoding="utf-8")
    if f'"{source}"' in text:
        return
    header = f"[skills.{category}]"
    line = f'"{source}" = {quote(spec)}'
    if header in text:
        text = text.replace(header, f"{header}\n{line}", 1)
    else:
        text = text.rstrip("\n") + f"\n\n{header}\n{line}\n"
    MANIFEST.write_text(text, encoding="utf-8")


def add(source: str, skill: str | None, category: str, install: str | None,
        no_save: bool, dry: bool) -> int:
    spec: object = {"install": install} if install else ([skill] if skill else [])
    if not no_save and not dry:
        save(source, spec, category)
    manifest = load()
    install_skill(manifest, source, spec, dry)
    if fan_out(dry):
        return 1
    print(f"ok    {source}")
    return 0


def onboard() -> int:
    """Pick categories. Writes `selected`, installs nothing by itself."""
    manifest = load()
    names = list(manifest.get("skills", {}))
    labels = manifest.get("categories", {})
    for index, name in enumerate(names, 1):
        count = len(manifest["skills"][name])
        print(f"  {index:>2}  {name:<10}{count:>3}  {labels.get(name, '')}")
    reply = input("\ncategories to install (numbers, or blank for all): ").strip()
    if not reply:
        chosen = names
    else:
        try:
            chosen = [names[int(n) - 1] for n in reply.replace(",", " ").split()]
        except (ValueError, IndexError):
            raise HarnessError(f"not a number in range 1-{len(names)}: {reply!r}")

    text = MANIFEST.read_text(encoding="utf-8")
    line = "selected = [" + ", ".join(f'"{c}"' for c in chosen) + "]"
    if "\nselected = " in text:
        text = "\n".join(line if l.startswith("selected = ") else l
                         for l in text.splitlines()) + "\n"
    else:
        text = text.replace("\n[categories]", f"\n{line}\n\n[categories]", 1)
    MANIFEST.write_text(text, encoding="utf-8")
    print(f"selected: {', '.join(chosen)}\nnext: harness.py sync")
    return 0


def upgrade(dry: bool, include_all: bool = False) -> int:
    if (ROOT / ".git").exists():
        run(["git", "-C", str(ROOT), "pull", "--ff-only"], dry)
    return sync(dry, include_all=include_all)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("command", nargs="?", default="sync",
                        choices=("sync", "status", "version", "add", "upgrade",
                                 "onboard"))
    parser.add_argument("source", nargs="?",
                        help="owner/repo for add; a name to match for sync")
    parser.add_argument("skill", nargs="?", help="one skill name, for add")
    parser.add_argument("--category", default="custom")
    parser.add_argument("--install", help="run this script instead of npx skills")
    parser.add_argument("--no-save", action="store_true")
    parser.add_argument("--all", action="store_true",
                        help="include hidden categories for this run")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    try:
        if args.command == "status":
            return status()
        if args.command == "version":
            print(f"harness {revision()}\n  collection: {ROOT}\n"
                  f"  skills:     {SKILLS_DIR}")
            return 0
        if args.command == "onboard":
            return onboard()
        if args.command == "upgrade":
            return upgrade(args.dry_run, args.all)
        if args.command == "add":
            if not args.source:
                parser.error("add needs owner/repo")
            return add(args.source, args.skill, args.category, args.install,
                       args.no_save, args.dry_run)
        return sync(args.dry_run, args.source or "", args.all)
    except HarnessError as refusal:
        print(refusal, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
