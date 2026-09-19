#!/usr/bin/env bash
# Poll a GitHub PR until CodeRabbit (coderabbitai[bot]) reviews the current head
# commit, then classify the outcome. Run in the background; act on RESULT.
#
# Usage: poll-coderabbit.sh [PR_NUMBER] [--repo OWNER/NAME] [--timeout SECONDS] [--interval SECONDS] [--request]
#   --request  post "@coderabbitai review" to trigger an incremental review.
#              Unlike Copilot, a comment IS the documented re-trigger for
#              CodeRabbit. Not needed after a push: CodeRabbit updates its
#              review automatically on every new commit.
#
# Output (last line is machine-readable):
#   RESULT=CLEAN                  APPROVED at head, no inline comments, no hidden-findings section
#   RESULT=NITPICKS count=N       otherwise clean, but N findings -- or N files skipped from
#                                 review -- sit in a collapsed body section
#   RESULT=PREMERGE count=N       otherwise clean, but N pre-merge checks failed
#   RESULT=SUGGESTIONS count=N    inline comments on head, or CHANGES_REQUESTED
#   RESULT=TIMEOUT                no review of head in time
#   RESULT=ERROR ...              draft PR, or could not resolve repo/PR/tools
#
# Measured on public PRs 2026-09-19 (ubiquity/ai.ubq.fi#338, pysnmp/pysmi#328,
# narnaud/git-loom#274):
#   * The review AND its inline comments share one login, coderabbitai[bot].
#     This is NOT the Copilot shape, where the review and the comments are
#     authored by two different logins. Do not copy that filter over.
#   * An APPROVED review carries an EMPTY body (body_len=0). So a pass cannot be
#     recognised from body text; read .state.
#   * A COMMENTED review's body opens with "**Actionable comments posted: N**".
#   * Drafts are skipped: CodeRabbit posts a "Draft PR not reviewed" comment
#     instead of reviewing.
# Measured against the captured corpus (jev-research/data/cr-bodies.jsonl,
# 2026-09-19): "Files skipped from review ... (N)" on Syrtis-Windows#115,
# "Nitpick comments (N)" on Syrtis-Windows#113, "Outside diff range comments
# (N)" on TokenBar#349, coralline#87 and NyanCogs#18/#22/#23. Only the
# "Duplicate comments (N)" spelling still comes from CodeRabbit's documented
# format with no captured sample. Every branch fails safe -- it can only
# withhold a CLEAN, never grant one.
set -u

# ---------------------------------------------------------------------------
# Classification helpers. Defined before the source guard below, so a harness
# replaying a captured payload can `source` this file and drive the SAME code
# the live poll runs instead of a copy that drifts out of step with it.
# ---------------------------------------------------------------------------

# The collapsed body sections whose findings CodeRabbit's own "Actionable
# comments posted: N" count ignores. ONE definition, read by every site that
# has to know the list -- the SUGGESTIONS "also reported" line, the CLEAN gate,
# and the excerpt printer. It used to be spelled out at two of those sites and
# they disagreed, which is exactly the "a contract stated in N places" failure.
#
# "Files skipped from review as they are similar to previous changes (N)" is a
# COVERAGE hole, not a nitpick bucket: it is CodeRabbit's equivalent of
# Copilot's "Files reviewed: 4/5". Nanako0129/Syrtis-Windows#115 carried one and
# was reported CLEAN (payload: jev-research/data/cr-bodies.jsonl). A file that
# was never read cannot have produced findings, so a zero count over it says
# nothing. It withholds CLEAN like the other buckets.
HIDDEN_RE='(Nitpick comments|Outside diff range comments|Duplicate comments|Files skipped from review[^(]*) \(([0-9]+)\)'

# A resolved thread counts as DISPOSITIONED only when a HUMAN has commented in
# it. SKILL.md:139 states the reply-before-resolve rule as the premise that
# makes "resolved = handled" safe, but nothing enforced it: "@coderabbitai
# resolve" closes every thread at once with no reply anywhere, and each
# silently-closed finding then dropped out of the count.
#
# "Human" keys on the GraphQL actor TYPE, never on the login spelling. Measured
# 2026-09-19 on Nanako0129/TokenBar#349 with the query below:
#
#   {"login":"coderabbitai","__typename":"Bot"}
#   {"login":"copilot-pull-request-reviewer","__typename":"Bot"}
#   {"login":"Nanako0129","__typename":"User"}
#
# GraphQL returns the bot login WITHOUT the "[bot]" suffix that REST's
# .user.login carries (BOT= above, which reads the REST endpoint). A first
# version of this tested `endswith("[bot]")` on author.login and therefore
# classified every bot as a human: a bot-only resolved thread was excused, the
# notice printed 0, and the hole this exists to close stayed open while looking
# closed. That is the same fail-open shape as the Copilot login filter.
#
# An author that is absent, null, or any actor type other than User is NOT
# human, so an unreadable thread is counted rather than excused.
HUMAN_JQ='def human: (.author.__typename // "") == "User";'
DISPOSITIONED_JQ="$HUMAN_JQ"'
  [.data.repository.pullRequest.reviewThreads.nodes[]?
  | select(.isResolved)
  | select([.comments.nodes[]? | human] | any)
  | .comments.nodes[]?.databaseId] | @json'
# Resolved threads with no human comment: still counted as open findings, and
# reported so the silent resolve is visible rather than inferred from absence.
UNREPLIED_JQ="$HUMAN_JQ"'
  [.data.repository.pullRequest.reviewThreads.nodes[]?
  | select(.isResolved)
  | select([.comments.nodes[]? | human] | any | not)] | length'

# GraphQL reviewThreads payload on stdin -> databaseIds of dispositioned comments
dispositioned_ids() { jq -r "$DISPOSITIONED_JQ" 2>/dev/null; }
# GraphQL reviewThreads payload on stdin -> count of resolved-without-human-reply threads
unreplied_resolved() { jq -r "$UNREPLIED_JQ" 2>/dev/null; }

# Review/comment bodies in $1 -> prints the reported outcome line, then any
# bucket that withholds CLEAN (with its RESULT= line). Returns 0 when it
# decided the verdict, 1 when nothing here blocks CLEAN.
classify_bodies() {
  local bodies="$1" hidden n premerge failed verdict=""
  printf '%s\n' "$bodies" | grep -oE 'Actionable comments posted: [0-9]+|No actionable comments were generated' | tail -1
  # No head -N: a body with more counted sections than the cap would silently
  # drop the overflow from the total. awk sums every line it is given.
  hidden=$(printf '%s\n' "$bodies" | grep -oE "$HIDDEN_RE")
  if [ -n "$hidden" ]; then
    n=$(printf '%s\n' "$hidden" | grep -oE '\(([0-9]+)\)$' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
    echo
    echo "Findings or skipped files are parked in collapsed body sections. They"
    echo "are NOT inline comments and do not move the count. Disposition them"
    echo "before merging."
    echo "------------------------------------------------------------"
    printf '%s\n' "$hidden"
    echo
    printf '%s\n' "$bodies" | sed -n -E "/$HIDDEN_RE/,/<\/details>/p" | head -80
    echo "------------------------------------------------------------"
    verdict="NITPICKS count=${n:-unknown}"
  fi
  # Pre-merge checks are CodeRabbit's SECOND bucket that its own finding
  # count ignores, and the fourth such bucket across three reviewers. Found
  # on TokenBar#330: completion marker present, inline findings 0, no
  # collapsed findings section -- and "Pre-merge checks | OK 4 | FAIL 1"
  # sitting in the same comment with a failed Docstring Coverage check.
  # A failed check is a disposition for a human, not an automatic block
  # (on #330 the right call was Defer: the coverage denominator is every
  # function the diff TOUCHED, so a contributor's 5-line change inherited
  # three pre-existing undocumented functions). So: withhold CLEAN, print
  # the failures, let the caller triage.
  # Key on the TALLY, never on the rows. Measured on TokenBar#350: the
  # failed row's Status cell reads "Warning", and the section heading counts
  # them as "(1 warning)" -- the failure marker appears only in the tally
  # and the heading. A parser that looks for it inside the row finds nothing
  # and reports a pass. CodeRabbit counts a warning as failed; so do we.
  premerge=$(printf '%s\n' "$bodies" | grep -oE 'Pre-merge checks[^|]*\|[^|]*\|[^<]*' | tail -1)
  failed=$(printf '%s\n' "$premerge" | grep -oE '❌[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | tail -1)
  if [ -n "$premerge" ] && [ "${failed:-0}" -ge 1 ] 2>/dev/null; then
    echo
    echo "Pre-merge checks failed. These are not findings and never touch the"
    echo "finding count, but they are a verdict CodeRabbit reported:"
    echo "------------------------------------------------------------"
    printf '%s\n' "$premerge"
    # Stop at "Passed checks", not at a blank line: the heading is followed
    # by one, so a blank-line range prints the heading and nothing else.
    printf '%s\n' "$bodies" | sed -n '/Failed checks/,/Passed checks/p' \
      | grep -vE '^\s*$|Passed checks|^\| *:-*' | head -12
    echo "------------------------------------------------------------"
    # Both buckets can be present in one body (sepia#258, NyanCogs#20 and #23
    # carry a failed pre-merge check AND a skipped-files section). Print both --
    # the caller has to disposition both -- and let the findings bucket name the
    # RESULT, which is the precedence the previous version already had.
    [ -n "$verdict" ] || verdict="PREMERGE count=$failed"
  fi
  [ -n "$verdict" ] || return 1
  echo "RESULT=$verdict"
}

# Sourced for offline replay: stop here with the helpers defined.
(return 0 2>/dev/null) && return 0

TIMEOUT=900 INTERVAL=20 PR="" REPO_ARG="" REQUEST=0
BOT="coderabbitai[bot]"
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
  || { echo "RESULT=ERROR no PR for the current branch"; exit 2; }
HEAD=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null) \
  || { echo "RESULT=ERROR cannot read PR #$PR in $REPO"; exit 2; }
if [ "$(gh pr view "$PR" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null)" = "true" ]; then
  echo "RESULT=ERROR PR #$PR is a draft -- CodeRabbit skips drafts (it posts a 'Draft PR not reviewed' comment). Run 'gh pr ready $PR', or set reviews.auto_review.drafts: true."
  exit 2
fi

if [ "$REQUEST" = "1" ]; then
  gh pr comment "$PR" --repo "$REPO" --body "@coderabbitai review" >/dev/null 2>&1 \
    || { echo "RESULT=ERROR could not post the @coderabbitai review comment"; exit 2; }
  echo "Posted '@coderabbitai review' on $REPO PR #$PR."
fi

echo "Polling CodeRabbit on $REPO PR #$PR (head ${HEAD:0:7}); timeout ${TIMEOUT}s, every ${INTERVAL}s."
deadline=$(( $(date +%s) + TIMEOUT ))
# A review and its inline comments are read back through two endpoints. Confirm
# a zero-comment pass twice, one interval apart, so a read landing between the
# two writes cannot be reported CLEAN.
clean_seen=0
announced=0

while [ "$(date +%s)" -lt "$deadline" ]; do
  # --paginate is not optional: the reviews endpoint caps at 30 per page and a
  # long-running PR pushes the newest review out of the first page. Note that
  # --paginate --slurp cannot be combined with gh's own --jq; pipe into jq.
  reviews=$(gh api --paginate --slurp "repos/$REPO/pulls/$PR/reviews?per_page=100" 2>/dev/null || printf '[]')
  athead=$(printf '%s\n' "$reviews" \
    | jq --arg h "$HEAD" --arg b "$BOT" '[.[][] | select(.user.login == $b and .commit_id == $h)]' 2>/dev/null || printf '[]')
  n_at_head=$(printf '%s\n' "$athead" | jq 'length' 2>/dev/null || echo 0)
  # A review object at head is NOT by itself a verdict. When a human replies in a
  # review thread, CodeRabbit answers each reply with its own review object:
  # state COMMENTED, body length 0, no verdict text, keyed to the head commit.
  # Measured on Nanako0129/pilotfish#85 at head 93eee6b (reported by the
  # pilotfish-71 session, reproduced here):
  #
  #   id=5254044474 state=COMMENTED len=0     01:46:53   <- answer to a reply
  #   id=5254045301 state=COMMENTED len=0     01:47:08   <- answer to a reply
  #   id=5254055908 state=COMMENTED len=1947  01:50:30   <- the real review
  #
  # The real one arrived three and a half minutes later carrying "Actionable
  # comments posted: 1" and a genuine unresolved finding. Treating the empty ones
  # as completion converged early and reported a pass over it -- the fifth
  # fail-open in this family, and again from reading structural presence as
  # semantic completion.
  #
  # So a review counts as a verdict only when it SAYS something: an APPROVED
  # state (whose body is legitimately empty under request_changes_workflow), or a
  # body carrying one of the two verdict phrases. Everything else keeps polling.
  # Corroborating signal, not relied on here: those answer-reviews carry only
  # comments with in_reply_to_id set, so a review whose comments are all replies
  # is not a review round either.
  verdict_reviews=$(printf '%s\n' "$athead" | jq '[.[] | select(
      .state == "APPROVED"
      or ((.body // "") | test("Actionable comments posted:|No actionable comments were generated"))
    )] | length' 2>/dev/null || echo 0)

  # A clean outcome can arrive with NO review object at all. Measured on
  # Nanako0129/Syrtis-Windows#112: the CodeRabbit status check went SUCCESS, the
  # PR carried zero reviews, and the verdict -- "No actionable comments were
  # generated in the recent review." -- was posted as an ISSUE COMMENT. Requiring
  # a review would poll that PR to TIMEOUT and report "no review" for a PR
  # CodeRabbit had finished and passed, i.e. the skill would be useless on
  # exactly the common case.
  #
  # The verdict comment names the range it reviewed ("...between <base> and
  # <head>"), so the full head sha appearing in the body keys it to this commit
  # as precisely as commit_id keys a review.
  icomments=$(gh api --paginate --slurp "repos/$REPO/issues/$PR/comments?per_page=100" 2>/dev/null || printf '[]')
  note=$(printf '%s\n' "$icomments" | jq -r --arg h "$HEAD" --arg b "$BOT" \
    '[.[][] | select(.user.login == $b and (.body | contains($h)))] | last | .body // ""' 2>/dev/null)
  case "$note" in
    *"Review skipped"*)
      echo "CodeRabbit skipped this PR:"
      printf '%s\n' "$note" | sed -n '/Review skipped/,/^$/p' | head -12
      echo "RESULT=ERROR review skipped (see the notice above; trigger one with '@coderabbitai review')"
      exit 2 ;;
  esac

  # NEVER infer a pass from absence. An earlier version treated "a comment
  # naming the head sha, and no inline findings" as clean, and reported CLEAN on
  # TokenBar#349 while CodeRabbit was still running: the in-progress notice also
  # names the head sha, also carries a "Run configuration" block, and of course
  # has no findings yet, so it was indistinguishable from a finished clean pass.
  # That is a gate failing OPEN -- the same class as the Copilot switchover,
  # where a wrong login filter matched nothing and passed a PR with 3 findings.
  #
  # So a verdict requires an explicit POSITIVE completion marker: a review
  # object at head, or a comment that states an outcome. "Currently processing"
  # overrides everything -- CodeRabbit edits that one comment in place as the
  # run proceeds, so its presence means a run is underway now.
  complete=0
  [ "${verdict_reviews:-0}" -ge 1 ] && complete=1
  case "$note" in
    *"No actionable comments were generated"*|*"Actionable comments posted"*) complete=1 ;;
  esac
  case "$note" in
    *"Currently processing"*)
      complete=0
      [ "${announced:-0}" = "1" ] || { echo "CodeRabbit is still processing this commit; waiting."; announced=1; } ;;
  esac

  if [ "$complete" = "1" ]; then
    comments=$(gh api --paginate --slurp "repos/$REPO/pulls/$PR/comments?per_page=100" 2>/dev/null || printf '[]')
    # in_reply_to_id filters out CodeRabbit's own thread replies, which live in
    # the same endpoint and are not findings. Measured on pysnmp/pysmi#328:
    # two coderabbitai[bot] comments on one line, one finding (in_reply_to null)
    # and one auto-reply pointing at it. Counting both reports 2 findings for 1,
    # and every round's replies inflate the next round's count, so an auto loop
    # would never converge.
    sel='.[][] | select(.user.login == $b and .original_commit_id == $h and .in_reply_to_id == null)'
    # A finding whose review thread has been RESOLVED *and replied to* was
    # dispositioned, not ignored. Resolving does not delete the inline comment,
    # so counting such findings leaves a PR permanently short of CLEAN and an
    # auto loop re-reporting the same verdict forever. Measured on NyanCogs#21:
    # one finding, rejected with reasoning and resolved, still returned
    # SUGGESTIONS count=1 on every subsequent poll.
    # The reply is what makes it a disposition (see DISPOSITIONED_JQ): a thread
    # closed by "@coderabbitai resolve" with nobody saying anything is an
    # absence, and this gate never infers a pass from absence. Measured on
    # NyanCogs#20 and #23: resolved threads, zero replies.
    threads=$(gh api graphql -f query="query{repository(owner:\"${REPO%%/*}\",name:\"${REPO##*/}\"){pullRequest(number:$PR){reviewThreads(first:100){nodes{isResolved comments(first:50){nodes{databaseId author{login __typename}}}}}}}}" 2>/dev/null || printf '{}')
    resolved_ids=$(printf '%s\n' "$threads" | dispositioned_ids || printf '[]')
    [ -n "$resolved_ids" ] || resolved_ids='[]'
    n_silent=$(printf '%s\n' "$threads" | unreplied_resolved || echo 0)
    # "not excused", not "counted": whether such a finding lands in THIS round's
    # count still depends on the head-commit keying above. Measured on
    # NyanCogs#23: two silently-resolved threads, both reported here, and
    # inline=0 that round because their comments sit on an earlier commit.
    # Saying "counted" there would state something the run did not do.
    [ "${n_silent:-0}" -ge 1 ] && echo "($n_silent resolved thread(s) have no human reply; not excused.)"
    open_sel="$sel | select([.id] | inside(\$done) | not)"
    inline=$(printf '%s\n' "$comments" \
      | jq --argjson done "$resolved_ids" --arg h "$HEAD" --arg b "$BOT" "[$open_sel] | length" 2>/dev/null || echo 0)
    n_done=$(printf '%s\n' "$comments" \
      | jq --argjson done "$resolved_ids" --arg h "$HEAD" --arg b "$BOT" "[$sel | select([.id] | inside(\$done))] | length" 2>/dev/null || echo 0)
    [ "${n_done:-0}" -ge 1 ] && echo "($n_done finding(s) on this commit already replied to and resolved; not counted.)"
    changes=$(printf '%s\n' "$athead" | jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length' 2>/dev/null || echo 0)

    if [ "${inline:-0}" -ge 1 ] || [ "${changes:-0}" -ge 1 ]; then
      echo "CodeRabbit has findings on the current commit:"
      echo "------------------------------------------------------------"
      # Print exactly what the count refers to: the unresolved set.
      printf '%s\n' "$comments" | jq -r --argjson done "$resolved_ids" --arg h "$HEAD" --arg b "$BOT" \
        "$open_sel | \"── \(.path):\(.line // .original_line // \"@pos\(.position)\") ──\n\(.body)\n\"" 2>/dev/null
      echo "------------------------------------------------------------"
      [ "${changes:-0}" -ge 1 ] && echo "(CodeRabbit submitted CHANGES_REQUESTED on this commit.)"
      # Surface the other buckets here too, so one round shows everything the
      # caller has to disposition instead of revealing them a round at a time.
      printf '%s\n%s\n' "$(printf '%s\n' "$athead" | jq -r '.[] | .body // ""' 2>/dev/null)" "$note" \
        | grep -oE "$HIDDEN_RE"'|Pre-merge checks[^<]*❌[^<]*' \
        | sed 's/^/(also reported: /; s/$/)/'
      echo "RESULT=SUGGESTIONS count=$inline"
      exit 0
    fi

    clean_seen=$(( clean_seen + 1 ))
    if [ "$clean_seen" -ge 2 ]; then
      # An APPROVED review has an empty body, so the summary lives in whichever
      # COMMENTED review is present. Collapsed sections there hold findings that
      # never became inline comments -- the same trap that let a Copilot CLEAN
      # ship 8 real defects across four rounds on sepia#250. Never report CLEAN
      # while one is present.
      # Scan the issue-comment verdict too, not just review bodies: when the
      # verdict arrives as a comment there are no review bodies to scan, and a
      # collapsed nitpick section would go unseen.
      bodies=$(printf '%s\n%s\n' "$(printf '%s\n' "$athead" | jq -r '.[] | .body // ""' 2>/dev/null)" "$note")
      if [ "${n_at_head:-0}" -ge 1 ]; then
        state=$(printf '%s\n' "$athead" | jq -r 'last | .state' 2>/dev/null)
        echo "CodeRabbit reviewed the current commit (last state: ${state:-unknown}) with no inline findings."
      else
        echo "CodeRabbit reported on the current commit by issue comment (no review object) with no inline findings."
      fi
      classify_bodies "$bodies" && exit 0
      echo "RESULT=CLEAN"
      exit 0
    fi
  else
    # A run that restarts (a new push mid-poll) must not inherit the previous
    # round's confirmations.
    clean_seen=0
  fi
  sleep "$INTERVAL"
done

echo "RESULT=TIMEOUT (no CodeRabbit review of ${HEAD:0:7} in ${TIMEOUT}s)"
exit 0
