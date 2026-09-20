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
import json, pathlib, statistics, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TAU = 0.5

repeats = int(sys.argv[1]) if len(sys.argv) > 1 else 3
qfile = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "coderabbit-review-wait/jev-questions-v3.json"

spec = json.load(open(qfile))
gold = json.load(open(ROOT / "tests/fixtures/gold-cr-labels.json"))
variant = spec.get("_variant", qfile.stem)


def call():
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
    r = subprocess.run([str(ROOT / "scripts/jev.sh"), "-"],
                       input=json.dumps(body), capture_output=True, text=True)
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
p = ROOT / f"tests/fixtures/result-cr-labels-{out['round']}.json"
json.dump(out, open(p, "w"), ensure_ascii=False, indent=1)
print("\n" + json.dumps(out["score"], ensure_ascii=False), "\n->", p)
