# PII detector benchmark

Measures local models that could mask personal data in query results before
they reach an agent: how much leaks, how much diagnostic text they destroy,
and how long they take.

## Data

- `corpus.py` writes `data/corpus.jsonl`: 650 Polish and English cells shaped
  like database content (transfer titles, notes with declined names, Oban
  errors, inspected structs, JSON, logfmt, Postgres errors, tickets) with gold
  spans and `keep` spans (UUIDs, invoice numbers, error names) that masking
  must not touch. Deterministic.
- `external.py nemotron` samples 300 documents from the Nemotron-PII test
  split (English); `external.py plbench` converts pl-pii-bench (Polish,
  evaluation only, never train on it).

## Running

```bash
nix shell nixpkgs#uv -c uv sync
uv run python run.py bardsai corpus.jsonl     # regex, bardsai, nym, gliner2-pl-t0.3, bonsai, bonsai-thinking
uv run python score.py regex+bardsai bonsai-2b-PQ2_0 --corpus corpus.jsonl --leaks 20
```

`mix run bench/gateway.exs corpus.jsonl` (from the repository root) writes
predictions of the gateway's own Elixir detection as `gateway`, so it can be
scored next to the Python adapters.

`a+b` scores the union of two detectors. A gold span leaks unless every letter
and digit in it is masked. UUIDs and ISO timestamps are never masked
(`--no-guard` disables that).

Bonsai runs behind llama-server from the PrismML fork (PQ2_0 needs it):
`BONSAI_URL`, `BONSAI_VARIANT` (name suffix) and `BONSAI_MODE`
(`spans`, `fewshot`, `rewrite`) select the server and prompt.

`basal_check.py` asks a [basal](https://github.com/rkinas/basal) decision
model whether a cell contains personal data, on raw cells or on cells a
detector already masked; `basal_score.py` turns the answers into catch rate
and false alarms per threshold.

## Results (2026-10-19)

Share of gold values leaked; "keep broken" counts UUIDs, invoice numbers and
error names that were masked. Bonsai sizes ran on an M2 Pro (Metal) over a
130-cell subset of `corpus.jsonl` and every third pl-pii-bench document.

| Detector | corpus | keep broken | pl-pii-bench | p50 per cell |
|---|---|---|---|---|
| regex + bardsai (ONNX INT8; pl-pii-bench with fp32) | 3.5% | 2.3% | 12.6% | 44 ms CPU |
| gateway (Elixir, 2026-10-20) | 2.3% | 2.3% | | 44 ms CPU |
| regex + nym | 9.0% | | 13.9% | |
| regex + gliner2-pl | 11.1% | | | |
| Bonsai 2 27B alone, subset | 3.3% | 0% | 17.6% | 9.5 s M2 |
| regex + bardsai + Bonsai 27B, subset | 0.3% | | 7.2% | 9.5 s M2 |

The gateway uses regex + bardsai: it runs on CPU in-process and its leaks
are systematic (Polish names declined after a preposition, US street
addresses, card endings), which reports from agents can turn into training
data. Bonsai 27B fixes declined names but needs a GPU. basal-2.0-mini is a
good raw-cell gate (AUROC 0.97, 0.26 s on M2) but not a check after masking
(AUROC 0.71).
