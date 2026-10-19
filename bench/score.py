"""Scores stored predictions against the corpus.

    uv run python score.py bardsai regex+bardsai [--corpus corpus.jsonl] [--leaks 20]

A gold span leaks unless every letter and digit in it is masked: half a name
is still a name. `keep` spans (UUIDs, invoice numbers, error names) broken by
masking count against utility, as does masking anything in cells with no
personal data at all.
"""

import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path

import re

from detectors import Bardsai, Gliner2Polish, Nym

DATA = Path(__file__).parent / "data"
MASKED = {"bardsai": Bardsai.MASKED, "gliner2-pl": Gliner2Polish.MASKED, "nym": Nym.MASKED}

# Record ids and timestamps are never personal data on their own and are what
# an agent joins and filters on, so the gateway would refuse to mask them.
GUARD = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?", re.I)
GUARDED = True


def guarded(text, spans):
    if not GUARDED:
        return spans
    protected = [m.span() for m in GUARD.finditer(text)]
    return [(s, e) for s, e in spans if not any(a <= s and e <= b for a, b in protected)]


def masked_labels(model):
    return next((v for k, v in MASKED.items() if model.startswith(k)), None)


def load_pred(model, corpus):
    path = DATA / "pred" / f"{model}--{Path(corpus).stem}.jsonl"
    allowed = masked_labels(model)
    preds = {}
    for line in path.open():
        p = json.loads(line)
        spans = [(s, e) for s, e, label in p["spans"] if allowed is None or label in allowed]
        preds[p["id"]] = (spans, p["ms"])
    return preds


def combine(names, corpus):
    parts = [load_pred(n, corpus) for n in names]
    ids = set.intersection(*(set(p) for p in parts))
    return {i: ([s for p in parts for s in p[i][0]], sum(p[i][1] for p in parts)) for i in ids}


def score(name, corpus, leaks_to_show, subset=None):
    cells = {c["id"]: c for c in map(json.loads, (DATA / corpus).open())}
    preds = combine(name.split("+"), corpus)
    if subset:
        keep_ids = set(load_pred(subset, corpus))
        preds = {i: p for i, p in preds.items() if i in keep_ids}
    total, leaked, partial = defaultdict(int), defaultdict(int), defaultdict(int)
    keep_total = keep_broken = neg_cells = neg_hit = 0
    over, non_gold = 0, 0
    examples = []
    for cid, (spans, _) in preds.items():
        cell = cells[cid]
        text = cell["text"]
        spans = guarded(text, spans)
        mask = bytearray(len(text))
        for s, e in spans:
            mask[max(s, 0):min(e, len(text))] = b"\x01" * (min(e, len(text)) - max(s, 0))
        gold = bytearray(len(text))
        for g in cell.get("ignore", []):
            gold[g["start"]:g["end"]] = b"\x01" * (g["end"] - g["start"])
        for g in cell["spans"]:
            gold[g["start"]:g["end"]] = b"\x01" * (g["end"] - g["start"])
            chars = [i for i in range(g["start"], g["end"]) if text[i].isalnum()]
            covered = sum(mask[i] for i in chars)
            for key in ("all", f"lang:{cell['lang']}", f"type:{g['type']}", f"shape:{cell['shape']}"):
                total[key] += 1
                if covered < len(chars):
                    leaked[key] += 1
                    if covered:
                        partial[key] += 1
            if covered < len(chars) and len(examples) < leaks_to_show:
                examples.append(f"  {cid} {g['type']}: {text[g['start']:g['end']]!r} in …{text[max(0, g['start'] - 30):g['end'] + 20]!r}…")
        for k in cell["keep"]:
            keep_total += 1
            if any(mask[k["start"]:k["end"]]):
                keep_broken += 1
        for i, ch in enumerate(text):
            if ch.isalnum() and not gold[i]:
                non_gold += 1
                over += mask[i]
        if cell["shape"] == "negative":
            neg_cells += 1
            neg_hit += any(mask)
    ms = sorted(p[1] for p in preds.values())
    return {
        "model": name,
        "cells": len(preds),
        "leak": {k: f"{leaked[k]}/{total[k]} ({100 * leaked[k] / total[k]:.1f}%)" for k in sorted(total)},
        "partial_of_leaks": f"{partial['all']}/{leaked['all']}",
        "keep_broken": f"{keep_broken}/{keep_total} ({100 * keep_broken / max(keep_total, 1):.1f}%)",
        "negative_cells_touched": f"{neg_hit}/{neg_cells}",
        "overmask_chars": f"{100 * over / max(non_gold, 1):.1f}%",
        "ms_mean": round(statistics.mean(ms), 1),
        "ms_p50": round(ms[len(ms) // 2], 1),
        "ms_p95": round(ms[int(len(ms) * 0.95)], 1),
        "examples": examples,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("models", nargs="+")
    ap.add_argument("--corpus", default="corpus.jsonl")
    ap.add_argument("--leaks", type=int, default=0)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-guard", action="store_true")
    ap.add_argument("--subset", help="score only cells this model's predictions cover")
    args = ap.parse_args()
    global GUARDED
    GUARDED = not args.no_guard
    for m in args.models:
        r = score(m, args.corpus, args.leaks, args.subset)
        if args.json:
            print(json.dumps(r, ensure_ascii=False))
            continue
        print(f"\n== {r['model']} ({r['cells']} cells)  leak {r['leak']['all']}  keep broken {r['keep_broken']}  "
              f"negatives touched {r['negative_cells_touched']}  overmask {r['overmask_chars']}  "
              f"ms p50 {r['ms_p50']} p95 {r['ms_p95']}")
        print("   " + "  ".join(f"{k}={v}" for k, v in r["leak"].items() if k != "all"))
        print("\n".join(r["examples"]))


if __name__ == "__main__":
    main()
