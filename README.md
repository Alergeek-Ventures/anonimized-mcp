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

Personal values become stable aliases (`NAME_k3j7x2ab`, `TAX_ID_q7m2c4ze`).
The same value always gets the same alias, so results can be joined across
queries. Agents can filter by alias (`WHERE email = 'EMAIL_…'`); the value is
bound as a text parameter inside the gateway and never appears in SQL text.
Columns that are not text need a cast (`birth_date::text = 'BIRTHDATE_…'`),
and `EXPLAIN` refuses aliases, since a plan prints bound values.

## How masking works

1. `pg_query` parses the statement; only one `SELECT` or `EXPLAIN SELECT`
   is accepted, and `pg_stats`-like relations and `XMLTABLE` are refused.
   Functions are allowlisted (aggregates, window, date/time, JSON, arrays,
   numbers, and text functions that return parts of their input
   unchanged); anything that could rewrite a name past the detectors, such
   as `reverse`, `translate` or `encode`, also called in attribute notation
   (`(name).reverse`), and casts to `bytea` are refused; case changes
   (`lower`, `upper`, `initcap`), which weaken detection, may filter and
   sort but not appear in a select list, a function in `FROM` or `VALUES`
   (`lib/anonimized_mcp/gateway/statement.ex`). Advisory locks are
   released after every query. The database role must be read-only
   regardless.
2. Every text value, including strings inside JSON and arrays, goes through
   checksum-validated patterns (NIP and EU VAT numbers, PESEL, REGON,
   IBAN/NRB, payment cards, ID cards and passports, e-mail, phone, profile
   links, IP, password hashes, JWTs, random tokens) and the
   [bardsai/eu-pii-anonimization-multilang-v2](https://huggingface.co/bardsai/eu-pii-anonimization-multilang-v2)
   NER model, run in-process on CPU through ONNX Runtime. Words written in
   capitals are also shown to the model title-cased. Addresses, tsvector
   lexemes, large numerics and JSON keys are checked like text. UUIDs and
   timestamps are never masked.
3. Values aliased so far in the source are replaced wherever else they
   appear, in any letter case and also by name stem, so a name found once
   stays masked in declined forms elsewhere.
4. Columns and JSON keys named like credentials are withheld as `[secret]`;
   dates in columns named like birth dates are aliased. The rules follow
   where a result column comes from in the statement, so `min(birth_date)`,
   `coalesce(token, '')` or `AS x` keep them, and apply per field to whole
   rows (`SELECT u FROM users u`).
5. Database errors are rewritten: data exceptions lose quoted input, and
   every message is masked. Other failures return a generic message and
   log only the exception type, never its text.

The query runs as a single autocommit statement and the connection returns
to the pool before masking starts. The model (340 MB) is downloaded on first
start into the user cache directory, pinned to one revision and checked by
SHA-256; the server does not start until it is loaded.

Masking can miss things, mostly Polish names declined after a preposition
("z Tomkiem Nowakiem") and surnames inside company names. Agents are told
to report such cells with `report_leak`; reports are stored in `leak_reports` with the masked cell,
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
`priv/repo/seeds.exs`; outside dev and test it requires `OPERATOR_PASSWORD`).
Self-registration is disabled. After 5 failed sign-ins for an email within
5 minutes, further attempts for it are refused until the window passes, even
with the correct password. Sign-in attempts are recorded in `auth_audit_log`
(email, outcome, IP truncated to /24 or /48, no passwords or tokens) and kept
for 30 days. Client registration stays open for MCP clients but is bounded:
OAuth request bodies are capped at 64 kB, client names at 200 characters,
redirect URIs at 10 of 2048 characters, and registered clients that no
operator approved are removed after a day. Each client IP may register 10
clients an hour and make 60 other OAuth requests a minute; past that the
server answers 429. The client IP is the connection's address, or, when the
connection comes from a private address (a reverse proxy such as Caddy on
Coolify), the rightmost public address in `X-Forwarded-For`. A proxy in
front must append to that header, as Caddy does.

Aliases are an HMAC keyed by `secret_key_base`. The development value is
public, so set `SECRET_KEY_BASE` (`mix phx.gen.secret`) before adding a source
with real data; otherwise aliases of guessable values (PESEL, NIP, phone
numbers, common names) can be reversed by anyone holding a result.

## Measuring leaks

- `mix run priv/sandbox/leak_check.exs` dumps every sandbox table, runs
  typical debugging queries and known bypass shapes, then searches each
  response for every personal value the seed inserted
  (`tmp/sandbox_pii.json`). `COLD=1` resets aliases before each query.
- `bench/` compares PII detectors on Polish and English cells shaped like
  database content; `mix run bench/gateway.exs` scores the gateway's own
  detection there (see `bench/README.md`).

## License

MIT, see `LICENSE`.
