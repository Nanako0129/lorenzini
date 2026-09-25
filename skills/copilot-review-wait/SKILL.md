---
name: copilot-review-wait
description: "[DORMANT since 2026-09-25: Copilot reviews no repository here. It answered 'the user who requested the review has reached their quota limit' and reviewed nothing; that quota is per requesting user, not per repository, so every repository on this side went at once. All five are on CodeRabbit - use coderabbit-review-wait everywhere. Each copilot-auto-review ruleset is enforcement=disabled rather than deleted, so returning one is a single field. Trigger only if the quota is confirmed restored and a repository is deliberately moved back.] Waits for copilot-pull-request-reviewer[bot] and classifies the outcome. A clean pass needs a review at head matching a VERIFIED clean shape ('### 🟢 Approval recommended', 'Comments generated: 0', a complete 'Files reviewed: N/N'), zero inline comments, no suppressed section. Any other shape is UNREAD, not clean - including a review object with no status line, which is what an exhausted quota submits."
---

# Wait for Copilot review

> **Dormant since 2026-09-25.** Copilot reviews no repository here. It answered *"Copilot was unable to review this pull request because the user who requested the review has reached their quota limit"* and reviewed nothing, and that quota is **per requesting user, not per repository**, so every repository on this side went at the same moment and no per-repository setting moved any of them. All five are on CodeRabbit now — NyanCogs on 2026-09-21, `tokscale-core`, `pilotfish-grok`, `homebrew-tokenbar` and `Syrtis-Agent` on 2026-09-25. Use `coderabbit-review-wait` everywhere. Everything below still applies verbatim if the quota is restored and a repository is deliberately moved back; each repository's `copilot-auto-review` ruleset is `enforcement=disabled` rather than deleted, so that is one field.

Copilot (`copilot-pull-request-reviewer[bot]`) reviews a PR by **submitting a review** carrying a "Pull Request Overview" summary, plus **inline comments** where it has suggestions. This skill polls until that review lands on the current head commit and tells you which outcome it is.

## Which repositories this covers

**None.** This skill covered five repositories and covers none now.

| Repositories | Reviewer | Skill |
|---|---|---|
| none | ~~GitHub Copilot~~ | this one, dormant |
| every repository | **CodeRabbit** | `coderabbit-review-wait` |

The five it used to cover — `tokscale-core`, `NyanCogs`, `pilotfish-grok`, `homebrew-tokenbar`, `Syrtis-Agent` — are on CodeRabbit. The star count decided nothing about this move: the quota is per requesting user, so it emptied this side regardless of any repository's size.

**If one is ever moved back**, three things go together and none of them happen on their own: set its `copilot-auto-review` ruleset to `enforcement=active`, set `reviews.auto_review.enabled: false` in its `.coderabbit.yaml` so two reviewers do not both run, and confirm on the next pull request that Copilot reviews it and CodeRabbit does not.

## What CLEAN means here — it is not a +1

The Codex reviewer signalled a clean pass with a `+1` reaction. **Copilot has no such signal.** It submits a review whichever way the review went, so the review's existence is not the gate.

**The body and the inline count answer two different questions, in order.** The body establishes *that a review happened*: Copilot can submit a review object without reviewing the code at all, and on `NyanCogs#31` it did — a `COMMENTED` review on the head commit whose entire body read *"Copilot was unable to review this pull request because the user who requested the review has reached their quota limit."* Zero inline comments, and every structural test for a clean pass satisfied. So a body carrying no `### <status>` line is `RESULT=NOT_REVIEWED`, never `CLEAN`. Only once that check passes does the inline comment count distinguish a clean result from suggestions.

An earlier version of this paragraph said the body is not part of the gate. That was true of every real review and false about the objects that are not reviews, and reading the body as noise is precisely what let a non-review be reported as a pass.

| | Codex (paused) | Copilot |
|---|---|---|
| Clean pass | `+1` reaction, newer than the head commit | A review whose `commit_id` is the head commit, whose body matches a **verified clean shape** — `### 🟢 Approval recommended` with `Comments generated: 0` and `Files reviewed: N/N` — with **zero inline comments** on that commit, and no undispositioned findings from another reviewer |
| Suggestions | Inline comments with `original_commit_id` = head | Same |
| Review state | `COMMENTED` | `COMMENTED` by default. Copilot **never** posts `REQUEST_CHANGES`; it posts `APPROVED` only if approval is explicitly turned on in org settings (off by default, and a later push dismisses it). So **do not read `state` as the verdict** — count comments. |
| Keyed to head by | Reaction timestamp (reactions carry no commit id) | The review's own `commit_id` — exact, no timestamp heuristic needed |

So **`CLEAN` requires all four**, and each clause is here because something passed without it:

1. A review whose `commit_id` is this exact head commit.
2. A body matching a **verified clean shape**: `### 🟢 Approval recommended`, `Comments generated: 0`, `Files reviewed: N/N`. Measured on `calico-claude#44` and `#45`. Anything else — including `ccr-overview-v2`, which has no clean sample — is `RESULT=UNREAD`. Without the shape check a quota-exhaustion notice passed (`NyanCogs#31`), and an unrecognised format fell through to `CLEAN`.
3. Zero inline comments on that commit, and no `Suppressed comments` section.
4. No undispositioned findings from a reviewer this gate does not read — threads *or* review bodies. See `RESULT=OTHERBOT`.

The script confirms a zero-comment review twice, one interval apart, because the review and its comments are read back through two endpoints and a read landing between the two writes would otherwise report a false CLEAN.

### Three things that will make you compute the wrong verdict

All three were measured on `Nanako0129/coralline#85`, 2026-09-17. The first one produced a false `RESULT=CLEAN` on a review that had three findings.

1. **Copilot uses two different logins.** The *review* is authored by `copilot-pull-request-reviewer[bot]`. Its *inline comments* are authored by **`Copilot`** (`type: Bot`, `id: 175728472`). Filter the comments by the review's login and you find zero of them every time, on every PR. Match both.
2. **`GET /pulls/{n}/reviews` caps at 30 without `--paginate`.** A PR with a long review history pushes the newest review onto page 2, where it is invisible and the poll times out against a review that exists. Note `gh api --paginate --slurp` cannot be combined with gh's own `--jq`; pipe into `jq` instead.
3. **`.line` is endpoint-dependent.** `GET /pulls/{n}/comments` populates `.line`; `GET /pulls/{n}/reviews/{id}/comments` returns `.line` and `.original_line` as `null` and gives only a diff `position`. Fall back, or you print `path:null`.

### What the body does and does not tell you

The body opens with a status line — the observed one was `### 🟡 Changes recommended` — followed by a "Pull request overview", a per-file table, and a "Review details" block carrying `Files reviewed: 4/5`, `Comments generated: 3` and `Review effort level: Lite`. Useful to read; **not** the gate, because the clean-pass wording has not been observed here and pinning unverified text would be a guard that lies.

`Comments generated: N` **equals the inline comment count** (3 and 3, measured), and the script now compares them: a body claiming more than was counted returns `RESULT=MISCOUNT` rather than a pass. This was described here as done for two days while the code contained no such check — see entry 6 of the fail-open ledger. Note the literal is `- **Comments generated:** 3`, with the emphasis markers *between* the colon and the number; a pattern written for `Comments generated: 3` matches nothing, which is how the first attempt at this guard shipped as dead code.

One part of the body has no inline counterpart: a **"Suppressed comments"** section, holding findings Copilot generated but withheld from the inline set as low-confidence. It is counted *separately* from `Comments generated` (the same review carried `Suppressed comments (1)` alongside `Comments generated: 3`, for 3 inline).

**Zero inline comments does not mean Copilot found nothing, and on the evidence so far it usually doesn't.** `Nanako0129/sepia#250` (reported by the `sepia-aa` session, 2026-09-17) ran **four rounds at inline 0 with suppressed findings every round — 8 real defects**, among them a flag-value regex accepting `[A-Za-z-]+` that let `--lang de2` bypass validation, and a version-checker docstring still naming three declarations. `coralline#85` carried one more. That is five observed reviews, five with a suppressed section. An auto loop reporting CLEAN would have merged that PR four times over.

So **a review with a `Suppressed comments` section is never reported as CLEAN.** The script gives it its own verdict:

| Verdict | Meaning |
|---|---|
| `RESULT=CLEAN` | Review of head matching a verified clean shape (`### 🟢 Approval recommended`, `Comments generated: 0`, `Files reviewed: N/N`), no inline comments, **no suppressed section**, and no undispositioned findings from another reviewer. The gate is met. |
| `RESULT=OTHERBOT` | Copilot is clean, but this PR carries undispositioned findings belonging to a reviewer this gate does not read — an unresolved thread, or a finding in that reviewer's own review body, which creates no thread at all. **A clean verdict here means COPILOT found nothing, not that the PR is clean.** Open the PR, read that reviewer's output, disposition each finding. |
| `RESULT=SUPPRESSED count=N` | Review of head, no inline comments, but N findings withheld into the body. The script prints the whole section — path, line and code. **Triage them like any other finding before merging.** |
| `RESULT=MISCOUNT claimed=N counted=M` | Copilot's own body reports more comments than were found on the head commit. Something it posted is not being counted — a login change, a filter bug, a failed read. **The gap is the finding.** |
| `RESULT=UNREAD format=X` | The body is in a format with no known clean shape — currently `ccr-overview-v2`. **Not a pass and not a failure: an admission.** Every captured sample of it carries a substantive summary line alongside `Findings: None` and zero inline comments, and none is a confirmed clean review, so an empty count there means nothing. The review is printed; a person reads it. |
| `RESULT=NOT_REVIEWED reason=quota fallback=coderabbit` | Copilot's quota is exhausted: it submitted a review object and reviewed nothing. **Switch to CodeRabbit — post `@coderabbitai review` and poll with `coderabbit-review-wait`.** The quota is per requesting user, so every repository on this side of the split is out at the same moment; waiting helps none of them, and stopping here leaves the PR with no reviewer. |
| `RESULT=NOT_REVIEWED` | Reported only at the deadline. A non-quota body with no `### <status>` line does **not** end the poll — a later review can supersede it, so the run keeps going and this verdict is what the timeout becomes if the body never turns into one. Nothing in it says the code was read. **A review object is not a review.** Measured on `NyanCogs#31`: a `COMMENTED` review on the head commit, zero inline comments, and a 119-character body reading *"Copilot was unable to review this pull request because the user who requested the review has reached their quota limit."* That satisfies review-of-head-plus-empty-inline-set exactly and was reported `CLEAN`. The check is positive evidence rather than a blocklist: all 40 real review bodies measured across both formats carry a `### ` line and the quota message is the only one that does not, so the next non-review message is caught too. |

`Files reviewed: N/N` **is** automated now, and is part of the clean shape rather than a glance: Copilot skips files, a skipped file was never reviewed, and a zero finding count over unread code says nothing. A body reporting `4/5` does not reach `CLEAN`; it is `RESULT=UNREAD format=approval-but-not-clean-shape`.

**Size a round by the suppressed count too, not by `count=N` alone.** Observed on sepia (reported by `sepia-aa`): #250 over four rounds, then #254 and #255 at **6 suppressed each**. The withheld set has been running at or above the inline set every round, so a round's real workload is roughly double what the inline count advertises. The 2-round budget below counts *rounds*, not findings — do not quietly spend it faster because a round turned out to hold twice the work, and do not extend it for volume alone. Volume is a reason to re-read the divergence section, not to add rounds.

### Replying and resolving — endpoint shapes

*Reported by the `sepia-aa` session from `Nanako0129/sepia#250` on 2026-09-17, and not re-measured here.* Reply through the **PR-scoped** endpoint; the PR-less form 404s:

```bash
gh api -X POST repos/OWNER/NAME/pulls/N/comments/COMMENT_ID/replies -f body="..."   # works
gh api -X POST repos/OWNER/NAME/pulls/comments/COMMENT_ID/replies -f body="..."     # 404
```

Also from that session: **GraphQL `requestReviews` cannot resolve the Copilot bot id**, so the REST `requested_reviewers` call above is the only working request path — do not spend time on the GraphQL route. And on a fork PR from a first-time contributor, the workflow run parks in `action_required` until `gh api -X POST repos/OWNER/NAME/actions/runs/RUN_ID/approve`, which is easy to mistake for a stuck gate.

## When to run it — check before asking anything

Copilot reviews on **PR opened (non-draft)**, **ready_for_review**, and **every push** — but only when the repository has a branch ruleset with *Automatically request Copilot code review* and *Review new pushes* enabled. Without the ruleset, nothing is automatic and every round must be requested.

Check the PR state first (`gh pr view N --json isDraft,headRefOid`), then:

| PR state | Do |
|---|---|
| **Draft** | Copilot will not review. Do **not** poll — it can only time out. Say so and offer `gh pr ready N` (that marks it ready and, under the ruleset, triggers the first round). |
| **Just opened ready, or just pushed, repo has the ruleset** | A round is already running. Launch the poller immediately — do **not** ask whether to wait. |
| **Repo has no ruleset, or the ruleset lacks "Review new pushes"** | No round is running. Launch the poller with `--request`. |
| **No new commit since the last verdict** | No new round exists. Re-polling would re-read the same verdict. Don't. |

The mode question below is asked **once per PR**, not once per round.

### Enabling the automatic ruleset for a repo

One-time per repo, so every later round matches the old Codex behaviour:

```bash
gh api repos/OWNER/NAME/rulesets -X POST --input - <<'JSON'
{"name":"copilot-auto-review","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
 "rules":[{"type":"copilot_code_review",
           "parameters":{"review_on_push":true,"review_draft_pull_requests":false}}]}
JSON
```

Requires a Copilot Pro, Pro+ or Max plan. Verify with `gh api repos/OWNER/NAME/rulesets`.

**Observed working:** on sepia#255 (reported by `sepia-aa`, 2026-09-17) a push with no `--request` was auto-reviewed within about 4 minutes under this ruleset. A manual `--request` on a PR with no new push also still works, so the two paths coexist.

There is also an account-wide switch (profile → Copilot settings → *Automatic Copilot code review* → Enabled), but read its scope literally: **"all the pull requests you've created"** — it covers only PRs *you* opened, never a contributor's. A repo that takes outside PRs needs the ruleset; the account switch cannot substitute. Whether the account switch also re-reviews on push is unverified here — it exposes no `review_on_push` option, and the sepia evidence above is a ruleset observation, not an account-switch one.

## Mode selection — ask once

Ask which mode to run (use `AskUserQuestion` when available). Skip the question if the request already states the mode ("loop until clean", "just check once") or if a mode was already chosen for this PR.

| Mode | Behavior |
|---|---|
| **Auto loop** (comment + resolve + keep tracking) | Full cycle without further prompts: wait → triage each finding as fix / defer / reject (see Triage) → apply fixes (batched into one commit, one green gate) → reply to each comment → resolve addressed threads → push (triggers a fresh review under the ruleset; otherwise re-request) → wait again. Budget: 2 rounds; extend only for a new critical/high confirmed finding, hard cap 4. Budget hit with suggestions remaining → stop and report. |
| **Single run** | Wait once, classify, print the verdict and any comments, stop. The user decides what happens next. |

> Choosing auto loop is explicit authorization to reply, resolve threads, and push fix commits on this PR until the loop ends. Merging, force-pushing, or closing the PR still needs its own approval.

## Run it

Run the poller in the **background** (so you are not blocked; you get notified when it exits). Invoke it by its **absolute path** and keep your working directory in the git repo you are reviewing:

```
bash <skill-dir>/scripts/poll-copilot.sh [PR_NUMBER] [--repo OWNER/NAME] [--timeout 900] [--interval 20] [--request]
```

Use `run_in_background: true`. `PR_NUMBER` is optional (defaults to the current branch's PR). Omitting `PR_NUMBER` resolves the current branch's PR, and that only works from inside the target repository: `--repo` (or `GH_REPO`) names a repository the current branch says nothing about, so the two cannot be combined and passing `--repo` without a number is refused.

> **If that command fails with `No such file or directory` and exit 127**, the
> path you ran is not where this file was loaded from. `<skill-dir>` means the
> directory holding *this* `SKILL.md`, whatever that is on your machine — it is
> not a fixed location, and substituting a remembered one is the most common
> way to reach 127.
>
> Two causes, and the second is now the likelier of the two:
>
> - **A stale symlink.** The three skill directories moved from the repository
>   root into `skills/` in v0.2.2, so a `~/.claude/skills/` symlink created
>   before that points at a path which no longer exists. A dangling skill
>   symlink does not announce itself: `ls` still lists the name and the skill
>   still appears in the loaded set, because the link itself is intact.
> - **The skill now loads from a package install.** When the package is
>   installed by any of the routes in the README, the symlink under
>   `~/.claude/skills/` is meant to be removed — one skill, one source. The
>   skill keeps loading and `<skill-dir>` keeps resolving, from the package's
>   own directory. A command that hardcodes `~/.claude/skills/<name>/scripts/`
>   then points at a directory that no longer exists, while everything else
>   about the skill works.
>
> If you were told to re-create the symlink, check first whether the package is
> installed. Doing both gives one skill two sources, which is the condition this
> repository's ledger is about.
>
> It fails closed either way: the script never ran, so no verdict was produced
> and nothing can have been passed on one.


**Resolving the repo:** the script auto-detects the repo from the current directory — but only when that is the target git repo. Do **not** `cd` into the skill dir to run it. If your working directory is not the repo, pass **`--repo OWNER/NAME`** (or export `GH_REPO`). Either one also makes `PR_NUMBER` mandatory: the current branch is evidence about the repository you are standing in and about no other, so the poller refuses a repository override with no number rather than resolving a branch name against a repository it does not belong to.

**Requesting manually** (what `--request` does, if you need it by hand): the `[bot]` suffix is mandatory; without it the API returns 422 *"Reviews may only be requested from collaborators"*.

```bash
gh api repos/OWNER/NAME/pulls/N/requested_reviewers -X POST \
  -f 'reviewers[]=copilot-pull-request-reviewer[bot]'
```

A 200 comes back with an **empty** `requested_reviewers` array — Copilot does not appear in that list, so do not read the response body as failure. Confirm it landed on the timeline instead:

```bash
gh api "repos/OWNER/NAME/issues/N/timeline?per_page=100" \
  -q '.[] | select(.event=="review_requested") | "\(.requested_reviewer.login) \(.created_at)"'
```

There is **no comment form** of this — `@copilot review` in a PR comment does not request a review.

When the poller completes, read the output file. The last line is the verdict:

| Result | Meaning | Next step |
|---|---|---|
| `RESULT=CLEAN` | A Copilot review of the head commit matching a verified clean shape (`### 🟢 Approval recommended`, `Comments generated: 0`, `Files reviewed: N/N`), no inline comments, no suppressed section, and nothing undispositioned from another reviewer | The review gate is met. Merge (do not merge before this). |
| `RESULT=OTHERBOT` | Copilot is clean, but this PR carries undispositioned findings belonging to a reviewer this gate does not read — unresolved threads, or findings in that reviewer's review body, which create no thread | **Not a pass.** Open the PR and read that reviewer's output. Measured on `NyanCogs#29`: CodeRabbit auto-review disabled there, triggered by hand anyway, 8 inline findings, three on lines Copilot never touched. |
| `RESULT=SUPPRESSED count=N` | Review of head, no inline comments, but N findings withheld into the body (printed above the result line) | **Not a pass.** Triage the N findings as fix / defer / reject like inline ones. Fixing any of them means a push and a fresh round. |
| `RESULT=SUGGESTIONS count=N` | N inline comments on the head commit (printed above the result line) | Auto loop: triage → fix → reply → resolve → push → wait again, within budget. Single run: print the comments and stop. |
| `RESULT=MISCOUNT claimed=N counted=M` | Copilot's own body reports N findings for this commit; M were found on it | **Not a pass.** The gap is the finding. Some live in sections that never become inline comments — `Previously missed` covers code unchanged since the last review. |
| `RESULT=UNREAD format=X` | A review format with no known clean shape, currently `ccr-overview-v2` | **Not a pass.** No clean example of this format has been observed, so an empty finding count proves nothing. The body is printed for a person to read. |
| `RESULT=NOT_REVIEWED reason=quota fallback=coderabbit` | Copilot reviewed nothing because the quota ran out; the script prints the two commands to run | **Switch reviewers. Do not wait, do not merge.** Post `@coderabbitai review`, then poll with `coderabbit-review-wait` and read the clean pass from THAT skill — the two gates define it differently and carrying this one's logic across fails silently. |
| `RESULT=NOT_REVIEWED` | The deadline passed with Copilot's last review still carrying no `### <status>` line, and the body was **not** the quota message. Non-quota non-verdict bodies do not end the poll on sight — only the quota case is terminal — so this means the body never became a verdict, not that one may still arrive | **Not a pass, and not a timeout either.** This is not evidence of quota exhaustion; that case carries `reason=quota` and its own row above. Read the body the script printed — it is the only thing that says what Copilot actually returned — then either request a fresh review and poll again, or, if the body is a format this gate should recognise, add it and say so in `docs/fail-open-ledger.md`. |
| `RESULT=TIMEOUT` | No review in time | Check the PR is not a draft, and that the review was actually requested (timeline query above). Otherwise Copilot is slow or the account lacks a plan with code review. A quota exhaustion does **not** land here — Copilot submits a review object saying so, which is `NOT_REVIEWED`. |
| `RESULT=ERROR ...` | Could not resolve repo/PR or `gh`/`jq` missing | Fix the precondition and retry. |

## Triage: fix / defer / reject

Disposition every finding **from the whole-plan view, not from the flagged line**. Before deciding, zoom out: re-read the PR's intent, the plan/spec it implements, and the un-diffed code around the finding. Reviewers set the defect list, never the agenda — judge the finding against the plan, not the plan against the finding.

Copilot labels each comment **High / Medium / Low** severity. That label is the reviewer's confidence in its own finding, not your priority — a High on a line the plan deliberately wrote that way is still a reject.

| Disposition | When | Then |
|---|---|---|
| **Fix** | Real defect, in scope, and the fix serves the plan | Batch into the round's commit, reply with what changed, resolve |
| **Defer** | Real but outside this PR's scope or plan phase | Reply with rationale, open a follow-up if worth tracking, resolve |
| **Reject** | Refuted by evidence — a guard the reviewer missed, a premise that doesn't hold | Reply with the counter-evidence (not "looks fine"), resolve |

Tunnel-vision check before each fix: does the change still serve the PR's goal, or does it merely satisfy the comment? A fix that satisfies the comment but distorts the design — patches the wrong layer, adds guard code exceeding what it guards, creeps the scope — is a defer or reject, not a fix.

**Copilot repeats itself.** GitHub documents that a re-review may raise the same comment again even after you resolved or downvoted the thread. A repeated comment is not a new finding and does not extend the round budget; reply once with a pointer to the earlier resolution and resolve it.

## Divergence: when to stop fixing and change method

The budget above caps effort. It does not tell you the loop is failing, and a loop that finds something every round *looks* like diligence. Ask a different question after every third round:

**Of the findings so far, how many were introduced or left incomplete by a previous round's fix?**

Keep that count from round one; it is the only cheap diagnostic and it is invisible if you don't. **Majority self-inflicted means the loop is diverging, not converging** — each fix is producing the next defect, and more rounds will not end it. Two more signals point the same way: findings clustering in one file or one boundary (platform API, serialization, filesystem) rather than spread across features, and the same rule turning out to be stated in several places.

When that fires, stop point-fixing and change method:

1. Send a **whole-directory** read-only review — not "verify this finding". Give it the full history of every round and ask explicitly for what a point-by-point reviewer cannot see: which surfaces disagree about the same thing, which rule has more than one home, what the enumerated failure modes are and what the user actually receives for each.
2. Act on the structural cause, usually one of two: **the code that keeps breaking has no test**, or **there is no single answer to "what was this asked to do"** and several places re-derive it.
3. **Turn the throwaway probes into tests.** If each fix was verified by a script that proved one thing and was deleted, every round starts from zero and nothing you did made the next defect cheaper to find. That is the actual mechanism of non-convergence.
4. Only then resume the loop.

Two things that came out of doing this on a real branch (13 rounds; 8 findings with 5 self-inflicted, then a structural pass, then 4 findings with 0 self-inflicted, then clean):

- **A redundant check that can be false is a second failure mode, not a second line of defence.** When a fix makes an older guard unnecessary, delete the older guard. Keeping "belt and braces" cost a user-visible false negative. The clean round arrived after a subtraction.
- **Tests hold behaviour; they do not hold whether a message is useful to the person reading it.** Two late findings were correct behaviour with a message naming the wrong token. Nothing automated catches that — it still needs a reader.

## Replying to Copilot

Keep replies **technical only**: state what changed and why. No praise, no affirmation openers ("right", "correct", "yes", "good catch", "thanks"); lead with the change.

**A claim in a reply needs the same evidence as a claim in the code.** Saying "stale logs are handled" because a `File.Exists` check was added asserts something the check does not do. Write what the change actually establishes, not what it was aimed at — a reply is where an unverified belief gets recorded as settled.

### Resolving threads (auto loop)

List unresolved threads with their IDs, then resolve each one **after** replying — never resolve silently:

```bash
gh api graphql -f query='query{repository(owner:"OWNER",name:"NAME"){pullRequest(number:N){reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{path body}}}}}}}'
gh api graphql -f query='mutation{resolveReviewThread(input:{threadId:"THREAD_ID"}){thread{isResolved}}}'
```

## Notes

- Both halves of the verdict are keyed to the current head commit: the review by its `commit_id`, inline comments by their `original_commit_id`. A prior round's review is ignored, so re-running after a push waits for the *new* round rather than replaying the old verdict.
- Requires `gh` (authenticated) and `jq`.
- `codex-review-wait` is dormant (subscription paused since 2026-09-17). `coderabbit-review-wait` is live for the ten-stars-and-up repositories. The three gates differ: Codex's was a `+1`, Copilot's is an empty inline set with no suppressed section, CodeRabbit's is an unresolved-finding count of zero with no collapsed bucket and no failed pre-merge check.
