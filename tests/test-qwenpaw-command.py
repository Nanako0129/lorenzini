#!/usr/bin/env python3
"""Assertions for the QwenPaw /lorenzini command.

These were a throwaway probe run once during packaging. That is the mechanism
of non-convergence this repository's ledger keeps describing: a check that
proves one thing and is deleted starts every later round from zero. Both
defects below were found by review, not by the probe, because the probe was
gone by then.

``agentscope`` is not installed here, so ``Msg`` and ``TextBlock`` are stubbed
with the smallest shapes the command actually uses. The stub records what was
passed rather than imitating agentscope: these assertions are about the text
the command composes and the role it assigns, which is all the host sees.
"""
import asyncio
import importlib.util
import re
import pathlib
import sys
import types

ROOT = pathlib.Path(__file__).resolve().parent.parent

stub = types.ModuleType("agentscope.message")
stub.TextBlock = lambda **kw: kw
stub.Msg = lambda **kw: kw
pkg = types.ModuleType("agentscope")
pkg.message = stub
sys.modules.setdefault("agentscope", pkg)
sys.modules.setdefault("agentscope.message", stub)

spec = importlib.util.spec_from_file_location(
    "lorenzini_qwenpaw", ROOT / ".qwenpaw-plugin" / "plugin.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

failures = []
checked = 0


def ok(label, condition):
    """Record one assertion. Collects rather than raises so one broken
    expectation does not hide the state of every assertion after it.

    The count is kept here rather than written at the bottom of the file. A
    hand-maintained total is a second statement of what the file contains,
    and it drifted on the first try -- the footer claimed 28 over 27 real
    assertions, so a deleted assertion would have been reported as a passing
    one. Counting the calls is the only version that cannot be wrong.
    """
    global checked
    checked += 1
    if not condition:
        failures.append(label)


def run(args):
    """Invoke the command and return (text, role) from the composed Msg."""
    msg = asyncio.run(mod._slash_lorenzini(None, args))
    return msg["content"][0]["text"], msg["role"]


# -- flag parsing -------------------------------------------------------
ok("bare number", mod._split_flags("12") == ("12", {}))
ok("both flags", mod._split_flags("12 --repo a/b --reviewer copilot")
   == ("12", {"repo": "a/b", "reviewer": "copilot"}))
ok("flag order does not matter",
   mod._split_flags("12 --reviewer copilot --repo a/b")[1]
   == {"repo": "a/b", "reviewer": "copilot"})
# Peeling right-to-left keeps the right-most value, which is what a person
# retyping a flag means.
ok("repeated flag keeps the right-most",
   mod._split_flags("12 --repo a/b --repo c/d")[1]["repo"] == "c/d")
# The first non-flag token ends the flag section, so prose after the number
# cannot smuggle control data in.
ok("flags only at the tail",
   mod._split_flags("12 --repo a/b trailing")[1] == {})

# -- rejections ---------------------------------------------------------
ok("empty args prints usage", run("")[0].startswith("Usage:"))
ok("non-numeric PR rejected", "is not a pull request number" in run("abc")[0])
# str.isdigit() is Unicode-aware, so these all returned True and reached the
# prompt. The poller's [0-9]* case pattern then drops them through its *)
# branch without an error and falls back to the current branch's pull request,
# so the gate would have adjudicated a different PR than it was asked about.
# Written as escapes, not as the characters themselves. The whole subject
# here is that these are indistinguishable from ASCII digits when read, so a
# literal would leave the next reader unable to tell what is actually being
# tested -- and unable to notice if an editor or an encoding round-trip
# quietly replaced one with its ASCII lookalike.
WIDE = "\uff11\uff12"        # FULLWIDTH DIGIT ONE, TWO
ARABIC = "\u0661\u0662"      # ARABIC-INDIC DIGIT ONE, TWO
MIXED = "\u0661" + "2"        # one of each: a check that only rejects
#                                fully non-ASCII input would pass this
for name, wide in (("fullwidth", WIDE), ("arabic-indic", ARABIC),
                   ("mixed", MIXED)):
    ok(f"non-ASCII digits rejected: {name}",
       "is not a pull request number" in run(wide)[0])
ok("unknown reviewer rejected",
   "Unknown --reviewer" in run("12 --reviewer gemini")[0])
ok("rejections address the person, not the agent", run("")[1] == "assistant")

# A --repo value reaches a prompt telling the agent to run `gh api repos/<it>`.
# What matters is that a malformed one never gets there, not which of the two
# guards stops it: `a/b;rm -rf /` contains a space, so _FLAG never recognises
# it as a flag at all and the whole string fails the PR-number check instead.
# Asserting the specific message would pin the wrong guard.
for bad in ("a", "a/b/c", "a/b;rm -rf /", "$(id)/x", "a/`id`"):
    text_bad, role_bad = run(f"12 --repo {bad}")
    ok(f"malformed repo rejected: {bad}", role_bad == "assistant")
    ok(f"malformed repo never reaches a prompt: {bad}",
       "stargazers_count" not in text_bad)

# -- the composed prompt ------------------------------------------------
text, role = run("12 --repo acme/app")
ok("prompt is handed to the agent", role == "user")
# The defect this file exists for: repo_line named acme/app while pick_line
# still told the agent to query the literal OWNER/NAME, a request that 404s.
ok("star-count lookup names the supplied repo",
   "gh api repos/acme/app -q .stargazers_count" in text)
ok("no literal OWNER/NAME survives when a repo was given",
   "repos/OWNER/NAME" not in text)

text_norepo, _ = run("12")
ok("without --repo the agent is told to resolve it first",
   "resolve the repository's OWNER/NAME from the working directory"
   in text_norepo)
# Whatever sits between backticks is what an agent will paste into a shell.
# The first version interpolated "OWNER/NAME, resolved from the working
# directory" into the command position, producing a gh invocation with prose
# in the middle of it.
#
# The first version of THIS check was a blocklist -- it rejected a comma and
# the word "the", so `gh api repos/OWNER/NAME resolved from working directory
# -q .stargazers_count` walked straight past it. That is the mistake this
# whole repository is about, committed inside its own test: recognition has to
# say what a pass looks like, not enumerate the bad shapes someone thought of.
# So the span must MATCH the command, and anything else fails by default.
# Two segments, spelled out. The first version put `/` inside one character
# class, so `repos/a/b/c` and `repos//a` matched -- a positive check that was
# still loose enough to accept a path no gh call can use. The segment set is
# the one _REPO validates --repo against, so the assertion and the guard agree
# on what a repository name is.
SEGMENT = r"[A-Za-z0-9._-]+"
COMMAND = re.compile(
    rf"\Agh api repos/{SEGMENT}/{SEGMENT} -q \.stargazers_count\Z"
)
for label, body in (("no --repo", text_norepo), ("--repo acme/app", text)):
    spans = re.findall(r"`([^`]+)`", body)
    # A vacuous loop asserts nothing. The guard only means something if there
    # is a span to check, so the count is an assertion in its own right.
    ok(f"{label}: prompt carries exactly one backticked span", len(spans) == 1)
    for span in spans:
        ok(f"{label}: span is the expected command, not prose: {span}",
           COMMAND.match(span) is not None)

text_cr, _ = run("12 --repo acme/app --reviewer coderabbit")
ok("explicit reviewer names its skill",
   "skills/coderabbit-review-wait/SKILL.md" in text_cr)
ok("explicit reviewer skips the star-count lookup",
   "stargazers_count" not in text_cr)

ok("every prompt carries the untrusted-data rule",
   all("untrusted data" in t for t in (text, text_norepo, text_cr)))

print(f"{checked - len(failures)} passed, {len(failures)} failed")
for f in failures:
    print(f"  FAIL {f}")
sys.exit(1 if failures else 0)
