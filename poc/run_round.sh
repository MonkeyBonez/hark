#!/bin/bash
# One improvement round: expand corpus -> label new episodes -> train student -> evaluate -> log.
# See PLAYBOOK.md for how to read the result and when to stop.
#
# Every stage is resumable: corpus writes are additive, and already-labeled episodes are skipped,
# so re-running after an interruption costs only the work that was actually lost.
#
# Usage: ./run_round.sh <round> <episodes-per-category> <shards> [teacher-repo]

set -u
cd "$(dirname "$0")" || exit 1

ROUND="${1:?usage: ./run_round.sh <round> <per-category> <shards> [teacher-repo]}"
PER_CAT="${2:?}"
SHARDS="${3:?}"
TEACHER="${4:-mlx-community/gpt-oss-20b-MXFP4-Q8}"
TAG="${TEACHER##*/}"
PY=./.venv/bin/python
LOG="rounds.md"

echo "=== ROUND $ROUND — per-category=$PER_CAT shards=$SHARDS teacher=$TAG ==="
date

echo
echo "--- 1/3 expand corpus (additive) ---"
$PY sporc_corpus.py build --shards "$SHARDS" --per-category "$PER_CAT" 2>&1 | tail -20
EPISODES=$(ls sporc/episodes 2>/dev/null | wc -l | tr -d ' ')

echo
echo "--- 2/3 label with $TAG (skips already-labeled) ---"
$PY make_silver.py "$TEACHER" 2>&1 | grep -vE "it/s|Fetching|warn" | tail -8
LABELED=$(ls "sporc/labels/$TAG" 2>/dev/null | wc -l | tr -d ' ')

echo
echo "--- 3/3 train student + evaluate ---"
RESULT=$($PY train_student.py "$TAG" --holdout 10 2>&1 | grep -vE "it/s|warn|Loading")
echo "$RESULT"

GOLD=$(echo "$RESULT" | awk '/GOLD/{f=1} f&&/median/{print $2; exit}')
SILVER=$(echo "$RESULT" | awk '/HELD-OUT/{f=1} f&&/median/{print $2; exit}')

# One row per round so rounds are directly comparable and the stopping rule is checkable.
[ -f "$LOG" ] || printf '# Rounds\n\n| round | episodes | labeled | gold F1 | held-out silver F1 | date |\n|---|---|---|---|---|---|\n' > "$LOG"
printf '| %s | %s | %s | %s | %s | %s |\n' \
  "$ROUND" "$EPISODES" "$LABELED" "${GOLD:-?}" "${SILVER:-?}" "$(date +%Y-%m-%d)" >> "$LOG"

echo
echo "=== ROUND $ROUND DONE — gold=$GOLD held-out-silver=$SILVER (appended to $LOG) ==="
echo "next: compare with the previous row. Stop if gold improved < 0.02 for two rounds running."
