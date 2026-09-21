#!/usr/bin/env bash
# Poll a GitHub PR until the Codex reviewer (chatgpt-codex-connector) responds,
# then classify the outcome. Run in the background; act on RESULT when it exits.
#
# Usage: poll-codex.sh [PR_NUMBER] [--repo OWNER/NAME] [--timeout SECONDS] [--interval SECONDS]
#   PR_NUMBER  optional; defaults to the PR for the current branch
#   --repo     OWNER/NAME; needed when the working dir is not the target git
#              repo (e.g. running this script from the skill dir). Also honors
#              the GH_REPO env var. Without either, the repo is auto-detected
#              from the current directory.
#   --timeout  total seconds to wait (default 900)
#   --interval seconds between polls (default 30)
#
# Output (last line is machine-readable):
#   RESULT=CLEAN                  Codex left a +1 and no inline comments on HEAD → gate met, may merge
#   RESULT=SUGGESTIONS count=N    Codex posted N inline comments on HEAD (listed above) → fix, push, re-run
#   RESULT=TIMEOUT                no response in time (Codex slow or out of quota)
#   RESULT=ERROR ...              draft PR, or could not resolve repo/PR/tools
#
# Only run this once a review round is actually running: the PR is non-draft and
# was just opened, marked ready, or pushed to. Those are the only triggers.
set -u

TIMEOUT=900 INTERVAL=30 PR="" REPO_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)     REPO_ARG="${2:-}";    shift 2 ;;
    --timeout)  TIMEOUT="${2:-900}";  shift 2 ;;
    --interval) INTERVAL="${2:-30}";  shift 2 ;;
    [0-9]*)     PR="$1";              shift ;;
    *)          shift ;;
  esac
done
command -v gh >/dev/null 2>&1 || { echo "RESULT=ERROR gh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "RESULT=ERROR jq not found"; exit 2; }

# When --repo is given, use it verbatim and never call the cwd-dependent
# `gh repo view` (which runs git and fails outside a repo, e.g. the skill dir).
# Otherwise auto-detect from the current directory. Every gh call below is then
# pinned with --repo / a full api path, so the working directory doesn't matter.
if [ -n "$REPO_ARG" ]; then
  REPO="$REPO_ARG"
elif [ -n "${GH_REPO:-}" ]; then
  REPO="$GH_REPO"
else
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
    || { echo "RESULT=ERROR cannot resolve the repo -- run from the target git repo, or pass --repo OWNER/NAME (or set GH_REPO)"; exit 2; }
fi
if [ -z "$PR" ]; then
  # `gh pr view` refuses to run without a selector when --repo is given --
  # measured: "argument required when using the --repo flag". $REPO always has
  # a value by this point, so passing it made this fallback unreachable on
  # every branch, while the error below claimed the branch had no PR. It said
  # that on branches that had one, which is the worse half: someone debugging
  # it checks their branch and their PR, finds both correct, and has no reason
  # to suspect the call.
  #
  # The current branch is evidence about the repository the shell is standing
  # in and about no other. When the repository was named explicitly there is
  # nothing to fall back to, so say that rather than resolving a branch name
  # against a repository it does not belong to.
  if [ -n "$REPO_ARG" ] || [ -n "${GH_REPO:-}" ]; then
    echo "RESULT=ERROR a PR number is required when the repo is named with --repo or GH_REPO -- the current branch is not evidence about another repository"
    exit 2
  fi
  PR=$(gh pr view --json number --jq .number 2>/dev/null) \
    || { echo "RESULT=ERROR no PR for the current branch -- pass a PR number"; exit 2; }
fi
HEAD=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null) \
  || { echo "RESULT=ERROR cannot read PR #$PR in $REPO"; exit 2; }
if [ "$(gh pr view "$PR" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null)" = "true" ]; then
  echo "RESULT=ERROR PR #$PR is a draft -- Codex does not review drafts. Run 'gh pr ready $PR' first (that triggers the review), then poll."
  exit 2
fi
# Reactions carry no commit id, so a previous round's +1 stays on the PR after a
# push. Accept only a +1 newer than the head commit; an empty date compares as
# always-newer, which degrades to the old behavior rather than hanging.
HEAD_DATE=$(gh api "repos/$REPO/commits/$HEAD" --jq .commit.committer.date 2>/dev/null || echo "")

echo "Polling Codex on $REPO PR #$PR (head ${HEAD:0:7}); timeout ${TIMEOUT}s, every ${INTERVAL}s."
deadline=$(( $(date +%s) + TIMEOUT ))

while [ "$(date +%s)" -lt "$deadline" ]; do
  comments=$(gh api --paginate --slurp "repos/$REPO/pulls/$PR/comments?per_page=100" 2>/dev/null || printf '[]')
  inline=$(printf '%s\n' "$comments" \
    | jq --arg h "$HEAD" '[.[][] | select((.user.login | startswith("chatgpt-codex")) and .original_commit_id == $h)] | length' 2>/dev/null || echo 0)
  if [ "${inline:-0}" -ge 1 ]; then
    echo "Codex left inline comments on the current commit:"
    echo "------------------------------------------------------------"
    printf '%s\n' "$comments" \
      | jq -r --arg h "$HEAD" '.[][] | select((.user.login | startswith("chatgpt-codex")) and .original_commit_id == $h) | "── \(.path):\(.line) ──\n\(.body)\n"'
    echo "------------------------------------------------------------"
    echo "RESULT=SUGGESTIONS count=$inline"
    exit 0
  fi
  reactions=$(gh api --paginate --slurp "repos/$REPO/issues/$PR/reactions?per_page=100" 2>/dev/null || printf '[]')
  plus1=$(printf '%s\n' "$reactions" \
    | jq --arg d "$HEAD_DATE" '[.[][] | select(.content == "+1" and (.user.login | startswith("chatgpt-codex")) and .created_at > $d)] | length' 2>/dev/null || echo 0)
  if [ "${plus1:-0}" -ge 1 ]; then
    echo "Codex reacted +1 (clean pass) and left no inline comments on the current commit."
    echo "RESULT=CLEAN"
    exit 0
  fi
  sleep "$INTERVAL"
done

echo "RESULT=TIMEOUT (no Codex response in ${TIMEOUT}s; it may be slow or out of quota)"
exit 0
