# MomentRanker Eval Sets

`debug_urls.txt` is the seen regression set. It should catch known failure modes.

`validation_urls.txt` is the rotating generalization set. Add fresh videos here
before tuning ranking logic.

Run:

```bash
scripts/eval_moments.sh eval/moments/validation_urls.txt
```

The runner writes JSON, timings, and a raw Markdown report under `/tmp`.
