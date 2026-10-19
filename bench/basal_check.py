"""Asks a basal decision model whether a cell still contains personal data,
on raw cells (a gate before masking) and on cells already masked by a
detector (a check after masking). Writes the yes-probability per cell; the
scorer turns it into catch rate and false alarms at each threshold.

    BASAL_URL=http://127.0.0.1:8084 uv run python basal_check.py raw
    BASAL_URL=... uv run python basal_check.py masked regex+bardsai
"""

import json
import os
import sys
import time
from pathlib import Path

import requests

from score import DATA, combine, guarded

URL = os.environ.get("BASAL_URL", "http://127.0.0.1:8084")
NAME = os.environ.get("BASAL_NAME", "basal")

RAW = ("Czy ten tekst zawiera dane osobowe: imię lub nazwisko konkretnej osoby, adres, e-mail, telefon, PESEL, NIP, "
       "numer konta, datę urodzenia, adres IP albo hasło lub token? Nazwy firm klientów też się liczą.")
MASKED = (RAW + " Wartości już zamaskowane wyglądają jak [PII] i nie są danymi osobowymi; liczy się tylko to, "
          "co zostało widoczne.")


def masked_text(text, spans):
    out, last = [], 0
    for s, e in sorted(spans):
        if s < last:
            s = last
        if e <= s:
            continue
        out += [text[last:s], "[PII]"]
        last = e
    return "".join(out + [text[last:]])


def ask(state, instructions):
    body = {"state": state, "questions": {"pii": {"type": "noul", "instructions": instructions}}}
    for attempt in range(4):
        try:
            r = requests.post(f"{URL}/v1/systemone", json=body, timeout=300)
            r.raise_for_status()
            break
        except requests.RequestException as e:
            if attempt == 3:
                raise RuntimeError(f"{e}: {getattr(e.response, 'text', '')[:300]}") from e
            time.sleep(5 * (attempt + 1))
    answer = r.json()["answers"]["pii"]
    return answer["noul"], answer.get("automated")


def main():
    mode = sys.argv[1]
    corpus = os.environ.get("CORPUS", "corpus.jsonl")
    cells = [json.loads(l) for l in (DATA / corpus).open()]
    preds = combine(sys.argv[2].split("+"), corpus) if mode == "masked" else {}
    tag = f"{NAME}-{mode}" + (f"-{sys.argv[2]}" if mode == "masked" else "")
    out = DATA / "pred" / f"{tag}--{Path(corpus).stem}.jsonl"
    with out.open("w") as f:
        for i, cell in enumerate(cells):
            text = cell["text"]
            if mode == "masked":
                if cell["id"] not in preds:
                    continue
                text = masked_text(text, guarded(text, preds[cell["id"]][0]))
            t = time.perf_counter()
            p, automated = ask(text, MASKED if mode == "masked" else RAW)
            ms = (time.perf_counter() - t) * 1000
            f.write(json.dumps({"id": cell["id"], "p_yes": p, "automated": automated, "ms": ms}) + "\n")
            if i % 100 == 0:
                print(f"{tag}: {i}/{len(cells)}", flush=True)
    print(out)


if __name__ == "__main__":
    main()
