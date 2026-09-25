---
name: codex-review-wait
description: "[DORMANT: the Codex subscription is paused as of 2026-09-17, so this reviewer no longer runs. PR review is no longer split: every repository uses coderabbit-review-wait as of 2026-09-25, after Copilot's per-user quota took out its whole side at once. Check with 'gh api repos/OWNER/NAME -q .stargazers_count' and read the gate from that skill; the three define a clean pass differently and reusing another one's logic fails silently. Trigger this skill only when the user names Codex explicitly, or when the subscription is confirmed back.] Wait for the Codex GitHub PR reviewer (chatgpt-codex-connector) to finish reviewing a pull request, then classify the outcome as a clean pass (a +1 reaction) or suggestions (inline comments, printed for you to address). Optionally takes a PR number; otherwise it uses the current branch's PR and auto-detects the repo."
---

# Wait for Codex review

> **Dormant since 2026-09-17.** The Codex subscription is paused, so `chatgpt-codex-connector` no longer reviews PRs. There is now **one** active gate for every repository: `coderabbit-review-wait`. Copilot went dormant on 2026-09-25 when its per-user quota emptied its whole side at once, so the star-count split is gone too. Read the gate from the skill that covers the repository — the three define a clean pass completely differently, and reusing the previous one's logic fails silently rather than loudly. Copilot's, for reference, is a review of the head commit **whose body carries a `### <status>` line** and which left zero inline comments; the middle clause exists because a quota-exhaustion notice satisfies the other two. Everything below still applies verbatim if the subscription resumes; the triage, divergence and reply sections are reviewer-agnostic and are mirrored in both active skills.

Codex (`chatgpt-codex-connector`) signals a clean pass with a **`+1` reaction** on the PR and posts **inline comments** when it has suggestions. This skill polls until one of those appears and tells you which.

## When to run it — check before asking anything

Codex reviews on PR events: **opened (non-draft)**, **ready_for_review**, and **every push to the PR branch**. Each of those starts exactly one new review round. Nothing else does — not time passing, not a comment.

Check the PR state first (`gh pr view N --json isDraft,headRefOid`), then:

| PR state | Do |
|---|---|
| **Draft** | Codex will not review. Do **not** poll — it can only time out. Say so and offer `gh pr ready N` (that marks it ready and triggers the first round; poll after it). |
| **Just opened ready, or just pushed** | A round is already running. Launch the poller immediately — do **not** ask whether to wait. |
| **No new commit since the last verdict** | No new round exists. Re-polling would re-read the same verdict. Don't. |

The mode question below is asked **once per PR**, not once per round. After that, every push in the same session goes straight back to polling under the chosen mode. "Should I wait for Codex again?" after a push is never the right question — pushing *is* the trigger, so the answer is always yes.

## Mode selection — ask once

Ask which mode to run (use `AskUserQuestion` when available). Skip the question if the request already states the mode ("loop until clean", "just check once") or if a mode was already chosen for this PR.

| Mode | Behavior |
|---|---|
| **Auto loop** (comment + resolve + keep tracking) | Full cycle without further prompts: wait → triage each finding as fix / defer / reject (see Triage) → apply fixes (batched into one commit, one green gate) → reply to each comment → resolve addressed threads → push (auto-triggers a fresh review) → wait again. Budget: 2 rounds; extend only for a new critical/high confirmed finding, hard cap 4. Budget hit with suggestions remaining → stop and report. |
| **Single run** | Wait once, classify, print the verdict and any comments, stop. The user decides what happens next. |

> Choosing auto loop is explicit authorization to reply, resolve threads, and push fix commits on this PR until the loop ends. Merging, force-pushing, or closing the PR still needs its own approval.

## Run it

Run the poller in the **background** (so you are not blocked; you get notified when it exits). Invoke it by its **absolute path** and keep your working directory in the git repo you are reviewing:

```
bash <skill-dir>/scripts/poll-codex.sh [PR_NUMBER] [--repo OWNER/NAME] [--timeout 900] [--interval 30]
```

(`<skill-dir>` is this skill's base directory, printed at the top when the skill loads.)

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


**Resolving the repo:** the script auto-detects the repo from the current directory — but only when that is the target git repo. Do **not** `cd` into the skill dir to run it (that dir is not a repo, so `gh` fails with `RESULT=ERROR cannot resolve the repo`). If your working directory is not the repo, pass **`--repo OWNER/NAME`** (or export `GH_REPO`). Either one also makes `PR_NUMBER` mandatory: the current branch is evidence about the repository you are standing in and about no other, so the poller refuses a repository override with no number rather than resolving a branch name against a repository it does not belong to.

When it completes, read the output file. The last line is the verdict:

| Result | Meaning | Next step |
|---|---|---|
| `RESULT=CLEAN` | `+1` and no inline comments on the head commit | The review gate is met. Merge (do not merge before this). |
| `RESULT=SUGGESTIONS count=N` | N inline comments on the head commit (printed above the result line) | Auto loop: triage → fix → reply → resolve → push → wait again, within budget. Single run: print the comments and stop. |
| `RESULT=TIMEOUT` | No response in time | First check the PR is not a draft (a draft never gets reviewed). Otherwise Codex is slow or out of quota: wait for its reset, or proceed only as a documented exception per project policy. |
| `RESULT=ERROR ...` | Could not resolve repo/PR or `gh`/`jq` missing | Fix the precondition and retry. |

## Triage: fix / defer / reject

Disposition every finding **from the whole-plan view, not from the flagged line**. Before deciding, zoom out: re-read the PR's intent, the plan/spec it implements, and the un-diffed code around the finding. Reviewers set the defect list, never the agenda — judge the finding against the plan, not the plan against the finding.

| Disposition | When | Then |
|---|---|---|
| **Fix** | Real defect, in scope, and the fix serves the plan | Batch into the round's commit, reply with what changed, resolve |
| **Defer** | Real but outside this PR's scope or plan phase | Reply with rationale, open a follow-up if worth tracking, resolve |
| **Reject** | Refuted by evidence — a guard the reviewer missed, a premise that doesn't hold | Reply with the counter-evidence (not "looks fine"), resolve |

Tunnel-vision check before each fix: does the change still serve the PR's goal, or does it merely satisfy the comment? A fix that satisfies the comment but distorts the design — patches the wrong layer, adds guard code exceeding what it guards, creeps the scope — is a defer or reject, not a fix.

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

## Replying to Codex

If you reply to a Codex comment, keep it **technical only**: state what changed and why. No praise, no affirmation openers ("right", "correct", "yes", "good catch", "thanks"); lead with the change. Do **not** post a `@codex review` comment to re-trigger — pushing a commit already triggers a fresh review.

**A claim in a reply needs the same evidence as a claim in the code.** Saying "stale logs are handled" because a `File.Exists` check was added asserts something the check does not do, and the next round said so, citing that reply. Write what the change actually establishes, not what it was aimed at — a reply is where an unverified belief gets recorded as settled.

### Resolving threads (auto loop)

List unresolved threads with their IDs, then resolve each one **after** replying — never resolve silently:

```bash
gh api graphql -f query='query{repository(owner:"OWNER",name:"NAME"){pullRequest(number:N){reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{path body}}}}}}}'
gh api graphql -f query='mutation{resolveReviewThread(input:{threadId:"THREAD_ID"}){thread{isResolved}}}'
```

## Notes

- Both halves of the verdict are keyed to the current head commit: inline comments by their `original_commit_id`, and the `+1` by being newer than the head commit's timestamp. A prior round's comments and its `+1` are both ignored, so re-running after a push waits for the *new* round rather than replaying the old verdict.
- Requires `gh` (authenticated) and `jq`.
