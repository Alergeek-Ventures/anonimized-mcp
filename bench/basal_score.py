"""Scores basal_check.py output.

    uv run python basal_score.py basal-raw
    uv run python basal_score.py basal-masked-regex+bardsai regex+bardsai

Raw: a cell is positive when it has any gold span. Masked: a cell is positive
when the detector left a gold span visible, and the useful number is how many
of those leaked values a flag would have stopped.
"""

import json
import statistics
import sys
from pathlib import Path

from score import DATA, combine, guarded


def leaked_spans(cell, spans):
    text = cell["text"]
    mask = bytearray(len(text))
    for s, e in guarded(text, spans):
        mask[s:e] = b"\x01" * (e - s)
    return [g for g in cell["spans"]
            if any(not mask[i] for i in range(g["start"], g["end"]) if text[i].isalnum())]


def auroc(pos, neg):
    if not pos or not neg:
        return float("nan")
    wins = sum((p > n) + 0.5 * (p == n) for p in pos for n in neg)
    return wins / (len(pos) * len(neg))


def main():
    tag = sys.argv[1]
    detector = sys.argv[2] if len(sys.argv) > 2 else None
    corpus = "corpus.jsonl"
    cells = {c["id"]: c for c in map(json.loads, (DATA / corpus).open())}
    answers = [json.loads(l) for l in (DATA / "pred" / f"{tag}--{Path(corpus).stem}.jsonl").open()]
    preds = combine(detector.split("+"), corpus) if detector else None

    rows = []
    for a in answers:
        cell = cells[a["id"]]
        weight = len(leaked_spans(cell, preds[a["id"]][0])) if preds else len(cell["spans"])
        rows.append((a["p_yes"], weight, a["ms"]))

    pos = [p for p, w, _ in rows if w]
    neg = [p for p, w, _ in rows if not w]
    total_values = sum(w for _, w, _ in rows)
    print(f"{tag}: {len(rows)} cells, {len(pos)} positive ({total_values} values), AUROC {auroc(pos, neg):.3f}, "
          f"ms p50 {statistics.median(r[2] for r in rows):.0f}")
    for t in (0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9):
        flagged = [r for r in rows if r[0] >= t]
        caught = sum(w for p, w, _ in flagged)
        false_alarms = sum(1 for p, w, _ in flagged if not w)
        print(f"  p_yes >= {t:.2f}: flags {len(flagged)}/{len(rows)} cells, values stopped {caught}/{total_values}, "
              f"false alarms {false_alarms}/{len(neg)}")


if __name__ == "__main__":
    main()
