# anonimized-mcp

A debugging data source for AI agents, alongside Sentry and PostHog: an MCP
server that runs read-only SQL against an application's PostgreSQL and
pseudonymizes personal data before results leave our infrastructure.

Proof of concept. It runs only against the synthetic `sandbox` database.

## Tools

| Tool | Purpose |
|---|---|
| `list_sources` | Configured databases |
| `describe_schema` | Tables, columns, foreign keys and how each column is masked |
| `query` | One `SELECT`/`EXPLAIN`, at most 500 rows, 15 s timeout |
| `check_value` | Properties of an aliased value (whitespace, checksums, comparison) without the value |

Personal values become stable aliases (`NAME_k3j9x2ab`, `TAX_ID_q7m2c4ze`).
The same value always gets the same alias, so results can be joined across
queries. Agents can filter by alias (`WHERE email = 'EMAIL_…'`); the value is
bound as a parameter inside the gateway and never appears in SQL text.

## How masking works

1. `pg_query` parses the statement; only one `SELECT` or `EXPLAIN` is
   accepted, and `pg_stats`-like relations are refused. The database role
   must be read-only regardless.
2. Lineage maps every output column back to table columns through aliases,
   `*`, joins, CTEs, subqueries, `LATERAL`, set operations and expressions.
3. Each column gets a kind from per-source overrides or shared naming rules
   (`lib/anonimized_mcp/masking/policy.ex`): `secret`, `alias:TYPE` or `none`.
4. Free text and JSON are scrubbed with checksum-validated detectors (NIP,
   PESEL, REGON, IBAN/NRB, e-mail, phone, JWT), key-value pairs classified
   by key name, and a dictionary of values preloaded from personal columns,
   matched exactly and by name stem to catch declined forms.
5. Database errors are rewritten: data exceptions lose quoted input, other
   messages are scrubbed.

The query runs as a single autocommit statement and the connection returns
to the pool before masking starts.

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

`mix run priv/sandbox/leak_check.exs` dumps every table, runs typical
debugging queries and known bypass shapes, then searches each response for
every personal value the seed inserted (`tmp/sandbox_pii.json`).
`COLD=1` resets aliases before each query; `NO_DICTIONARY=1` also skips the
dictionary.
