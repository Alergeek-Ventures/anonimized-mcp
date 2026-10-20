defmodule AnonimizedMcp.Gateway.QueryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AnonimizedMcp.Gateway
  alias AnonimizedMcp.Sources

  # The test database stands in for a source; queries use literals, not tables.
  setup do
    sources = Application.get_env(:anonimized_mcp, :sources, %{})
    repo = Application.fetch_env!(:anonimized_mcp, AnonimizedMcp.Repo)

    url =
      "postgres://#{repo[:username]}:#{repo[:password]}@#{repo[:hostname]}:#{repo[:port]}/" <>
        repo[:database]

    Application.put_env(:anonimized_mcp, :sources, %{"gw" => [url: url]})
    on_exit(fn -> Application.put_env(:anonimized_mcp, :sources, sources) end)

    [_registry | pools] = Sources.child_specs()
    Enum.each(pools, &start_supervised!/1)
    :ok
  end

  defp alias_of(sql) do
    assert {:ok, %{rows: [[alias]]}} = Gateway.query("gw", sql)
    alias
  end

  test "strips the whole quoted input from data exceptions and masks the rest" do
    for value <- [
          ~s(Firma "Piotr Nowakowski" Sp. j.),
          ~s({"contact": "Ewa Kamińska", "phone": "512 345 678"})
        ] do
      sql = "SELECT id FROM (SELECT 1 AS id, '#{value}'::text AS meta) t WHERE meta::int = 5"
      assert {:error, message} = Gateway.query("gw", sql)
      assert message =~ "22P02"
      refute message =~ ~r/Piotr|Nowakowski|Ewa|Kamińska|512 345 678|contact/
    end
  end

  test "asks for a text cast when an alias meets a column that is not text" do
    birth_date = alias_of("SELECT DATE '1990-11-02' AS birth_date")
    assert birth_date =~ ~r/^BIRTHDATE_/

    log =
      capture_log(fn ->
        assert {:error, message} =
                 Gateway.query("gw", "SELECT 1 AS one WHERE DATE '1990-11-02' = '#{birth_date}'")

        assert message =~ "birth_date::text = 'BIRTHDATE_...'"
        refute message =~ "1990"
      end)

    refute log =~ "1990"

    assert {:ok, %{rows: [[1]]}} =
             Gateway.query(
               "gw",
               "SELECT 1 AS one WHERE (DATE '1990-11-02')::text = '#{birth_date}'"
             )
  end

  test "refuses EXPLAIN with aliases, whose plan would print their values" do
    email = alias_of("SELECT 'jan.kowalski@example.com' AS email")

    assert {:error, "EXPLAIN cannot use aliases" <> _} =
             Gateway.query("gw", "EXPLAIN SELECT 1 WHERE lower('#{email}') = 'x'")

    assert {:ok, %{rows: [[1]]}} =
             Gateway.query("gw", "SELECT 1 AS one WHERE '#{email}' = 'jan.kowalski@example.com'")

    assert {:ok, _} = Gateway.query("gw", "EXPLAIN SELECT 1 WHERE lower('x') = 'x'")
  end

  test "refuses attribute notation calls but keeps catalog columns" do
    assert {:error, message} =
             Gateway.query("gw", "SELECT (name).reverse FROM (VALUES ('x')) t(name)")

    assert message =~ "would call reverse(x)"

    assert {:error, _} = Gateway.query("gw", "SELECT (42::bigint).pg_advisory_lock AS locked")

    assert {:ok, _} =
             Gateway.query("gw", "SELECT a.application_name FROM pg_stat_activity a LIMIT 1")
  end

  # Masking of birth-named arrays raised with the cells in the message; whether
  # or not masking handles them, nothing may raise or log the value.
  test "never raises or logs cell values" do
    log =
      capture_log(fn ->
        result = Gateway.query("gw", "SELECT ARRAY[DATE '1990-11-02'] AS birth_dates")

        case result do
          {:error, message} -> assert message == "The query failed unexpectedly."
          {:ok, %{rows: [[cell]]}} -> refute inspect(cell) =~ "1990"
        end
      end)

    refute log =~ "1990"
  end
end
