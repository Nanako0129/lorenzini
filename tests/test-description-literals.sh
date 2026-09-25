#!/bin/bash
# Every quoted literal in a skill's frontmatter description must exist in that
# skill's poller or its body.
#
# The description is what an agent reads to decide how to classify a verdict,
# and it is read without the body — a plugin host lists descriptions, not
# files. A literal there that does not match what the poller actually matches
# produces a misclassification that nothing else catches: the code is right,
# the body is right, and the agent following the summary is wrong.
#
# Found the hard way on 2026-09-25. copilot-review-wait's description quoted
# '### Approval recommended' while poll-copilot.sh:501 requires
# '^### 🟢 Approval recommended[[:space:]]*$'. The body had it right in three
# places. An agent following the description would have classified a genuine
# clean pass as UNREAD.
#
# That exact looseness is a bug this repository already fixed once in code:
# poll-copilot.sh:478 records that matching *"Approval recommended"* caught a
# "### 🟡 Changes recommended" body. The fix landed in the script and the
# description kept the broken form for months.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

python3 - "$ROOT" <<'PY'
import pathlib, re, sys, yaml

root = pathlib.Path(sys.argv[1])
checked = failed = 0

for skill in sorted(root.glob("skills/*/SKILL.md")):
    raw = skill.read_text(encoding="utf-8")
    desc = yaml.safe_load(raw.split("---")[1]).get("description", "") or ""
    body = raw.split("---", 2)[2]
    scripts = "".join(p.read_text(encoding="utf-8")
                      for p in (skill.parent / "scripts").glob("poll-*.sh"))

    # Compared whole. The first version split each literal on its colon and
    # compared only the left side, assuming a placeholder like
    # 'Files reviewed: N/N' appears in no source. That was never measured and
    # is false -- every literal matches verbatim, placeholders included. The
    # loosening bought nothing and cost the value: 'Comments generated: 0'
    # compared as 'Comments generated' would have accepted a description
    # saying 1, the opposite of a clean pass.
    #
    # An apostrophe is not a quote. `'([^']{6,80})'` pairs the apostrophe in
    # "Copilot's" with the next real quote, which silently shifts every pair
    # after it: the literal that should be checked stops being checked, and a
    # fabricated one appears that can only fail. Today that does not happen
    # only because the span from "Copilot's" to the next quote exceeds the
    # 80-character ceiling -- luck, not design, and it breaks the moment
    # someone shortens that sentence.
    #
    # So an apostrophe is excluded structurally: a quote opens a literal only
    # when it does not directly follow a word character.
    lits = re.findall(r"(?<![A-Za-z0-9])'([^']{6,80})'", desc)
    print(f"  {skill.parent.name}: {len(lits)} literal(s)")
    for lit in lits:
        checked += 1
        if lit in scripts or lit in body:
            continue
        failed += 1
        print(f"FAIL {skill.parent.name}")
        print(f"  description quotes: {lit!r}")
        print(f"  found in neither {skill.parent.name}/scripts/ nor the body")

print(f"{checked - failed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
