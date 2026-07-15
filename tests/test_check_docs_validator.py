#!/usr/bin/env python3

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("check_docs.py")
SPEC = importlib.util.spec_from_file_location("check_docs", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
CHECK_DOCS = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECK_DOCS
SPEC.loader.exec_module(CHECK_DOCS)


class DocsValidatorTest(unittest.TestCase):
    def test_github_slug_keeps_inline_code_and_cyrillic(self) -> None:
        self.assertEqual(
            CHECK_DOCS.github_slug("`<VRWebMirror>` — зеркало (как в VRChat)"),
            "vrwebmirror--зеркало-как-в-vrchat",
        )

    def test_fenced_examples_are_ignored_without_changing_line_numbers(self) -> None:
        source = "before\n```md\n[broken](missing.md)\n```\nafter"
        clean = CHECK_DOCS.strip_fenced_code(source)
        self.assertEqual(len(clean.splitlines()), len(source.splitlines()))
        self.assertNotIn("missing.md", clean)

    def test_extracts_inline_and_reference_links(self) -> None:
        source = "[inline](one.md#anchor)\n[ref]: two.md\n"
        links = CHECK_DOCS.extract_links(Path("doc.md"), source)
        self.assertEqual(
            [(link.line, link.raw_target) for link in links],
            [(1, "one.md#anchor"), (2, "two.md")],
        )

    def test_reports_missing_file_and_anchor(self) -> None:
        original_root = CHECK_DOCS.REPO_ROOT
        try:
            with tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                docs = root / "docs"
                docs.mkdir()
                source = docs / "README.md"
                target = docs / "target.md"
                source.write_text(
                    "[missing](missing.md)\n[bad anchor](target.md#missing)\n",
                    encoding="utf-8",
                )
                target.write_text("# Existing\n", encoding="utf-8")
                CHECK_DOCS.REPO_ROOT = root
                findings, _graph = CHECK_DOCS.validate_links([source, target])
                messages = [finding.message for finding in findings]
                self.assertTrue(any("target does not exist" in item for item in messages))
                self.assertTrue(any("anchor does not exist" in item for item in messages))
        finally:
            CHECK_DOCS.REPO_ROOT = original_root


if __name__ == "__main__":
    unittest.main()
