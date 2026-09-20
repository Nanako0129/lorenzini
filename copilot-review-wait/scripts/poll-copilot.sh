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
#   RESULT=UNREAD format=X        a review format with no known clean shape -- a human must read it
#   RESULT=NOT_REVIEWED           a review object at HEAD whose body is not a verdict (e.g. quota exhausted)
#   RESULT=OTHERBOT              Copilot is clean, but this PR carries undispositioned findings
#                                 from a reviewer this gate does not read (listed above)
#   RESULT=TIMEOUT                no review in time (Copilot slow, or not enabled for this account)
#   RESULT=ERROR ...              draft PR, or could not resolve repo/PR/tools
#
# Unlike the Codex reviewer, Copilot signals a clean pass by SUBMITTING A REVIEW
# WITH NO INLINE COMMENTS -- there is no +1 reaction. So the inline comment count
# carries the verdict once a review has happened.
#
# But the body decides WHETHER one happened, and an earlier version of this
# comment said the opposite: that a body is always present whichever way the
# review went, so the body is not a signal. That was measured on reviews and
# was true of every one of them; it was false about the objects that are not
# reviews. On NyanCogs#31 Copilot submitted a review carrying only "unable to
# review ... reached their quota limit", and reading the body as noise made
# that indistinguishable from a clean pass. The body is now read first, for
# the one question the inline count cannot answer. See the NOT_REVIEWED guard
# below for the marker and the measurement behind it.
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
  # A FAILED READ IS NOT AN EMPTY REVIEW LIST. $reviews feeds the head-keyed
  # verdict, the body shape check AND the foreign-reviewer body scan, so a
  # failure here loses both the findings and the evidence that findings exist.
  # Raised against the sibling script on lorenzini#2 and fixed here by grep.
  if ! reviews=$(gh api --paginate --slurp "repos/$REPO/pulls/$PR/reviews?per_page=100" 2>/dev/null) \
     || ! printf '%s\n' "$reviews" | jq -e 'type == "array" and all(.[]; type == "array")' >/dev/null 2>&1; then
    [ "${rev_warned:-0}" = "1" ] || { echo "Could not read the reviews endpoint. Retrying rather than counting zero reviews."; rev_warned=1; }
    clean_seen=0; sleep "$INTERVAL"; continue
  fi
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
      # A REVIEW OBJECT IS NOT A REVIEW. Checked before anything else here,
      # because every guard below assumes a review actually happened and the
      # sentence printed after this one would otherwise assert that it did.
      #
      # Nanako0129/NyanCogs#31, head 8f6eee6, 2026-09-20: Copilot submitted a
      # COMMENTED review on the head commit with zero inline comments and a
      # 119-character body reading "Copilot was unable to review this pull
      # request because the user who requested the review has reached their
      # quota limit." That satisfies "a review of head plus an empty inline set"
      # exactly, and this script printed RESULT=CLEAN over it -- a pass over a
      # review object stating in plain English that no review was performed.
      # Reported by the messagewatch-rule-based-alerts session and reproduced
      # here by running this script against that pull request before the fix.
      #
      # The test is POSITIVE EVIDENCE, not one more entry on a blocklist. Every
      # other guard in this file names a specific bad thing, which is why each
      # new vendor message has arrived as a fresh clean verdict; requiring a
      # verdict to look like a verdict catches the next one too, whatever it says.
      #
      # `^### ` is the marker, measured 2026-09-20 over 41 Copilot review bodies
      # across nine repositories and BOTH body formats: the older one opening
      # `### 🟢 Approval recommended` with a `Comments generated:` count, and
      # `ccr-overview-v2`, which opens with an HTML comment and carries
      # `Findings:` instead. All 40 real reviews carry a `### ` status line; the
      # quota message is the only body without one. `Findings:` and `Comments
      # generated:` were both rejected as the marker because each is absent from
      # one of the two formats. No Copilot review with an empty body appeared in
      # that survey, so requiring the line cannot block a pass observed to exist.
      if ! printf '%s\n' "$body" | grep -qE '^### '; then
        echo "Copilot submitted a review object on this commit, but its body is not a review."
        echo "A verdict body carries a '### <status>' line in both of Copilot's formats."
        echo "This one does not, so nothing here says the code was read."
        echo "------------------------------------------------------------"
        printf '%s\n' "$body"
        echo "------------------------------------------------------------"
        case "$body" in
          *"reached their quota limit"*)
            echo "This is the quota message: the review was never performed, and the quota"
            echo "is per requesting user, so every repository on the Copilot routing table"
            echo "is affected at the same time. Wait for the quota to reset, or trigger the"
            echo "other reviewer by hand with a top-level '@coderabbitai review' comment --"
            echo "which works on these repositories precisely because their CodeRabbit auto"
            echo "review is disabled and the manual command is the documented escape hatch."
            ;;
        esac
        echo "RESULT=NOT_REVIEWED"
        exit 0
      fi

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
      # The vendor's own number, in whatever spelling this format uses.
      #
      # The older body said "- **Comments generated:** 3". The ccr-overview-v2
      # body dropped that entirely and reports "**Findings:** N", plus named
      # sections "Open (N)" and "Previously missed (N)" -- the latter being
      # findings in code that has not changed since the last review, which
      # therefore never become inline comments at all. Measured on lorenzini#1,
      # 2026-09-19: "Findings: 1", "Open (1)", "Previously missed (2)", zero
      # inline comments at head, two real documentation defects. Reported CLEAN.
      #
      # Ledger entry 7 said the honest mitigation is to re-find this number in
      # each new format rather than add one more pattern per bucket, because a
      # pattern that stops matching is silent and a bucket list is never
      # complete. This is that: collect every count the body states about
      # findings and take the largest. Their exact relationship is not modelled
      # -- Open and Previously missed overlap here -- so the maximum is used
      # deliberately. Over-counting withholds a pass; under-counting grants one.
      claimed=$(printf '%s\n' "$body" \
        | grep -oE 'Comments generated:[*[:space:]]*[0-9]+|\*\*Findings:\*\*[[:space:]]*[0-9]+|Open \(([0-9]+)\)|Previously missed \(([0-9]+)\)' \
        | grep -oE '[0-9]+' | sort -rn | head -1)
      if [ -n "${claimed:-}" ] && [ "${claimed:-0}" -gt "${inline:-0}" ]; then
        echo
        echo "Copilot's own body reports $claimed finding(s) for this commit; ${inline:-0} were"
        echo "found on it. Some are in sections that never become inline comments --"
        echo "'Previously missed' covers code unchanged since the last review."
        echo "Read the body. Do not read this as clean: the gap is the finding."
        printf '%s\n' "$body" | sed 's/<[^>]*>//g' | grep -nE '^###|Findings:|^Open \(|^Previously missed \(|^Resolved since' | head -8
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
      # NEW BODY FORMAT: THIS GATE DOES NOT KNOW WHAT CLEAN LOOKS LIKE.
      #
      # Three rounds were spent patching a hand-rolled Markdown table parser for
      # the ccr-overview-v2 body -- wrong column, `< NF` instead of `<= NF`,
      # then a missing leading pipe -- each round finding a defect the previous
      # round introduced. That is the divergence signature: findings clustering
      # in one function rather than spread across the work.
      #
      # The reason it kept failing is that it was the wrong question. Across
      # five captured new-format bodies, EVERY one carries "Needs a closer look"
      # and a substantive one-line summary under it, and not one of them is a
      # confirmed clean review. Syrtis-Agent#4 was reported CLEAN by this script
      # while its summary read "The configuration will not automatically
      # re-enable CodeRabbit reviews after the repository reaches ten stars" --
      # a real observation, with Findings: None and no inline comments.
      #
      # So there is no clean sample of this format to recognise, and inventing a
      # pattern for one would be a guard asserting something never measured.
      # The honest behaviour is to refuse the pass and hand the body to a human,
      # which is what this gate does everywhere else when it cannot tell.
      #
      # Delete this branch once a genuinely clean new-format review has been
      # captured and its shape is known -- not before.
      # RECOGNISE THE CLEAN SHAPE, NOT THE UNCLEAN ONES. Raised by Copilot on
      # lorenzini#1 against the version that did the opposite: it listed two
      # literal markers for the new format and sent those to UNREAD, so a body
      # that was neither the old format nor those two markers -- a renamed
      # marker, a third format -- fell through to CLEAN at the bottom of this
      # block. That is the blocklist problem again, in the branch written to
      # fix a fail-open.
      #
      # Inverting it is only honest if a clean shape has actually been
      # measured, otherwise CLEAN becomes unreachable and the gate is dead
      # rather than strict. One has: the older format, on calico-claude#44 and
      # #45, both reading
      #
      #   ### 🟢 Approval recommended
      #   - **Files reviewed:** 5/5 changed files
      #   - **Comments generated:** 0
      #
      # (#45 spells the count "0 new"). All three parts are required. The
      # files-reviewed ratio is part of the shape rather than a separate glance
      # because a body reporting 4/5 has a file nobody read, and a zero finding
      # count over unread code says nothing -- the same reason CodeRabbit's
      # "Files skipped from review" withholds CLEAN in the sibling script.
      #
      # ccr-overview-v2 still has no clean sample. Every captured one carries a
      # substantive summary alongside "Findings: None" and zero inline comments,
      # and Syrtis-Agent#4 was reported CLEAN by this script while its summary
      # read "The configuration will not automatically re-enable CodeRabbit
      # reviews after the repository reaches ten stars". So it stays UNREAD, now
      # by falling through rather than by being named.
      #
      # Delete nothing here when a clean new-format sample appears: ADD its
      # shape to the case below. The default must stay UNREAD.
      # ANCHORED TO THE STATUS LINE, not to the phrase anywhere in the body.
      # `*"Approval recommended"*` matched a "### 🟡 Changes recommended" body
      # that mentioned the phrase further down -- in its own per-file table, or
      # in a quoted suggestion -- which could then satisfy the zero-count and
      # complete-ratio checks and pass as CLEAN. Raised by CodeRabbit on
      # lorenzini#1, in the outside-diff bucket, because the lines it is about
      # were not in that round's diff.
      #
      # The comment three paragraphs up already said the shape was
      # "### 🟢 Approval recommended"; the code matched something looser. This
      # is not a new guard, it is the code being made to say what the contract
      # above it already claimed.
      #
      # DO NOT DROP THE gen/ratio CHECKS AS REDUNDANT. Measured 2026-09-21:
      # NyanCogs#30's ccr-overview-v2 body carries the SAME
      # "### 🟢 Approval recommended" line, so the status line does not
      # distinguish the two formats at all. What keeps ccr-overview-v2 -- which
      # has no verified clean sample -- out of clean_shape is that it spells its
      # counts "Findings: None" instead of "Comments generated: 0" and carries
      # no "Files reviewed: N/N". That exclusion is therefore load-bearing and
      # accidental-looking, which is exactly the kind of check that gets
      # simplified away by someone reading the status line and assuming it is
      # the discriminator.
      clean_shape=0
      if printf '%s\n' "$body" | grep -qE '^### 🟢 Approval recommended[[:space:]]*$'; then
        gen=$(printf '%s\n' "$body" | grep -oE 'Comments generated:[*[:space:]]*[0-9]+' | grep -oE '[0-9]+' | tail -1)
        ratio=$(printf '%s\n' "$body" | grep -oE 'Files reviewed:[*[:space:]]*[0-9]+/[0-9]+' | grep -oE '[0-9]+/[0-9]+' | tail -1)
        if [ "${gen:-x}" = "0" ] && [ -n "$ratio" ] && [ "${ratio%%/*}" = "${ratio##*/}" ]; then
          clean_shape=1
        fi
      fi
      if [ "$clean_shape" != "1" ]; then
        case "$body" in
          *ccr-overview-v2*|*"Copilot review overview"*) fmt=ccr-overview-v2 ;;
          *"Approval recommended"*)                      fmt=approval-but-not-clean-shape ;;
          *)                                             fmt=unrecognised ;;
        esac
        echo
        echo "This review body does not match any shape verified to mean a clean pass,"
        echo "so an empty inline count over it proves nothing. Read the review:"
        echo "------------------------------------------------------------"
        # The WHOLE body. A head -14 here was raised on lorenzini#1 and is a
        # real hole: the per-file table can place findings past the cutoff, so
        # the truncation hid exactly the cells that made the format unreadable.
        # A review body is a few kilobytes; there is nothing to save by cutting
        # it, and this branch exists precisely because a person must read it.
        printf '%s\n' "$body" | sed 's/<[^>]*>//g' | grep -vE '^[[:space:]]*$'
        echo "------------------------------------------------------------"
        echo "RESULT=UNREAD format=$fmt"
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

      # THE REVIEWER THIS GATE DOES NOT OWN. The symmetric half of the hole
      # recorded as entry 10 of docs/fail-open-ledger.md and closed in the
      # CodeRabbit poller first: this script filters to Copilot's two logins, so
      # on a pull request a second reviewer also looked at, that reviewer's
      # findings are invisible to every verdict produced here.
      #
      # The routing does not prevent it. All five repositories on this side
      # carry CodeRabbit's own "Auto reviews are disabled on this repository"
      # notice, so the split is real -- but a hand or checkbox trigger puts
      # CodeRabbit on any of them without leaving a trace this poller reads.
      # NyanCogs#29 is the measured case: auto review disabled, CodeRabbit
      # triggered anyway, three rounds and eight inline findings, three of them
      # on lines Copilot's first round never touched. This gate would have said
      # CLEAN.
      #
      # Checked last, because it is the only gate about a reviewer this script
      # cannot read. It does not classify the other bot's findings -- parsing a
      # second vendor's body format here would be a second gate inside this one
      # -- it refuses the pass and names the login and the file. A thread
      # resolved with a human reply counts as dispositioned.
      #
      # GraphQL omits the "[bot]" suffix REST carries, so the owned set is
      # spelled the GraphQL way, and Copilot needs BOTH of its logins here for
      # the same reason the comment filter above does.
      # A FAILED GRAPHQL CALL IS NOT AN EMPTY THREAD SET. The `|| printf '{}'`
      # that was here on the first version of this guard turned a rate limit or
      # a 5xx into "no threads", and the guard then fell through to CLEAN --
      # the third time today that a fallback value was written where a retry
      # belonged, and the first time it was written INTO a guard against
      # exactly that. Raised by CodeRabbit on lorenzini#1.
      #
      # The shape is checked, not just the exit status: GraphQL answers a failed
      # query with HTTP 200 and an `errors` array, so a zero exit says nothing
      # about whether `reviewThreads` came back.
      # PAGINATED. `reviewThreads(first:100)` silently truncates at 100, the
      # same defect as the reviews endpoint capping at 30 without --paginate: a
      # long-lived pull request pushes its newest threads out of the window and
      # their absence reads as "handled". gh supplies $endCursor itself and
      # emits one document per page; `jq -s` merges them back into the single
      # shape the filter below already expects.
      # `set -o pipefail` INSIDE the substitution: without it the pipeline takes
      # jq's status, so a --paginate call that fails AFTER emitting earlier
      # pages exits 0 and jq -s builds a valid PARTIAL array that passes the
      # shape check below. Scoped to the subshell because this script has
      # pipelines that legitimately exit non-zero, `grep -c` with no match
      # among them.
      if ! threads=$(set -o pipefail; gh api graphql --paginate -f query="query(\$endCursor:String){repository(owner:\"${REPO%%/*}\",name:\"${REPO##*/}\"){pullRequest(number:$PR){reviewThreads(first:100, after:\$endCursor){pageInfo{hasNextPage endCursor} nodes{isResolved comments(first:50){nodes{path author{login __typename}}}}}}}}" 2>/dev/null \
                     | jq -s '{data:{repository:{pullRequest:{reviewThreads:{nodes:[.[].data.repository.pullRequest.reviewThreads.nodes[]]}}}}}' 2>/dev/null) \
         || ! printf '%s\n' "$threads" | jq -e '.data.repository.pullRequest.reviewThreads.nodes | type == "array"' >/dev/null 2>&1; then
        [ "${thread_warned:-0}" = "1" ] || { echo "Could not read the review threads. Retrying rather than counting zero findings."; thread_warned=1; }
        clean_seen=0
        sleep "$INTERVAL"
        continue
      fi
      foreign=$(printf '%s\n' "$threads" | jq -r --argjson owned '["copilot-pull-request-reviewer","Copilot"]' '
        [.data.repository.pullRequest.reviewThreads.nodes[]?
         | select(.isResolved | not)
         | .comments.nodes[0]
         | select((.author.__typename // "") == "Bot")
         | (.author.login // "") as $login
         | select(($owned | index($login)) | not)
         | "\($login)  \(.path // "?")"] | .[]' 2>/dev/null)
      # grep -c prints 0 AND exits 1 when nothing matches, so a `|| echo 0`
      # fallback here would append a second zero and make the numeric test
      # below fail with "integer expected" -- falling through to CLEAN. That
      # happened in the sibling script on its first live run.
      n_foreign=$(printf '%s\n' "$foreign" | grep -c '[^[:space:]]') || true

      # A FOREIGN BOT'S FINDINGS NEED NOT CREATE A THREAD AT ALL. Raised by
      # CodeRabbit on lorenzini#1, about its own behaviour: it parks
      # outside-diff-range, nitpick and duplicate findings in the REVIEW BODY,
      # which produces no reviewThreads entry, so a guard reading only threads
      # counts zero and falls through to CLEAN.
      #
      # That is the same shape as this repository's entry 11 and as the
      # outside-diff verdict bug in the sibling script -- a review whose
      # findings are all in the body -- now reappearing one level up, inside the
      # guard written to see the other reviewer at all. The threads check was
      # answering "did the other bot open a conversation", not "did it find
      # something".
      #
      # Only unambiguous statements of findings count, so this cannot block
      # forever on an ordinary clean foreign review: the collapsed-section
      # headings with their own counts, and a nonzero actionable count. A
      # foreign review saying "No actionable comments were generated" matches
      # nothing here and does not withhold the pass.
      fbodies=$(printf '%s\n' "$reviews" | jq -r --arg h "$HEAD" --argjson owned '["copilot-pull-request-reviewer[bot]","Copilot"]' '
        [.[][] | select(.commit_id == $h)
         | select((.user.type // "") == "Bot")
         | (.user.login // "") as $l | select(($owned | index($l)) | not)
         | "\($l)\t\(.body // "")"] | .[]' 2>/dev/null)
      fbody_hits=$(printf '%s\n' "$fbodies" \
        | grep -oE '(Nitpick comments|Outside diff range comments|Duplicate comments|Files skipped from review[^(]*) \([1-9][0-9]*\)|Actionable comments posted: [1-9][0-9]*' || true)
      n_fbody=$(printf '%s\n' "$fbody_hits" | grep -c '[^[:space:]]') || true

      if [ "${n_fbody:-0}" -ge 1 ]; then
        echo
        echo "Copilot is clean on this commit, but another reviewer's review at this same"
        echo "commit reports findings in its BODY, where they create no review thread."
        echo "A clean verdict here means COPILOT found nothing -- not that the pull"
        echo "request is clean."
        echo "------------------------------------------------------------"
        printf '%s\n' "$fbodies" | cut -f1 | sort -u | sed 's/^/reviewer: /'
        printf '%s\n' "$fbody_hits"
        echo "------------------------------------------------------------"
        echo "Open the PR and read that review in full, then disposition each finding."
        echo "RESULT=OTHERBOT"
        exit 0
      fi

      if [ "${n_foreign:-0}" -ge 1 ]; then
        echo
        echo "Copilot is clean on this commit, but $n_foreign unresolved finding(s) on this PR"
        echo "belong to a reviewer this gate does not read. A clean verdict here means"
        echo "COPILOT found nothing -- not that the pull request is clean."
        echo "------------------------------------------------------------"
        printf '%s\n' "$foreign"
        echo "------------------------------------------------------------"
        echo "Open them on the PR and disposition each one: reply, then resolve."
        echo "RESULT=OTHERBOT"
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
