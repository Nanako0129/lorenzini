# Fail-open ledger

Every gate bug found in this repository, in order. All five failed the same
direction: they reported **pass**.

A gate that fails closed wastes a poll. A gate that fails open merges a defect
and tells you it was fine. Only one of those is recoverable, which is why the
rule at the top of the README is stated as an absolute rather than a preference.

None of these were found by testing. Each one was caught by someone hitting it
on a real pull request.

---

## 1. Codex → Copilot: the login filter matched nothing

**2026-09-17, `Nanako0129/coralline#85`.** Reported `RESULT=CLEAN` on a review
carrying three findings.

The Copilot skill was written by adapting the Codex one. Copilot authors its
*review* as `copilot-pull-request-reviewer[bot]` but its *inline comments* as
`Copilot` — two different logins. Filtering comments by the review's login found
zero of them, on every pull request, every time.

**Shape:** a filter that matches nothing is indistinguishable from a clean
result. Both produce an empty set.

**Now:** both logins are matched explicitly, and `Comments generated: N` in the
body is used as a free cross-check — if the body says 3 and you counted 0, the
filter is wrong, not the pull request clean.

---

## 2. Copilot: findings withheld into the body

**2026-09-17, `Nanako0129/sepia#250`.** Four consecutive clean verdicts over
**8 real defects**.

Copilot parks low-confidence findings in a `Suppressed comments` body section
that never touches the inline comment count. The gate counted inline comments,
so it counted zero, four rounds running. Among the hidden defects: a flag-value
regex accepting `[A-Za-z-]+` that let `--lang de2` bypass validation.

**Shape:** the reviewer's own count is not the whole verdict. It never has been,
for any reviewer.

**Now:** any collapsed findings section withholds `CLEAN` and gets its own
verdict with the section printed in full. A notice gets skimmed; the content
does not.

---

## 3. CodeRabbit: absence read as a pass

**2026-09-19, `Nanako0129/TokenBar#349`.** Reported `RESULT=CLEAN` while
CodeRabbit was still running.

A fix for a genuine bug — a clean verdict can arrive as an issue comment with no
review object at all — was implemented as "a comment naming the head sha, and no
inline findings". The in-progress notice also names the head sha and also has no
findings yet, so it was indistinguishable from a finished clean pass.

**Shape:** fixing one fail-open by loosening a condition introduced another.
The loosened condition was again an absence.

**Now:** a verdict requires an explicit positive completion marker
(`No actionable comments were generated`, `Actionable comments posted: N`,
`APPROVED`, or `Review skipped`). `Currently processing new changes in this PR`
overrides everything. Anything else keeps polling.

---

## 4. CodeRabbit: pre-merge checks, and silent resolves

**2026-09-19, `Nanako0129/TokenBar#330` and `#350`.** Reported `RESULT=CLEAN`
with a failed pre-merge check sitting in the same comment.

A second bucket the finding count ignores. The failed row's status cell reads
`⚠️ Warning` and the heading counts `(1 warning)` — the failure marker appears
only in the `✅ N | ❌ M` tally, so a parser reading the rows finds nothing.

A related hole in the same family: resolved threads were treated as
dispositioned, on the premise that this skill requires a reply before any
resolve. Nothing enforced that premise — `@coderabbitai resolve` closes every
thread at once with no reply anywhere, and each silently-closed finding dropped
out of the count. A resolve is only a disposition when a **human** commented in
the thread, keyed on the GraphQL actor type rather than the login spelling
(GraphQL omits the `[bot]` suffix that REST carries, so testing for it
classified every bot as human — the same fail-open shape as #1).

**Shape:** the count is never the whole verdict, and a premise nothing enforces
is not a premise.

**Now:** `RESULT=PREMERGE` withholds the pass, parsing the tally rather than the
rows. Resolved threads count as open unless a human commented.

---

## 5. CodeRabbit: an empty review object is not a review

**2026-09-19, `Nanako0129/pilotfish#85`.** Reported a pass over a real
unresolved finding. Caught by the user opening the pull request page.

When a human replies in a review thread, CodeRabbit answers each reply with its
own review object: `state: COMMENTED`, body length 0, no verdict text, keyed to
the head commit. Those satisfied "a review object at head means complete".

```
id=5254044474  state=COMMENTED  len=0     01:46:53   <- answer to a reply
id=5254045301  state=COMMENTED  len=0     01:47:08   <- answer to a reply
id=5254055908  state=COMMENTED  len=1947  01:50:30   <- the real review
```

The real review arrived three and a half minutes later with
`Actionable comments posted: 1`.

The trap inside the fix: "empty body" cannot be the test on its own, because an
`APPROVED` review legitimately has `body_len=0` under
`request_changes_workflow: true`. Testing only for a non-empty body would have
broken the pass path in the other direction.

**Shape:** structural presence read as semantic completion. A review object
existing is not a review having happened.

**Now:** a review counts as a verdict only when it *says* something — `APPROVED`
state, or a body carrying a verdict phrase. State and body are read together.

---

## What the pattern is

Four of the five are the same sentence with different nouns: **an empty set was
read as a clean result.** Empty because the filter was wrong (#1), because the
findings were somewhere else (#2, #4), because the work had not finished yet
(#3, #5).

The defence is not vigilance. It is that the default answer to "I found nothing"
is *keep looking*, and only an explicit statement of completion ends the wait.
Written as code rather than as a habit, because the habit failed five times.

Two consequences worth keeping in view:

- **Fixing a fail-open can open another one.** #3 was introduced while fixing a
  real bug, and #5's fix had a symmetric trap waiting inside it. Any change to
  the completion logic needs the existing regression cases run, not just the new
  one.
- **None of these were found by the person who wrote the code.** Four came from
  other sessions or from the user; one came from the reviewer itself. Testing
  covers the shapes you already imagined, which is exactly the set that does not
  contain your next bug.
