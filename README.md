# lorenzini

[English](README.md) · [繁體中文](README.zh-TW.md)

Claude Code skills that poll third-party pull request reviewers—CodeRabbit, GitHub Copilot, and Codex—and adjudicate whether their verdicts actually permit a merge.

They do not review source code; they adjudicate what the reviewer reported.

A shark's ampullae of Lorenzini are electroreceptors that locate prey buried in sand where eyes see nothing. That is the job here. Every automated reviewer observed across these repositories has reported findings inside collapsed sections, uncounted comments, or separate threads that its own top-level summary ignored. Every bug in this repository has made the identical error: assuming silence means clean code.

## The one rule

Never infer a pass from absence.

A verdict requires an explicit positive completion marker. Without one, keep polling. Silence is not approval, and an empty finding list does not mean zero issues. Every gate failure in this project failed *open*: it reported success when none was earned.

The record of every missed finding lives in [`docs/fail-open-ledger.md`](docs/fail-open-ledger.md). It is not an appendix; it is the evidence base for whether this tool can be trusted. The ledger documents 11 incidents where earlier versions returned an unearned pass, starting on 2026-09-17 with `coralline#85`, where a login filter missed one of Copilot's two logins and returned `CLEAN` on a pull request containing three actionable findings.

## Reviewer skills and routing

One skill is live; the other two are kept dormant rather than deleted.

- [`coderabbit-review-wait`](skills/coderabbit-review-wait/): CodeRabbit (`coderabbitai[bot]`). **Every repository, as of 2026-09-25.**
- [`copilot-review-wait`](skills/copilot-review-wait/): GitHub Copilot (`copilot-pull-request-reviewer[bot]`). Dormant since 2026-09-25.
- [`codex-review-wait`](skills/codex-review-wait/): Codex (`chatgpt-codex-connector`). Dormant since 2026-09-17, upstream subscription suspended.

There used to be a split by star count. It ended when Copilot answered *"Copilot was unable to review this pull request because the user who requested the review has reached their quota limit"* and reviewed nothing. **That quota is per requesting user, not per repository**, so it emptied one whole side of the routing table at the same moment and no per-repository setting moved any of it — the same failure shape the star-count split was built around, arriving from the other vendor.

Moving a repository across takes two changes together: `reviews.auto_review.enabled: true` in its `.coderabbit.yaml`, and its `copilot-auto-review` ruleset set to `enforcement=disabled`. Disabled rather than deleted, so coming back is one field.

**Whether the star count still decides how a review is triggered is unsettled.** Automatic review was observed at 0 to 5 stars, but every observation was taken inside a paid trial that reviews automatically whatever the count. Post a top-level `@coderabbitai review` rather than relying on it. Query star counts with the GitHub CLI if you need them for something else:

```bash
gh api repos/OWNER/NAME -q .stargazers_count
```

Routing directs traffic, but cannot prevent overlaps. A second reviewer can still be triggered manually on any pull request or enabled via checkboxes in CodeRabbit pause notifications, leaving no trace readable by the primary poller. On `lorenzini`'s own pull requests, PR #2 had three Copilot findings slip through two adjudications unmentioned, while PR #1 had four findings entirely omitted from review summaries, two of which were legitimate defects. That leakage is why `RESULT=OTHERBOT` exists.

## Adjudication verdicts

Each skill polls until a definitive verdict is recorded against the current head commit, then emits a single machine-readable `RESULT=` line. The three skills define clean differently; read the `SKILL.md` for the repository you are configuring. Porting logic between them fails silently rather than loudly.

| Verdict | Meaning | Disposition |
|---|---|---|
| `RESULT=CLEAN` | Gate passed. Safe to merge. | Merge the pull request. |
| `RESULT=SUGGESTIONS count=N` | N inline findings on head, or `CHANGES_REQUESTED`. | Resolve or reply before merging. |
| `RESULT=NITPICKS count=N` | Otherwise clean, but N findings—or N skipped, unread files—sit in a collapsed body section that the reviewer's own count ignores. | Not a pass. A file that was never read means a zero count over it proves nothing. Disposition each, push, and re-poll. |
| `RESULT=PREMERGE count=N` | Otherwise clean, but N pre-merge checks failed. The reliable count is the `✅ N | ❌ M` tally and the section heading; an individual row's status cell reads `⚠️ Warning`, so a parser hunting `❌` inside the rows finds nothing and reports a pass. | Not a pass. Often a legitimate defer—a coverage threshold counts every function touched by the diff, not just added ones. Disposition each. |
| `RESULT=MISCOUNT claimed=N counted=M` | The reviewer's own claimed count exceeds what this gate arrived at. | Not a pass. The gap itself is the finding: posted content is not being counted. |
| `RESULT=UNREPLIED count=N` | N resolved threads carry no human reply. | Not a pass. `@coderabbitai resolve` closes every thread at once, leaving no record of decisions. Reply with dispositions, then resolve. |
| `RESULT=OTHERBOT` | This gate is clean, but the pull request carries undispositioned findings from a reviewer it cannot read—either an unresolved thread or a finding inside that reviewer's own review body that generates no thread. | Not a pass. Clean here only proves that *one* reviewer found nothing. Open the pull request and read what the secondary bot reported. |
| `RESULT=NOT_REVIEWED` | A review object exists at head, but its body is not a verdict. | With `reason=quota fallback=coderabbit`, Copilot reviewed nothing. Because quotas are per requesting user, all repositories on that account lose coverage simultaneously: switch to CodeRabbit immediately. Other variants report at deadline, not on sight. |
| `RESULT=UNREAD format=X` | The review body uses a format with no verified clean sample (currently `ccr-overview-v2`). | Not a pass and not a failure: an admission. No clean sample of this format has been captured, so zero findings prove nothing. The body is printed in full for a human to evaluate. |
| `RESULT=TIMEOUT` | Head did not receive a verdict within the polling deadline. | Gate held. Never treat a timeout as approval. |
| `RESULT=ERROR ...` | Polling cannot resolve this state: draft PRs, paused or skipped reviews, exhausted GitHub API rate limits, or an unresolvable repository/PR. | Fix the precondition. Rate limits report their reset time directly rather than polling to the deadline. |

## Install

These are portable [Agent Skills](https://agentskills.io/specification): one canonical `SKILL.md` per reviewer under `skills/`, no per-platform forks. Every command below installs at **user scope** — once, for every project.

Requires an authenticated `gh` CLI and `jq`.

### Any agent (Skills CLI)

```bash
npx skills add Nanako0129/lorenzini -g     # -g = user scope
npx skills update lorenzini -g
```

### Claude Code

```bash
claude plugin marketplace add Nanako0129/lorenzini
claude plugin install lorenzini@lorenzini --scope user

# update
claude plugin marketplace update lorenzini
claude plugin update lorenzini
```

### Codex

```bash
codex plugin marketplace add Nanako0129/lorenzini
codex plugin add lorenzini@lorenzini

# update — refresh the snapshot, then re-add
codex plugin marketplace upgrade lorenzini
codex plugin add lorenzini@lorenzini
```

### Antigravity

```bash
agy plugin install https://github.com/Nanako0129/lorenzini
```

### Grok Build

```bash
grok plugin install Nanako0129/lorenzini --trust
grok plugin update
```

### QwenPaw

```bash
git clone https://github.com/Nanako0129/lorenzini
qwenpaw plugin install ./lorenzini/.qwenpaw-plugin
```

> **What "installs" means here.** The packaging was exercised to the point that each manifest parses and the skills resolve. Whether every host then loads and runs them as documented has not been checked platform by platform, and the QwenPaw entry point has not been run at all — no QwenPaw install was available. File an issue if your agent trips on it.

### Removing it

Kept out of the blocks above, because those are meant to be copied whole and
an uninstall line at the bottom of an install block undoes the install.

```bash
npx skills remove lorenzini -g          # Skills CLI
qwenpaw plugin uninstall lorenzini      # QwenPaw
```

Only these two routes' removal commands are recorded here. The others were not
run, and guessing a command that deletes something is worse than omitting it —
check your own host's documentation.

### From a clone, pinned to a tag

The manual route, and the one to use if you want the gate to change only when you say so:

```bash
git clone https://github.com/Nanako0129/lorenzini.git ~/side-project/lorenzini
cd ~/side-project/lorenzini && git checkout v0.2.3
for s in codex copilot coderabbit; do
  ln -sfn ~/side-project/lorenzini/skills/$s-review-wait ~/.claude/skills/$s-review-wait
done
```

> **Upgrading from v0.2.1 or earlier breaks this symlink.** The three skill directories moved from the repository root into `skills/` so the package can be installed by the tools above. A clone that pulls past that point leaves the old symlinks dangling, and a dangling skill symlink does not announce itself — the skill is simply gone. Re-run the loop above, or switch to one of the package installs.

Pin to a tag, never to `main`. These skills govern merge safety and `main` is where each newly caught fail-open is patched, so on `main` an ordinary `git pull` changes your gate. Symlinks target directories rather than commits, so they survive:

```bash
git fetch --tags && git checkout v0.2.3
```

If you develop inside `lorenzini`, your checked-out branch **is** your active gate. On 2026-09-20, the same poller on the same pull request minutes apart produced `RESULT=CLEAN` from one branch and `RESULT=NOT_REVIEWED` from another — over a review body stating the source files were never read.

## Version support

| Tag | Status | Notes |
|---|---|---|
| `v0.2.3` | Usable | Current baseline. Makes the documented current-branch PR fallback actually resolve — it could never succeed, and reported `no PR for the current branch` on branches that had one. Hardens the argument parser: a flag with no value hung the poller silently, an empty `--repo` polled the wrong repository, and an empty `--timeout` returned `RESULT=TIMEOUT` without waiting. |
| `v0.2.2` | Superseded | Previous baseline. Moves the three skill directories into `skills/` and adds five package manifests, so the gate installs as a plugin rather than a hand-made symlink. **Breaking:** an existing `~/.claude/skills/` symlink into this clone goes dangling on upgrade. |
| `v0.2.1` | Superseded | Previous baseline. Fixes a race where a skip notice was read as terminal while the review was starting, and routes a spent Copilot quota to CodeRabbit instead of stopping. |
| `v0.2.0` | Superseded | Has the cross-reviewer, non-review and format recognition guards, but treats a skip notice as terminal on first sight. On a repository with CodeRabbit auto review disabled, that fires every round. |
| `v0.1.1` | Superseded | Lacks cross-reviewer guards, non-review detection, and updated format recognition. |
| `v0.1.0` | Do not use | Contains four distinct gates that report passes without earning them. |

If you cloned before 2026-09-20, your local repository reflects `main` at that moment, somewhere within `v0.1.x`. Check your position with `git log --oneline -1` against the tags above.

## How changes land here

Changes land via pull requests, but nothing enforces this mechanically: `main` has no branch protection rules and requires no reviews. A pull request here can merge under any verdict or no verdict at all. The gate is an operational discipline rather than an infrastructure lock, matching the arrangement in every repository this tool reviews.

Reviews here run on CodeRabbit and verdicts are read by `coderabbit-review-wait`, as on every repository since 2026-09-25. An earlier version of this line attributed that to `lorenzini` sitting above a 10-star threshold; whether the star count decides anything is unsettled, and it decided nothing about this — the whole routing table moved when Copilot's per-user quota emptied its side. The legacy `copilot-auto-review` ruleset remains in repository settings with its status set to disabled. Copilot still reviewed pull requests here, which is where the `OTHERBOT` leak was first discovered.

Draft pull requests are refused immediately: the poller exits with `RESULT=ERROR` naming draft status, ensuring draft silence is never mistaken for review latency. Merge only on `RESULT=CLEAN`. For any other outcome, disposition the output first.

The first two commits to this repository were pushed directly to `main` with no pull requests and no reviewer configured. A project built entirely to refuse unverified merges merged itself twice without any verdict. The ruleset was created only after someone asked why there were no pull requests. That was not a broken rule; it was an unwritten rule where it least belonged. It shared the exact shape of every ledger entry, one abstraction layer up: the guard was assumed to exist rather than verified.

## The optional Jev shadow classifier

`coderabbit-review-wait` can query a classifier to determine whether a collapsed markdown section heading describes unaddressed work.

Jev is off by default and changes no gate decisions today. When enabled via `JEV_SHADOW=1`, it operates strictly in shadow mode: if it disagrees with a passing verdict, it prints `(jev: would HOLD ...)` alongside the script's verdict, and the script exits using the gate's original verdict. Enabling Jev cannot block a merge; it only reports what would have been held.

If Jev is ever granted veto authority in the future, the design constraint is strictly unidirectional: `CLEAN` may transition to `HOLD`, but `HOLD` can never transition to `CLEAN`. A held verdict stays held regardless of classifier output. That is why every failure mode—missing keys, timeouts, network errors, or low confidence—leaves today's verdict untouched. Verifying this invariant under real polling is the entire purpose of the observation period before wiring any model output to verdicts. When `JEV_SHADOW` is unset, no calls are made, no output is printed, and no dependencies are loaded.

Configuration:
- Set `JEV_SHADOW=1` to enable shadow evaluation.
- Set `TYPESAFE_API_KEY` in your environment or write it to `~/.config/typesafe/api_key` (`chmod 600`). API keys can be requested at `https://console.typesafe.ai/settings/keys` (early access waitlist).
- For Claude Code, add `TYPESAFE_API_KEY` and `JEV_SHADOW` to the `env` block in `~/.claude/settings.json`.
- Holds are logged to `$XDG_STATE_HOME/lorenzini/shadow-holds.jsonl` (falling back to `~/.local/state/lorenzini/shadow-holds.jsonl`, overridable via `JEV_SHADOW_LOG`). API calls are logged to `jev-calls.jsonl` in the same directory (overridable via `JEV_LOG`).

Jev produces four distinct outputs, kept deliberately distinguishable:
- `(jev: unavailable -- ...)`: Did not run. Missing API keys, network timeouts, HTTP errors, or a missing question file.
- `(jev: INCOMPLETE -- M of N heading(s) came back without a usable score)`: Ran, but responses were partial or non-numeric. This is not a complete check; subsequent lines cover only headings that returned usable scores.
- `(jev: checked X of N heading(s), nothing the patterns missed)`: Jev found nothing the patterns had missed. `X` is the number of headings that came back with a usable score, so this line can follow `INCOMPLETE` and then covers only those.
- `(jev: would HOLD -- ...)`: Jev identified a heading the patterns do not know. This line can also follow `INCOMPLETE`, on the headings that answered.

Collapsing the first three outputs into the same silence is the exact failure documented across most of the ledger. The `INCOMPLETE` state exists because the very first version of this classifier script made that exact error: partial API responses generated an empty flags list, which the script reported as "nothing missed."

The criteria file *is* the classifier. Prompts live in `skills/coderabbit-review-wait/jev-questions-v3.json` rather than inline code because altering a single word shifts scoring behavior. In gold set benchmarks, label `L01` ("🧹 Nitpick comments (3)") represents legitimate findings. In `v1`, the classifier scored it 0.37 (falling below the 0.50 threshold) simply because the word "nitpick" was absent from the prompt criteria. Explicitly naming "nitpick" in `v2` raised that same heading's score to 0.697. Every execution records a SHA hash of the question set, and prompt iterations are tracked in filenames rather than guessed.

To evaluate prompt modifications against the fixture baseline:

```bash
python3 tests/run-gold-set.py 3 skills/coderabbit-review-wait/jev-questions-v4.json
```

Benchmarks run across 30 labels in `tests/fixtures/`, evaluated three times per release:

| Version | Accuracy | Hidden Work Recall | False Positives | Flip Rate (3 Runs) | Notes |
|---|---|---|---|---|---|
| `v1` | 27/30 | 6/8 | 1 | 1/30 | Missed `L01` ("🧹 Nitpick comments (3)") at score 0.37 (threshold 0.50). |
| `v2` | 28/30 | 8/8 | 2 | 0/30 | Added "nitpick" to criteria; `L01` score rose to 0.697. |
| `v3` (Current) | 29/30 | 8/8 | 1 | 0/30 | Cannot recover "Action not completed"; recorded in the file as a known limitation. |

## Testing a change

```bash
bash tests/run-all.sh
```

The runner is the list. This section used to name `tests/test-classifiers.sh` and nothing else while three other suites were added around it, two of them written to catch a specific regression and then left with no path by which anyone would run them — which is the same as not having written them. Adding a suite means adding a line to `tests/run-all.sh`; this section does not repeat the names, so it cannot go stale against them.

`tests/run-gold-set.py` is deliberately outside that runner: it calls a paid classifier and needs a key. Its invocation is in the Jev section below.

`tests/test-classifiers.sh` sources helpers directly from production scripts rather than copying patterns into test files. This distinction proved essential when an earlier test asserted against a duplicated regex string: a mutation test that broadened the production pattern broke nothing in CI because the test verified an obsolete copy. New assertions now sit alongside production helpers and invoke them directly.

The public pull requests named in each `SKILL.md` are live manual regression fixtures. Their upstream state shifts for reasons unrelated to this codebase: `pysnmp/pysmi#328` moved from `SUGGESTIONS` to `PREMERGE` within an hour when the upstream maintainer resolved a thread. Any behavioral verification must rely on controlled comparisons—replaying the identical captured payload with a single modified input—before trusting a pass or a failure.

## The fail-open ledger

[`docs/fail-open-ledger.md`](docs/fail-open-ledger.md) documents every instance where an adjudication gate permitted an unearned pass into production. It records 11 verified incidents, detailing the triggering pull request, the operational cost, and how the defect was identified.

The ledger is not an appendix; it is the evidence base for whether this tool can be trusted. Every entry marks an occasion where an earlier version returned `CLEAN` when it should have held the gate. The earliest entry occurred on 2026-09-17 (`Nanako0129/coralline#85`), where a login filter missed one of Copilot's two logins and reported `CLEAN` on a pull request containing three actionable findings.

The poller scripts encode conclusions that look arbitrary without the historical failures that forced them. A defensive guard whose origin is forgotten will eventually be discarded as redundant by whoever edits it next.
