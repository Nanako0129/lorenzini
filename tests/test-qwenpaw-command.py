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


def ok(label, condition):
    """Record one assertion. Collects rather than raises so one broken
    expectation does not hide the state of every assertion after it."""
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
ok("without --repo the lookup stays a placeholder",
   "repos/OWNER/NAME" in text_norepo)
ok("without --repo the agent is told where to resolve it from",
   "working directory" in text_norepo)

text_cr, _ = run("12 --repo acme/app --reviewer coderabbit")
ok("explicit reviewer names its skill",
   "skills/coderabbit-review-wait/SKILL.md" in text_cr)
ok("explicit reviewer skips the star-count lookup",
   "stargazers_count" not in text_cr)

ok("every prompt carries the untrusted-data rule",
   all("untrusted data" in t for t in (text, text_norepo, text_cr)))

total = 5 + 4 + 10 + 4 + 2 + 2 + 1
print(f"{total - len(failures)} passed, {len(failures)} failed")
for f in failures:
    print(f"  FAIL {f}")
sys.exit(1 if failures else 0)
