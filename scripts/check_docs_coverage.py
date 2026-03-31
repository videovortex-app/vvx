#!/usr/bin/env python3
"""
check_docs_coverage.py — Verify DocsCommand.swift documents every parser flag.

For each vvx subcommand, runs `vvx <command> --help`, extracts every --flag-name
the binary reports, and asserts that the flag appears verbatim somewhere in
Sources/vvx/Commands/DocsCommand.swift.

Run from the repo root after a release build:
  python3 scripts/check_docs_coverage.py
  python3 scripts/check_docs_coverage.py --vvx .build/release/vvx

Exit codes
  0  DocsCommand.swift covers every flag exposed by the parser
  1  one or more parser flags are missing from DocsCommand.swift
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


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def get_parser_flags(binary: str, command: str) -> set[str]:
    """
    Return the set of --flag-names that `vvx <command> --help` reports.
    Both stdout and stderr are scanned because ArgumentParser sometimes writes
    to stderr on error paths.
    """
    result = subprocess.run(
        [binary, command, "--help"],
        capture_output=True,
        text=True,
    )
    output = result.stdout + result.stderr
    flags = set(re.findall(r'(--[\w-]+)', output))
    return flags - UNIVERSAL_FLAGS


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Check that DocsCommand.swift covers all parser flags.",
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

        missing = sorted(f for f in flags if f not in docs_text)

        if missing:
            print(f"  ✗  {cmd}: {len(missing)} flag(s) missing from DocsCommand.swift")
            for flag in missing:
                print(f"       └─ {flag}")
            all_missing.extend((cmd, f) for f in missing)
        else:
            print(f"  ✓  {cmd}: {len(flags)} flag(s) all covered")

    print()

    if all_missing:
        print(
            f"FAIL — {len(all_missing)} flag(s) across "
            f"{len({cmd for cmd, _ in all_missing})} command(s) are in the parser "
            f"but absent from DocsCommand.swift."
        )
        print()
        print("Add documentation for each missing flag to the corresponding")
        print("section string in DocsCommand.swift, then re-run this script.")
        sys.exit(1)
    else:
        print(
            f"PASS — DocsCommand.swift covers all parser flags "
            f"across {len(COMMANDS)} commands."
        )
        sys.exit(0)


if __name__ == "__main__":
    main()
