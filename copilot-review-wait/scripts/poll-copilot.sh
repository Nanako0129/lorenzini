#!/usr/bin/env bash
# Poll a GitHub PR until the Copilot reviewer (copilot-pull-request-reviewer[bot])
# submits a review for the current head commit, then classify the outcome.
# Run in the background; act on RESULT when it exits.
#
# Usage: poll-copilot.sh [PR_NUMBER] [--repo OWNER/NAME] [--timeout SECONDS] [--interval SECONDS] [--request]
#   PR_NUMBER  optional; defaults to the PR for the current branch
#   --repo     OWNER/NAME; needed when the working dir is not the target git
#              repo (e.g. running this script from the skill dir). Also honors
#              the GH_REPO env var. Without either, the repo is auto-detected
#              from the current directory.
#   --timeout  total seconds to wait (default 900)
#   --interval seconds between polls (default 20)
#   --request  ask Copilot for a review before polling. Needed when the repo has
#              no "Automatically request Copilot code review" ruleset, and after
#              every push when that ruleset lacks "Review new pushes".
#
# Output (last line is machine-readable):
#   RESULT=CLEAN                  Copilot reviewed HEAD and left no inline comments → gate met, may merge
#   RESULT=SUGGESTIONS count=N    Copilot left N inline comments on HEAD (listed above) → fix, push, re-run
#   RESULT=MISCOUNT claimed=N counted=M   Copilot's body reports more comments than were found
#   RESULT=TABLE count=N          findings reported in the per-file table, not as comments
#   RESULT=TIMEOUT                no review in time (Copilot slow, out of quota, or not enabled for this account)
#   RESULT=ERROR ...              draft PR, or could not resolve repo/PR/tools
#
# Unlike the Codex reviewer, Copilot signals a clean pass by SUBMITTING A REVIEW
# WITH NO INLINE COMMENTS -- there is no +1 reaction. The review body is always
# present (a "Pull Request Overview" summary) whether or not it found anything,
# so the body is NOT the signal; the inline comment count is.
#
# Two logins, measured on Nanako0129/coralline#85 on 2026-09-17: the REVIEW is
# authored by "copilot-pull-request-reviewer[bot]" but its INLINE COMMENTS are
# authored by "Copilot" (type Bot, id 175728472). Filtering comments by the
# review's login finds zero of them and reports a false CLEAN. Both are matched
# below; do not collapse them.
set -u

TIMEOUT=900 INTERVAL=20 PR="" REPO_ARG="" REQUEST=0
BOT="copilot-pull-request-reviewer[bot]"
CBOT="Copilot"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)     REPO_ARG="${2:-}";    shift 2 ;;
    --timeout)  TIMEOUT="${2:-900}";  shift 2 ;;
    --interval) INTERVAL="${2:-20}";  shift 2 ;;
    --request)  REQUEST=1;            shift ;;
    [0-9]*)     PR="$1";              shift ;;
    *)          shift ;;
  esac
done
command -v gh >/dev/null 2>&1 || { echo "RESULT=ERROR gh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "RESULT=ERROR jq not found"; exit 2; }

if [ -n "$REPO_ARG" ]; then
  REPO="$REPO_ARG"
elif [ -n "${GH_REPO:-}" ]; then
  REPO="$GH_REPO"
else
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
    || { echo "RESULT=ERROR cannot resolve the repo -- run from the target git repo, or pass --repo OWNER/NAME (or set GH_REPO)"; exit 2; }
fi
[ -n "$PR" ] || PR=$(gh pr view --repo "$REPO" --json number --jq .number 2>/dev/null) \
  || { echo "RESULT=ERROR no PR for the current branch (pass a PR number, or --repo with a PR number)"; exit 2; }
HEAD=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null) \
  || { echo "RESULT=ERROR cannot read PR #$PR in $REPO"; exit 2; }
if [ "$(gh pr view "$PR" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null)" = "true" ]; then
  echo "RESULT=ERROR PR #$PR is a draft -- Copilot does not review drafts. Run 'gh pr ready $PR' first, then poll."
  exit 2
fi

if [ "$REQUEST" = "1" ]; then
  # The [bot] suffix is required: without it the API rejects the login with 422
  # "Reviews may only be requested from collaborators". A 200 here returns an
  # empty requested_reviewers array -- Copilot does not appear in that list, so
  # confirm the request landed via the timeline, not the response body.
  gh api "repos/$REPO/pulls/$PR/requested_reviewers" -X POST -f "reviewers[]=$BOT" >/dev/null 2>&1 \
    || { echo "RESULT=ERROR could not request a Copilot review (is Copilot code review enabled for this account?)"; exit 2; }
  echo "Requested a Copilot review on $REPO PR #$PR."
fi

echo "Polling Copilot on $REPO PR #$PR (head ${HEAD:0:7}); timeout ${TIMEOUT}s, every ${INTERVAL}s."
deadline=$(( $(date +%s) + TIMEOUT ))

# A review and its inline comments are submitted together, but they are read
# back through two endpoints. Confirm a zero-comment review twice, one interval
# apart, so a read that lands between the two writes cannot be reported CLEAN.
clean_seen=0

while [ "$(date +%s)" -lt "$deadline" ]; do
  # --paginate --slurp cannot be combined with gh's own --jq; pipe to jq instead.
  # Without --paginate the reviews endpoint caps at 30 and a long-running PR
  # pushes the newest review onto page 2, where it is invisible.
  reviews=$(gh api --paginate --slurp "repos/$REPO/pulls/$PR/reviews?per_page=100" 2>/dev/null || printf '[]')
  reviewed=$(printf '%s\n' "$reviews" \
    | jq --arg h "$HEAD" --arg b "$BOT" '[.[][] | select(.user.login == $b and .commit_id == $h)] | length' 2>/dev/null || echo 0)
  if [ "${reviewed:-0}" -ge 1 ]; then
    # A FAILED read is not an empty result. Verified on coralline#85: with only
    # this call failing and the reviews endpoint succeeding, the script reported
    # CLEAN on a review carrying three findings. The twice-over confirmation
    # below does not help, because a rate limit or 5xx persists across rounds.
    if ! comments=$(gh api --paginate --slurp "repos/$REPO/pulls/$PR/comments?per_page=100" 2>/dev/null) \
       || ! printf '%s\n' "$comments" | jq -e 'type == "array"' >/dev/null 2>&1; then
      [ "${read_warned:-0}" = "1" ] || {
        echo "Could not read the review-comments endpoint. Retrying rather than counting zero findings."
        read_warned=1
      }
      clean_seen=0
      sleep "$INTERVAL"
      continue
    fi
    read_warned=0
    # Measured on coralline#85: this endpoint populates .line, but the
    # reviews/{id}/comments endpoint returns it as null with only a diff
    # `position`. The fallback below keeps the display right either way.
    # in_reply_to_id excludes Copilot's own thread replies, which are not
    # findings. Counting them only over-counts (fail closed), but it inflates
    # every later round, so an auto loop would not converge.
    sel='.[][] | select((.user.login == $b or .user.login == $c) and .original_commit_id == $h and .in_reply_to_id == null)'
    inline=$(printf '%s\n' "$comments" \
      | jq --arg h "$HEAD" --arg b "$BOT" --arg c "$CBOT" "[$sel] | length" 2>/dev/null || echo 0)
    if [ "${inline:-0}" -ge 1 ]; then
      echo "Copilot left inline comments on the current commit:"
      echo "------------------------------------------------------------"
      printf '%s\n' "$comments" \
        | jq -r --arg h "$HEAD" --arg b "$BOT" --arg c "$CBOT" \
          "$sel | \"── \(.path):\(.line // .original_line // \"@pos\(.position)\") ──\n\(.body)\n\"" 2>/dev/null
      echo "------------------------------------------------------------"
      echo "RESULT=SUGGESTIONS count=$inline"
      exit 0
    fi
    clean_seen=$(( clean_seen + 1 ))
    if [ "$clean_seen" -ge 2 ]; then
      # Zero inline comments is NOT the same as "Copilot found nothing".
      # Copilot withholds low-confidence findings into a "Suppressed comments"
      # section of the review body, where they never touch the comment count.
      # Measured: sepia#250 ran FOUR rounds at inline 0 with suppressed findings
      # every round -- 8 real defects, which a CLEAN verdict would have merged
      # four times over. coralline#85 carried one more. Five observations, five
      # with suppressed findings. So a body with that section gets its own
      # verdict and must never be reported as CLEAN.
      body=$(printf '%s\n' "$reviews" | jq -r --arg h "$HEAD" --arg b "$BOT" \
        '[.[][] | select(.user.login == $b and .commit_id == $h)] | last | .body // ""' 2>/dev/null)
      echo "Copilot reviewed the current commit and left no inline comments."
      printf '%s\n' "$body" | head -1 | sed 's/^/Review body says: /'
      sup=$(printf '%s\n' "$body" | grep -c 'Suppressed comments')
      if [ "${sup:-0}" -ge 1 ]; then
        n=$(printf '%s\n' "$body" | sed -n 's/.*Suppressed comments (\([0-9]*\)).*/\1/p' | head -1)
        echo
        echo "Copilot withheld findings from the inline set. These are NOT covered by"
        echo "the comment count, and on sepia#250 every such finding was a real defect."
        echo "Disposition them like any other finding before merging."
        echo "------------------------------------------------------------"
        printf '%s\n' "$body" | sed -n '/Suppressed comments/,$p' \
          | sed '/^- \*\*Files reviewed/,$d' | sed '/^<\/details>/,$d'
        echo "------------------------------------------------------------"
        echo "RESULT=SUPPRESSED count=${n:-unknown}"
        exit 0
      fi

      # CROSS-CHECK COPILOT'S OWN NUMBER AGAINST OURS.
      #
      # The fail-open ledger and SKILL.md both stated this was already done --
      # "if the body says 3 and you counted 0, the filter is wrong, not the pull
      # request clean" -- and it was never in this file. The claim shipped to a
      # public repository and outlived its truth. It exists now.
      #
      # It is the guard against the ledger's own entry #1 recurring: Copilot
      # renamed nothing, but it authors its review and its inline comments under
      # two different logins, and a filter matching neither produces the same
      # empty set as a clean pull request. Only an independent number can tell
      # those apart. It is also the one signal that moves when the vendor
      # changes its output format, which every regex here silently will not.
      # The literal is "- **Comments generated:** 3" -- the emphasis markers sit
      # BETWEEN the colon and the number, so 'Comments generated: [0-9]+' matches
      # nothing. The first version of this guard used exactly that and was dead
      # code: a check that can never fire, added while fixing checks that never
      # fired. Tolerate optional emphasis and spacing, and verify against a real
      # body rather than a remembered one.
      claimed=$(printf '%s\n' "$body" | grep -oE 'Comments generated:[*[:space:]]*[0-9]+' | grep -oE '[0-9]+' | tail -1)
      if [ -n "${claimed:-}" ] && [ "${claimed:-0}" -gt "${inline:-0}" ]; then
        echo
        echo "Copilot reports $claimed comment(s) generated for this commit, but only"
        echo "${inline:-0} were found on it. Something it posted is not being counted."
        echo "Do not read this as clean: the gap is the finding."
        echo "RESULT=MISCOUNT claimed=$claimed counted=${inline:-0}"
        exit 0
      fi

      # THE NEW BODY FORMAT PARKS FINDINGS IN A TABLE CELL.
      #
      # Measured on lorenzini#1, 2026-09-19. Copilot changed its review body
      # (marker "ccr-overview-v2") and every string the older checks keyed on
      # disappeared in the same stroke: "Comments generated", "Suppressed
      # comments" and "Files reviewed" all went to zero occurrences. The gate
      # did not error -- it reported CLEAN on a review whose per-file table read
      # "Two moderate issues ... Two nits ...", with the summary line saying
      # "Needs a closer look" and "Findings: None" alongside it.
      #
      # This is the vendor-drift failure an independent review predicted the day
      # before: every pattern here encodes one day's rendering, and when the
      # rendering moves they stop matching silently and the gate degrades into a
      # machine that always says CLEAN.
      #
      # "Findings: None" counts INLINE findings, as the old count did. The
      # per-file table is the bucket. Read the last column of each data row; a
      # cell that is not empty and not a literal none/dash is a finding Copilot
      # is reporting somewhere other than the count.
      # Locate the Findings column by its HEADER, never by position. The older
      # body format also has a per-file table, but it is "| File | Description |"
      # -- reading its last column as findings reported Syrtis-Agent#4, a clean
      # PR, as having one. Fail-closed, but wrong, and a gate that cries wolf on
      # clean runs gets ignored or edited away.
      table_findings=$(printf '%s\n' "$body" | awk -F'|' '
        /^\|/ {
          if (col == 0) {
            for (i = 2; i < NF; i++) {
              h = $i; gsub(/^[ \t]+|[ \t]+$/, "", h)
              if (tolower(h) == "findings") { col = i }
            }
            next
          }
          if ($0 ~ /^\|[ \t]*:?-+:?[ \t]*\|/) next
          if (col > 0 && col < NF) {
            c = $col; gsub(/^[ \t]+|[ \t]+$/, "", c)
            lc = tolower(c)
            if (c != "" && lc != "none" && lc != "-" && lc != "n/a" && lc != "—") print c
          }
        }')
      if [ -n "$table_findings" ]; then
        echo
        echo "Copilot reported findings in its per-file table rather than as inline"
        echo "comments. They do not move the comment count:"
        echo "------------------------------------------------------------"
        printf '%s\n' "$table_findings"
        echo "------------------------------------------------------------"
        echo "RESULT=TABLE count=$(printf '%s\n' "$table_findings" | wc -l | tr -d ' ')"
        exit 0
      fi

      # Copilot is documented never to submit CHANGES_REQUESTED, and none has
      # been observed. If that ever changes, a zero-comment CHANGES_REQUESTED
      # would otherwise read as clean. One line, fails closed.
      changes=$(printf '%s\n' "$reviews" | jq --arg h "$HEAD" --arg b "$BOT" \
        '[.[][] | select(.user.login == $b and .commit_id == $h and .state == "CHANGES_REQUESTED")] | length' 2>/dev/null || echo 0)
      if [ "${changes:-0}" -ge 1 ]; then
        echo "Copilot submitted CHANGES_REQUESTED on this commit with no inline comments."
        echo "RESULT=SUGGESTIONS count=0"
        exit 0
      fi

      echo "RESULT=CLEAN"
      exit 0
    fi
  fi
  sleep "$INTERVAL"
done

echo "RESULT=TIMEOUT (no Copilot review of ${HEAD:0:7} in ${TIMEOUT}s; it may be slow, out of quota, or not enabled for this account)"
exit 0
