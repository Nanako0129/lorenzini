#!/usr/bin/env bash
# Regression tests for the classification helpers, run as:  bash tests/test-classifiers.sh
#
# WHY THIS EXISTS. Every fix in docs/fail-open-ledger.md was verified by a
# throwaway probe that proved one thing and was deleted, so every round started
# from zero and several rounds reintroduced a defect an earlier round had
# already fixed -- a failed read counted as empty, a zero counted as a finding,
# an unpaginated read counted as complete. The ledger names that as the actual
# mechanism of non-convergence. These assertions are those probes, kept.
#
# The helpers are SOURCED from the real scripts rather than copied, which is
# what the source guard in each poller was put there for: a copy drifts, and a
# test passing against a copy of the gate says nothing about the gate.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$ROOT/coderabbit-review-wait/scripts/poll-coderabbit.sh"

pass=0 fail=0

# ok <name> <expected> <actual>
#
# Compare and record. Prints nothing on success, and on failure prints the name
# with both values on their own lines so the difference is readable rather than
# inferred from a diff of two long strings.
#
# String comparison, deliberately, even for the counts: an assertion that a
# verdict is "RESULT=NITPICKS count=3" must fail when the verdict is
# "RESULT=NITPICKS count=0", and a numeric comparison would need the count
# extracted first, which is a second parser of the thing under test.
ok() {
  if [ "$2" = "$3" ]; then pass=$((pass+1));
  else fail=$((fail+1)); printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; fi
}

# verdict <review-body> -> the RESULT= line classify_bodies decided, or empty
#
# Empty means classify_bodies found nothing that withholds CLEAN. That is not
# the same as "clean": the CLEAN verdict itself is granted by the polling loop
# after several further checks -- the completion marker, unreplied threads, the
# foreign reviewer -- which need live API state and are asserted separately
# through the jq helpers rather than through this function.
#
# stderr is dropped because classify_bodies prints its excerpts there; the
# assertions are about the verdict, and the excerpt text is vendor-formatted
# output that would make every assertion a brittle transcript comparison.
verdict() { classify_bodies "$1" 2>/dev/null | grep -oE 'RESULT=[A-Z]+( count=[0-9]+)?' | tail -1; }

# --- HIDDEN_RE: the buckets whose findings the reviewer's own count ignores ---
# Ledger entries 2, 4 and 11. Each spelling is here because a review carrying it
# was reported CLEAN before it was added.
for spec in \
  'Nitpick comments (3)|MATCH' \
  'Outside diff range comments (1)|MATCH' \
  'Duplicate comments (2)|MATCH' \
  'Files skipped from review as they are similar to previous changes (1)|MATCH' \
  'Nitpick comments|no' \
  'Suppressed comments (2)|no'
do
  body=${spec%|*}; want=${spec#*|}
  got=no; printf '%s' "$body" | grep -qE "$HIDDEN_RE" && got=MATCH
  ok "HIDDEN_RE: $body" "$want" "$got"
done

# --- classify_bodies: a hidden section withholds CLEAN and sums every section ---
ok "one nitpick section" "RESULT=NITPICKS count=3" \
   "$(verdict '**Actionable comments posted: 0**
<summary>Nitpick comments (3)</summary>')"
# No head -N when summing: a body with more sections than a cap would silently
# drop the overflow, which is the bug the awk sum replaced.
ok "two sections are summed" "RESULT=NITPICKS count=5" \
   "$(verdict 'Nitpick comments (3)
Outside diff range comments (2)')"
# Ledger entry 11: a review whose findings are ALL outside the diff carries no
# "Actionable comments posted" line at all.
ok "outside-diff only, no count line" "RESULT=NITPICKS count=1" \
   "$(verdict '> [!CAUTION]
> Outside diff range comments (1)')"

# --- pre-merge checks: parse the TALLY, never the rows (ledger entry 4) ---
# The failed row's Status cell reads "Warning"; the failure marker appears only
# in the tally, so a parser reading rows finds nothing and reports a pass.
ok "premerge failure in the tally" "RESULT=PREMERGE count=1" \
   "$(verdict 'No actionable comments were generated
Pre-merge checks | ✅ 4 | ❌ 1
Failed checks
Docstring Coverage | ⚠️ Warning')"
# Syrtis-Windows#115: an all-pass tally omits the failure field entirely, so a
# pattern requiring two pipes does not match it.
ok "all-pass tally is not a failure" "" \
   "$(verdict 'No actionable comments were generated
Pre-merge checks | ✅ 5')"

# --- a clean body decides nothing here (the CLEAN path lives in the loop) ---
ok "clean body blocks nothing" "" "$(verdict 'No actionable comments were generated')"

# --- UNREPLIED / DISPOSITIONED: a resolved thread is only a disposition when a
# HUMAN replied, keyed on the GraphQL actor type. Ledger entry 4: testing
# endswith("[bot]") classified every bot as human, because GraphQL omits the
# suffix REST carries -- a bot-only resolved thread was then excused.
threads='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
  {"isResolved":true,  "comments":{"nodes":[{"databaseId":1,"path":"a","author":{"login":"coderabbitai","__typename":"Bot"}}]}},
  {"isResolved":true,  "comments":{"nodes":[{"databaseId":2,"path":"b","author":{"login":"coderabbitai","__typename":"Bot"}},
                                            {"databaseId":3,"path":"b","author":{"login":"Nanako0129","__typename":"User"}}]}},
  {"isResolved":false, "comments":{"nodes":[{"databaseId":4,"path":"c","author":{"login":"Copilot","__typename":"Bot"}}]}},
  {"isResolved":false, "comments":{"nodes":[{"databaseId":5,"path":"d","author":null}]}},
  {"isResolved":false, "comments":{"nodes":[{"databaseId":6,"path":"e","author":{"login":"coderabbitai","__typename":"Bot"}}]}}
]}}}}}'
ok "bot-only resolve is not a disposition" "1" \
   "$(printf '%s' "$threads" | unreplied_resolved)"
ok "human-replied thread is dispositioned"  "[2,3]" \
   "$(printf '%s' "$threads" | dispositioned_ids)"

# --- FOREIGN_JQ: the reviewer this gate does not read (ledger entry 10) ---
# Owned excluded; the gate's own unresolved thread excluded; a resolved foreign
# thread excluded (dispositioned); a null author is not a Bot; everything else
# flagged. The jq trap this caught in review: inside index(...) the input is the
# filter's own input, so the login must be bound with `as` first or the
# expression aborts and silently counts zero.
foreign=$(printf '%s' "$threads" | jq -r --argjson owned '["coderabbitai"]' "$FOREIGN_JQ"' | .[]')
ok "foreign bots flagged"      "Copilot  c" "$foreign"
ok "foreign count"             "1"          "$(printf '%s\n' "$foreign" | grep -c '[^[:space:]]')"

# --- zero is not a finding (fail-closed, but a gate that cries wolf gets ignored) ---
for spec in 'Suppressed comments (0)|no' 'Suppressed comments (4)|MATCH' \
            'Comments generated: 0|no'   'Comments generated: 3|MATCH'
do
  # $FOREIGN_BODY_RE comes from the script, NOT a copy. A first version of this
  # block inlined the pattern and a mutation run walked straight past it:
  # widening the script's pattern to accept (0) broke no assertion, because the
  # assertion was testing its own duplicate. That is the failure this whole
  # repository is about, reproduced inside its test suite.
  body=${spec%|*}; want=${spec#*|}; got=no
  printf '%s' "$body" | grep -qE "$FOREIGN_BODY_RE" && got=MATCH
  ok "foreign-body marker: $body" "$want" "$got"
done

# --- a foreign review this gate cannot read is UNKNOWN, not clean ---
# The blocklist criticism, answered: FOREIGN_BODY_RE alone enumerates where
# findings appeared last time, so a heading rename made the count zero and a
# body-only finding reached CLEAN. Recognition now runs both directions.
for spec in \
  'Findings: None|clean' \
  'Comments generated: 0|clean' \
  'No actionable comments were generated|clean' \
  'Findings: 2|found' \
  'Suppressed comments (3)|found' \
  'Review overview: everything looks reasonable|unknown' \
  'Some future format nobody has seen|unknown'
do
  body=${spec%|*}; want=${spec#*|}
  if printf '%s' "$body" | grep -qE "$FOREIGN_BODY_RE"; then got=found
  elif printf '%s' "$body" | grep -qE "$FOREIGN_CLEAN_RE"; then got=clean
  else got=unknown; fi
  ok "foreign review: $body" "$want" "$got"
done

# --- EACH foreign review is classified on its own, never as an aggregate ---
# Raised on lorenzini#2 against the first version, which grepped a newline-joined
# blob: review bodies contain newlines so "one line per review" was never true,
# and one body matching the clean pattern marked the whole aggregate clean,
# masking a second unrecognised review posted after it.
# The production classifier, called rather than reimplemented. The first
# version of this block defined its own jq program, so a change to the
# found/clean/unknown precedence in the poller would have left every assertion
# below passing -- the duplicate-under-test failure this repository has now hit
# three times, most recently with a regex that a mutation run walked straight
# past because the assertion held a copy of it.
classify_reviews() { classify_foreign "HEAD1" '["coderabbitai[bot]"]'; }
masking='[[{"commit_id":"HEAD1","user":{"login":"Copilot","type":"Bot"},"body":"Findings: None"},
           {"commit_id":"HEAD1","user":{"login":"other-bot","type":"Bot"},"body":"a format nobody has seen"}]]'
# The expected strings are the production ones, spacing included. The first
# version of this assertion carried its own formatting and passed against its
# own jq program; pointing it at the real classifier failed immediately, which
# is the duplicate having already drifted.
ok "a clean foreign review does not mask an unknown one" "clean   Copilot
unknown other-bot  (format this gate does not recognise -- states neither findings nor their absence)" \
   "$(printf '%s' "$masking" | classify_reviews)"

owned_only='[[{"commit_id":"HEAD1","user":{"login":"coderabbitai[bot]","type":"Bot"},"body":"anything"}]]'
ok "the gate's own review is not foreign" "" "$(printf '%s' "$owned_only" | classify_reviews)"

other_head='[[{"commit_id":"HEAD0","user":{"login":"Copilot","type":"Bot"},"body":"Findings: 3"}]]'
ok "a foreign review on another commit is not at head" "" "$(printf '%s' "$other_head" | classify_reviews)"

contradictory='[[{"commit_id":"HEAD1","user":{"login":"Copilot","type":"Bot"},"body":"Findings: None\nSuppressed comments (2)"}]]'
ok "a contradictory body reads as found, not clean" "found   Copilot" "$(printf '%s' "$contradictory" | classify_reviews)"

# --- a rate limit is terminal, not something to poll through ---
# The four read sites retry on failure, which is right for a 5xx and wrong for a
# rate limit: the poller would retry to the deadline and report TIMEOUT, which
# says the verdict may still arrive. It will not. Same category error as
# reporting a paused or skipped review as a timeout.
#
# gh is stubbed rather than the limit exhausted, and the stub answers the
# rate_limit endpoint only, so the function is exercised exactly as it runs.
_stub_gh() { # _stub_gh <core-remaining> <graphql-remaining>
  local dir; dir=$(mktemp -d)
  printf '#!/bin/sh\n[ "$1" = "api" ] && [ "$2" = "rate_limit" ] || exit 1\nprintf %%s %s\n' \
    "'{\"resources\":{\"core\":{\"remaining\":$1,\"reset\":$(( $(date +%s) + 600 ))},\"graphql\":{\"remaining\":$2,\"reset\":$(( $(date +%s) + 600 ))}}}'" \
    > "$dir/gh"
  chmod +x "$dir/gh"; printf '%s' "$dir"
}
d=$(_stub_gh 4000 5000)
( PATH="$d:$PATH"; rate_limited >/dev/null ); ok "headroom on both -> not limited" "0" "$?"
rm -rf "$d"

d=$(_stub_gh 0 5000)
( PATH="$d:$PATH"; rate_limited >/dev/null ); ok "core exhausted -> limited" "1" "$?"
out=$( PATH="$d:$PATH"; rate_limited 2>&1 | head -1 )
ok "and it says so" "GitHub's API rate limit is exhausted (core=0 graphql=5000)." "$out"
rm -rf "$d"

# core and graphql exhaust independently, and this script uses both.
d=$(_stub_gh 5000 0)
( PATH="$d:$PATH"; rate_limited >/dev/null ); ok "graphql exhausted alone -> limited" "1" "$?"
rm -rf "$d"

# An unreadable rate_limit endpoint is NOT evidence of a limit: returning 1 here
# would turn any transient failure into a terminal verdict.
d=$(mktemp -d); printf '#!/bin/sh\nexit 1\n' > "$d/gh"; chmod +x "$d/gh"
( PATH="$d:$PATH"; rate_limited >/dev/null ); ok "unreadable limit endpoint is not a limit" "0" "$?"
rm -rf "$d"

# --- pipefail: a paginated read that dies after page 1 must not look complete ---
# Without it the pipeline takes jq's status, and jq -s builds a valid PARTIAL
# array from the pages that did arrive.
st=$( { printf '{"a":1}\n'; exit 3; } | jq -s 'length' >/dev/null; echo $? )
ok "no pipefail hides producer failure" "0" "$st"
st=$( set -o pipefail; { printf '{"a":1}\n'; exit 3; } | jq -s 'length' >/dev/null; echo $? )
ok "pipefail surfaces producer failure" "3" "$st"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
