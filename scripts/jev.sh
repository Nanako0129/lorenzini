#!/usr/bin/env bash
# jev.sh -- one call to TypeSafe System One. curl and jq only, no SDK.
#
#   echo '{"state":...,"questions":...}' | jev.sh -
#
# Prints the .answers object on stdout, and one JSONL record per call to the
# log. Exit codes are loud on purpose; callers decide their own fail-closed
# semantics:
#
#   0 ok · 2 no key · 3 bad input · 4 http or network error · 5 malformed response
#
# Key: $TYPESAFE_API_KEY, else ~/.config/typesafe/api_key (chmod 600). Never
# logged, never printed, not passed on a command line.
#
# The model is PINNED. jev-latest silently changes models, and a classifier's
# version is part of its contract -- so is the question text, which is why every
# record carries a hash of the question set. Two records with different hashes
# were produced by different classifiers even if the model string matches.
#
# Origin: adapted from ~/side-project/jev-research/bin/jev.sh, which is an
# unversioned local experiment directory. This copy exists because the skills in
# this repository must not reach outside it: a public repository that hardcodes
# a path under someone's home directory does not work for anyone who clones it,
# and the thing it points at can change or vanish without a diff.
#
# No dependency is installed for this. The vendor's SDK is a recent package
# whose default retry timeout would park a poll for half a minute; curl with an
# explicit --max-time is both smaller and more predictable.
set -u

KEY="${TYPESAFE_API_KEY:-$(cat "$HOME/.config/typesafe/api_key" 2>/dev/null)}"
[ -n "$KEY" ] || { echo "jev: no key (TYPESAFE_API_KEY or ~/.config/typesafe/api_key)" >&2; exit 2; }

MODEL="${JEV_MODEL:-jev-1.13.0}"
TIMEOUT="${JEV_TIMEOUT:-8}"
LOG="${JEV_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/lorenzini/jev-calls.jsonl}"

[ "${1:-}" = "-" ] || { echo "usage: jev.sh - < body.json" >&2; exit 3; }
body=$(jq -c --arg m "$MODEL" '. + {model: $m}') || { echo "jev: stdin is not JSON" >&2; exit 3; }
qset_hash=$(printf '%s' "$body" | jq -cS '.questions' | shasum -a 256 | cut -c1-16)

out=$(mktemp); trap 'rm -f "$out"' EXIT
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

meta=$(curl -sS -o "$out" -w '%{http_code} %{time_total}' --max-time "$TIMEOUT" \
  -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d "$body" https://api.typesafe.ai/v1/systemone 2>>"${LOG%.jsonl}.err") \
  || { echo "jev: network or timeout after ${TIMEOUT}s" >&2; exit 4; }
code=${meta%% *}; secs=${meta#* }

if [ "$code" != "200" ]; then
  echo "jev: HTTP $code $(jq -r '.detail // .error // empty' "$out" 2>/dev/null | head -c 200)" >&2
  exit 4
fi

answers=$(jq -c '.answers // empty' "$out") && [ -n "$answers" ] \
  || { echo "jev: no .answers in response" >&2; exit 5; }

# A failed append must be loud. A caller that reports "recorded" over a write
# that did not happen is the same absence-read-as-success this repository exists
# to stop; the answers still go to stdout, so the verdict path is unaffected.
if ! jq -cn --arg ts "$(date -u +%FT%TZ)" --arg m "$MODEL" --arg qh "$qset_hash" --arg s "$secs" \
     --argjson usage "$(jq -c '.usage // {}' "$out")" --argjson a "$answers" \
     '{ts:$ts, model:$m, qset_hash:$qh, secs:($s|tonumber), usage:$usage, answers:$a}' >>"$LOG" 2>/dev/null; then
  echo "jev: could not append to $LOG (answers returned anyway)" >&2
fi

printf '%s\n' "$answers"
