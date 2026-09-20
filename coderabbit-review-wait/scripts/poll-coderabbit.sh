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
#   RESULT=MISCOUNT claimed=N counted=M   the reviewer's own count exceeds ours -- the gap is the finding
#   RESULT=UNREPLIED count=N      N resolved threads carry no human reply
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

# ---------------------------------------------------------------------------
# Jev shadow check (opt-in, JEV_SHADOW=1). Classifies every collapsed <details>
# heading in the review body: "does this section list work a maintainer still
# has to look at?" Reports only headings HIDDEN_RE did not already match, which
# is the marginal value being measured.
#
# SHADOW MEANS SHADOW. This never changes a verdict. The transition it is being
# evaluated for, and the only one it may ever be given, is CLEAN -> HOLD. It can
# withhold a pass; it can never grant one. With that rule, a 429, a timeout, a
# missing key and a low-confidence answer are all automatically fail-closed --
# they leave today's verdict exactly as it was.
#
# Three outcomes, kept distinguishable on purpose. "Did not run" and "ran and
# had nothing to say" look identical if you let them, and four of the nine
# entries in the fail-open ledger are an absence that was read as good news.
#
# Model pinned to jev-1.13.0 by jev.sh; the criteria below are the v3 wording
# measured at 29/30 on a 30-item gold set, 8/8 recall on hidden work, 0/30 flip
# rate over three repeats. Changing one word changes the classifier, which is
# why each call logs a qset_hash and why the variant is named here rather than
# left to be inferred from the text.
jev_shadow() {
  [ "${JEV_SHADOW:-0}" = "1" ] || return 0
  local body="$1" jev headings n out
  # Repo-local, never a path under someone'"'"'s home. This file lives in a public
  # repository: a hardcoded ~/side-project/... works on exactly one machine, and
  # the thing it points at is not version controlled, so it can change or vanish
  # without a diff. Resolved from this script'"'"'s own location so a clone works.
  local here; here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  jev="${JEV_BIN:-$here/scripts/jev.sh}"
  local qfile="${JEV_QUESTIONS:-$here/coderabbit-review-wait/jev-questions-v3.json}"
  [ -r "$qfile" ] || { echo "(jev: unavailable -- questions file $qfile not readable)"; return 0; }
  [ -x "$jev" ] || { echo "(jev: unavailable -- $jev not executable)"; return 0; }

  headings=$(printf '%s\n' "$body" \
    | grep -oE '<summary>.*</summary>' \
    | sed -E 's#</?summary>##g; s/<[^>]*>//g' \
    | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' \
    | grep -vE '^$')
  # NO `sort -u` HERE. It was, and it collapsed two distinct <details> sections
  # that happen to share a <summary> into one entry -- so only the first was
  # sent to the classifier, $n undercounted the sections, and the run then
  # printed "checked N of N heading(s)" over a section it never looked at.
  # Deduplicating the input to a COUNTING gate turns a duplicate into an
  # absence, which is this repository's one recurring bug wearing a new hat.
  # Found by Copilot on lorenzini#2, in the poller for the other reviewer.
  # Document order is kept too: the flagged list now reads in the order a
  # person scrolling the review body would meet the sections.
  [ -n "$headings" ] || { echo "(jev: nothing to check -- no collapsed sections in this body)"; return 0; }
  n=$(printf '%s\n' "$headings" | wc -l | tr -d ' ')

  # The question and criteria come from a VERSIONED FILE, not from a heredoc
  # here. The criteria text is the classifier -- v1 missed "Nitpick comments" at
  # 0.37 purely because the word "nitpick" did not appear, and one added
  # sentence took it to 0.70. Kept inline it would be a second home for the same
  # contract, drifting from the copy the gold set was measured against; kept in
  # a file it can be diffed, versioned, and re-measured by tests/run-gold-set.py.
  #
  # The request is built once so its qset_hash can be computed the same way
  # jev.sh does. jev.sh logs that hash to its own file but returns only
  # .answers, so a shadow row written from the answers alone could not say which
  # criteria produced it, and rows from two variants would be indistinguishable
  # in one file.
  local req qhash
  req=$(printf '%s\n' "$headings" | jq -R . | jq -sc --slurpfile spec "$qfile" '
      $spec[0] as $s |
      {state: {source: "GitHub pull request review body, collapsed section headings"},
       questions: (to_entries | map({key: ("h\(.key)"), value: {type: "noul",
         instructions: {question: $s.question, label: .value},
         criteria: $s.criteria}}) | from_entries)}') \
    || { echo "(jev: unavailable -- could not build the request from $qfile)"; return 0; }
  qhash=$(printf '%s' "$req" | jq -cS '.questions' | shasum -a 256 | cut -c1-16)
  out=$(printf '%s' "$req" | JEV_TIMEOUT="${JEV_TIMEOUT:-8}" "$jev" - 2>/dev/null) \
    || { echo "(jev: unavailable -- call failed; verdict unchanged)"; return 0; }

  # Only headings HIDDEN_RE did NOT already catch: the question is what a
  # classifier adds over the patterns, not whether it agrees with them.
  local shadow_log="${JEV_SHADOW_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/lorenzini/shadow-holds.jsonl}"
  mkdir -p "$(dirname "$shadow_log")" 2>/dev/null || true
  # A heading with no answer is NOT a heading that came back negative. The
  # first version skipped missing values silently, so a partial or malformed
  # response produced an empty flag list and the run reported "nothing the
  # patterns missed" -- a clean-looking measurement over nothing measured.
  # Found by CodeRabbit on lorenzini#2. It is the same shape as four entries in
  # the ledger, sitting inside the code written to address that shape.
  local flagged="" missing=0 i=0 lbl val
  while IFS= read -r lbl; do
    val=$(printf '%s\n' "$out" | jq -r --arg k "h$i" '.[$k].noul // empty' 2>/dev/null)
    i=$((i+1))
    if [ -z "$val" ] || ! awk -v v="$val" 'BEGIN{exit !(v == v + 0)}' 2>/dev/null; then
      missing=$(( missing + 1 )); continue
    fi
    awk -v v="$val" 'BEGIN{exit !(v >= 0.5)}' || continue
    printf '%s\n' "$lbl" | grep -qE "$HIDDEN_RE" && continue
    flagged="${flagged}    ${val}  ${lbl}
"
  done <<EOF
$headings
EOF

  # Report the gap before anything else. "Ran and found nothing" must not be
  # printed over headings that were never answered.
  if [ "$missing" -ge 1 ]; then
    if [ "$missing" -ge "$n" ]; then
      echo "(jev: unavailable -- the response carried no usable answers for any of $n heading(s))"
      return 0
    fi
    echo "(jev: INCOMPLETE -- $missing of $n heading(s) came back without a usable score."
    echo " The result below covers only the $(( n - missing )) that did. Do not read it as a full check.)"
  fi

  if [ -n "$flagged" ]; then
    echo "(jev: would HOLD -- $n heading(s) checked, these are unrecognised by the patterns)"
    printf '%s' "$flagged"
    echo "(jev: SHADOW MODE -- verdict unchanged. Given veto power this would be RESULT=HOLD.)"
    # Every would-HOLD is a candidate gold-set row: a label the patterns did not
    # know and the classifier thinks is work. Whether it was right is decided
    # later by a person reading the PR, so the label is recorded verbatim with
    # the score and where it came from. This file is the only way the two-week
    # shadow period produces anything; without it the run is just noise on a
    # terminal that nobody re-reads.
    #
    # THE APPEND IS CHECKED. scripts/jev.sh states the rule -- a failed append
    # must be loud, because a caller that reports "recorded" over a write that
    # did not happen is the same absence-read-as-success this repository exists
    # to stop -- and this call site, the other home of that same contract, did
    # not honour it. An unwritable or missing parent directory lost the only
    # persistent record of a would-HOLD while the terminal still printed the
    # candidate, so a two-week shadow period could end with an empty log and no
    # sign anything was wrong. Found by Copilot on lorenzini#2.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s' "$line" | awk -v repo="$REPO" -v pr="$PR" -v head="$HEAD" '
        { v=$1; $1=""; sub(/^[ \t]+/,""); printf "%s\t%s\t%s\t%s\t%s\n", repo, pr, head, v, $0 }' \
      | while IFS=$'\t' read -r rp pn hd nv lb; do
          jq -cn --arg ts "$(date -u +%FT%TZ)" --arg repo "$rp" --arg pr "$pn" --arg head "$hd" \
                 --arg qh "$qhash" \
                 --arg noul "$nv" --arg label "$lb" --arg model "${JEV_MODEL:-jev-1.13.0}" \
            '{ts:$ts, repo:$repo, pr:($pr|tonumber), head:$head, model:$model,
               qset_hash:$qh,
               noul:($noul|tonumber), label:$label, verdict_without_jev:"CLEAN", adjudicated:null}' \
            >> "$shadow_log" \
            || echo "(jev: could not append to $shadow_log -- this would-HOLD is NOT recorded)"
        done
    done <<SHADOWEOF
$flagged
SHADOWEOF
  else
    echo "(jev: checked $(( n - missing )) of $n heading(s), nothing the patterns missed)"
  fi
}

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
  # Do not require a fixed number of pipes. CodeRabbit omits a zero-count field
  # entirely: Syrtis-Windows#115 rendered an all-pass tally as
  # "Pre-merge checks | OK 5" with no failure field at all. The symmetric case,
  # everything failing, renders as a single-segment "Pre-merge checks | FAIL N"
  # -- which a two-pipe pattern does not match, so total failure read as no
  # failures. A repository with one check configured reaches that shape the
  # first time the check fails.
  premerge=$(printf '%s\n' "$bodies" | grep -oE 'Pre-merge checks[^<]*' | tail -1)
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
  # A FAILED READ IS NOT AN EMPTY COMMENT LIST. The `|| printf '[]'` that used
  # to be here turned a rate limit, a 5xx or a dropped page into an
  # authoritative "no comments", and everything below -- the head-keyed
  # verdict, the skip notice, the pause notice -- then read as absent. The
  # terminal states are exactly what an unreadable endpoint erases, so the
  # failure mode is a TIMEOUT reported over a PR that was skipped or paused.
  # Same shape as the review-comments read above and as nine entries in
  # docs/fail-open-ledger.md: retry, never count zero.
  if ! icomments=$(gh api --paginate --slurp "repos/$REPO/issues/$PR/comments?per_page=100" 2>/dev/null) \
     || ! printf '%s\n' "$icomments" | jq -e 'type == "array"' >/dev/null 2>&1; then
    [ "${inote_warned:-0}" = "1" ] || { echo "Could not read the issue-comments endpoint. Retrying rather than reading it as no comments."; inote_warned=1; }
    clean_seen=0; sleep "$INTERVAL"; continue
  fi
  note=$(printf '%s\n' "$icomments" | jq -r --arg h "$HEAD" --arg b "$BOT" \
    '[.[][] | select(.user.login == $b and (.body | contains($h)))] | last | .body // ""' 2>/dev/null)
  # A SKIP NOTICE CARRIES NO HEAD SHA, so it must not be looked for in $note.
  # Measured on Syrtis-Agent#4, 2026-09-20: CodeRabbit posted "Review skipped --
  # auto reviews are disabled on this repository" and that comment contains no
  # commit id at all, because a skip is about the configuration rather than
  # about a commit. Keying it to the head sha meant the branch never fired and
  # the poll fell through to TIMEOUT on five pull requests at once.
  #
  # TIMEOUT and SKIPPED are not interchangeable. TIMEOUT says the verdict may
  # still arrive; SKIPPED says it never will. Reported as the same thing, the
  # operator waits for something that is not coming.
  #
  # The LAST bot comment is the authority, not any comment: a skip notice from
  # an earlier state (a draft since marked ready) must not block forever, and
  # CodeRabbit posts a fresh comment whenever it acts.
  last_note=$(printf '%s\n' "$icomments" | jq -r --arg b "$BOT" \
    '[.[][] | select(.user.login == $b)] | last | .body // ""' 2>/dev/null)
  # PAUSED is a third member of the family that SKIPPED already belongs to, and
  # it was found the same way: a poll sat for twenty minutes on lorenzini#1 and
  # reported TIMEOUT while the most recent bot comment read "Reviews paused".
  # auto_pause_after_reviewed_commits defaults to 5, that pull request had seven
  # commits and six reviews, and nothing was ever going to arrive.
  #
  # TIMEOUT says the verdict may still come. PAUSED says it will not until
  # someone asks. Reported as the same thing, the operator waits for nothing --
  # which is what happened here, for the full twenty minutes.
  case "$last_note" in
    *"Reviews paused"*)
      echo "CodeRabbit has PAUSED automatic reviews on this PR (its most recent comment says so)."
      echo "auto_pause_after_reviewed_commits defaults to 5; this is not a slow review and"
      echo "waiting will not produce one. Resume with '@coderabbitai resume', ask for a single"
      echo "round with '@coderabbitai review', or re-run this with --request."
      echo "RESULT=ERROR reviews paused -- nothing will arrive until one is requested"
      exit 2 ;;
  esac
  case "$last_note" in
    *"Review skipped"*)
      echo "CodeRabbit skipped this PR (its most recent comment is a skip notice):"
      printf '%s\n' "$last_note" | sed 's/<[^>]*>//g' | sed -n '/Review skipped/,/^$/p' | head -8
      echo "RESULT=ERROR review skipped -- not a slow review. Check reviews.auto_review.enabled and the base branch."
      exit 2 ;;
  esac
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
    # A FAILED read is not an empty result. `|| printf '[]'` used to conflate
    # them, so one endpoint erroring while the others succeeded produced
    # inline=0 and a CLEAN verdict over real findings. Verified on coralline#85
    # and TokenBar#349: with only this call failing, the scripts reported CLEAN
    # on pull requests carrying 3 and 1 findings respectively. The twice-over
    # confirmation below does not help -- a rate limit or 5xx persists across
    # rounds, so both rounds fail and both read as clean.
    #
    # `--paginate` makes this a multi-request call, so a second page failing on
    # a PR with more than 100 comments is ordinary, not exotic. Validate that
    # the payload actually parses too: a partial page with '[]' appended is
    # invalid JSON, which jq then turns back into 0 through its own `|| echo 0`.
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
    [ "${n_silent:-0}" -ge 1 ] && echo "($n_silent resolved thread(s) have no human reply.)"
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

      # CROSS-CHECK THE REVIEWER'S OWN NUMBER AGAINST OURS.
      #
      # This was claimed as fixed in the fail-open ledger and in SKILL.md, and
      # was never in the code. The claim outlived its truth for two days in a
      # public repository. It is the whole reason the Copilot login bug could
      # have recurred silently: anything that makes our count too low -- a
      # renamed login, an over-eager in_reply_to filter, a commit-keying
      # mismatch, a failed read -- is invisible unless something independent
      # disagrees with it.
      #
      # It is also the only signal here that tracks the vendor. Every regex in
      # this file encodes how CodeRabbit rendered its output on one day; if the
      # format shifts, they all silently stop matching and the gate degrades
      # into a machine that always says CLEAN. The reviewer's own count is the
      # one thing that moves when the vendor moves, so a disagreement surfaces
      # the drift instead of hiding it.
      #
      # N counts the findings that round. Ours are the unresolved ones at head
      # (inline) plus the dispositioned ones at head (n_done). N larger than
      # that sum means we did not see something it posted.
      # Literal measured on pilotfish#85: "**Actionable comments posted: 1**",
      # colon and number both inside the emphasis. Matched here with the same
      # tolerance as the Copilot script anyway, because the difference between
      # the two vendors' spellings is exactly the kind of detail that is true
      # until it is not.
      claimed=$(printf '%s\n' "$bodies" | grep -oE 'Actionable comments posted:[*[:space:]]*[0-9]+' | grep -oE '[0-9]+' | sort -rn | head -1)
      if [ -n "${claimed:-}" ] && [ "${claimed:-0}" -gt $(( ${inline:-0} + ${n_done:-0} )) ]; then
        echo
        echo "CodeRabbit reports $claimed actionable comment(s) for this commit, but only"
        echo "$(( ${inline:-0} + ${n_done:-0} )) were found on it ($inline open, $n_done dispositioned)."
        echo "Something it posted is not being counted. Do not read this as clean:"
        echo "the gap is the finding."
        echo "RESULT=MISCOUNT claimed=$claimed counted=$(( ${inline:-0} + ${n_done:-0} ))"
        exit 0
      fi

      # A thread closed by "@coderabbitai resolve" with nobody saying anything
      # is an absence, and this gate never infers a pass from absence. The
      # earlier fix moved these out of the EXCUSED set but never put them into a
      # BLOCKING one, so the notice printed and the run passed anyway. Verified
      # on TokenBar#349: it withheld CLEAN only because a pre-merge check
      # happened to fail as well; with that varied away, a silently-resolved
      # finding passed.
      if [ "${n_silent:-0}" -ge 1 ]; then
        echo
        echo "$n_silent resolved thread(s) carry no human reply, so nothing records a"
        echo "decision about them. Reply to each with its disposition, then resolve."
        echo "RESULT=UNREPLIED count=$n_silent"
        exit 0
      fi

      jev_shadow "$bodies"
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
