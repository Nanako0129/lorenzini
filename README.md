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
polling — not "nothing found, therefore clean". Every bug found here so far has come from
breaking this rule, in a different way each time, and each one failed *open*:
it reported success. No count is given on purpose -- an earlier version of this
sentence carried one, the ledger grew, and the two disagreed until a reviewer
said so. [`docs/fail-open-ledger.md`](docs/fail-open-ledger.md)
records each one, what it cost, and how it was caught.

That ledger is the most valuable file here. The scripts encode its conclusions,
but the conclusions look arbitrary without the failures that produced them, and
a guard whose reason has been forgotten gets "simplified" away by the next
person.

## How changes land here

Through a pull request. Nothing enforces that — `main` carries no branch
protection and no required review, so a pull request here can be merged with any
verdict or none. The gate is a decision, not a mechanism, which is the same
arrangement every repository this reviews uses.

The reviewer is **GitHub Copilot**. A repository ruleset named
`copilot-auto-review` holds one rule of type `copilot_code_review` with
`review_on_push: true`, so Copilot is requested automatically when a NON-DRAFT
pull request opens and on every push to it. The same rule carries
`review_draft_pull_requests: false`, so a draft is not reviewed at all. The
script refuses one up front rather than waiting: it exits immediately with
`RESULT=ERROR` naming the draft, so there is nothing to wait for and nothing to
misread as slowness. `copilot-review-wait` reads the verdict;
merge on `RESULT=CLEAN`, and on anything else disposition what it printed first.

Why Copilot rather than CodeRabbit: CodeRabbit's OSS tier requires a public
repository with fewer than ten stars to have its reviews triggered by hand, and
this one is under that line. The threshold is that vendor's constraint, not a
rule about which reviewer suits which repository.

Stating all of this because it was not stated, and it was not followed: the
first two commits here went straight to `main` with no pull request and no
reviewer configured at all. A repository whose entire purpose is refusing to
merge on an unverified pass merged itself twice on no verdict whatsoever. The
ruleset was created afterwards, in response to being asked why there was no pull
request.

That is not a rule that was broken. It is a rule that was never written down, in
the one place that should have known better than to leave it implicit — the same
shape as every entry in the ledger, one level up: the guard was assumed to exist
rather than checked.

## Testing a change

The regression cases named in each `SKILL.md` are live public pull requests.
Their state changes for reasons unrelated to this code — `pysnmp/pysmi#328`
moved from `SUGGESTIONS` to `PREMERGE` between two runs an hour apart because
that repository's maintainer resolved a thread in between. Confirm any behaviour
change with a controlled comparison (same captured payload, one input varied)
before believing either the pass or the failure.
