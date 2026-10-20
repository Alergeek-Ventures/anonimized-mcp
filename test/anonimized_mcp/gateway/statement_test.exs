defmodule AnonimizedMcp.Gateway.StatementTest do
  use ExUnit.Case, async: true

  alias AnonimizedMcp.Gateway.Statement

  # Column and field names of the source, as Catalog.names/1 returns them.
  @names %{
    columns: MapSet.new(~w(id name email state inserted_at attempt args errors issue_date note
                    full_name pid application_name address city key value)),
    functions: MapSet.new(~w(count lower reverse md5 pg_advisory_lock pg_cancel_backend))
  }

  defp parse(sql), do: Statement.parse(sql, @names)

  defp refused(sql) do
    assert {:error, message} = parse(sql)
    message
  end

  test "runs typical debugging queries" do
    for sql <- [
          "SELECT state, count(*) FROM oban.oban_jobs GROUP BY state",
          "SELECT date_trunc('day', inserted_at), max(attempt) FROM oban.oban_jobs GROUP BY 1",
          "SELECT args->>'id', jsonb_array_length(errors) FROM oban.oban_jobs",
          "SELECT trim(email), length(name), substring(name FROM 1 FOR 3) FROM users",
          "SELECT id FROM users WHERE lower(email) = 'x' ORDER BY upper(name)",
          "SELECT u.id FROM users u JOIN contacts c ON lower(c.email) = lower(u.email)",
          "SELECT extract(year FROM issue_date), coalesce(note, '-') FROM sales_invoices",
          "SELECT inserted_at AT TIME ZONE 'Europe/Warsaw', id::text FROM users",
          "SELECT row_number() OVER (ORDER BY id), pg_catalog.length(name) FROM users",
          "SELECT d FROM generate_series(now() - interval '1 day', now(), interval '1 hour') d",
          "EXPLAIN SELECT * FROM users WHERE lower(email) = 'x'"
        ] do
      assert {:ok, _} = parse(sql), sql
    end
  end

  test "refuses functions that rewrite text beyond recognition, wherever they appear" do
    assert refused("SELECT reverse(name) FROM users") =~ "reverse() is not available"
    assert refused("SELECT pg_catalog.REVERSE(name) FROM users") =~ "reverse()"
    assert refused("SELECT id FROM users WHERE translate(name, 'a', 'b') = 'x'") =~ "translate()"

    assert refused("SELECT (SELECT encode(convert_to(name, 'UTF8'), 'base64')) FROM users") =~
             "encode()"
  end

  test "refuses functions called in attribute notation" do
    for sql <- [
          "SELECT (full_name).reverse AS r FROM people",
          "SELECT p.reverse AS r FROM people, LATERAL btrim(full_name) p",
          "SELECT (p.full_name).reverse FROM people p",
          "SELECT (42::bigint).pg_advisory_lock AS locked",
          "SELECT (pid).pg_cancel_backend FROM pg_stat_activity WHERE application_name = 'x'",
          "SELECT id FROM people p WHERE (p.full_name).md5 = 'x'",
          "SELECT (42::bigint).pg_advisory_lock, 1 AS pg_advisory_lock",
          "SELECT q.reverse FROM (SELECT full_name AS x FROM people) q(reverse)"
        ] do
      assert refused(sql) =~ "would call", sql
    end

    assert refused("SELECT (full_name).lower FROM people") =~ "lower"
  end

  test "keeps qualified columns, fields and names the statement defines" do
    for sql <- [
          "SELECT u.name, u.* FROM users u",
          "SELECT public.users.email FROM public.users",
          "SELECT (address).city FROM people",
          "SELECT (p.address).city, (jsonb_each(p.args)).key FROM people p",
          "SELECT e.key, e.value FROM people p, jsonb_each(p.args) e",
          "SELECT q.total FROM (SELECT count(*) AS total FROM users) q",
          "WITH c(n) AS (SELECT count(*) FROM users) SELECT c.n FROM c",
          "SELECT t.v FROM (VALUES (1)) t(v)",
          "SELECT x.a FROM json_to_record('{}') AS x(a int)",
          "SELECT p.count FROM (SELECT count(*) FROM users) p"
        ] do
      assert {:ok, _} = parse(sql), sql
    end
  end

  test "allows case changes only where they cannot shape the result" do
    assert refused("SELECT lower(email) FROM users") =~
             "lower() is not available in the select list"

    assert refused("SELECT x FROM (SELECT upper(name) AS x FROM users) q") =~ "upper()"

    assert refused("WITH c AS (SELECT initcap(name) AS n FROM users) SELECT n FROM c") =~
             "initcap()"

    for sql <- [
          "SELECT u.id, l FROM users u CROSS JOIN LATERAL lower(u.name) AS l",
          "SELECT l FROM users u, LATERAL lower(u.name) l",
          "SELECT v FROM users u, LATERAL (VALUES (upper(u.name))) t(v)",
          "SELECT w FROM users u, unnest(string_to_array(lower(u.name), ' ')) w",
          "SELECT l FROM users u, ROWS FROM (initcap(u.name)) l",
          "VALUES (lower('x'))"
        ] do
      assert refused(sql) =~ "is not available in the select list, FROM functions or VALUES",
             sql
    end
  end

  test "refuses functions from application schemas" do
    assert refused("SELECT public.lower(name) FROM users") =~ "public.lower()"
  end

  test "refuses casts to bytea" do
    assert refused("SELECT name::bytea FROM users") =~ "bytea"
    assert refused("SELECT CAST(name AS pg_catalog.bytea) FROM users") =~ "bytea"
  end

  test "refuses XMLTABLE, whose XPath functions go unchecked" do
    assert refused(
             "SELECT * FROM users, XMLTABLE('/a' PASSING xmlparse(document '<a/>') " <>
               "COLUMNS n text PATH 'translate(., \"a\", \"b\")') x"
           ) =~ "xmltable()"
  end

  test "refuses planner statistics and anything but one SELECT or EXPLAIN" do
    assert refused("SELECT * FROM pg_stats") =~ "pg_stats exposes sample column values"
    assert refused("DELETE FROM users") =~ "Only SELECT and EXPLAIN"

    assert refused("EXPLAIN ANALYZE DELETE FROM users") =~
             "Only SELECT statements can be explained"

    assert refused("SELECT 1; SELECT 2") =~ "exactly one statement"
  end
end
