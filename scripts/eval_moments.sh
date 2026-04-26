#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL_FILE="${1:-"$ROOT/eval/moments/validation_urls.txt"}"
LIMIT="${MOMENT_LIMIT:-10}"

if [[ ! -f "$URL_FILE" ]]; then
  echo "URL file not found: $URL_FILE" >&2
  exit 1
fi

cd "$ROOT"
swift build -c release --disable-sandbox >/tmp/vvx-moment-eval-build.log 2>&1

set_name="$(basename "$URL_FILE" .txt)"
out_dir="/tmp/vvx-moment-eval-${set_name}-$(date +%Y%m%d%H%M%S)"
mkdir -p "$out_dir"
transcript_dir="$out_dir/transcripts"
mkdir -p "$transcript_dir"

printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "video_id" "sense_status" "sense_seconds" "moments_status" "moments_seconds" "title" \
  > "$out_dir/summary.tsv"

video_id_for_url() {
  local url="$1"
  local id="$url"
  if [[ "$url" == *"v="* ]]; then
    id="${url##*v=}"
    id="${id%%&*}"
  else
    id="$(printf '%s' "$url" | shasum -a 1 | awk '{print substr($1,1,12)}')"
  fi
  printf '%s' "$id"
}

while IFS= read -r url; do
  [[ "$url" =~ ^[[:space:]]*(#|$) ]] && continue

  id="$(video_id_for_url "$url")"
  sense_status=0
  moments_status=0

  /usr/bin/time -p .build/release/vvx sense --transcript-dir "$transcript_dir" "$url" \
    > "$out_dir/$id.sense.json" \
    2> "$out_dir/$id.sense.err" || sense_status=$?

  /usr/bin/time -p .build/release/vvx moments --from-sense "$out_dir/$id.sense.json" --limit "$LIMIT" --explain \
    > "$out_dir/$id.moments.json" \
    2> "$out_dir/$id.moments.err" || moments_status=$?

  sense_seconds="$(awk '/^real / {print $2}' "$out_dir/$id.sense.err" | tail -1)"
  moments_seconds="$(awk '/^real / {print $2}' "$out_dir/$id.moments.err" | tail -1)"
  title="$(jq -r '.sourceTitle // .title // ""' "$out_dir/$id.moments.json" 2>/dev/null | tr '\t\n' '  ')"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$sense_status" "${sense_seconds:-n/a}" "$moments_status" "${moments_seconds:-n/a}" "$title" \
    >> "$out_dir/summary.tsv"
done < "$URL_FILE"

top_tsv="$out_dir/top-ranked-moments.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "video_id" "rank" "score" "click_raw" "click_final" "cap_applied" "cap_reason" \
  "selected_for_product" "content_mode" \
  "sponsor_detected" "start" "end" "chapter" "center_sentence" "signals" "usefulness" \
  "mode_boosts" "mode_penalties" \
  > "$top_tsv"

for f in "$out_dir"/*.moments.json; do
  id="$(basename "$f" .moments.json)"
  jq -r --arg id "$id" '
    (.rankedMoments // [])[]
    | [
        $id,
        .rank,
        .score,
        (.clickScoreRaw // .wouldUserClickScore // ""),
        (.clickScoreFinal // .wouldUserClickScore // ""),
        (if .scoreCapApplied == null then "" else (.scoreCapApplied | tostring) end),
        (.scoreCapReason // ""),
        (if .selectedForProduct == null then "" else (.selectedForProduct | tostring) end),
        (.contentMode // ""),
        (if .sponsorDetected == null then "" else (.sponsorDetected | tostring) end),
        .startSeconds,
        .endSeconds,
        (.chapterTitle // ""),
        (.centerSentence // ""),
        ((.productWorthinessSignals // []) | join(",")),
        ((.usefulnessSignals // []) | join(",")),
        ((.modeSpecificBoosts // []) | join(",")),
        ((.modeSpecificPenalties // []) | join(","))
      ]
    | @tsv
  ' "$f" >> "$top_tsv"
done

report="$out_dir/raw-detailed-report.md"
{
  printf '# MomentRanker Raw Detailed Eval\n\n'
  printf 'URL file: `%s`\n\n' "$URL_FILE"
  printf 'Output directory: `%s`\n\n' "$out_dir"
  printf 'Limit: `%s`\n\n' "$LIMIT"
  printf '## Timing Summary\n\n```tsv\n'
  cat "$out_dir/summary.tsv"
  printf '```\n\n'
  printf '## Counts\n\n```tsv\nvideo_id\trankedMoments\tmomentCandidates\trejectedAnchors\n'
  for f in "$out_dir"/*.moments.json; do
    id="$(basename "$f" .moments.json)"
    printf '%s\t' "$id"
    jq -r '[((.rankedMoments // [])|length), ((.momentCandidates // [])|length), ((.rejectedAnchors // [])|length)] | @tsv' "$f"
  done
  printf '```\n\n'
  printf '## Selected Moment Checks\n\n```tsv\nvideo_id\tselectedQuestionAnchors\tselectedUnalignedTopicZeroNumbers\tselectedSponsors\tselectedNotProduct\tselectedBelow75\n'
  for f in "$out_dir"/*.moments.json; do
    id="$(basename "$f" .moments.json)"
    question_count="$(jq -r '[.rankedMoments[]? | select((.centerSentence // "") | test("\\?$"))] | length' "$f")"
    unaligned_count="$(jq -r '[.rankedMoments[]? | select((.numberIsTopicAligned == false) and ((.cleanText // "") | test("[0-9]")) and ((.topicAlignment // 0) == 0))] | length' "$f")"
    sponsor_count="$(jq -r '[.rankedMoments[]? | select(.sponsorDetected == true)] | length' "$f")"
    not_product_count="$(jq -r '[.rankedMoments[]? | select(.selectedForProduct == false)] | length' "$f")"
    below_product_count="$(jq -r '[.rankedMoments[]? | select((.clickScoreFinal // .wouldUserClickScore // .score // 0) < 75)] | length' "$f")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$question_count" "$unaligned_count" "$sponsor_count" "$not_product_count" "$below_product_count"
  done
  printf '```\n\n'
  printf '## Rejection Reason Totals\n\n```text\n'
  jq -r '.rejectedAnchors[]? | .rejectionReason' "$out_dir"/*.moments.json | sort | uniq -c | sort -nr
  printf '```\n\n'
  for f in "$out_dir"/*.moments.json; do
    id="$(basename "$f" .moments.json)"
    printf '## %s\n\n' "$id"
    jq -r '"Title: \(.sourceTitle)\n\nURL: \(.sourceURL)\n"' "$f"
    jq -r '
      (.rankedMoments // [])[]
      | "### #\(.rank) score=\(.score) clickRaw=\(.clickScoreRaw // .wouldUserClickScore // 0) clickFinal=\(.clickScoreFinal // .wouldUserClickScore // 0) duration=\(.durationSeconds)s time=\(.startSeconds)-\(.endSeconds)\n\nchapter: \(.chapterTitle // "n/a")\ncontentMode: \(.contentMode // "n/a")\nselectedForProduct: \(.selectedForProduct // false)\nsponsorDetected: \(.sponsorDetected // false)\nscoreCapApplied: \(.scoreCapApplied // false)\nscoreCapReason: \(.scoreCapReason // "n/a")\ntitleHint: \(.titleHint)\ncenterSentence: \(.centerSentence // "n/a")\nanchorScore: \(.anchorScore // 0)\ntopicAlignment: \(.topicAlignment // 0)\nchapterSpecificity: \(.chapterSpecificity // 0)\nnumberIsTopicAligned: \(.numberIsTopicAligned // false)\nhasConsequenceNearby: \(.hasConsequenceNearby // false)\nproductWorthinessSignals: \((.productWorthinessSignals // []) | join(", "))\nusefulnessSignals: \((.usefulnessSignals // []) | join(", "))\nmodeSpecificBoosts: \((.modeSpecificBoosts // []) | join(", "))\nmodeSpecificPenalties: \((.modeSpecificPenalties // []) | join(", "))\nscoreBreakdown: topic=\(.scoreBreakdown.topicRelevance) insight=\(.scoreBreakdown.insight) concrete=\(.scoreBreakdown.concreteness) selfContained=\(.scoreBreakdown.selfContained) chapter=\(.scoreBreakdown.chapter) qualityPenalty=\(.scoreBreakdown.qualityPenalty) mmr=\(.scoreBreakdown.mmrDiversity)\nwhySelected: \((.whySelected // []) | join("; "))\n\n```text\n\(.cleanText)\n```\n"
    ' "$f"
    printf '### Rejected Anchor Reasons\n\n```text\n'
    jq -r '.rejectedAnchors[]? | .rejectionReason' "$f" | sort | uniq -c | sort -nr
    printf '```\n\n'
  done
} > "$report"

printf '%s\n' "$out_dir"
