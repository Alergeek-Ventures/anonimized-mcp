defmodule AnonimizedMcp.Gateway.StatementTest do
  use ExUnit.Case, async: true

  alias AnonimizedMcp.Gateway.Statement

  defp refused(sql) do
    assert {:error, message} = Statement.parse(sql)
    message
  end

  test "runs typical debugging queries" do
    for sql <- [
          "SELECT state, count(*) FROM oban.oban_jobs GROUP BY state",
          "SELECT date_trunc('day', inserted_at), max(attempt) FROM oban.oban_jobs GROUP BY 1",
          "SELECT args->>'id', jsonb_array_length(errors) FROM oban.oban_jobs",
          "SELECT lower(trim(email)), length(name), substring(name FROM 1 FOR 3) FROM users",
          "SELECT extract(year FROM issue_date), coalesce(note, '-') FROM sales_invoices",
          "SELECT inserted_at AT TIME ZONE 'Europe/Warsaw', id::text FROM users",
          "SELECT row_number() OVER (ORDER BY id), pg_catalog.upper(name) FROM users",
          "SELECT d FROM generate_series(now() - interval '1 day', now(), interval '1 hour') d",
          "EXPLAIN SELECT * FROM users WHERE lower(email) = 'x'"
        ] do
      assert {:ok, _} = Statement.parse(sql), sql
    end
  end

  test "refuses functions that rewrite text beyond recognition, wherever they appear" do
    assert refused("SELECT reverse(name) FROM users") =~ "reverse() is not available"
    assert refused("SELECT pg_catalog.REVERSE(name) FROM users") =~ "reverse()"
    assert refused("SELECT id FROM users WHERE translate(name, 'a', 'b') = 'x'") =~ "translate()"

    assert refused("SELECT (SELECT encode(convert_to(name, 'UTF8'), 'base64')) FROM users") =~
             "encode()"
  end

  test "refuses functions from application schemas" do
    assert refused("SELECT public.lower(name) FROM users") =~ "public.lower()"
  end

  test "refuses casts to bytea" do
    assert refused("SELECT name::bytea FROM users") =~ "bytea"
    assert refused("SELECT CAST(name AS pg_catalog.bytea) FROM users") =~ "bytea"
  end

  test "refuses planner statistics and anything but one SELECT or EXPLAIN" do
    assert refused("SELECT * FROM pg_stats") =~ "pg_stats exposes sample column values"
    assert refused("DELETE FROM users") =~ "Only SELECT and EXPLAIN"
    assert refused("SELECT 1; SELECT 2") =~ "exactly one statement"
  end
end
