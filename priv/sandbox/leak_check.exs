# Measures what masking lets through on the synthetic sandbox: runs every
# table dump, typical debugging queries and known bypass shapes, then searches
# each response for every personal value the seed inserted.
#
#     mix run priv/sandbox/seed.exs && mix run priv/sandbox/leak_check.exs
#
# With COLD=1 every query starts with a fresh alias map, as if it were the
# agent's first: only the preloaded dictionary of personal columns helps free
# text, not values seen in earlier responses. NO_DICTIONARY=1 also skips that.

alias AnonimizedMcp.Gateway

source = "sandbox"
pii = "tmp/sandbox_pii.json" |> File.read!() |> Jason.decode!()
{:ok, %{tables: tables}} = Gateway.describe(source)

dumps = Enum.map(tables, &{"dump #{&1.name}", "SELECT * FROM #{&1.name}"})

debugging = [
  {"failed jobs", "SELECT id, state, queue, worker, attempt, args, errors FROM oban.oban_jobs WHERE state <> 'completed'"},
  {"bank sync", "SELECT r.status, b.iban, b.owner_name, j.state, j.errors FROM requisitions r JOIN bank_accounts b ON b.requisition_id = r.id LEFT JOIN oban.oban_jobs j ON j.args->'primary_key'->>'id' = b.id::text"},
  {"invoice with buyer", "SELECT i.number, i.buyer_tax_id, c.tax_id, c.display_name, i.internal_note FROM sales_invoices i JOIN counterparties c ON c.id = i.buyer_id"},
  {"events", "SELECT resource, action, data FROM ash_events"},
  # Free text alone: nothing else in the response names the people in it.
  {"notes only", "SELECT internal_note FROM sales_invoices"},
  {"remittance only", "SELECT remittance_information_unstructured FROM transactions"},
  {"description only", "SELECT description FROM counterparties"}
]

bypasses = [
  {"concat", "SELECT concat(given_name, ' ', surname, ' ', pesel) FROM counterparties"},
  {"string_agg", "SELECT string_agg(name, ', ') FROM users"},
  {"cte rename", "WITH x AS (SELECT name AS label FROM users) SELECT label FROM x"},
  {"subquery rename", "SELECT q.v FROM (SELECT surname AS v FROM counterparties) q"},
  {"lateral", "SELECT l.x FROM users u, LATERAL (SELECT u.name AS x) l"},
  {"correlated", "SELECT (SELECT u.name) FROM users u"},
  {"row cast", "SELECT u::text FROM users u"},
  {"row_to_json", "SELECT row_to_json(c) FROM counterparties c"},
  {"json_agg", "SELECT json_agg(c) FROM counterparties c"},
  {"jsonb_build_object", "SELECT jsonb_build_object('x', surname, 'y', pesel) FROM counterparties"},
  {"array_agg", "SELECT array_agg(email) FROM users"},
  {"union literal", "SELECT name FROM users UNION ALL SELECT 'x'"},
  {"union swap", "SELECT 'x' UNION ALL SELECT name FROM users"},
  {"case", "SELECT CASE WHEN true THEN name END FROM users"},
  {"substring", "SELECT substring(email from 1 for 6) FROM users"},
  {"reverse", "SELECT reverse(name) FROM users"},
  {"format", "SELECT format('%s|%s', name, phone) FROM users"},
  {"translate", "SELECT translate(name, 'aeiou', 'AEIOU') FROM users"},
  {"cast error", "SELECT name::int FROM users"},
  {"jsonb error", "SELECT (data->>'owner_name')::int FROM ash_events"},
  {"json path", "SELECT data->>'owner_name' FROM ash_events"},
  {"args text", "SELECT args::text, errors::text FROM oban.oban_jobs"},
  {"explain filter", "EXPLAIN SELECT * FROM users WHERE name = 'x'"},
  {"pg_stats", "SELECT * FROM pg_stats WHERE tablename = 'users'"},
  {"activity", "SELECT query FROM pg_stat_activity"}
]

results =
  for {label, sql} <- dumps ++ debugging ++ bypasses do
    if System.get_env("COLD") == "1" do
      :ets.delete_all_objects(AnonimizedMcp.Masking.Aliases)

      if System.get_env("NO_DICTIONARY") == "1",
        do: :persistent_term.put({AnonimizedMcp.Masking.Dictionary, source}, System.monotonic_time(:millisecond)),
        else: :persistent_term.erase({AnonimizedMcp.Masking.Dictionary, source})
    end

    text =
      case Gateway.query(source, sql, 500) do
        {:ok, result} -> Jason.encode!(result)
        {:error, message} -> Jason.encode!(%{error: message})
      end

    # JSON escapes quotes and non-ASCII; compare against the decoded text.
    plain = text |> Jason.decode!() |> inspect(limit: :infinity, printable_limit: :infinity)
    leaks = Enum.filter(pii, &(String.contains?(text, &1) or String.contains?(plain, &1)))
    {label, leaks, text}
  end

total = Enum.flat_map(results, &elem(&1, 1)) |> Enum.uniq()

for {label, leaks, text} <- results do
  status = if leaks == [], do: "ok  ", else: "LEAK"
  error = if String.starts_with?(text, ~s({"error")), do: "  (error response)", else: ""
  IO.puts("#{status} #{label}#{error}" <> if(leaks == [], do: "", else: " -> #{length(leaks)}: #{Enum.join(Enum.take(leaks, 4), " | ")}"))
end

IO.puts("\n#{length(total)} of #{length(pii)} personal values leaked in at least one response.")
