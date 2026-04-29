#!/usr/bin/env python3
"""Reorder `wiki/index.md` content sections to Concepts → Entities → Sources.

Pure stdlib. Idempotent: re-running on an already-correct index produces no diff.

Usage:
    migrate-index-order.py <vault> [--dry-run]

Behavior:
    1. Locate the three top-level H2 sections `## Concepts`, `## Entities`,
       `## Sources` (case-sensitive heading match).
    2. If all three exist AND their current relative order is not
       Concepts → Entities → Sources, reorder them in place.
    3. The decorative sections (`## Activity heatmap`, `## Handover calendar`,
       and any others NOT in the trio) stay where they are. The reorder swaps
       only the three named blocks among themselves.
    4. The body of each section (its bullet list of pages) is preserved
       verbatim — only the section headings and their adjacent content move.

Output: CHANGED / UNCHANGED / MISSING-SECTIONS / NO-INDEX, one line, with summary.
Exits 0 on success or for harmless skips; exits 1 only on hard CLI errors.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys


SECTION_NAMES = ("Concepts", "Entities", "Sources")
H2_RE = re.compile(r"^##\s+(.+?)\s*$", re.MULTILINE)


def find_section_blocks(text: str) -> dict[str, tuple[int, int]]:
    """Return {name: (start_idx, end_idx)} for each H2 section.

    `start_idx` is the position of the `##` heading line.
    `end_idx` is the position before the next `## ` heading (or EOF).
    Sections not present in `text` are absent from the dict.
    """
    blocks: dict[str, tuple[int, int]] = {}
    matches = list(H2_RE.finditer(text))
    for i, m in enumerate(matches):
        name = m.group(1).strip()
        start = m.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        blocks[name] = (start, end)
    return blocks


def reorder_sections(text: str) -> tuple[str, str]:
    """Return (new_text, status). Status is one of CHANGED / UNCHANGED / MISSING-SECTIONS."""
    blocks = find_section_blocks(text)
    missing = [n for n in SECTION_NAMES if n not in blocks]
    if missing:
        return text, "MISSING-SECTIONS"

    # Current order of the three named sections, by their start index.
    spans = [(blocks[n][0], blocks[n][1], n) for n in SECTION_NAMES]
    current_order = sorted(spans, key=lambda s: s[0])
    current_names = tuple(s[2] for s in current_order)

    desired_names = SECTION_NAMES
    if current_names == desired_names:
        return text, "UNCHANGED"

    # The trio occupies a contiguous span in the file IF nothing else lives
    # between any two of them. We only allow reorder when the trio is contiguous.
    # That is, between the end of the first occurrence and the start of the
    # last occurrence, there must be no other H2 section.
    first_start = current_order[0][0]
    last_end = current_order[-1][1]
    other_h2s_in_range = [
        m for m in H2_RE.finditer(text)
        if first_start < m.start() < last_end and m.group(1).strip() not in SECTION_NAMES
    ]
    if other_h2s_in_range:
        return text, "MISSING-SECTIONS"  # treat as unsafe to reorder

    # Build new content: prefix (before trio) + trio in desired order + suffix (after trio).
    prefix = text[:first_start]
    suffix = text[last_end:]
    # Normalize each block to end with exactly one blank line separator, so that
    # whichever block lands in the middle keeps clean separation from the next.
    # The last block's trailing whitespace is then re-trimmed to match the
    # original file's final whitespace policy.
    normalized = []
    for n in desired_names:
        b = text[blocks[n][0]:blocks[n][1]]
        b = b.rstrip("\n") + "\n\n"
        normalized.append(b)
    # Rebuild the trio span. Reattach the suffix as-is; if the suffix is empty
    # (the trio was at EOF) keep one trailing newline (matches typical EOF).
    new_trio = "".join(normalized)
    if not suffix:
        new_trio = new_trio.rstrip("\n") + "\n"
    new_text = prefix + new_trio + suffix

    if new_text == text:
        return text, "UNCHANGED"
    return new_text, "CHANGED"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("vault", type=pathlib.Path)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    vault: pathlib.Path = args.vault
    if not (vault / "WIKI.md").is_file():
        print(f"ERROR: {vault} is not a vault (no WIKI.md)", file=sys.stderr)
        return 1

    index = vault / "wiki" / "index.md"
    if not index.is_file():
        print(f"NO-INDEX {index.relative_to(vault)}")
        print("# index-order: NO-INDEX")
        return 0

    text = index.read_text(encoding="utf-8")
    new_text, status = reorder_sections(text)
    print(f"{status} {index.relative_to(vault)}")
    if status == "CHANGED" and not args.dry_run:
        index.write_text(new_text, encoding="utf-8")
    print(f"# index-order: {status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
