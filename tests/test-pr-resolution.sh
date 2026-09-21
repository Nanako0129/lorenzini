#!/bin/bash
# Does omitting the PR number actually resolve the current branch's PR?
#
# All three SKILL.md files promise it does: "Optionally takes a PR number;
# otherwise it uses the current branch's PR and auto-detects the repo." It did
# not. `gh pr view` refuses to run without a selector when --repo is given, and
# the pollers always passed --repo, so the fallback could never succeed on any
# branch however correct the setup. It printed "no PR for the current branch"
# on branches that had one.
#
# This runs the shipping scripts against a stub `gh` rather than testing an
# extracted copy of the logic. The defect was in how the command line was
# built, so a test that does not build a command line cannot see it.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT

# The stub encodes measured gh behaviour, not assumed behaviour. Taken from
# gh 2.x against a real repository on a branch with an open PR:
#
#   $ gh pr view --repo OWNER/NAME --json number
#   argument required when using the --repo flag           (exit 1)
#   $ gh pr view --json number                             (same directory)
#   85                                                     (exit 0)
#
# BRANCH_PR is the number the stub reports for the current branch. Every other
# selector is treated as an explicit PR and echoed back, so a wrong resolution
# shows up as a wrong number rather than as an absence.
cat >"$STUB_DIR/gh" <<'STUB'
#!/bin/bash
BRANCH_PR=85
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo "acme/app"; exit 0; fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  shift 2
  selector="" ; has_repo=0 ; field=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) has_repo=1; shift 2 ;;
      --json) field="$2"; shift 2 ;;
      --jq)   shift 2 ;;
      --*)    shift ;;
      *)      [ -z "$selector" ] && selector="$1"; shift ;;
    esac
  done
  if [ -z "$selector" ] && [ "$has_repo" = "1" ]; then
    echo "argument required when using the --repo flag" >&2
    exit 1
  fi
  [ -z "$selector" ] && selector="$BRANCH_PR"
  case "$field" in
    number)     echo "$selector" ;;
    headRefOid) echo "deadbee" ;;
    isDraft)    echo "false" ;;
    *)          echo "" ;;
  esac
  exit 0
fi
# Anything else: succeed quietly. These tests only reach the resolution step.
exit 0
STUB
chmod +x "$STUB_DIR/gh"

failures=0
checked=0

check() {  # check <label> <expected-substring> <poller> [args...]
  local label="$1" want="$2" poller="$3"; shift 3
  checked=$((checked + 1))
  local got
  # --timeout 0 makes the loop hit its deadline immediately, so the run ends
  # after the resolution step instead of polling a repository that does not
  # exist. The first line is what carries the resolved PR number.
  got=$(PATH="$STUB_DIR:$PATH" bash "$poller" "$@" --timeout 0 --interval 1 2>&1 | head -1)
  if [[ "$got" == *"$want"* ]]; then
    return 0
  fi
  printf 'FAIL %s\n  want substring: %s\n  got:            %s\n' "$label" "$want" "$got"
  failures=$((failures + 1))
}

for poller in "$ROOT"/skills/*/scripts/poll-*.sh; do
  name=$(basename "$poller")

  # The promise in every SKILL.md. This is the assertion that was failing.
  check "$name: no PR number resolves the branch's PR" "PR #85" "$poller"

  # An explicit number must still win, and must not be replaced by the
  # branch's PR. 86 and 85 are both plausible, so a wrong answer is visible.
  check "$name: an explicit PR number is used" "PR #86" "$poller" 86

  # With --repo and no PR number there is no current branch to speak of: the
  # named repository is not necessarily the one the shell is standing in, so
  # the branch is not evidence about it. This must fail, and say why.
  checked=$((checked + 1))
  got=$(PATH="$STUB_DIR:$PATH" bash "$poller" --repo other/repo --timeout 0 --interval 1 2>&1 | head -1)
  case "$got" in
    *"RESULT=ERROR"*)
      case "$got" in
        *"PR number"*) : ;;
        *) printf 'FAIL %s: --repo without a PR number errors, but does not say a PR number is needed\n  got: %s\n' "$name" "$got"
           failures=$((failures + 1)) ;;
      esac ;;
    *) printf 'FAIL %s: --repo without a PR number should error, got: %s\n' "$name" "$got"
       failures=$((failures + 1)) ;;
  esac
done

echo "$((checked - failures)) passed, $failures failed"
[ "$failures" -eq 0 ]
