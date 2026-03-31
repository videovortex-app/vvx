# Docs

This directory contains tracked documentation for `vvx`.

## Files

- `VVX_CLI_SPEC.md` — the canonical AI-facing CLI reference, generated from the compiled binary via `vvx docs`

## Regenerating The CLI Spec

From the repo root:

```bash
swift build -c release
.build/release/vvx docs > docs/VVX_CLI_SPEC.md
```

## Validation

Use the repo scripts to verify both the docs contract and skill command validity:

```bash
python3 scripts/check_docs_coverage.py --vvx .build/release/vvx
python3 scripts/lint_skill.py SKILL.md --vvx .build/release/vvx
```

`check_docs_coverage.py` fails if the parser exposes a flag that is missing from `DocsCommand.swift`.

`lint_skill.py` fails if a skill contains hallucinated or invalid `vvx` flags.
