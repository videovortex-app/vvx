#!/usr/bin/env python3
"""
lint_skill.py — Validate vvx commands embedded in a skill Markdown file.

For every `vvx ...` command found inside a fenced code block, runs the command
against the local vvx binary and checks whether ArgumentParser rejects it with
exit code 64 (EX_USAGE) and an "Unknown option" / "Unknown argument" message in
stderr.  Any other exit code means the flags parsed correctly — the command may
have failed for a legitimate runtime reason (no DB, no network), but that is not
a linting concern.

Exit codes
  0  all commands passed flag validation
  1  one or more commands contain hallucinated or invalid flags

Usage
  python3 scripts/lint_skill.py path/to/SKILL.md
  python3 scripts/lint_skill.py path/to/SKILL.md --vvx .build/release/vvx
  python3 scripts/lint_skill.py skills/*.md          # glob multiple files
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

def extract_vvx_commands(md_text: str) -> list[tuple[int, str]]:
    """
    Return (line_number, command_string) for every vvx command found inside
    fenced code blocks (``` ... ```) in md_text.

    Inline comments (# ...) are stripped.  Lines that are clearly template
    placeholders with no actual flags (e.g. just `vvx`) are included as-is so
    the binary's own missing-argument error surfaces naturally.
    """
    commands: list[tuple[int, str]] = []
    in_fence = False

    for i, line in enumerate(md_text.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence and re.match(r'^vvx\b', stripped):
            # Strip trailing inline comments
            cmd = re.sub(r'\s+#\s+.*$', '', stripped).strip()
            if cmd:
                commands.append((i, cmd))

    return commands


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def check_command(binary: str, cmd_str: str, timeout: int = 10) -> tuple[bool, str]:
    """
    Run cmd_str, substituting the leading 'vvx' token with `binary`.

    Returns (is_valid, detail):
      is_valid=True  — flags parsed OK (any exit code other than 64, or 64 without
                       "Unknown option/argument" in stderr — e.g. missing required arg)
      is_valid=False — ArgumentParser rejected an unknown flag (exit 64 +
                       "Unknown option" or "Unknown argument" in stderr)
    """
    parts = cmd_str.split()
    if parts and parts[0] == "vvx":
        parts[0] = binary

    try:
        result = subprocess.run(
            parts,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        # Timed out waiting for something (probably DB I/O) — flags were valid
        return True, "(timed out — flags accepted, likely waiting on DB)"
    except FileNotFoundError:
        return False, f"vvx binary not found at: {binary}"

    if result.returncode == 64:
        stderr = result.stderr.strip()
        first_line = stderr.splitlines()[0] if stderr else ""
        if "Unknown option" in stderr or "Unknown argument" in stderr:
            return False, first_line
        # Exit 64 for a different reason (e.g. missing required argument) — flags OK
        return True, f"exit 64 — {first_line or 'missing required argument'}"

    return True, f"exit {result.returncode}"


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def lint_file(path: Path, binary: str) -> list[tuple[int, str, str]]:
    """Lint a single skill file.  Returns list of (line_no, cmd, detail) failures."""
    md_text = path.read_text(encoding="utf-8")
    commands = extract_vvx_commands(md_text)

    if not commands:
        print(f"  (no vvx commands found in {path.name})")
        return []

    failures: list[tuple[int, str, str]] = []
    for line_no, cmd in commands:
        valid, detail = check_command(binary, cmd)
        marker = "✓" if valid else "✗"
        print(f"  {marker}  line {line_no:4d}  {cmd}")
        if not valid:
            print(f"            └─ {detail}")
            failures.append((line_no, cmd, detail))

    return failures


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Validate vvx commands in skill Markdown files.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument(
        "skill_files",
        nargs="+",
        metavar="FILE",
        help="Skill Markdown file(s) to lint",
    )
    ap.add_argument(
        "--vvx",
        default="vvx",
        metavar="PATH",
        help="Path to the vvx binary (default: vvx from PATH)",
    )
    args = ap.parse_args()

    all_failures: list[tuple[str, int, str, str]] = []

    for raw_path in args.skill_files:
        path = Path(raw_path)
        if not path.exists():
            print(f"ERROR: file not found: {path}", file=sys.stderr)
            sys.exit(1)

        print(f"\n{path}")
        print("─" * min(len(str(path)), 72))
        file_failures = lint_file(path, args.vvx)
        for line_no, cmd, detail in file_failures:
            all_failures.append((str(path), line_no, cmd, detail))

    print()
    if all_failures:
        print(f"FAIL — {len(all_failures)} invalid command(s) across "
              f"{len(args.skill_files)} file(s).")
        sys.exit(1)
    else:
        print(f"PASS — all commands in {len(args.skill_files)} file(s) use valid flags.")
        sys.exit(0)


if __name__ == "__main__":
    main()
