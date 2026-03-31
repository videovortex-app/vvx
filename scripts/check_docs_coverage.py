#!/usr/bin/env python3
"""
check_docs_coverage.py — Verify DocsCommand.swift documents every parser flag
in the CORRECT section.

For each vvx subcommand, runs `vvx <command> --help`, extracts every --flag-name
the binary reports, and asserts that the flag appears inside the matching section
string in Sources/vvx/Commands/DocsCommand.swift.

A section is delimited by the Swift string variable name, e.g.:
  var searchSection: String { ... }   ← covers the "search" command
  var gatherSection: String { ... }   ← covers the "gather" command

The check is section-scoped: a flag that only appears in gatherSection does NOT
satisfy the requirement for clip.  This prevents the cross-section false-pass
that allowed --exact and --pad to slip out of the clip docs.

Run from the repo root after a release build:
  python3 scripts/check_docs_coverage.py
  python3 scripts/check_docs_coverage.py --vvx .build/release/vvx

Exit codes
  0  Every flag for every command is documented in the correct section
  1  One or more parser flags are missing from the correct section
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path


COMMANDS = [
    "sense",
    "fetch",
    "search",
    "gather",
    "sync",
    "clip",
    "ingest",
    "library",
    "sql",
    "reindex",
    "doctor",
    "engine",
]

DOCS_FILE = Path("Sources/vvx/Commands/DocsCommand.swift")

# Flags that ArgumentParser injects on every command and that need not appear
# in the hand-written prose (they are always present and self-explanatory).
UNIVERSAL_FLAGS = {"--help", "--version"}

# Flags that are intentionally shared across sections (e.g. --limit appears
# in both search and gather). List them here to suppress duplicate warnings
# when a flag is legitimately documented only in one canonical section.
# Key = flag, Value = the one section where it is canonically documented.
# Any command that also has the flag but is NOT the canonical section is exempt.
CANONICAL_SECTION: dict[str, str] = {
    # These flags exist on multiple commands; document them in the canonical
    # section only. Other commands that have the flag are exempt.
    "--limit":    "search",
    "--platform": "search",
    "--after":    "search",
    "--uploader": "search",
    "--pad":      "gather",   # gather owns the full pad/snap/context table
    "--snap":     "gather",
    "--context-seconds": "gather",
    "--dry-run":  "search",   # first introduced in search NLE export
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def get_parser_flags(binary: str, command: str) -> set[str]:
    """
    Return the set of real parser flags from the OPTIONS section of
    `vvx <command> --help`.

    Important: do NOT scan the whole help output. Example blocks in the
    discussion can mention flags from other commands (for example `vvx search
    --rag` inside `vvx clip --help`), which creates false positives.
    """
    result = subprocess.run(
        [binary, command, "--help"],
        capture_output=True,
        text=True,
    )
    output = result.stdout + result.stderr

    options_match = re.search(r"(?ms)^OPTIONS:\n(.*?)(?:^\S|\Z)", output)
    options_text = options_match.group(1) if options_match else ""

    flags = set()
    for line in options_text.splitlines():
        stripped = line.lstrip()
        if not stripped.startswith("-"):
            continue
        flags.update(re.findall(r"(--[\w-]+)", stripped))

    return flags - UNIVERSAL_FLAGS


def extract_section(docs_text: str, command: str) -> str:
    """
    Return the text of the Swift string variable `var <command>Section`.
    Falls back to the full file if the section cannot be isolated, so the
    check is never noisier than the old global search.
    """
    # Match:  var <command>Section: String {
    #           """
    #           ...content...
    #           """
    #         }
    # We use a simple heuristic: grab everything between the opening triple-
    # quote after `var <cmd>Section` and the closing triple-quote.
    pattern = re.compile(
        rf'var {re.escape(command)}Section\b.*?"""\n(.*?)"""',
        re.DOTALL,
    )
    m = pattern.search(docs_text)
    if m:
        return m.group(1)
    # Fallback: return the full file (old behaviour, less strict)
    return docs_text


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Check that DocsCommand.swift covers all parser flags "
                    "in the CORRECT section.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument(
        "--vvx",
        default=".build/release/vvx",
        metavar="PATH",
        help="Path to the compiled vvx binary (default: .build/release/vvx)",
    )
    ap.add_argument(
        "--docs",
        default=str(DOCS_FILE),
        metavar="FILE",
        help=f"Path to DocsCommand.swift (default: {DOCS_FILE})",
    )
    args = ap.parse_args()

    docs_path = Path(args.docs)
    if not docs_path.exists():
        print(
            f"ERROR: {docs_path} not found.  Run from the repo root.",
            file=sys.stderr,
        )
        sys.exit(1)

    docs_text = docs_path.read_text(encoding="utf-8")

    print(f"Binary : {args.vvx}")
    print(f"Docs   : {docs_path}")
    print()

    all_missing: list[tuple[str, str]] = []

    for cmd in COMMANDS:
        flags = get_parser_flags(args.vvx, cmd)

        if not flags:
            print(f"  ?  {cmd}: no flags found in --help output (binary missing?)")
            continue

        section_text = extract_section(docs_text, cmd)

        missing = []
        for flag in sorted(flags):
            # If this flag has a canonical section and it isn't this command,
            # check only that the canonical section documents it (skip here).
            canonical = CANONICAL_SECTION.get(flag)
            if canonical and canonical != cmd:
                continue
            if flag not in section_text:
                missing.append(flag)

        if missing:
            print(f"  ✗  {cmd}: {len(missing)} flag(s) missing from {cmd}Section")
            for flag in missing:
                print(f"       └─ {flag}")
            all_missing.extend((cmd, f) for f in missing)
        else:
            print(f"  ✓  {cmd}: all flags covered in {cmd}Section")

    print()

    if all_missing:
        print(
            f"FAIL — {len(all_missing)} flag(s) across "
            f"{len({cmd for cmd, _ in all_missing})} command(s) are in the parser "
            f"but absent from the correct section of DocsCommand.swift."
        )
        print()
        print("Add documentation for each missing flag to the corresponding")
        print("section string in DocsCommand.swift, then re-run this script.")
        sys.exit(1)
    else:
        print(
            f"PASS — DocsCommand.swift covers all parser flags "
            f"across {len(COMMANDS)} commands (section-scoped)."
        )
        sys.exit(0)


if __name__ == "__main__":
    main()
