---
name: coderabbit-review-wait
description: Wait for the CodeRabbit PR reviewer (coderabbitai[bot]) to finish reviewing a pull request, then classify the outcome as a clean pass, nitpicks-only, or suggestions (inline findings, printed for you to address). A clean pass needs an explicit positive completion marker at the head commit - an APPROVED review, or a body saying 'No actionable comments were generated' or 'Actionable comments posted: N', or a collapsed findings section - AND no inline findings, no CHANGES_REQUESTED, no collapsed findings section, no failed pre-merge checks, and nothing undispositioned from a second reviewer. Absence of findings is never a pass on its own: with no completion marker the poller keeps waiting rather than concluding. Findings belonging to a reviewer this gate does not read are OTHERBOT, not clean - a second reviewer can be triggered onto any pull request by hand whatever the star-count routing says, and its findings may sit in its review body where they create no thread. Before starting, asks the user to pick a mode - auto loop (fix, reply, resolve threads, push, and keep tracking until clean or budget) or a single wait-and-report run. Use right after opening a non-draft PR, marking one ready, or pushing to a PR branch - CodeRabbit auto-reviews on open and updates on every push, so poll without asking again. Drafts are skipped by default, so do not poll one. Optionally takes a PR number; otherwise it uses the current branch's PR and auto-detects the repo. Covers the repositories at or above ten stars only - sepia, pilotfish, coralline, TokenBar, remora-cc, Syrtis-Windows, calico-claude. The five under ten stars (tokscale-core, NyanCogs, pilotfish-grok, homebrew-tokenbar, Syrtis-Agent) are reviewed by GitHub Copilot instead; use copilot-review-wait there.
---

# Wait for CodeRabbit review

CodeRabbit (`coderabbitai[bot]`) reviews a PR automatically when it is opened and updates its review on every push. This skill polls until a review lands on the current head commit and classifies it.

## Which repositories this covers

| Repositories | Reviewer | Skill |
|---|---|---|
| `sepia`, `pilotfish`, `coralline`, `TokenBar`, `remora-cc`, `Syrtis-Windows`, `calico-claude` — 10 stars and up | **CodeRabbit** | this one |
| `tokscale-core`, `NyanCogs`, `pilotfish-grok`, `homebrew-tokenbar`, `Syrtis-Agent` — under 10 stars | **GitHub Copilot** | `copilot-review-wait` |

CodeRabbit's OSS tier: *"For public repositories with less than 10 stars, CodeRabbit requires reviews to be triggered manually."* Automatic review on those five ends with the Advanced trial on 2026-10-02, so they moved to Copilot on 2026-09-19 and set `reviews.auto_review.enabled: false` here. Check with `gh api repos/OWNER/NAME -q .stargazers_count` rather than assuming; a repository crossing ten stars can move back.

## Rate limits are the constraint that bites an auto loop

Observed on `sepia#264`, 2026-09-19:

> Your included review limit is currently reached under our Fair Usage Limits Policy. This review may still proceed through usage-based billing if eligible. **Your next included review will be available in 13 minutes.**

So the limit throttles rather than drops — but a poll waiting on a review that has not been admitted yet looks exactly like a slow one.

| Plan | PR reviews / hour |
|---|---|
| OSS | 1–10, varying by star count, **scoped per repository** |
| Team | 8 |
| Advanced (the trial here, until 2026-10-02) | 10 |

**Every round counts**, including automatic incremental reviews after a push and manual `@coderabbitai review` commands. Polling itself is free — `poll-coderabbit.sh` only reads — but `--request` is not.

An auto loop over several PRs is the way to exhaust this. Twelve PRs at two to four rounds each consumed the hourly allowance in one sitting here. Two consequences worth holding:

- **`auto_pause_after_reviewed_commits: 0` removes the only built-in brake.** It was set to 0 across these repositories to stop a silent pause being read as a timeout — which is real — but the pause is also what stops one runaway pull request eating an hour's allowance. Setting it near the hourly limit (10) keeps both properties: far above the longest observed loop of four rounds, and bounded by what an hour affords.
- **A `TIMEOUT` may be a throttle, not a slow review.** Before treating one as a stuck run, check the PR's latest `coderabbitai[bot]` comment for the Fair Usage notice; it names the minutes remaining.

## What a pass means here

The gate works in both of CodeRabbit's modes, and does not need to know which is on. With `request_changes_workflow: true` CodeRabbit uses **GitHub's native review states** (`APPROVED` / `CHANGES_REQUESTED`), which is sturdier than parsing text; with it off, every review is `COMMENTED` and the finding count carries the verdict. Either way the script keys on the inline finding set plus `CHANGES_REQUESTED`, so it does not silently change meaning when the setting is flipped.

Here it is **off**, and `@coderabbitai configuration` on Syrtis-Windows#112 showed why: all 171 keys reported `# Source: defaults`. It had never been set anywhere, rather than set and not taking effect.

**Configuration is read from the PR's own branch, not the default branch.** Measured 2026-09-19 across twelve PRs that added a `.coderabbit.yaml`: every review reported `Configuration used: Repository: <owner>/<repo>/.coderabbit.yaml` while the file existed only on the feature branch. A configuration PR therefore tests itself, and a broken one breaks its own review before it can be merged.

**A repo-level file is the only home available to a personal account.** Global Overrides sits under Organization Settings and does not exist for a personal GitHub user, which `gh api users/<name> -q .type` answers in one call — check that before recommending it.

**`request_changes_workflow: true` enforces nothing on its own.** It makes CodeRabbit post `CHANGES_REQUESTED` instead of `COMMENTED`, but without branch protection requiring an approving review, GitHub still allows the merge. Check with `gh api repos/O/R/branches/<default>/protection` before treating it as a gate; on all seven main repositories here it was a visual marker and nothing more.

| | Codex (dormant) | Copilot (active, under 10 stars) | CodeRabbit (active, 10 stars and up) |
|---|---|---|---|
| Clean pass | `+1` reaction | review of head with zero inline comments | a **positive completion marker** at head (`APPROVED`, a verdict phrase, or a collapsed findings section) **and** no inline findings, no `CHANGES_REQUESTED` and no collapsed section (with `request_changes_workflow: true` that review is an **`APPROVED`** one), and nothing undispositioned from a second reviewer (see `RESULT=OTHERBOT`) |
| Findings | inline comments | inline comments | `CHANGES_REQUESTED`, or inline findings at head |
| Re-trigger | push only | push (ruleset) or REST request | push, or comment **`@coderabbitai review`** — a comment genuinely works here, unlike Copilot |

### Measured shapes (2026-09-19, public PRs)

Taken from `ubiquity/ai.ubq.fi#338`, `pysnmp/pysmi#328`, `narnaud/git-loom#274`:

1. **One login for everything.** The review *and* its inline comments are both `coderabbitai[bot]`. This is **not** the Copilot shape, where the review and the comments carry two different logins — do not port that filter over.
2. **An `APPROVED` review has an empty body** (`body_len=0`). A pass cannot be recognised from body text; read `.state`.
3. **A `COMMENTED` review's body opens with `**Actionable comments posted: N**`**, and N matched the real finding count. Use it as a free cross-check on your filter.
4. **`in_reply_to_id` separates findings from CodeRabbit's own replies.** Both live in `/pulls/{n}/comments`. On pysmi#328 one line carried two `coderabbitai[bot]` comments: the finding (`in_reply_to_id: null`) and an auto-reply pointing at it. Counting both reports 2 findings for 1, and since every round adds replies, an auto loop counting them never converges.
5. **Drafts are skipped.** CodeRabbit posts a "Draft PR not reviewed" comment instead of reviewing. `reviews.auto_review.drafts: true` changes that.
6. **A PR whose base is not the default branch is skipped too** — "Auto reviews are disabled on base/target branches other than the default branch" (observed on `Nanako0129/sepia#258`). This bites stacked PRs, where each one targets its parent rather than `main`. Either widen `reviews.auto_review.base_branches` or trigger each stacked PR by hand with `@coderabbitai review`. Poll such a PR without triggering and you get a `TIMEOUT` that looks like slowness rather than a skip.

7. **A clean pass can arrive with NO review object at all.** On `Nanako0129/Syrtis-Windows#112` the `CodeRabbit` status check went `SUCCESS`, the PR carried **zero reviews**, and the verdict — "No actionable comments were generated in the recent review. 🎉" — was an **issue comment**. A poller that requires a review times out on this and reports "no review" for a PR CodeRabbit finished and passed. The verdict comment names its range ("...between `<base>` and `<head>`"), so the full head sha appearing in the body keys it to the commit as precisely as `commit_id` keys a review.
8. **The `CodeRabbit` status check is not the verdict.** Measured on the same pair, minutes apart: #112 had the check `SUCCESS` with zero reviews, while #113 had three reviews already posted with the check still `PENDING`. It is wrong in both directions — never gate on it.
9. **It waits for your other CI.** The documented CI/CD pipeline-analysis sequence is: pipelines run → CodeRabbit waits for results → it reads failure logs → it posts root-cause fixes on the failing lines. Measured end to end on #112: about **7–8 minutes** from check start to `SUCCESS`, on a repo with a multi-target Windows build matrix. So review latency is floored by the slowest CI job, and the default `--timeout 900` is thin for a big matrix. The only knob in the resolved configuration is `reviews.tools.github-checks.enabled` (default `true`); turning it off removes the wait and the failure analysis together. **There is no `timeout_ms`** — third-party guides still show one, but a full 171-key resolved config dump (Syrtis-Windows#112, 2026-09-18) contains no `timeout` key anywhere, which also explains why the observed wait ran to 7–8 minutes rather than capping at the 90s those guides quote.

### Defaults that shape the loop

From the full resolved config (`@coderabbitai configuration`, Syrtis-Windows#112, 2026-09-18 — all 171 keys sourced from `defaults`):

| Key | Default | Why it matters |
|---|---|---|
| `auto_pause_after_reviewed_commits` | `5` | **Auto review pauses after 5 reviewed commits on a PR.** A long fix loop silently stops getting reviewed and the poller then reads as `TIMEOUT`. Set it to **`0`** to disable the pause — that is the schema's documented sentinel ("Set to 0 to disable"). Its `maximum` is `9007199254740991`, so a large hand-picked number is neither a ceiling nor a bound, just an unmeasured guess. |
| `fail_commit_status` | `false` | This is *why* the `CodeRabbit` status check is green regardless of findings. Set it `true` if you want the check itself to go red. |
| `base_branches` | `[]` | Empty means default branch only, which is what skips stacked PRs. |
| `drafts` | `false` | Drafts skipped. |
| `auto_incremental_review` | `true` | Each push reviews only the new commits; CodeRabbit will not re-review commits it has already seen. |
| `request_changes_workflow` | `false` | No `CHANGES_REQUESTED`; every review is `COMMENTED`. |

`@coderabbitai configuration` prints every key with a `# Source:` comment (`defaults`, `UI settings`, `global overrides`, repo YAML). It is the only way to know what is actually in force — a dashboard toggle that never reached the run looks identical to one that was never set.

**A skip leaves no review, only an issue comment.** So "is CodeRabbit active on this repo?" cannot be answered by looking at `/pulls/{n}/reviews` — a skipped PR looks identical to an uninstalled app. Check `/issues/{n}/comments` for `coderabbitai[bot]` as well.

### Never infer a pass from absence

This is the rule the whole classifier turns on, and it was learned by breaking it. An earlier version treated *"a `coderabbitai[bot]` comment naming the head sha, and no inline findings"* as clean. On `Nanako0129/TokenBar#349` it reported `RESULT=CLEAN` while CodeRabbit was **still running** — caught by the `tokenbar-native-b7` session on the skill's first real use here. The in-progress notice names the head sha, carries no findings *yet*, and there is no review object, so under that logic it was indistinguishable from a finished clean pass.

**Three reviewers, three times a wrong-shaped gate reported success.** Codex → Copilot (wrong login filter matched nothing → clean verdict on 3 findings) → CodeRabbit (absence read as a pass). Every one failed *open*.

So a verdict requires an explicit **positive completion marker**, never the absence of findings:

| Signal in the head-keyed comment | Meaning |
|---|---|
| `No actionable comments were generated` | Complete, clean |
| `Actionable comments posted: N` | Complete, N findings |
| `Currently processing new changes in this PR` | **Underway — keep polling.** Overrides everything else; CodeRabbit edits this one comment in place as the run proceeds (created 19:17:22, updated 19:40:09, one comment, not one per round). |
| `Review skipped` | Skipped, not reviewed |
| A review object at head that **says something** — `state: APPROVED`, or a body carrying one of the two phrases above | Complete |
| A review object at head with an **empty body and `state: COMMENTED`** | **Not a verdict — keep polling.** CodeRabbit emits one of these per human reply in a review thread. See below. |
| none of the above | Unknown — keep polling, never guess |

**An empty review object is not a review.** When a human replies in a review thread, CodeRabbit answers each reply with its own review object: `state: COMMENTED`, body length 0, no verdict text, keyed to the head commit. Measured on `Nanako0129/pilotfish#85` at head `93eee6b` (found by the `pilotfish-71` session, reproduced here):

```
id=5254044474  state=COMMENTED  len=0     01:46:53   <- answer to a reply
id=5254045301  state=COMMENTED  len=0     01:47:08   <- answer to a reply
id=5254055908  state=COMMENTED  len=1947  01:50:30   <- the real review
```

The real one arrived three and a half minutes later carrying `Actionable comments posted: 1` and a genuine unresolved finding. An earlier version treated any review at head as completion, converged on the empty pair, and reported a pass over that finding; the user caught it by opening the PR page. **That is the fifth fail-open in this family** — Codex, Copilot's login filter, CodeRabbit's absence-as-pass, silent resolves, and now structural presence read as semantic completion. Every one of them failed towards "passed".

Note that "empty body" cannot be the test on its own: an `APPROVED` review legitimately has `body_len=0` under `request_changes_workflow: true`. Read state *and* body together, as the table above does. A corroborating signal, if you need one: those answer-reviews carry only comments with `in_reply_to_id` set, so a review whose comments are all replies is not a review round.

A `⚙️ Run configuration` block is **not** a skip marker: the skip notice, the in-progress notice and the finished verdict all carry one. Anything keying on it to detect a skip fires on a run that is merely underway.

## The hidden-findings rule, carried over

Copilot parked low-confidence findings in a `Suppressed comments` body section that never touched the comment count. On `sepia#250` that produced **four consecutive clean verdicts over 8 real defects**. CodeRabbit has the same shape available — collapsed `Nitpick comments (N)`, `Outside diff range comments (N)`, `Duplicate comments (N)` sections — so the same rule applies from day one instead of being learned again:

**A review with a collapsed findings section is never reported as CLEAN.** It gets `RESULT=NITPICKS count=N` and the section is printed.

A fourth collapsed section belongs in the same bucket although it holds no findings at all: **`🚧 Files skipped from review as they are similar to previous changes (N)`**. It is a *coverage* gap — CodeRabbit's equivalent of Copilot's `Files reviewed: 4/5` — and a zero finding count over a file nobody read says nothing. Measured on `Syrtis-Windows#115` (2026-09-19): one skipped file, zero inline findings, no failed pre-merge check, and the gate reported `CLEAN`. It now reports `NITPICKS count=1`.

The bucket list lives in exactly one place, `HIDDEN_RE` at the top of `scripts/poll-coderabbit.sh`, and every site that needs it reads that variable. It used to be spelled out separately at two sites, which is how #115's section came to be recognised at neither.

### CodeRabbit has a second such bucket: pre-merge checks

Found on `Nanako0129/TokenBar#330` by the `tokenbar-native-bc` session and reproduced here: completion marker present, inline findings **0**, no collapsed findings section — and in the same comment:

```
🚥 Pre-merge checks | ✅ 4 | ❌ 1
❌ Docstring Coverage | ⚠️ Warning
   57.14%, required 80.00%. Scoped to functions touched by this diff.
```

Pre-merge checks are not findings and never move the finding count, so they were invisible to the gate. That is **four buckets across three reviewers** — Codex, Copilot's `Suppressed comments`, CodeRabbit's collapsed sections, and now CodeRabbit's pre-merge checks. Assume the count is never the whole verdict.

A failed check is a **disposition for a human, not an automatic block**, so it withholds CLEAN rather than failing: `RESULT=PREMERGE count=N`, with the failed rows printed.

**Parse the tally, never the rows.** Measured on `TokenBar#350` (reported by `tokenbar-native-b7`): the failed row's Status cell reads `⚠️ Warning` and the heading counts `(1 warning)` — the ❌ appears only in the `✅ N | ❌ M` tally and the section heading. A parser looking for ❌ inside the row finds nothing and reports a pass. CodeRabbit counts a warning as failed; match that.

Confirmed on two PRs (`#330` Docstring Coverage, `#350` Linked Issues check). Not every failed check is about code — `#350`'s was PR/issue traceability — but the same slot can carry one that is, and a gate does not get to assume which.

**`Docstring Coverage` on an outside contribution is usually a Defer.** Its denominator is every function the diff *touched*, not the functions it added. On #330 a contributor's five-line pure function inherited three pre-existing undocumented functions and scored 57%. Holding a contributor to a threshold the repository has never met itself applies the standard to the wrong person.

**Verified 2026-09-19 on `Nanako0129/TokenBar#349`** (review `5251978349`, commit `0358ffd5`). The review body opened with:

> ⚠️ **Some comments are outside the diff and can't be posted inline due to GitHub limitations.**
> **Outside diff range comments (1)**

That review carried **zero** inline comments; the finding existed only in the body. The detection returns `RESULT=NITPICKS count=1` on it.

**The mechanism matters more than the count.** GitHub's review-comment API can only anchor an inline comment to a line inside the PR's diff hunks. A finding about a line the PR did not touch is rejected, so CodeRabbit parks it in the body. That biases the invisible bucket toward exactly the findings worth most: the ones about how the change interacts with code that did *not* change. A gate that counts only inline comments is therefore not merely incomplete — it is selectively blind to the higher-value half.

### Two things a re-request will not fix

*Both observed by the `pilotfish-71` session on `pilotfish#85` and `#86`, 2026-09-19; not independently reproduced here.*

**`@coderabbitai full review` does not clear `Files skipped from review as they are similar to previous changes`.** Three attempts across two PRs, and each time the skipped file was exactly the one file that round had changed — so the fix itself was never read. Re-requesting is not the remedy; read the skipped file yourself and say so. This is the bucket most likely to be mistaken for noise, because its name sounds like deduplication rather than a coverage hole.

**`You've used all 10 included reviews currently available.` appeared in review bodies while reviews still ran.** So it is not currently a hard stop. But if it ever becomes one, the symptom is *no new review* — which is the same shape as everything else in this file: an absence that reads as a pass. If a poll times out, check the latest `coderabbitai[bot]` body for that line and for the Fair Usage notice before calling it a slow review.

## Run it

```
bash <skill-dir>/scripts/poll-coderabbit.sh [PR_NUMBER] [--repo OWNER/NAME] [--timeout 900] [--interval 20] [--request]
```

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

Use `run_in_background: true`. Keep the working directory in the target repo, or pass `--repo`. Omitting `PR_NUMBER` resolves the current branch's PR, and that only works from inside the target repository: `--repo` (or `GH_REPO`) names a repository the current branch says nothing about, so the two cannot be combined and passing `--repo` without a number is refused. `--request` posts `@coderabbitai review`; it is **not** needed after a push, since CodeRabbit re-reviews new commits on its own.

| Result | Meaning | Next step |
|---|---|---|
| `RESULT=CLEAN` | A **completed** review at head — an explicit positive completion marker, never merely the absence of findings — with no inline findings, no collapsed section, no `CHANGES_REQUESTED`, and nothing undispositioned from another reviewer | Gate met. Merge. |
| `RESULT=NITPICKS count=N` | Otherwise clean, but a collapsed body section holds N findings — or N files that were skipped from review (printed above) | **Not a pass.** Triage them, then push and re-poll. A skipped file is a coverage gap: read it yourself or re-request a review of it. |
| `RESULT=PREMERGE count=N` | Otherwise clean, but N pre-merge checks failed (printed above). A body carrying both a collapsed section and a failed check prints both blocks and reports `NITPICKS` | **Not a pass.** Disposition each; a failed check is often a legitimate Defer. |
| `RESULT=MISCOUNT claimed=N counted=M` | CodeRabbit's body reports N actionable comments for this commit; only M were found on it | **Not a pass.** Something it posted is not being counted. The gap is the finding — and this is the one signal here that moves when the vendor changes its output format, which every regex in the script silently will not. |
| `RESULT=UNREPLIED count=N` | N resolved threads carry no human reply, so nothing records a decision about them | **Not a pass.** Reply with the disposition, then resolve. A thread closed silently is an absence, and this gate never infers a pass from absence. |
| `RESULT=OTHERBOT` | CodeRabbit is clean, but this PR carries undispositioned findings belonging to a reviewer this gate does not read — an unresolved thread, or a finding in that reviewer's own review body, which creates no thread at all | **Not a pass, and the distinction matters:** a clean verdict here means *CodeRabbit* found nothing, not that the PR is clean. The star-count routing does not prevent this — a second reviewer can be triggered onto any PR by hand or by the checkbox in a paused-review notice, leaving no trace this poller reads. Measured on `NyanCogs#29`: CodeRabbit auto-review disabled there, triggered anyway, 8 inline findings, three on lines Copilot's first round never touched. Open the PR, read that reviewer's output, disposition each finding. |
| `RESULT=SUGGESTIONS count=N` | N inline findings at head, or `CHANGES_REQUESTED` | Triage → fix → reply → resolve → push → poll again, within budget. |
| `RESULT=TIMEOUT` | No review of head in time | Check the PR is not a draft and that CodeRabbit is installed on the repo. |
| `RESULT=ERROR ...` | Draft PR, or could not resolve repo/PR/tools | Fix the precondition and retry. |

Both halves of the verdict are keyed to the head commit — the review by `commit_id`, findings by `original_commit_id` — so re-running after a push waits for the new round rather than replaying the old verdict.

### Resolved findings do not count

Resolving a review thread does **not** delete its inline comment. A finding that was legitimately **rejected** — replied to with counter-evidence and resolved, which is a complete disposition — therefore stays in the comment set forever, and a verdict counting it can never reach CLEAN. Measured on `NyanCogs#21`: one finding, rejected with reasoning and resolved, returned `SUGGESTIONS count=1` on every subsequent poll. An auto loop would re-report that verdict until its budget ran out, with nothing left to do.

So the verdict counts **unresolved** findings. Resolved ones are printed as a separate line rather than dropped silently, because a resolve is a claim that someone dispositioned it and that claim should stay visible.

This is safe only because a resolved thread must carry a **human** reply, and that is now enforced rather than assumed. It used to rest on this skill telling you to reply before resolving, with no code checking it — while `@coderabbitai resolve` closes every thread at once with no reply anywhere. A thread resolved silently is an absence again, and the rule at the top of this file applies: never infer a pass from absence.

So: a resolved thread in which **no comment has a `User` author** is not excused, and the run prints `(N resolved thread(s) have no human reply; not excused.)`. Whether such a finding also lands in *this* round's count still depends on the head-commit keying — on `NyanCogs#23` two such threads were reported while `inline` was 0, because their comments sit on an earlier commit. Measured on `NyanCogs#20` and `#23` (2026-09-19): resolved threads whose only author is the bot. `NyanCogs#21` — rejected with reasoning, replied to, resolved — is still excused, so that loop does not come back.

The human test keys on the GraphQL actor type (`author.__typename == "User"`), never on the login spelling. **GraphQL returns a bot login without the `[bot]` suffix that REST's `.user.login` carries** — measured on `TokenBar#349`: `{"login":"coderabbitai","__typename":"Bot"}` through GraphQL, `coderabbitai[bot]` through REST. A first version of this check tested the suffix, classified every bot as a human, and excused exactly the threads it existed to catch.

### A warning about the regression cases in this file

Several of them are live public PRs. `pysnmp/pysmi#328` moved from `SUGGESTIONS` to `PREMERGE` between two runs an hour apart, not because the script changed but because that repository's maintainer resolved the thread in the meantime. A case whose expected verdict can change for reasons unrelated to the code under test is not a regression test — it is a sighting. Confirm a behaviour change with a controlled comparison (same captured payload, one input varied) before believing either the pass or the failure.

## Commands worth knowing

| Command | Effect |
|---|---|
| `@coderabbitai review` | Incremental review of changes since the last one |
| `@coderabbitai full review` | Ignores prior comments, reviews everything fresh |
| `@coderabbitai resolve` | Resolves all CodeRabbit threads |
| `@coderabbitai approve` | Resolves threads and attempts to approve |
| `@coderabbitai pause` / `resume` | Stop / restart automatic reviews |
| `@coderabbitai configuration` | Prints the resolved config for the repo |

`approve` and `resolve` must be **top-level PR comments** — CodeRabbit refuses approve commands posted as review-thread replies (observed on pysmi#328).

## Triage: fix / defer / reject

Disposition every finding **from the whole-plan view, not from the flagged line**. Re-read the PR's intent and the un-diffed code around the finding first. Reviewers set the defect list, never the agenda — judge the finding against the plan, not the plan against the finding.

CodeRabbit labels findings with a category and severity (`🩺 Stability & Availability | 🟠 Major | 🏗️ ...`). That is its confidence in its own finding, not your priority: a Major on a line the plan deliberately wrote that way is still a reject.

| Disposition | When | Then |
|---|---|---|
| **Fix** | Real defect, in scope, and the fix serves the plan | Batch into the round's commit, reply with what changed, resolve |
| **Defer** | Real but outside this PR's scope or plan phase | Reply with rationale, open a follow-up if worth tracking, resolve |
| **Reject** | Refuted by evidence — a guard the reviewer missed, a premise that doesn't hold | Reply with the counter-evidence (not "looks fine"), resolve |

Tunnel-vision check before each fix: does the change still serve the PR's goal, or does it merely satisfy the comment? A fix that patches the wrong layer, adds guard code exceeding what it guards, or creeps the scope is a defer or reject, not a fix.

## Budget and divergence

Auto loop budget: **2 rounds**; extend only for a new confirmed high-severity finding, hard cap 4. The budget counts *rounds*, not findings — do not spend it faster because one round held more work, and do not extend it for volume alone.

Ask a different question after every third round: **of the findings so far, how many were introduced or left incomplete by a previous round's fix?** Keep that count from round one; it is invisible if you don't. Majority self-inflicted means the loop is diverging, not converging — each fix is producing the next defect. Two more signals point the same way: findings clustering in one file or boundary rather than spread across features, and the same rule turning out to be stated in several places.

When that fires, stop point-fixing:

1. Send a **whole-directory** read-only review, not "verify this finding". Ask for what a point-by-point reviewer cannot see: which surfaces disagree about the same thing, which rule has more than one home, what the failure modes are and what the user receives for each.
2. Act on the structural cause — usually the code that keeps breaking has no test, or several places re-derive "what was this asked to do".
3. **Turn the throwaway probes into tests.** If each fix was verified by a script that proved one thing and was deleted, every round starts from zero. That is the actual mechanism of non-convergence.
4. Only then resume.

Two things that came out of doing this on a real branch (13 rounds; 8 findings with 5 self-inflicted, then a structural pass, then 4 findings with 0 self-inflicted, then clean):

- **A redundant check that can be false is a second failure mode, not a second line of defence.** When a fix makes an older guard unnecessary, delete the older guard. The clean round arrived after a subtraction.
- **Tests hold behaviour; they do not hold whether a message is useful to the person reading it.** Two late findings were correct behaviour with a message naming the wrong token. Nothing automated catches that.

## Replying and resolving

Keep replies **technical only**: state what changed and why. No praise, no affirmation openers; lead with the change. A claim in a reply needs the same evidence as a claim in the code — a reply is where an unverified belief gets recorded as settled.

Reply through the PR-scoped endpoint; the PR-less form 404s:

```bash
gh api -X POST repos/OWNER/NAME/pulls/N/comments/COMMENT_ID/replies -f body="..."
```

Resolve threads **after** replying, never silently:

```bash
gh api graphql -f query='query{repository(owner:"OWNER",name:"NAME"){pullRequest(number:N){reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{path body}}}}}}}'
gh api graphql -f query='mutation{resolveReviewThread(input:{threadId:"THREAD_ID"}){thread{isResolved}}}'
```

Or let CodeRabbit do it: `@coderabbitai resolve` as a top-level comment.

## Notes

- Requires `gh` (authenticated) and `jq`.
- `gh api --paginate --slurp` cannot be combined with gh's own `--jq`; pipe into `jq`. Without `--paginate` the reviews endpoint caps at 30 and a long PR hides its newest review on page 2.
- In this harness the Bash tool runs **zsh**, where `for x in $var` does **not** word-split. Iterate multi-line output with `| while read -r` instead, or loops silently process one blob.
- `copilot-review-wait` and `codex-review-wait` are dormant. If CodeRabbit is dropped, their gates differ: Copilot's was an empty inline set, Codex's was a `+1`.
