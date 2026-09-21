#!/usr/bin/env python3
"""Assertions for the QwenPaw /lorenzini command.

The command composes a prompt. What matters is whether that prompt names the
right repository and carries a command an agent can actually run -- three real
defects landed there, and each one has a case below.

``agentscope`` is not installed here, so ``Msg`` and ``TextBlock`` are stubbed
with the smallest shapes the command uses.
"""
import asyncio
import importlib.util
import pathlib
import re
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
    """Record one assertion; collect rather than raise so a break early in the
    file does not hide the state of everything after it. The count lives here
    because a hand-written total is a second statement of what the file
    contains, and it drifted the first time it was written."""
    global checked
    checked += 1
    if not condition:
        failures.append(label)


def run(args):
    """Invoke the command and return (text, role) from the composed Msg."""
    msg = asyncio.run(mod._slash_lorenzini(None, args))
    return msg["content"][0]["text"], msg["role"]


# The star-count command is what an agent pastes into a shell, so it is
# matched against its own form rather than scanned for bad substrings. The
# first version of this check was a blocklist and let prose through.
SEGMENT = r"[A-Za-z0-9._-]+"
COMMAND = re.compile(
    rf"\Agh api repos/{SEGMENT}/{SEGMENT} -q \.stargazers_count\Z"
)


def only_span(text):
    """The prompt's single backticked span, or None if it does not carry
    exactly one. Returning None rather than skipping keeps a prompt that
    stopped carrying a command from passing silently."""
    spans = re.findall(r"`([^`]+)`", text)
    return spans[0] if len(spans) == 1 else None


# -- flags --------------------------------------------------------------
ok("flags parse off the tail",
   mod._split_flags("12 --repo a/b --reviewer copilot")
   == ("12", {"repo": "a/b", "reviewer": "copilot"}))
# The first non-flag token ends the flag section, so prose after the number
# cannot smuggle control data in.
ok("a trailing word ends the flag section",
   mod._split_flags("12 --repo a/b trailing")[1] == {})

# -- rejections ---------------------------------------------------------
ok("non-numeric PR rejected", "is not a pull request number" in run("abc")[0])

# str.isdigit() is Unicode-aware, so these reached the prompt. The poller
# matches positional PR numbers with [0-9]*, drops anything else through its
# *) branch without an error, and falls back to the current branch's pull
# request -- so the gate adjudicated a different PR than it was asked about.
# Escapes, not literals: these are indistinguishable from ASCII when read.
for name, digits in (("fullwidth", "\uff11\uff12"),
                     ("arabic-indic", "\u0661\u0662"),
                     # a check rejecting only fully non-ASCII passes this one
                     ("mixed", "\u0661" + "2")):
    ok(f"non-ASCII digits rejected: {name}",
       "is not a pull request number" in run(digits)[0])

# --repo is interpolated into a command the agent is told to run.
for bad in ("a", "a/b/c", "a/`id`"):
    ok(f"malformed repo never reaches a prompt: {bad}",
       "stargazers_count" not in run(f"12 --repo {bad}")[0])

# -- the composed prompt ------------------------------------------------
text, role = run("12 --repo acme/app")
ok("prompt is handed to the agent, not the person", role == "user")
# repo_line named acme/app while pick_line queried the literal OWNER/NAME.
ok("lookup names the supplied repo",
   only_span(text) == "gh api repos/acme/app -q .stargazers_count")

text_norepo, _ = run("12")
ok("without --repo, resolution is its own instruction",
   "resolve the repository's OWNER/NAME from the working directory"
   in text_norepo)
# Interpolating that sentence into the command position produced
# `gh api repos/OWNER/NAME, resolved from the working directory -q ...`.
ok("without --repo, the span is still a command",
   COMMAND.match(only_span(text_norepo) or "") is not None)

text_cr, _ = run("12 --reviewer coderabbit")
ok("an explicit reviewer skips the lookup and names its skill",
   "stargazers_count" not in text_cr
   and "skills/coderabbit-review-wait/SKILL.md" in text_cr)

print(f"{checked - len(failures)} passed, {len(failures)} failed")
for f in failures:
    print(f"  FAIL {f}")
sys.exit(1 if failures else 0)
