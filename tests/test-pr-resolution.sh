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
# GH_STUB_FAIL simulates a gh that cannot answer at all -- an expired token,
# not an absent PR. It exits nonzero by the same route a real absence does,
# which is the whole point: the poller must not decide which one it was.
if [ -n "${GH_STUB_FAIL:-}" ] && [ "$1" = "pr" ]; then
  echo "error: not authenticated. run: gh auth login" >&2
  exit 1
fi
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

fail() {  # fail <label> <want> <got>
  # Record one failed assertion. Prints want and got on separate lines
  # because the interesting failures here are whole command outputs, and a
  # one-line diff of two long strings is unreadable at the moment it matters.
  printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"
  failures=$((failures + 1))
}

check() {  # check <label> <expected-substring> <poller> [args...]
  # Run one poller under the stub and assert its first line contains <want>.
  # --timeout 0 makes the loop hit its deadline immediately, so the run ends
  # after the resolution step instead of polling a repository that does not
  # exist. The first line is what carries the resolved PR number.
  local label="$1" want="$2" poller="$3"; shift 3
  checked=$((checked + 1))
  local got
  got=$(PATH="$STUB_DIR:$PATH" bash "$poller" "$@" --timeout 0 --interval 1 2>&1 | head -1)
  [[ "$got" == *"$want"* ]] || fail "$label" "substring: $want" "$got"
}

check_no_hang() {  # check_no_hang <label> <poller> [args...]
  # Assert the poller terminates and says why, rather than spinning.
  #
  # `shift 2` with one argument left fails and shifts nothing. With set -u and
  # no set -e the loop reselects the same flag forever, printing nothing --
  # measured before the fix: `poll-coderabbit.sh --repo` was alive after five
  # seconds with empty output. A test that only checked the message would pass
  # against a build that hangs, because a hang produces no wrong message. So
  # termination is asserted first, on its own.
  local label="$1" poller="$2"; shift 2
  checked=$((checked + 1))
  local out; out=$(mktemp)
  PATH="$STUB_DIR:$PATH" bash "$poller" "$@" >"$out" 2>&1 &
  local pid=$!
  local i
  for i in 1 2 3; do
    sleep 1
    kill -0 "$pid" 2>/dev/null || break
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    fail "$label" "terminates" "still running after 3s, output: $(head -1 "$out")"
    rm -f "$out"; return
  fi
  wait "$pid" 2>/dev/null
  local got; got=$(head -1 "$out"); rm -f "$out"
  [[ "$got" == *"requires a value"* ]] || fail "$label" "substring: requires a value" "$got"
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

  # A flag given without its operand. Every one of these spun forever before
  # the fix, with no output at all.
  check_no_hang "$name: --repo with no operand"     "$poller" --repo
  check_no_hang "$name: --timeout with no operand"  "$poller" --timeout
  check_no_hang "$name: --interval with no operand" "$poller" --interval

  # A flag followed by another flag. Checking only that a second token exists
  # let the next option be swallowed as this one's value: `--repo --timeout 0`
  # reported `cannot read PR #0 in --timeout`, a message about a repository
  # nobody named. Neither a repository name nor a number can start with --.
  check "$name: --repo followed by another option" \
        "--repo requires a value" "$poller" --repo --timeout 0
  check "$name: --timeout followed by another option" \
        "--timeout requires a value" "$poller" --timeout --interval 5

  # GH_REPO takes the same path as --repo: it names a repository the current
  # branch says nothing about, so omitting the PR number must be refused the
  # same way. Only --repo was covered before, and the two are separate
  # branches of the same condition.
  checked=$((checked + 1))
  got=$(PATH="$STUB_DIR:$PATH" GH_REPO=other/repo bash "$poller" --timeout 0 --interval 1 2>&1 | head -1)
  case "$got" in
    *"RESULT=ERROR"*"PR number"*) : ;;
    *) fail "$name: GH_REPO without a PR number is refused" \
            "RESULT=ERROR ... PR number" "$got" ;;
  esac

  # A failed read is not an absent pull request. An expired token exits
  # nonzero exactly like a branch with no PR, and the gate's own rule is that
  # a read which errored is not a count of zero. The poller must relay what gh
  # said rather than assert which of the two it was.
  checked=$((checked + 1))
  got=$(PATH="$STUB_DIR:$PATH" GH_STUB_FAIL=1 bash "$poller" --timeout 0 --interval 1 2>&1 | head -1)
  case "$got" in
    *"gh auth login"*) : ;;   # gh's own words survived to the operator
    *) fail "$name: a gh failure is relayed, not classified" \
            "substring: gh auth login" "$got" ;;
  esac
done

echo "$((checked - failures)) passed, $failures failed"
[ "$failures" -eq 0 ]
