#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUERY_FILE="${1:-"$ROOT/eval/moments/query_eval.tsv"}"
shift || true
LIMIT="${QUERY_MOMENT_LIMIT:-10}"

if [[ ! -f "$QUERY_FILE" ]]; then
  echo "Query file not found: $QUERY_FILE" >&2
  exit 1
fi

cd "$ROOT"
swift build -c release --disable-sandbox >/tmp/vvx-query-moment-eval-build.log 2>&1

if [[ "$#" -gt 0 ]]; then
  SENSE_DIRS=("$@")
else
  mapfile -t SENSE_DIRS < <(ls -td /tmp/vvx-moment-eval-validation_urls-* /tmp/vvx-moment-eval-holdout_urls-* 2>/dev/null | head -8)
fi

if [[ "${#SENSE_DIRS[@]}" -eq 0 ]]; then
  echo "No sense directories supplied or discovered." >&2
  exit 1
fi

out_dir="/tmp/vvx-query-moment-eval-$(date +%Y%m%d%H%M%S)"
mkdir -p "$out_dir"

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "video_id" "query" "status" "seconds" "queryStrength" "rankedMoments" \
  "queryCandidates" "rejectedQueryAnchors" "dedupedOverlaps" "noResultReason" "title" \
  > "$out_dir/summary.tsv"

find_sense_file() {
  local id="$1"
  local dir
  for dir in "${SENSE_DIRS[@]}"; do
    if [[ -f "$dir/$id.sense.json" ]]; then
      if jq -e '(.transcriptBlocks // []) | length > 0' "$dir/$id.sense.json" >/dev/null 2>&1; then
        printf '%s/%s.sense.json' "$dir" "$id"
        return 0
      fi
    fi
  done
  return 1
}

while IFS=$'\t' read -r video_id query _rest; do
  [[ "$video_id" =~ ^[[:space:]]*(#|$) ]] && continue
  [[ -z "${query:-}" ]] && continue

  status=0
  sense_file="$(find_sense_file "$video_id" || true)"
  if [[ -z "$sense_file" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$video_id" "$query" "missing_sense" "n/a" "" "" "" "" "" "missing_sense_file" "" \
      >> "$out_dir/summary.tsv"
    continue
  fi

  /usr/bin/time -p .build/release/vvx moments \
    --from-sense "$sense_file" \
    --query "$query" \
    --limit "$LIMIT" \
    --explain \
    > "$out_dir/$video_id.query.json" \
    2> "$out_dir/$video_id.query.err" || status=$?

  seconds="$(awk '/^real / {print $2}' "$out_dir/$video_id.query.err" | tail -1)"
  title="$(jq -r '.sourceTitle // ""' "$out_dir/$video_id.query.json" 2>/dev/null | tr '\t\n' '  ')"
  query_strength="$(jq -r '.queryStrength // ""' "$out_dir/$video_id.query.json" 2>/dev/null)"
  ranked_count="$(jq -r '(.rankedMoments // []) | length' "$out_dir/$video_id.query.json" 2>/dev/null)"
  candidate_count="$(jq -r '(.queryCandidates // []) | length' "$out_dir/$video_id.query.json" 2>/dev/null)"
  rejected_count="$(jq -r '(.rejectedQueryAnchors // []) | length' "$out_dir/$video_id.query.json" 2>/dev/null)"
  deduped_count="$(jq -r '(.dedupedOverlaps // []) | length' "$out_dir/$video_id.query.json" 2>/dev/null)"
  no_result="$(jq -r '.noResultReason // ""' "$out_dir/$video_id.query.json" 2>/dev/null)"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$video_id" "$query" "$status" "${seconds:-n/a}" "$query_strength" \
    "${ranked_count:-0}" "${candidate_count:-0}" "${rejected_count:-0}" \
    "${deduped_count:-0}" "$no_result" "$title" \
    >> "$out_dir/summary.tsv"
done < "$QUERY_FILE"

top_tsv="$out_dir/top-query-moments.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "video_id" "query" "rank" "score" "strength" "queryMatch" "momentQuality" \
  "boundaryQuality" "combined" "selectedForProduct" "start" "end" "matchedTerms" "centerSentence" \
  > "$top_tsv"

for f in "$out_dir"/*.query.json; do
  [[ -f "$f" ]] || continue
  id="$(basename "$f" .query.json)"
  query_value="$(jq -r '.query // ""' "$f")"
  jq -r --arg id "$id" --arg query "$query_value" '
    (.rankedMoments // [])[]
    | [
        $id,
        $query,
        .rank,
        .score,
        (.queryStrength // ""),
        (.queryMatchScore // ""),
        (.momentQualityScore // ""),
        (.boundaryQualityScore // ""),
        (.combinedScore // ""),
        (if .selectedForProduct == null then "" else (.selectedForProduct | tostring) end),
        .startSeconds,
        .endSeconds,
        ((.matchedTerms // []) | join(",")),
        (.centerSentence // "")
      ]
    | @tsv
  ' "$f" >> "$top_tsv"
done

report="$out_dir/raw-detailed-report.md"
{
  printf '# Query MomentRanker Raw Detailed Eval\n\n'
  printf 'Query file: `%s`\n\n' "$QUERY_FILE"
  printf 'Sense directories:\n\n'
  for dir in "${SENSE_DIRS[@]}"; do
    printf -- '- `%s`\n' "$dir"
  done
  printf '\nOutput directory: `%s`\n\n' "$out_dir"
  printf 'Limit: `%s`\n\n' "$LIMIT"
  printf '## Timing Summary\n\n```tsv\n'
  cat "$out_dir/summary.tsv"
  printf '```\n\n'
  printf '## Query Result Counts\n\n```tsv\nvideo_id\tquery\tstrength\tranked\tcandidates\trejected\tdeduped\tnoResultReason\n'
  tail -n +2 "$out_dir/summary.tsv" | awk -F '\t' '{print $1 "\t" $2 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $9 "\t" $10}'
  printf '```\n\n'
  printf '## Rejection Reason Totals\n\n```text\n'
  jq -r '.rejectedQueryAnchors[]? | .rejectionReason' "$out_dir"/*.query.json 2>/dev/null | sort | uniq -c | sort -nr || true
  printf '```\n\n'
  printf '## Deduped Overlap Totals\n\n```text\n'
  jq -r '.dedupedOverlaps[]? | .reason' "$out_dir"/*.query.json 2>/dev/null | sort | uniq -c | sort -nr || true
  printf '```\n\n'

  for f in "$out_dir"/*.query.json; do
    [[ -f "$f" ]] || continue
    id="$(basename "$f" .query.json)"
    printf '## %s\n\n' "$id"
    jq -r '"Title: \(.sourceTitle)\n\nURL: \(.sourceURL)\n\nQuery: \(.query)\nQuery strength: \(.queryStrength // "n/a")\nNo result reason: \(.noResultReason // "n/a")\n"' "$f"
    jq -r '
      (.rankedMoments // [])[]
      | "### #\(.rank) score=\(.score) strength=\(.queryStrength // "n/a") query=\(.queryMatchScore // 0) moment=\(.momentQualityScore // 0) boundary=\(.boundaryQualityScore // 0) duration=\(.durationSeconds)s time=\(.startSeconds)-\(.endSeconds)\n\nchapter: \(.chapterTitle // "n/a")\nselectedForProduct: \(.selectedForProduct // false)\nmatchedTerms: \((.matchedTerms // []) | join(", "))\ntitleHint: \(.titleHint)\ncenterSentence: \(.centerSentence // "n/a")\nwhySelected: \((.whySelected // []) | join("; "))\nvideoURLAtTime: \(.videoURLAtTime // "n/a")\n\n```text\n\(.cleanText)\n```\n"
    ' "$f"
    printf '### Rejected Query Anchors\n\n```text\n'
    jq -r '.rejectedQueryAnchors[]? | "\(.rejectionReason)\tq=\(.queryMatchScore)\t\(.centerSentence)"' "$f" | head -30
    printf '```\n\n'
    printf '### Deduped Overlaps\n\n```text\n'
    jq -r '.dedupedOverlaps[]? | "\(.reason)\tduplicateOf=\(.duplicateOf)\tsim=\(.similarity)\toverlap=\(.overlapRatio)\t\(.centerSentence)"' "$f" | head -30
    printf '```\n\n'
  done
} > "$report"

printf '%s\n' "$out_dir"
