#!/usr/bin/env python3
"""Re-run the Jev question set against the gold set and report accuracy.

    python3 tests/run-gold-set.py [repeats] [questions-file]

Defaults: 3 repeats, coderabbit-review-wait/jev-questions-v3.json.

Why repeats: a single pass cannot tell a stable answer from one sitting on the
threshold. The flip rate -- how many labels cross 0.5 between runs -- is the
number that says whether a score is reproducible, and it is reported separately
from accuracy for that reason.

Why this exists at all: the criteria text IS the classifier. Editing one word in
the questions file changes what it decides, and the only way to know which
direction is to run this and compare against the recorded baselines in
tests/fixtures/. Write a NEW result file per variant; overwriting an old one
destroys the comparison that makes the next edit judgeable.
"""
import json, os, pathlib, re, statistics, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
TAU = 0.5

repeats = int(sys.argv[1]) if len(sys.argv) > 1 else 3
qfile = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "coderabbit-review-wait/jev-questions-v3.json"

spec = json.load(open(qfile))
gold = json.load(open(ROOT / "tests/fixtures/gold-cr-labels.json"))
variant = spec.get("_variant", qfile.stem)


def call():
    """Score every gold-set label once and return the raw answers.

    Every label is embedded in its own question rather than passed as a shared
    list, so one label cannot influence another's score. The question and both
    criteria come from the spec file, unmodified: this runner must measure the
    classifier that ships, not a paraphrase of it.
    """
    body = {
        "state": {"source": "GitHub pull request review body, collapsed section headings"},
        "questions": {
            g["id"]: {
                "type": "noul",
                "instructions": {"question": spec["question"], "label": g["label"]},
                "criteria": spec["criteria"],
            }
            for g in gold
        },
    }
    # jev.sh caps its own HTTP call, but a hung child would otherwise park this
    # script forever. The parent timeout is deliberately the inner one plus
    # slack, so a genuine slow response is not mistaken for a hang.
    inner = int(os.environ.get("JEV_TIMEOUT", "8"))
    try:
        r = subprocess.run([str(ROOT / "scripts/jev.sh"), "-"],
                           input=json.dumps(body), capture_output=True, text=True,
                           timeout=inner + 20)
    except subprocess.TimeoutExpired:
        sys.exit(f"jev.sh did not return within {inner + 20}s")
    if r.returncode:
        sys.exit(f"jev.sh exit {r.returncode}: {r.stderr.strip()}")
    return json.loads(r.stdout)


runs = [call() for _ in range(repeats)]
detail, wrong = [], 0
print(f"{'id':4} {'exp':5} {'mean':5} {'spread':6} verdict  label")
for g in gold:
    vals = [run[g["id"]]["noul"] for run in runs]
    mean, spread = statistics.mean(vals), max(vals) - min(vals)
    pred = mean >= TAU
    ok = pred == g["expected"]
    wrong += not ok
    flip = any((v >= TAU) != pred for v in vals)
    mark = "FLIP" if flip else ("ok  " if ok else "MISS")
    print(f"{g['id']:4} {str(g['expected']):5} {mean:.2f}  {spread:.2f}   {mark}     {g['label']}")
    detail.append({"id": g["id"], "cat": g.get("category"), "expected": g["expected"],
                   "mean": round(mean, 3), "vals": vals, "pass": ok, "flip": flip})

n = len(gold)
pos = [d for d in detail if d["expected"]]
out = {"round": f"{spec.get('_model', 'jev-1.13.0')}-{variant}", "family": "CR-labels",
       "tau": TAU, "repeat": repeats,
       "score": {"accuracy": f"{n - wrong}/{n}",
                 "recall_hidden_work": f"{sum(d['pass'] for d in pos)}/{len(pos)}",
                 "false_positive": sum(1 for d in detail if not d["expected"] and not d["pass"]),
                 "flip_rate": f"{sum(d['flip'] for d in detail)}/{n}"},
       "detail": detail}
# Never overwrite a recorded baseline. The docstring above says so and the code
# below used not to: a verification run with one repeat replaced the committed
# three-repeat v3 result, and its "0/30 flip rate" then meant nothing, because a
# single pass cannot flip. A contract stated in a docstring and contradicted by
# the function under it is not a contract.
#
# The exclusive "x" mode is what enforces it, not the exists() check that used
# to guard a plain "w". Two mechanisms defeated that: a second run starting in
# the same whole second produced an identical alternate name and the later
# open(..., "w") overwrote the earlier alternate, and exists() followed by a
# separate open is a check that can go stale between the two lines. "x" moves
# the decision into the one syscall that can actually refuse, so the only way
# to lose a recorded result is to delete it on purpose. Raised by CodeRabbit on
# lorenzini#2 against the alternate path; the primary path had it too.
# out["round"] is built from _model and _variant, which come from whichever
# questions file was passed on the command line, and it becomes a FILENAME. A
# separator or a ".." in either field puts the result somewhere other than
# tests/fixtures, where the docstring above promises results live and where the
# next run looks for a baseline to compare against.
#
# Deliberately NOT framed as an attack. The operator chooses the questions file
# and already has write access to everything this script can reach, so a
# containment check against a hostile _variant would be guarding a door its own
# key opens. The failure worth guarding is ordinary: a variant named "v4/semantic"
# or a _model copied with a stray slash writes the result out of the comparison
# set and nothing says so. A whitelist is checked here rather than a resolve()
# containment check because the whitelist makes traversal unrepresentable, which
# leaves the containment check carrying no information -- and a check carrying no
# information can still be wrong.
#
# Measured 2026-09-20 against this exact template, printing the resolved path
# rather than trusting a prefix comparison (the first probe's containment test
# was wrong and said every case stayed inside):
#   "v3"                 -> tests/fixtures/result-cr-labels-jev-1.13.0-v3.json
#   "../../../tmp/pwned" -> tests/tmp/pwned.json                      ESCAPES
#   "v4/semantic"        -> tests/fixtures/result-...-v4/semantic.json  wrong dir
#   ".."                 -> tests/fixtures/result-...-...json          harmless
# ".." is accepted by the pattern and stays put, because the value is always
# embedded mid-filename and never becomes a path component of its own. Left
# accepted rather than special-cased: rejecting it would be guarding against a
# shape this template cannot produce.
SAFE = re.compile(r"\A[A-Za-z0-9._-]+\Z")
for field, value in (("_model", spec.get("_model", "jev-1.13.0")), ("_variant", variant)):
    if not SAFE.match(str(value)):
        sys.exit(f"{field} is {value!r}; it becomes part of a filename, so it must "
                 f"match [A-Za-z0-9._-]+. Fix it in {qfile}.")
base = ROOT / f"tests/fixtures/result-cr-labels-{out['round']}.json"
stamp = int(time.time())
p, note = base, None
for suffix in range(64):
    try:
        fh = open(p, "x")
        break
    except FileExistsError:
        if note is None:
            note = base.name
        p = base.with_name(f"{base.stem}-r{repeats}-{stamp}{'' if suffix == 0 else f'-{suffix}'}.json")
else:
    sys.exit(f"could not find an unused name next to {base.name} after 64 tries")
if note:
    print(f"\n{note} exists and is not being touched.")
    print(f"Writing {p.name} instead. Compare them, then keep whichever you mean to keep.")
with fh:
    json.dump(out, fh, ensure_ascii=False, indent=1)
print("\n" + json.dumps(out["score"], ensure_ascii=False), "\n->", p)
