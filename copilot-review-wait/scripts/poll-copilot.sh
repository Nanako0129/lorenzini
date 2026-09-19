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
    comments=$(gh api --paginate --slurp "repos/$REPO/pulls/$PR/comments?per_page=100" 2>/dev/null || printf '[]')
    # Measured on coralline#85: this endpoint populates .line, but the
    # reviews/{id}/comments endpoint returns it as null with only a diff
    # `position`. The fallback below keeps the display right either way.
    sel='.[][] | select((.user.login == $b or .user.login == $c) and .original_commit_id == $h)'
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
      echo "RESULT=CLEAN"
      exit 0
    fi
  fi
  sleep "$INTERVAL"
done

echo "RESULT=TIMEOUT (no Copilot review of ${HEAD:0:7} in ${TIMEOUT}s; it may be slow, out of quota, or not enabled for this account)"
exit 0
