#!/usr/bin/env python3
"""Static validation for the Markdown knowledge base.

The checker intentionally uses only the Python standard library so it can run locally and in
CI without installing dependencies. It validates local links and repository planning rules;
external URLs are left to a separate, networked checker if one is ever needed.
"""

from __future__ import annotations

import argparse
import html
import re
import sys
import unicodedata
from collections import defaultdict, deque
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote, urlsplit


REPO_ROOT = Path(__file__).resolve().parents[1]
DOCS_ROOT = REPO_ROOT / "docs"
DOCS_INDEX = DOCS_ROOT / "README.md"
ROADMAP = DOCS_ROOT / "roadmap.md"

FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})")
HEADING_RE = re.compile(r"^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$")
INLINE_LINK_RE = re.compile(r"!?\[[^\]]*\]\(\s*(<[^>]+>|[^\s)]+)")
REFERENCE_LINK_RE = re.compile(r"^\s*\[[^\]]+\]:\s*(<[^>]+>|\S+)", re.MULTILINE)
CHECKBOX_RE = re.compile(r"^\s*[-*+]\s+\[[ xX]\]\s+", re.MULTILINE)
PLANNING_HEADING_RE = re.compile(
    r"^\s{0,3}#{1,6}\s+.*(?:TODO|что дальше|следующие инкременты|полный план|"
    r"этапы разработки|открытые вопросы)",
    re.IGNORECASE | re.MULTILINE,
)
HTML_TAG_RE = re.compile(r"<[^>]*>")
INLINE_CODE_RE = re.compile(r"`([^`]*)`")

EXTERNAL_SCHEMES = {
    "data",
    "ftp",
    "http",
    "https",
    "irc",
    "mailto",
    "tel",
}


@dataclass(frozen=True)
class Finding:
    level: str
    path: Path
    line: int
    message: str

    def format(self) -> str:
        relative = self.path.relative_to(REPO_ROOT)
        return f"{self.level}: {relative}:{self.line}: {self.message}"


@dataclass(frozen=True)
class Link:
    source: Path
    line: int
    raw_target: str


def markdown_files() -> list[Path]:
    return sorted(DOCS_ROOT.rglob("*.md"))


def strip_fenced_code(text: str) -> str:
    """Preserve line numbers while blanking fenced code blocks."""
    output: list[str] = []
    active_fence: str | None = None
    for line in text.splitlines():
        match = FENCE_RE.match(line)
        marker = match.group(1) if match else None
        if active_fence is None and marker:
            active_fence = marker[0]
            output.append("")
        elif active_fence is not None:
            output.append("")
            if marker and marker[0] == active_fence:
                active_fence = None
        else:
            output.append(line)
    return "\n".join(output)


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def extract_links(path: Path, text: str) -> list[Link]:
    clean = strip_fenced_code(text)
    result: list[Link] = []
    for regex in (INLINE_LINK_RE, REFERENCE_LINK_RE):
        for match in regex.finditer(clean):
            target = match.group(1)
            if target.startswith("<") and target.endswith(">"):
                target = target[1:-1]
            result.append(Link(path, line_number(clean, match.start()), target))
    return result


def github_slug(value: str) -> str:
    """Approximate GitHub's heading slugger for the characters used in this repository."""
    value = html.unescape(value).strip().lower()
    value = INLINE_CODE_RE.sub(
        lambda match: match.group(1).replace("<", "").replace(">", ""), value
    )
    value = HTML_TAG_RE.sub("", value)
    chars: list[str] = []
    for char in value:
        category = unicodedata.category(char)
        if char in {"-", "_", " "} or category[0] in {"L", "N", "M"}:
            chars.append(char)
    return "".join(chars).replace(" ", "-")


def anchors(path: Path) -> set[str]:
    text = strip_fenced_code(path.read_text(encoding="utf-8"))
    result: set[str] = set()
    occurrences: defaultdict[str, int] = defaultdict(int)
    for line in text.splitlines():
        match = HEADING_RE.match(line)
        if not match:
            continue
        base = github_slug(match.group(2))
        number = occurrences[base]
        occurrences[base] += 1
        result.add(base if number == 0 else f"{base}-{number}")
    return result


def exact_case_exists(path: Path) -> bool:
    """Catch links that work on case-insensitive macOS but fail on Linux CI."""
    try:
        relative = path.resolve().relative_to(REPO_ROOT.resolve())
    except ValueError:
        return False
    current = REPO_ROOT.resolve()
    for part in relative.parts:
        if not current.is_dir():
            return False
        names = {child.name for child in current.iterdir()}
        if part not in names:
            return False
        current /= part
    return current.exists()


def resolve_link(link: Link) -> tuple[Path | None, str]:
    decoded = unquote(link.raw_target)
    split = urlsplit(decoded)
    if split.scheme.lower() in EXTERNAL_SCHEMES or split.netloc:
        return None, ""
    path_part = split.path
    if not path_part:
        target = link.source
    elif path_part.startswith("/"):
        target = REPO_ROOT / path_part.lstrip("/")
    else:
        target = link.source.parent / path_part
    return target.resolve(), unquote(split.fragment)


def validate_links(files: list[Path]) -> tuple[list[Finding], dict[Path, set[Path]]]:
    findings: list[Finding] = []
    graph: dict[Path, set[Path]] = defaultdict(set)
    anchor_cache: dict[Path, set[str]] = {}

    for source in files:
        for link in extract_links(source, source.read_text(encoding="utf-8")):
            target, fragment = resolve_link(link)
            if target is None:
                continue
            try:
                target.relative_to(REPO_ROOT.resolve())
            except ValueError:
                findings.append(Finding("ERROR", source, link.line,
                        f"local link escapes repository: {link.raw_target}"))
                continue
            if not target.exists():
                findings.append(Finding("ERROR", source, link.line,
                        f"target does not exist: {link.raw_target}"))
                continue
            if not exact_case_exists(target):
                findings.append(Finding("ERROR", source, link.line,
                        f"target has incorrect filename case: {link.raw_target}"))
                continue

            if target.is_dir():
                readme = target / "README.md"
                if readme.exists():
                    graph[source].add(readme.resolve())
                if fragment:
                    findings.append(Finding("ERROR", source, link.line,
                            f"directory link cannot validate anchor: {link.raw_target}"))
                continue

            if target.suffix.lower() == ".md":
                graph[source].add(target)
                if fragment:
                    available = anchor_cache.setdefault(target, anchors(target))
                    if fragment not in available:
                        findings.append(Finding("ERROR", source, link.line,
                                f"anchor does not exist: {link.raw_target}"))

    return findings, graph


def validate_roadmap_rules(files: list[Path]) -> list[Finding]:
    findings: list[Finding] = []
    if not ROADMAP.exists():
        findings.append(Finding("ERROR", ROADMAP, 1, "canonical roadmap is missing"))
        return findings

    for path in files:
        if path == ROADMAP:
            continue
        clean = strip_fenced_code(path.read_text(encoding="utf-8"))
        for match in CHECKBOX_RE.finditer(clean):
            findings.append(Finding("ERROR", path, line_number(clean, match.start()),
                    "task checkbox is allowed only in docs/roadmap.md"))
        for match in PLANNING_HEADING_RE.finditer(clean):
            findings.append(Finding("ERROR", path, line_number(clean, match.start()),
                    "local planning section must link to docs/roadmap.md instead"))

    index_text = DOCS_INDEX.read_text(encoding="utf-8") if DOCS_INDEX.exists() else ""
    if "roadmap.md" not in index_text:
        findings.append(Finding("ERROR", DOCS_INDEX, 1,
                "documentation index must link to docs/roadmap.md"))
    return findings


def validate_reachability(files: list[Path], graph: dict[Path, set[Path]]) -> list[Finding]:
    reachable: set[Path] = set()
    queue: deque[Path] = deque([DOCS_INDEX.resolve()])
    while queue:
        current = queue.popleft()
        if current in reachable:
            continue
        reachable.add(current)
        queue.extend(graph.get(current, set()) - reachable)

    findings: list[Finding] = []
    for path in files:
        if path.resolve() not in reachable:
            findings.append(Finding("WARNING", path, 1,
                    "document is not reachable from docs/README.md"))
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strict", action="store_true",
            help="treat warnings (such as orphan documents) as errors")
    args = parser.parse_args()

    files = markdown_files()
    findings, graph = validate_links(files)
    findings.extend(validate_roadmap_rules(files))
    findings.extend(validate_reachability(files, graph))
    findings.sort(key=lambda item: (str(item.path), item.line, item.level, item.message))

    for finding in findings:
        print(finding.format())

    errors = sum(item.level == "ERROR" for item in findings)
    warnings = sum(item.level == "WARNING" for item in findings)
    if errors or (args.strict and warnings):
        print(f"documentation validation failed: {errors} error(s), {warnings} warning(s)")
        return 1
    print(f"documentation validation passed: {len(files)} files, {warnings} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
