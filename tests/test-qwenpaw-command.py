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


def commands(text):
    """Every backticked span in the prompt.

    The prompt used to carry `gh api repos/<it> -q .stargazers_count`, and two
    review rounds went into keeping that span executable: prose leaked into the
    command position once, and the check written to catch it was a blocklist a
    third phrasing walked straight past. The command is gone with the
    star-count routing it served, so what remains is the rule that outlived it
    -- nothing sits between backticks unless an agent could run it.
    """
    return re.findall(r"`([^`]+)`", text)


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
# This check used to be "stargazers_count" not in the prompt, which was true
# while a valid --repo produced a star-count command. Routing changed and no
# prompt carries that string any more, so the assertion became true of every
# input and would have passed with a malformed repository composed straight
# into an agent prompt. A guard that can no longer fail is not a guard.
#
# The rejection is asserted by what a rejection IS: addressed to the person
# rather than handed to the agent, and naming the flag.
#
# The rejection DOES echo the value back -- "'$(id)/x' is not an OWNER/NAME
# repository". That is correct: it goes to the person who typed it, as
# role="assistant", and telling them what was rejected is the point. An
# earlier comment here claimed the value appears nowhere in the output, which
# was never true and was never asserted either way.
#
# What must not happen is the value reaching a prompt the agent acts on, so
# that is what the third assertion checks: role, not substring.
for bad in ("a", "a/b/c", "a/`id`", "$(id)/x"):
    body, who = run(f"12 --repo {bad}")
    ok(f"malformed repo is refused: {bad}", who == "assistant")
    ok(f"malformed repo says which flag: {bad}",
       "is not an OWNER/NAME repository" in body)
    ok(f"malformed repo reaches no agent prompt: {bad}",
       "skills/" not in body and "Adjudicate the review verdict" not in body)

# -- the composed prompt ------------------------------------------------
text, role = run("12 --repo acme/app")
ok("prompt is handed to the agent, not the person", role == "user")
ok("the supplied repo reaches the prompt", "Repository: acme/app." in text)

text_norepo, _ = run("12")
ok("without --repo the agent is told to detect it",
   "detect it from the working directory" in text_norepo)

# Routing by star count was the defect, not the feature. Copilot's quota is per
# requesting user, so its whole side went dormant at once and every repository
# moved to CodeRabbit on 2026-09-25. A prompt still sending an under-ten-star
# repository to copilot-review-wait hands the pull request to a gate that
# reviews nothing -- fail-open, while reading as though a reviewer was picked.
for label, body in (("no --repo", text_norepo), ("--repo acme/app", text)):
    ok(f"{label}: defaults to CodeRabbit",
       "skills/coderabbit-review-wait/SKILL.md" in body)
    ok(f"{label}: does not route to a dormant gate",
       "copilot-review-wait/SKILL.md" not in body
       and "codex-review-wait/SKILL.md" not in body)
    ok(f"{label}: emits no star-count lookup", "stargazers_count" not in body)
    # Asserted as a count, not as a property of each span. `all()` over an
    # empty list is True, so the per-span version could not fail: the prompt
    # carries no backticks at all since the star-count command was removed,
    # measured at 0 spans for every input. That is the same defect this
    # branch fixed one commit earlier in the --repo guard, regrown in the
    # check written to replace it.
    #
    # Pinning the count to zero makes the absence a stated fact. If a prompt
    # ever grows a backticked span again, this goes red and someone decides
    # whether it is executable, which is the judgement the per-span version
    # was pretending to make.
    ok(f"{label}: prompt carries no backticked span", len(commands(body)) == 0)

# A dormant gate is still reachable deliberately, by name.
text_cp, _ = run("12 --reviewer copilot")
ok("an explicit reviewer is honoured even when dormant",
   "skills/copilot-review-wait/SKILL.md" in text_cp)

print(f"{checked - len(failures)} passed, {len(failures)} failed")
for f in failures:
    print(f"  FAIL {f}")
sys.exit(1 if failures else 0)
