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
