# Fail-open ledger

Every gate bug found in this repository, in order. Several entries hold more
than one defect; no count is kept, because the last two attempts at one went
stale within a day and a reviewer caught both. Every one of them failed the same direction: it reported
**pass**, or it claimed a guard existed that did not.

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

**Now:** both logins are matched explicitly, and the reviewer's own count is
compared against ours — if the body says 3 and we counted 0, the filter is
wrong, not the pull request clean.

> **This entry was false for two days.** The cross-check was described here and
> in `SKILL.md` as done, and was not in the code. It was added on 2026-09-19
> after entry #6 found the claim, and its first implementation was dead code:
> the literal is `**Comments generated:** 3`, with the emphasis markers between
> the colon and the number, so a pattern for `Comments generated: 3` matched
> nothing. A guard that cannot fire, written while fixing guards that did not
> fire. Both are corrected; see #6.

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

## 6. The ledger itself: three gates that were never in the code

**2026-09-19.** Found by an independent fresh-context agent asked one question:
*find a sixth failure mode this ledger does not contain*. It returned REFUTED on
the claim that the gate fails closed, with four reproductions: three code paths
that reported a pass, and this file claiming a guard that was not there.

**The one that matters most is this file.** Entry #1 above claimed the reviewer's
own count was used as a cross-check. `grep -c "Comments generated"
copilot-review-wait/scripts/poll-copilot.sh` returned **0**. The claim lived in
the ledger, in `SKILL.md`, and nowhere else. It shipped to a public repository
and stayed true-looking for two days.

That is the "contract stated in N places" failure with the worst possible
occupant: the place that records what was already fixed. Every other entry here
is trustworthy only to the degree this one was, and it was not.

The other three, each reproduced against real payloads with one input varied:

| | What | Direction |
|---|---|---|
| **F1** | `comments=$(gh api ... \|\| printf '[]')` — one endpoint failing while the others succeed gives `inline=0`. Reproduced: `CLEAN` on `coralline#85` (3 findings) and `TokenBar#349` (1 finding). `--paginate` makes a second-page failure ordinary, not exotic. | **open** |
| **F3** | A resolved thread with no human reply was moved out of the *excused* set by entry #4 but never into a *blocking* one. The notice printed; the run passed. `TokenBar#349` withheld `CLEAN` only because a pre-merge check happened to fail too; varying that away, the silently-resolved finding passed. | **open** |
| **F4** | The pre-merge tally pattern required two pipes. CodeRabbit omits a zero-count field, so an all-failing tally renders as one segment and matched nothing — total failure read as no failures. | **open** |

**Now:** reads that fail are distinguished from reads that return nothing (retry,
never count zero); `MISCOUNT` withholds the pass when the reviewer's number
exceeds ours; `UNREPLIED` withholds it when a thread was closed with nobody
saying anything; the tally pattern no longer assumes a field count.

**Shape:** a fix believed to be in place is worse than a known gap. A known gap
gets watched.

**What it says about the other entries:** none of them were verified by their
author after being written. The three that were real had been caught by someone
else hitting them. The one that was fiction survived because nobody re-read the
code it described — including, twice, the person who wrote both.

---

## 7. Copilot changed its body format, and the gate did not notice

**2026-09-19, `Nanako0129/lorenzini#1`.** Reported `RESULT=CLEAN` on a review
that said *"Needs a closer look"* and listed four issues.

Copilot shipped a new review body (marker `ccr-overview-v2`). Every string the
Copilot gate keyed on vanished in the same stroke:

| Pattern | Occurrences in the new body |
|---|---|
| `Comments generated` | 0 |
| `Suppressed comments` | 0 |
| `Files reviewed` | 0 |

Nothing errored. The suppressed-findings gate from entry #2 and the miscount
cross-check added hours earlier in entry #6 both silently stopped applying, and
the verdict fell through to `CLEAN`.

The findings were in a per-file table cell:

> `README.md` | ... | **Two moderate issues: enforcement requirements and the
> `RESULT=CLEAN` condition are unclear. Two nits: the star-threshold wording and
> ruleset terminology are technically inaccurate.**

alongside `**Findings:** None`, which counts inline findings just as the old
count did.

**This was predicted.** The independent review recorded in entry #6 closed with
exactly this: every pattern in these scripts encodes one day's rendering, and
when the rendering moves they stop matching with no error and the gate degrades
into a machine that always says `CLEAN`. It named the reviewer's own count as
the only signal that moves when the vendor moves. That count is what disappeared.

**Shape:** a pattern that no longer matches is indistinguishable from a finding
that is not there. The fifth variation of the same empty set.

**Now:** `RESULT=TABLE` withholds the pass when the per-file table reports
anything. The Findings column is located by its **header**, not by position —
the older format's table is `| File | Description |`, and reading its last
column as findings reported a clean pull request as having one. A gate that
cries wolf on clean runs gets edited away, so a fail-closed bug is not free
either.

**What it does not fix:** the next format change. Nothing here detects that the
patterns stopped matching; it only adds one more pattern. The honest mitigation
is the cross-check in #6 — a number the vendor maintains, disagreeing with a
number we compute — and it needs re-finding in each new format rather than
assuming the old spelling survived.

---

## 8. The same bug, one round later, because the fix added a pattern

**2026-09-19, `Nanako0129/lorenzini#1`, round four.** Reported `RESULT=CLEAN` on
a review whose body said `**Findings:** 1`.

Entry #7 ended by naming what its own fix did not do: *"nothing here detects
that the patterns stopped matching; it only adds one more pattern."* One round
later the same body format produced findings in a place the new pattern did not
look — no per-file table this time, and instead:

```
### 🔵 Needs a closer look
**Findings:** 1
Open (1)
Previously missed (2)   <- findings in code unchanged since the last review
```

`Previously missed` is the sharpest of these: those findings can never become
inline comments, because the lines they concern were not touched. Zero inline
comments at head was therefore correct and meaningless at the same time.

Both findings were real, and one of them was the N-places failure for the third
time: `RESULT=TABLE` had been added to the explanatory verdict table in
`SKILL.md` and not to the operational one lower in the same file.

**Now:** the cross-check reads the vendor's own number in whatever spelling the
format uses — `Comments generated: N`, `**Findings:** N`, `Open (N)`,
`Previously missed (N)` — and takes the largest. Their relationship is not
modelled, because modelling it means understanding a format that will change
again; the maximum over-counts at worst, and over-counting withholds a pass
while under-counting grants one.

**Shape:** a fix that enumerates buckets is a fix that is already incomplete.
The bucket list is the vendor's to change, and it does not announce changes.

**Round five found the fix's own latent bug.** The awk that locates the Findings
column bounded its scan with `< NF` instead of `<= NF`. A Markdown table may omit
the trailing pipe, which drops awk's empty final field; the Findings header then
sits at `i == NF`, is never found, and every data row is skipped. Copilot's
current tables do carry the trailing pipe, which is exactly why this passed the
tests written for it — a fail-open held back by one character of someone else's
formatting.

That is three self-inflicted findings across five rounds, in three consecutive
rounds. Not a majority, so the loop is still converging rather than diverging,
but the trend is the thing to watch: the findings are no longer about the
original work, they are about the fixes. The rule from the divergence section
applies at the next one — if round six also finds a defect introduced by round
five, stop point-fixing and take the whole file structurally instead.

**The general lesson, now paid for twice:** prefer a signal the vendor maintains
over a pattern you maintain. A number they publish about their own work moves
when they move; a regex you wrote about their output does not, and its silence
is indistinguishable from good news.

---

## 9. Three rounds patching a parser, when the question was wrong

**2026-09-19, `Nanako0129/lorenzini#1`, rounds four to six.** The stop condition
written in entry 8 fired: round six found a defect introduced by round five,
which had found one introduced by round four.

All three were in the same hand-rolled Markdown table parser added to read the
`ccr-overview-v2` body: the wrong column, then `< NF` where the trailing pipe is
optional, then a leading pipe assumed to be present. Findings clustering in one
function rather than spread across the work — the divergence signature, and it
took being written down in advance to be acted on rather than argued with.

**The parser was answering the wrong question.** Across five captured
new-format bodies, every single one carries `### 🔵 Needs a closer look` and a
substantive one-line summary, and **not one is a confirmed clean review**. There
was no clean shape to recognise. Each round added a pattern for where findings
had appeared last time, which is a list the vendor owns and does not announce
changes to.

`Syrtis-Agent#4` makes the cost concrete. This script reported it `CLEAN`, and
that verdict was relayed to the user as one of five clean pull requests ready to
merge. Its summary line read: *"The configuration will not automatically
re-enable CodeRabbit reviews after the repository reaches ten stars."* A real
observation, with `Findings: None`, no per-file Findings column, and zero inline
comments. Three of those five carried substantive comments; the report said all
five were clean.

**Now:** the parser is deleted. A body in this format returns `RESULT=UNREAD`
and prints the review for a person to read. Not a pass, not a failure — an
admission. The branch carries an explicit condition for its own removal: once a
genuinely clean new-format review has been captured and its shape is known.

**Shape:** patching the place a finding appeared is a fix for the last one. When
three rounds each fix the previous round's fix, the defect is not in the code
being patched, it is in what the code is trying to decide.

**The subtraction:** the ledger already said it, two entries before this one —
*a redundant check that can be false is a second failure mode, not a second line
of defence.* The clean round arrived by deleting the check, not by fixing it.

---

## What the pattern is

Most of them are the same sentence with different nouns: **an empty set was read
as a clean result.** The set came back empty because the filter was wrong,
because the findings were parked somewhere the count did not reach, because the
work had not finished yet, because a read failed rather than returning nothing,
or because the vendor changed its wording and every pattern stopped matching at
once.

**Do not keep a tally here, and do not enumerate the entries.** Both go stale on
the next entry, and both have. An earlier version of this paragraph said "four
of the five" and was overtaken within a day. Its replacement dropped the tally
but kept a list of entry numbers, which stopped at #7 while the ledger grew to
#9 -- so the paragraph forbidding a count was itself carrying three, and a
reviewer caught that too. An entry number, like a count, is a contract with a
second home. Name the mechanism; the entries are above and they are numbered.

The defence is not vigilance. It is that the default answer to "I found nothing"
is *keep looking*, and only an explicit statement of completion ends the wait.
That is written as code rather than kept as a habit, because the habit is what
failed every time listed above.

Two consequences worth keeping in view:

- **Fixing a fail-open can open another one.** At least one entry here was
  introduced while fixing a real bug, and another's fix had a symmetric trap
  waiting inside it. Any change to the completion logic needs the existing
  regression cases run, not just the new one.
- **None of these were found by the person who wrote the code.** They came from
  other sessions, from the user, and in one case from the reviewer itself.
  Testing covers the shapes you already imagined, which is exactly the set that
  does not contain your next bug.
