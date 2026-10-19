"""Runs one detector over a corpus and stores its spans and timings.

    uv run python run.py bardsai [corpus.jsonl] [--limit N]
"""

import argparse
import json
import time
from pathlib import Path

import psutil

from detectors import build

DATA = Path(__file__).parent / "data"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("corpus", nargs="?", default="corpus.jsonl")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--every", type=int, default=1, help="take every n-th cell")
    args = ap.parse_args()

    cells = [json.loads(l) for l in (DATA / args.corpus).open()][:: args.every][: args.limit]
    t0 = time.perf_counter()
    det = build(args.model)
    load_s = time.perf_counter() - t0
    # Warm-up so the first cell does not carry lazy initialisation.
    det.detect("Jan Kowalski, jan@example.com")

    out = DATA / "pred" / f"{det.name}--{Path(args.corpus).stem}.jsonl"
    out.parent.mkdir(exist_ok=True)
    proc = psutil.Process()
    with out.open("w") as f:
        for i, cell in enumerate(cells):
            t = time.perf_counter()
            spans = det.detect(cell["text"])
            ms = (time.perf_counter() - t) * 1000
            f.write(json.dumps({"id": cell["id"], "spans": spans, "ms": ms}, ensure_ascii=False) + "\n")
            if i % 50 == 0:
                print(f"{det.name}: {i}/{len(cells)}", flush=True)
    meta = {"model": det.name, "corpus": args.corpus, "cells": len(cells), "load_s": load_s,
            "rss_mb": proc.memory_info().rss / 2**20, "not_found": getattr(det, "not_found", None)}
    out.with_suffix(".meta.json").write_text(json.dumps(meta))
    print(json.dumps(meta))


if __name__ == "__main__":
    main()
