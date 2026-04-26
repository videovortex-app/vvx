# MomentRanker Eval Sets

`debug_urls.txt` is the seen regression set. It should catch known failure modes.

`validation_urls.txt` is the rotating generalization set. Add fresh videos here
before tuning ranking logic.

`holdout_urls.txt` is a blind check set. Do not tune against it first; use it
after a ranking change to catch overfitting.

Run:

```bash
scripts/eval_moments.sh eval/moments/validation_urls.txt
scripts/eval_moments.sh eval/moments/holdout_urls.txt
```

The runner writes JSON, timings, and a raw Markdown report under `/tmp`.
