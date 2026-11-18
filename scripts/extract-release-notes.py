#!/usr/bin/env python3
"""Extract three-language release notes for a given version tag from CHANGELOG*.md."""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FALLBACK_NOTES = (
    "Unsigned IPA built by GitHub Actions. "
    "Sign it with your own App Group-capable profile before installing. See README.md."
)
SOURCES = (
    ("简体中文", ROOT / "CHANGELOG.zh.md"),
    ("English", ROOT / "CHANGELOG.md"),
    ("日本語", ROOT / "CHANGELOG.ja.md"),
)


def extract_version_section(text: str, version: str) -> str:
    header_re = re.compile(r"^##\s+v?" + re.escape(version) + r"(?:\s|$|[—–-])")
    next_section_re = re.compile(r"^##\s+")
    lines = text.splitlines()
    collecting = False
    collected = []

    for line in lines:
        if not collecting:
            if header_re.match(line.strip()):
                collecting = True
            continue
        if next_section_re.match(line.strip()):
            break
        if line.startswith("### "):
            collected.append("#" + line)
        else:
            collected.append(line)

    return "\n".join(collected).strip()


def build_release_notes(tag: str) -> str:
    version = tag[1:] if tag.startswith(("v", "V")) else tag
    sections = []
    for title, path in SOURCES:
        if not path.is_file():
            continue
        body = extract_version_section(path.read_text(encoding="utf-8"), version)
        if body:
            sections.append(f"### {title}\n\n{body}")

    if not sections:
        print(f"WARNING: no changelog section found for {version}; using fallback notes", file=sys.stderr)
        return FALLBACK_NOTES + "\n"
    return "\n\n".join(sections) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="Release tag or version (e.g. v2.1.1 or 2.1.1)")
    parser.add_argument("-o", "--output", help="Output markdown file path (defaults to stdout)")
    args = parser.parse_args()

    notes = build_release_notes(args.tag)
    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(notes, encoding="utf-8", newline="\n")
    else:
        sys.stdout.write(notes)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
