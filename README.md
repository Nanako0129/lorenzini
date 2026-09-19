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
