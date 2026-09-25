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

    # Single-quoted runs long enough to be a quoted artefact rather than prose.
    #
    # Compared whole. The first version of this check split each literal on its
    # colon and compared only the left side, on the assumption that a
    # placeholder like 'Files reviewed: N/N' would appear nowhere in the
    # sources. That assumption was never measured, and it is false -- all seven
    # literals match verbatim, placeholders included. The loosening bought
    # nothing and cost the value: 'Comments generated: 0' compared as
    # 'Comments generated' would have accepted a description saying 1, which is
    # the opposite of a clean pass. Found by review, on the commit that added
    # the check.
    for lit in re.findall(r"'([^']{6,80})'", desc):
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
