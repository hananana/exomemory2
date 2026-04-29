#!/usr/bin/env python3
"""Prefix bare `- [[X]] ...` Connection lines with `- related_to:: `.

Pure stdlib. No PyYAML.

Usage:
    migrate-typed-connections.py <vault> [--dry-run]

Behavior:
    For each wiki/entities/*.md and wiki/concepts/*.md:
      1. Locate the `## Connections` section.
      2. For each line in that section:
         - If the line is exactly of the form `- [[<anything>]]<rest>`, rewrite
           to `- related_to:: [[<anything>]]<rest>`.
         - If the line already starts with `- <key>:: ` where `<key>` is in the
           v0.9 vocabulary, leave it untouched.
         - Other custom lines (`- (memo) [[X]]`, prose, etc.) are untouched.
      3. Idempotent: lines already prefixed are not re-prefixed.

Outputs CHANGED / UNCHANGED / NO-CONNECTIONS / PARSE-ERROR per page on stdout.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys


VOCABULARY = ("depends_on", "contradicts", "caused_by", "fixed_in", "supersedes", "related_to")
TYPED_LINE_RE = re.compile(
    r"^(?P<lead>\s*-\s+)(?P<key>[A-Za-z_]+)::\s+",
)
BARE_LINK_LINE_RE = re.compile(r"^(?P<lead>\s*-\s+)\[\[")
CONNECTIONS_HEADING_RE = re.compile(r"^##\s+Connections\s*$", re.MULTILINE)
NEXT_H2_RE = re.compile(r"^##\s+", re.MULTILINE)


def split_frontmatter(text: str) -> tuple[str, str] | None:
    m = re.match(r"^---\n(.*?)\n---\n?(.*)$", text, re.S)
    if not m:
        return None
    return m.group(1), m.group(2)


def find_connections_span(body: str) -> tuple[int, int] | None:
    m = CONNECTIONS_HEADING_RE.search(body)
    if not m:
        return None
    start = m.end()
    nm = NEXT_H2_RE.search(body, pos=start)
    end = nm.start() if nm else len(body)
    return start, end


def rewrite_connections(section_text: str) -> tuple[str, int]:
    """Return (new_section, count_of_lines_changed)."""
    out = []
    changed = 0
    for line in section_text.split("\n"):
        typed = TYPED_LINE_RE.match(line)
        if typed and typed.group("key") in VOCABULARY:
            out.append(line)
            continue
        m = BARE_LINK_LINE_RE.match(line)
        if m:
            lead = m.group("lead")
            rest = line[len(lead):]
            new_line = f"{lead}related_to:: {rest}"
            out.append(new_line)
            changed += 1
            continue
        out.append(line)
    return "\n".join(out), changed


def process_page(page: pathlib.Path, dry_run: bool) -> str:
    text = page.read_text(encoding="utf-8")
    parts = split_frontmatter(text)
    if parts is None:
        return "PARSE-ERROR"
    fm_block, body = parts

    span = find_connections_span(body)
    if span is None:
        return "NO-CONNECTIONS"
    start, end = span
    section = body[start:end]
    new_section, changed = rewrite_connections(section)
    if changed == 0:
        return "UNCHANGED"

    new_body = body[:start] + new_section + body[end:]
    new_text = f"---\n{fm_block}\n---\n{new_body}"
    if new_text == text:
        return "UNCHANGED"
    if not dry_run:
        page.write_text(new_text, encoding="utf-8")
    return "CHANGED"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("vault", type=pathlib.Path)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    vault: pathlib.Path = args.vault
    if not (vault / "WIKI.md").is_file():
        print(f"ERROR: {vault} is not a vault (no WIKI.md)", file=sys.stderr)
        return 1

    counters = {"CHANGED": 0, "UNCHANGED": 0, "NO-CONNECTIONS": 0, "PARSE-ERROR": 0}
    for sub in ("entities", "concepts"):
        d = vault / "wiki" / sub
        if not d.is_dir():
            continue
        for page in sorted(d.glob("*.md")):
            status = process_page(page, args.dry_run)
            counters[status] += 1
            print(f"{status} {page.relative_to(vault)}")

    summary = " ".join(f"{k}={v}" for k, v in counters.items())
    print(f"# typed-connections: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
