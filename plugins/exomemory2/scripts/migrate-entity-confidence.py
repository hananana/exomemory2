#!/usr/bin/env python3
"""Backfill v0.9 confidence/sources/last_verified on entity & concept pages.

Pure stdlib (re, pathlib, sys, datetime, argparse). No PyYAML.

Usage:
    migrate-entity-confidence.py <vault> [--dry-run]

Behavior:
    For each wiki/entities/*.md and wiki/concepts/*.md:
      1. Skip if frontmatter has nested YAML (continuation lines starting with space)
         and emit a warning. We rely on flat-scalar frontmatter only.
      2. Compute sources = number of wiki/sources/*.md files containing
         [[<slug>]], [[<slug>|...]], or [[<slug>#...]].
      3. Compute confidence:
           base = clamp(sources/5.0, 0.3, 1.0)
           if any "## Connections" bullet starts with "- contradicts::":
               confidence = min(base, 0.5)
           else:
               confidence = base
      4. last_verified = today (YYYY-MM-DD).
      5. Upsert these three keys in the page's frontmatter, preserving order
         and unrelated keys (line-based, in-place).

Outputs CHANGED / UNCHANGED / SKIPPED-NESTED / PARSE-ERROR per page on stdout.
Exits 0 even if some pages were skipped; exits 1 only on hard CLI errors.
"""
from __future__ import annotations

import argparse
import datetime
import pathlib
import re
import sys


CONNECTIONS_HEADING_RE = re.compile(r"^##\s+Connections\s*$", re.MULTILINE)
NEXT_H2_RE = re.compile(r"^##\s+", re.MULTILINE)
WIKILINK_RE = re.compile(r"^\[\[(?P<slug>[^\[\]\|#]+)(?:[\|#][^\[\]]*)?\]\]")


def is_nested_frontmatter(fm_block: str) -> bool:
    """Detect frontmatter that uses YAML nesting (continuation lines).

    Flat scalar frontmatter has every line of the form `key: value`.
    Continuation lines (starting with a space or tab) indicate nesting and
    are unsafe for line-based rewrite. We bail on these.
    """
    for line in fm_block.split("\n"):
        if not line.strip():
            continue
        # The first character is whitespace AND it's not a flow-style scalar
        # like "[X, Y]" (which starts with `[`).
        if line[:1] in (" ", "\t"):
            return True
    return False


def get_connections_section(body: str) -> str:
    """Return the body of the `## Connections` section, or '' if absent."""
    m = CONNECTIONS_HEADING_RE.search(body)
    if not m:
        return ""
    start = m.end()
    rest = body[start:]
    nm = NEXT_H2_RE.search(rest)
    if nm:
        return rest[: nm.start()]
    return rest


def has_contradicts(body: str) -> bool:
    section = get_connections_section(body)
    for line in section.split("\n"):
        # match `- contradicts:: ...` (allow leading whitespace before -)
        s = line.lstrip()
        if s.startswith("- contradicts::"):
            return True
    return False


def count_sources(vault: pathlib.Path, slug: str) -> int:
    """Count wiki/sources/*.md files that contain [[slug]], [[slug|...]] or [[slug#...]]."""
    sources_dir = vault / "wiki" / "sources"
    if not sources_dir.is_dir():
        return 0
    needle_re = re.compile(r"\[\[" + re.escape(slug) + r"(\||#|\])")
    count = 0
    for f in sorted(sources_dir.glob("*.md")):
        try:
            text = f.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if needle_re.search(text):
            count += 1
    return count


def compute_confidence(sources: int, contradictions_present: bool) -> float:
    base = max(0.3, min(1.0, sources / 5.0))
    if contradictions_present:
        return min(base, 0.5)
    return base


def split_frontmatter(text: str) -> tuple[str, str] | None:
    m = re.match(r"^---\n(.*?)\n---\n?(.*)$", text, re.S)
    if not m:
        return None
    return m.group(1), m.group(2)


def upsert_keys(fm_block: str, updates: dict[str, str]) -> str:
    """Upsert flat key:value lines, preserving order and unknown keys.

    `updates` maps key -> formatted value string (everything after `<key>: `).
    Existing matching lines are replaced in place; new keys are appended at
    the end of the frontmatter block.
    """
    lines = fm_block.split("\n")
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:(.*)$", line)
        if m and m.group(1) in updates:
            key = m.group(1)
            out.append(f"{key}: {updates[key]}")
            seen.add(key)
        else:
            out.append(line)
    for key, value in updates.items():
        if key not in seen:
            out.append(f"{key}: {value}")
    return "\n".join(out)


def format_confidence(value: float) -> str:
    # Round to 2 decimal places, no trailing zeros beyond what's needed.
    rounded = round(value, 2)
    s = f"{rounded:.2f}"
    return s


def process_page(page: pathlib.Path, vault: pathlib.Path, today: str, dry_run: bool) -> str:
    text = page.read_text(encoding="utf-8")
    parts = split_frontmatter(text)
    if parts is None:
        return "PARSE-ERROR"
    fm_block, body = parts

    if is_nested_frontmatter(fm_block):
        return "SKIPPED-NESTED"

    slug = page.stem
    sources = count_sources(vault, slug)
    contradicts = has_contradicts(body)
    confidence = compute_confidence(sources, contradicts)

    new_fm = upsert_keys(
        fm_block,
        {
            "sources": str(sources),
            "last_verified": today,
            "confidence": format_confidence(confidence),
        },
    )
    new_text = f"---\n{new_fm}\n---\n{body}"
    if new_text == text:
        return "UNCHANGED"
    if not dry_run:
        page.write_text(new_text, encoding="utf-8")
    return "CHANGED"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("vault", type=pathlib.Path, help="vault root (contains WIKI.md)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    vault: pathlib.Path = args.vault
    if not (vault / "WIKI.md").is_file():
        print(f"ERROR: {vault} is not a vault (no WIKI.md)", file=sys.stderr)
        return 1

    today = datetime.date.today().isoformat()
    dirs = [vault / "wiki" / "entities", vault / "wiki" / "concepts"]
    counters = {"CHANGED": 0, "UNCHANGED": 0, "SKIPPED-NESTED": 0, "PARSE-ERROR": 0}
    for d in dirs:
        if not d.is_dir():
            continue
        for page in sorted(d.glob("*.md")):
            status = process_page(page, vault, today, args.dry_run)
            counters[status] += 1
            print(f"{status} {page.relative_to(vault)}")

    summary = " ".join(f"{k}={v}" for k, v in counters.items())
    print(f"# entity-confidence: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
