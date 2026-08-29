#!/usr/bin/env python3
"""The manifest reader, the selection, and the commands sync would run.

No network, no npx, no agent dirs. Every check reads a temp manifest and
asserts on what `--dry-run` would emit.
"""
import io
import contextlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

import harness

MANIFEST = '''
agents = "-a claude-code -a cursor"
selected = ["one"]

[categories]
one = "first"
two = "second"

[skills.one]
"owner/all" = []
"owner/some" = ["a", "b"]
"owner/script" = { install = "scripts/thing.sh" }

[skills.two]
"owner/unselected" = []

[mcp]
"@vendor/server" = {}
'''


class ManifestTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "collection.toml"
        self.path.write_text(MANIFEST, encoding="utf-8")
        self._saved = harness.MANIFEST
        harness.MANIFEST = self.path

    def tearDown(self) -> None:
        harness.MANIFEST = self._saved
        self.tmp.cleanup()

    def emit(self, source: str, spec: object) -> str:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            harness.install_skill(harness.load(), source, spec, dry=True)
        return out.getvalue().strip()

    def test_an_empty_list_takes_every_skill_in_the_repo(self) -> None:
        self.assertIn("--skill *", self.emit("owner/all", []))

    def test_a_named_list_takes_only_those_skills(self) -> None:
        line = self.emit("owner/some", ["a", "b"])
        self.assertIn("-s a -s b", line)
        self.assertNotIn("--skill *", line)

    def test_an_install_spec_runs_its_script_instead_of_npx(self) -> None:
        line = self.emit("owner/script", {"install": "scripts/thing.sh"})
        self.assertNotIn("npx", line)
        self.assertTrue(line.endswith("scripts/thing.sh"), line)

    def test_selection_hides_a_category_without_deleting_it(self) -> None:
        manifest = harness.load()
        self.assertEqual(harness.categories(manifest), ["one"])
        self.assertEqual([s for _, s, _ in harness.sources(manifest)],
                         ["owner/all", "owner/some", "owner/script"])

    def test_no_selection_key_means_every_category(self) -> None:
        self.path.write_text(MANIFEST.replace('selected = ["one"]', ""),
                             encoding="utf-8")
        self.assertEqual(harness.categories(harness.load()), ["one", "two"])

    def test_an_empty_selection_means_none_rather_than_all(self) -> None:
        self.path.write_text(MANIFEST.replace('selected = ["one"]', "selected = []"),
                             encoding="utf-8")
        self.assertEqual(harness.categories(harness.load()), [])

    def test_mcp_reaches_every_agent_with_a_smithery_client(self) -> None:
        # claude-code maps to `claude`, cursor to itself; the rest have none.
        self.assertEqual(harness.mcp_clients(harness.load()), ["claude", "cursor"])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            failed = harness.sync_mcp(harness.load(), dry=True)
        self.assertEqual(failed, [])
        self.assertIn("smithery mcp add @vendor/server --client claude", out.getvalue())
        self.assertIn("smithery mcp add @vendor/server --client cursor", out.getvalue())

    def test_add_appends_under_its_table_and_keeps_the_comments(self) -> None:
        self.path.write_text(MANIFEST + "\n# a note worth keeping\n", encoding="utf-8")
        harness.save("owner/new", ["x"], "one")
        text = self.path.read_text(encoding="utf-8")
        self.assertIn('"owner/new" = ["x"]', text)
        self.assertIn("# a note worth keeping", text)
        self.assertEqual(harness.load()["skills"]["one"]["owner/new"], ["x"])

    def test_adding_the_same_source_twice_changes_nothing(self) -> None:
        harness.save("owner/all", [], "one")
        self.assertEqual(self.path.read_text(encoding="utf-8").count('"owner/all"'), 1)

    def test_a_missing_manifest_is_a_refusal_not_a_traceback(self) -> None:
        self.path.unlink()
        with self.assertRaisesRegex(harness.HarnessError, "no manifest"):
            harness.load()

    def test_security_table_parser_keeps_every_non_clean_row(self) -> None:
        output = """\
│  \x1b[36mgraphify\x1b[0m  Med Risk          2 alerts          Med Risk
│  safe skill  Safe              0 alerts          Low Risk
│  shellcheck  High Risk         0 alerts          Med Risk
"""
        self.assertEqual(
            harness.unclean(harness.scan_risk(output)),
            [("graphify", "Med Risk", 2, "Med"),
             ("shellcheck", "High Risk", 0, "Med")])

    def test_missing_security_table_has_no_advisory(self) -> None:
        self.assertIsNone(harness.risk_warning("installation complete"))

    def test_custom_installer_reports_risk_and_reaches_real_home(self) -> None:
        script = self.path.parent / "risky-installer.sh"
        marker = self.path.parent / "real-install"
        script.write_text(
            "#!/bin/sh\n"
            "if [ \"$HOME\" = \"$REAL_HOME\" ]; then "
            "touch \"$REAL_INSTALL\"; fi\n"
            "printf '│  custom  Low Risk          0 alerts          Low Risk\\n'\n",
            encoding="utf-8")
        script.chmod(0o755)
        with mock.patch.dict(os.environ, {
                "HOME": str(self.path.parent / "real-home"),
                "REAL_HOME": str(self.path.parent / "real-home"),
                "REAL_INSTALL": str(marker)}):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                harness.install_skill(harness.load(), "owner/custom",
                                      {"install": str(script)}, dry=False)
        self.assertTrue(marker.exists(), "custom installer missed real home")
        self.assertIn("security advisory", out.getvalue())


class SecurityAdvisoryBlackBoxTest(unittest.TestCase):
    def test_risky_install_succeeds_and_fans_out(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            shutil.copy2(Path(harness.__file__), root / "harness.py")
            (root / "collection.toml").write_text(
                'agents = "-a claude-code"\n\n'
                '[skills.research]\n"owner/risky" = ["graphify"]\n',
                encoding="utf-8")

            bin_dir = root / "bin"
            scripts = root / "scripts"
            bin_dir.mkdir()
            scripts.mkdir()
            (bin_dir / "npx").write_text(
                "#!/bin/sh\n"
                "if [ \"$HOME\" = \"$REAL_HOME\" ]; then "
                "touch \"$REAL_INSTALL\"; fi\n"
                "printf '│  graphify  Med Risk          2 alerts          Med Risk\\n'\n",
                encoding="utf-8")
            (bin_dir / "npx").chmod(0o755)
            marker = root / "fanned-out"
            (scripts / "sync-skills.sh").write_text(
                f"#!/bin/sh\ntouch {marker}\n", encoding="utf-8")
            (scripts / "sync-skills.sh").chmod(0o755)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env["HOME"] = str(root / "real-home")
            env["REAL_HOME"] = env["HOME"]
            env["REAL_INSTALL"] = str(root / "real-install")
            done = subprocess.run(
                [sys.executable, str(root / "harness.py"), "sync"],
                capture_output=True, text=True, env=env)

            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            self.assertIn("security advisory", done.stdout)
            self.assertIn("1/1 sources installed", done.stdout)
            self.assertTrue((root / "real-install").exists(),
                            "installer missed the real home")
            self.assertTrue(marker.exists(), "cross-agent fan-out did not run")


if __name__ == "__main__":
    unittest.main()
