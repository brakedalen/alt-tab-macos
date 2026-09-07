#!/bin/bash
set -euo pipefail

sample_count="${1:-31}"
sample_interval="${2:-2}"
if ! [[ "$sample_count" =~ ^[1-9][0-9]*$ && "$sample_interval" =~ ^[1-9][0-9]*$ ]] || (( sample_count > 301 || sample_interval > 60 )); then
    echo "Usage: bash scripts/measure_resources.sh [samples: 1-301] [interval seconds: 1-60]" >&2
    exit 2
fi

# Resolve current PIDs for every run; neither AltTab instance has a fixed PID.
top_args=()
for app_name in "WindowServer" "AltTab" "AltTab dev" "Ice" "replayd" "systemstatusd"; do
    while IFS= read -r process_id; do
        [[ -n "$process_id" ]] && top_args+=(-pid "$process_id")
    done < <(pgrep -x "$app_name" || true)
done
if (( ${#top_args[@]} == 0 )); then
    echo "No matching processes found." >&2
    exit 1
fi
date -Iseconds
sw_vers
echo "First top sample has no interval CPU baseline; use subsequent samples."
echo "MEM is top's process footprint, not ps RSS. This is correlation, not WindowServer attribution."
top -l "$sample_count" -s "$sample_interval" "${top_args[@]}" -stats pid,command,cpu,mem,threads,ports
