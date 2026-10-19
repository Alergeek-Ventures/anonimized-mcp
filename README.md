# anonimized-mcp

A debugging data source for AI agents, alongside Sentry and PostHog: an MCP
server that runs read-only SQL against an application's PostgreSQL and
pseudonymizes personal data before results leave our infrastructure.

A source needs only a database URL. Nothing is configured per table or
column: agents query whatever they need, and masking looks at the values.

Proof of concept. It runs only against the synthetic `sandbox` database.

## Tools

| Tool | Purpose |
|---|---|
| `list_sources` | Configured databases |
| `describe_schema` | Tables, columns, types and foreign keys |
| `query` | One `SELECT`/`EXPLAIN`, at most 500 rows, 15 s timeout |
| `check_value` | Properties of an aliased value (whitespace, checksums, comparison) without the value |
| `report_leak` | Flags a cell of an earlier result that still shows personal data, by query id, row and column |

Personal values become stable aliases (`NAME_k3j9x2ab`, `TAX_ID_q7m2c4ze`).
The same value always gets the same alias, so results can be joined across
queries. Agents can filter by alias (`WHERE email = 'EMAIL_…'`); the value is
bound as a parameter inside the gateway and never appears in SQL text.

## How masking works

1. `pg_query` parses the statement; only one `SELECT` or `EXPLAIN` is
   accepted, and `pg_stats`-like relations are refused. The database role
   must be read-only regardless.
2. Every text value, including strings inside JSON and arrays, goes through
   checksum-validated patterns (NIP, PESEL, REGON, IBAN/NRB, e-mail, phone,
   IP, password hashes, JWTs, random tokens) and the
   [bardsai/eu-pii-anonimization-multilang-v2](https://huggingface.co/bardsai/eu-pii-anonimization-multilang-v2)
   NER model, run in-process on CPU through ONNX Runtime. UUIDs and
   timestamps are never masked.
3. Values aliased so far in the source are replaced wherever else they
   appear, also by name stem, so a name found once stays masked in declined
   forms elsewhere.
4. Columns and JSON keys named like credentials are withheld as `[secret]`;
   dates in columns named like birth dates are aliased.
5. Database errors are rewritten: data exceptions lose quoted input, other
   messages are masked.

The query runs as a single autocommit statement and the connection returns
to the pool before masking starts. The model (340 MB) is downloaded on first
start into the user cache directory, pinned to one revision and checked by
SHA-256; the server does not start until it is loaded.

Masking can miss things, mostly Polish names declined after a preposition
("z Tomkiem Nowakiem"). Agents are told to report such cells with
`report_leak`; reports are stored in `leak_reports` with the masked cell,
copied from the gateway's own copy of the result, never from the agent.

## Running locally

```bash
direnv allow                     # or: devenv shell
(cd local && podman-compose up -d)
mix setup && mix run priv/sandbox/seed.exs
mix phx.server
```

With a restrictive umask, run `chmod -R a+rX local/init` before the first
`podman-compose up`, or Postgres cannot read the init script.

`/mcp` is an OAuth 2.1 resource (PKCE, dynamic client registration, refresh
token rotation) served by `ash_authentication_oauth2_server`. Sign in as
`dev@alergeek.ventures` / `dev-password-123` (created by
`priv/repo/seeds.exs`). Self-registration is disabled.

## Measuring leaks

- `mix run priv/sandbox/leak_check.exs` dumps every sandbox table, runs
  typical debugging queries and known bypass shapes, then searches each
  response for every personal value the seed inserted
  (`tmp/sandbox_pii.json`). `COLD=1` resets aliases before each query.
- `bench/` compares PII detectors on Polish and English cells shaped like
  database content; `mix run bench/gateway.exs` scores the gateway's own
  detection there (see `bench/README.md`).
