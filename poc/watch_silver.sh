#!/bin/bash
# Blocks until the silver-labeling run finishes, then prints a summary and exits.
# Exiting is the point: it fires a completion notification so the next stage can start
# without polling. Safe to re-run; it only watches, never writes.
#
# Usage: ./watch_silver.sh [teacher-tag] [expected-count]

cd "$(dirname "$0")" || exit 1
TAG="${1:-gpt-oss-20b-MXFP4-Q8}"
EXPECTED="${2:-390}"
LABELS="sporc/labels/$TAG"

while pgrep -f "make_silver.py" > /dev/null; do
  sleep 60
done

# The process is gone — but distinguish "finished all episodes" from "died early", because a
# crash at episode 200 looks identical to success unless we count what actually landed.
DONE=$(ls "$LABELS" 2>/dev/null | wc -l | tr -d ' ')
echo "=== silver labeling stopped ==="
echo "labeled: $DONE / $EXPECTED"
if [ "$DONE" -lt "$EXPECTED" ]; then
  echo "STATUS: INCOMPLETE — resume with: ./.venv/bin/python make_silver.py mlx-community/$TAG"
  echo "(already-labeled episodes are skipped, so a resume costs nothing)"
else
  echo "STATUS: COMPLETE"
fi
echo "--- last log lines ---"
grep "ranges," sporc/silver_run.log 2>/dev/null | tail -3
