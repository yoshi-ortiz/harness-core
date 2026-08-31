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


def source_matches(source: str, only: str) -> bool:
    """Match repository names loosely, but branch names exactly."""
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
    named = [flag for skill in (spec or []) for flag in ("-s", str(skill))]
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

    print("\nfan out to agent dirs")
    if FANOUT.is_file():
        try:
            run(["bash", str(FANOUT)], dry)
        except subprocess.CalledProcessError as exc:
            failed.append(f"sync-skills.sh: {exc}")

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
    installed = (len([p for p in SKILLS_DIR.iterdir() if p.is_dir()])
                 if SKILLS_DIR.is_dir() else 0)
    print(f"harness {revision()}")
    print(f"  collection: {ROOT}")
    print(f"  manifest:   {MANIFEST.name}")
    print(f"  agents:     {manifest.get('agents', '')}")
    print(f"  skills dir: {SKILLS_DIR}  ({installed} installed)")
    print(f"  mcp:        {len(manifest.get('mcp', {}))} server(s)")
    print(f"\n  {'CATEGORY':<12}REPOS")
    for cat, entries in manifest.get("skills", {}).items():
        mark = "*" if cat in chosen else "-"
        print(f"  {mark} {cat:<10}{len(entries)}")
    return 0


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
    if FANOUT.is_file():
        run(["bash", str(FANOUT)], dry)
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
