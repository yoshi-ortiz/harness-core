#!/usr/bin/env python3
"""The manifest reader, the selection, and the commands sync would run.

No network, no npx, no agent dirs. Every check reads a temp manifest and
asserts on what `--dry-run` would emit.
"""
import io
import contextlib
import tempfile
import unittest
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


if __name__ == "__main__":
    unittest.main()
