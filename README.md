# lorenzini

Claude Code skills that wait for a third-party pull-request reviewer and decide
whether its verdict actually means *pass*.

A shark's ampullae of Lorenzini are electroreceptors: they find prey buried in
sand, where there is nothing to see. That is what these skills are for. Every
reviewer so far has reported findings in places its own count ignores, and every
bug in this repository has been the same mistake — treating "I cannot see a
problem" as "there is no problem".

## What is here

| Skill | Reviewer | Status |
|---|---|---|
| [`coderabbit-review-wait`](coderabbit-review-wait/) | CodeRabbit (`coderabbitai[bot]`) | Active on repositories with 10 stars or more |
| [`copilot-review-wait`](copilot-review-wait/) | GitHub Copilot (`copilot-pull-request-reviewer[bot]`) | Active on repositories under 10 stars |
| [`codex-review-wait`](codex-review-wait/) | Codex (`chatgpt-codex-connector`) | Dormant since 2026-09-17, subscription paused |

The CodeRabbit/Copilot split is a vendor constraint, not a preference:
CodeRabbit's OSS tier requires a public repository with fewer than ten stars to
have its reviews triggered by hand, so those repositories moved to Copilot.
Check which applies with `gh api repos/OWNER/NAME -q .stargazers_count` rather
than assuming.

Each skill polls until a verdict lands on the current head commit and prints one
machine-readable `RESULT=` line. They do not review code; they adjudicate what a
reviewer said about it.

## Install

Symlink into `~/.claude/skills/`:

```bash
git clone git@github.com:Nanako0129/lorenzini.git ~/side-project/lorenzini
for s in codex copilot coderabbit; do
  ln -s ~/side-project/lorenzini/$s-review-wait ~/.claude/skills/$s-review-wait
done
```

Requires `gh` (authenticated) and `jq`.

## The optional Jev shadow check

`coderabbit-review-wait` can ask a classifier whether a collapsed section heading
names work someone still has to look at. **It is off unless you turn it on, and
it never changes a verdict.**

You do not need it. Without a key, or with `JEV_SHADOW` unset, the scripts behave
exactly as they do today.

| | |
|---|---|
| Turn it on | `JEV_SHADOW=1` |
| Key | `TYPESAFE_API_KEY`, or `~/.config/typesafe/api_key` (chmod 600) |
| Get a key | <https://console.typesafe.ai/settings/keys> — early access, currently a waitlist |
| In Claude Code | put `TYPESAFE_API_KEY` and `JEV_SHADOW` in the `env` block of `~/.claude/settings.json` |
| Where holds are logged | `$XDG_STATE_HOME/lorenzini/shadow-holds.jsonl`, falling back to `~/.local/state/lorenzini/` when `XDG_STATE_HOME` is unset. Override with `JEV_SHADOW_LOG`. Call records go to `jev-calls.jsonl` alongside it, or `JEV_LOG`. |

**With `JEV_SHADOW` unset the scripts behave exactly as they did before this
existed** — no call, no output, no dependency. That is the claim worth making
precisely: with it *on*, the runs print extra lines, so "exactly as today" is
true of disabled mode and not of enabled mode.

With it on and no key, it prints `(jev: unavailable -- ...)` and leaves the
verdict alone. So do a timeout, an HTTP error and a missing questions file. That is not
politeness: the only transition this is ever allowed to make is `CLEAN → HOLD`,
so every way it can fail leaves today's answer standing. A classifier that could
turn a held verdict into a pass would need its failures handled one at a time,
and one of them would be missed.

Four outcomes, kept distinguishable on purpose:

| Line | Means |
|---|---|
| `(jev: unavailable -- ...)` | did not run; no key, a timeout, an HTTP error, a missing questions file |
| `(jev: INCOMPLETE -- M of N heading(s) came back without a usable score)` | ran, but part of the response was missing or non-numeric. **Not a full check**, and the line below it covers only the headings that answered |
| `(jev: checked X of N heading(s), nothing the patterns missed)` | ran, found nothing the patterns did not already catch |
| `(jev: would HOLD -- ...)` | ran, found a heading the patterns do not know |

Collapsing the first three into one silence is the mistake the ledger is mostly
about, and the INCOMPLETE state exists because the first version of this code
made exactly that mistake: a partial response produced an empty flag list and
the run reported that nothing was missed.

**The criteria are the classifier.** They live in
[`coderabbit-review-wait/jev-questions-v3.json`](coderabbit-review-wait/jev-questions-v3.json),
not inside a script, because editing one word changes what the thing decides:
v1 missed `Nitpick comments` at 0.37 only because the word "nitpick" was absent,
and one added sentence took it to 0.70. After any edit, re-run the gold set and
write a NEW result file:

```bash
python3 tests/run-gold-set.py 3 coderabbit-review-wait/jev-questions-v4.json
```

Baselines are in [`tests/fixtures/`](tests/fixtures/). v3 scores 29/30 with 8/8
recall on hidden work and a 0/30 flip rate over three repeats. It does **not**
recover the heading `Action not completed`, which the file records as a known
limit rather than leaving for the next person to rediscover.

## The one rule

**Never infer a pass from absence.**

A verdict requires an explicit positive completion marker. No marker means keep
polling — not "nothing found, therefore clean". Five separate bugs have come
from breaking this rule in five different ways, and all five failed *open*:
they reported success. [`docs/fail-open-ledger.md`](docs/fail-open-ledger.md)
records each one, what it cost, and how it was caught.

That ledger is the most valuable file here. The scripts encode its conclusions,
but the conclusions look arbitrary without the failures that produced them, and
a guard whose reason has been forgotten gets "simplified" away by the next
person.

## Testing a change

The regression cases named in each `SKILL.md` are live public pull requests.
Their state changes for reasons unrelated to this code — `pysnmp/pysmi#328`
moved from `SUGGESTIONS` to `PREMERGE` between two runs an hour apart because
that repository's maintainer resolved a thread in between. Confirm any behaviour
change with a controlled comparison (same captured payload, one input varied)
before believing either the pass or the failure.
