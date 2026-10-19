defmodule AnonimizedMcp.Gateway do
  @moduledoc """
  The agent-facing operations: list sources, describe a schema, run a
  read-only query, check properties of an aliased value and report a cell
  that masking missed. Every result, including database errors, leaves
  through masking; nothing here raises with data in the message.

  A query runs as one autocommit statement capped at `limit + 1` rows, and the
  connection returns to the pool before masking starts, so no transaction is
  held while results are processed.
  """

  alias AnonimizedMcp.Debugging.LeakReport
  alias AnonimizedMcp.Gateway.{Literals, Results}
  alias AnonimizedMcp.Masking
  alias AnonimizedMcp.Masking.{Aliases, Identifiers}
  alias AnonimizedMcp.Sources
  alias AnonimizedMcp.Sources.Catalog

  @max_limit 500
  @select_prefix "SELECT * FROM (\n"

  # Planner statistics hold sample values of every readable column.
  @blocked_relations ~w(pg_stats pg_statistic pg_stats_ext pg_stats_ext_exprs pg_statistic_ext_data)

  @doc "Lists the configured sources."
  @spec list_sources() :: [%{name: String.t(), description: String.t()}]
  def list_sources, do: Enum.map(Sources.all(), &Map.take(&1, [:name, :description]))

  @doc "Describes all tables of a source, or the columns of one table."
  @spec describe(String.t(), String.t() | nil, boolean()) :: {:ok, map()} | {:error, String.t()}
  def describe(source_name, table \\ nil, refresh? \\ false) do
    with {:ok, source} <- Sources.fetch(source_name),
         {:ok, catalog} <- catalog(source, refresh?) do
      case table do
        nil ->
          tables =
            catalog
            |> Enum.sort()
            |> Enum.map(fn {name, t} ->
              %{
                name: name,
                estimated_rows: t.estimated_rows,
                columns: Enum.map(t.columns, & &1.name)
              }
            end)

          {:ok, %{tables: tables}}

        table ->
          name = if String.contains?(table, "."), do: table, else: "public." <> table

          case Map.fetch(catalog, name) do
            {:ok, t} ->
              {:ok, Map.put(t, :name, name)}

            :error ->
              {:error,
               "Unknown table #{inspect(table)}. Call describe_schema without a table to list them."}
          end
      end
    end
  end

  @doc "Runs a read-only SELECT or EXPLAIN and returns the masked result."
  @spec query(String.t(), String.t(), pos_integer()) :: {:ok, map()} | {:error, String.t()}
  def query(source_name, sql, limit \\ 100) do
    limit = limit |> max(1) |> min(@max_limit)
    sql = sql |> String.trim() |> String.trim_trailing(";")

    with {:ok, source} <- Sources.fetch(source_name),
         {:ok, statement} <- parse(sql),
         {:ok, rewritten, params} <- Literals.substitute(sql, source.name) do
      started = System.monotonic_time(:millisecond)

      case execute(source, statement, rewritten, params, limit) do
        {:ok, query, result} ->
          rows =
            Masking.mask(
              source.name,
              query.columns,
              query.result_types,
              Enum.take(result.rows, limit)
            )

          query_id = Results.put(%{source: source.name, columns: query.columns, rows: rows})

          {:ok,
           %{
             query_id: query_id,
             columns: query.columns,
             rows: rows,
             row_count: length(rows),
             truncated: length(result.rows) > limit,
             elapsed_ms: System.monotonic_time(:millisecond) - started
           }}

        {:error, error} ->
          # Error positions refer to the executed text; map them back to the agent's SQL.
          wrapper = if select?(statement), do: byte_size(@select_prefix), else: 0
          shift = wrapper + byte_size(rewritten) - byte_size(sql)
          {:error, database_error(source.name, error, shift)}
      end
    end
  end

  @doc """
  Reports properties of the value behind `alias` (whitespace, length,
  character classes, checksums) and, with `compare_with`, how it relates to
  another aliased value. The value itself is never returned.
  """
  @spec check_value(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def check_value(source_name, alias, compare_with \\ nil) do
    with {:ok, source} <- Sources.fetch(source_name),
         {:ok, entry} <- lookup(source.name, alias),
         {:ok, other} <- if(compare_with, do: lookup(source.name, compare_with), else: {:ok, nil}) do
      value = entry.canonical

      properties = %{
        type: entry.type,
        length: String.length(value),
        byte_size: byte_size(value),
        ascii_only: String.match?(value, ~r/^[\x20-\x7E]*$/),
        digits_only: String.match?(value, ~r/^\d+$/),
        contains_whitespace: String.match?(value, ~r/\s/u),
        contains_double_space: String.contains?(value, "  "),
        contains_control_or_invisible:
          String.match?(value, ~r/[\p{C}\x{00A0}\x{200B}-\x{200D}\x{FEFF}]/u),
        uppercase_letters: String.match?(value, ~r/\p{Lu}/u),
        lowercase_letters: String.match?(value, ~r/\p{Ll}/u),
        unicode_nfc_normalized: value == String.normalize(value, :nfc),
        valid_nip: Identifiers.nip?(String.replace(value, "-", "")),
        valid_pesel: Identifiers.pesel?(value),
        valid_regon: Identifiers.regon?(value),
        valid_iban: Identifiers.iban?(value),
        valid_email: String.match?(value, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/)
      }

      comparison =
        if other do
          norm =
            &(&1 |> String.normalize(:nfc) |> String.downcase() |> String.replace(~r/[\s-]/u, ""))

          %{
            compared_with: compare_with,
            equal: value == other.canonical,
            equal_ignoring_case: String.downcase(value) == String.downcase(other.canonical),
            equal_ignoring_case_whitespace_and_dashes: norm.(value) == norm.(other.canonical),
            one_contains_the_other:
              String.contains?(value, other.canonical) or String.contains?(other.canonical, value)
          }
        end

      {:ok,
       %{
         alias: alias,
         note:
           "Aliases strip surrounding whitespace; it is shown around the alias in query results.",
         properties: properties,
         comparison: comparison
       }}
    end
  end

  @doc """
  Records that a cell of an earlier result still shows personal data. The
  cell is taken from the stored result, so the agent never has to repeat it.
  """
  @spec report_leak(
          String.t(),
          String.t(),
          non_neg_integer(),
          String.t(),
          String.t() | nil,
          map() | nil
        ) ::
          {:ok, map()} | {:error, String.t()}
  def report_leak(source_name, query_id, row, column, note, reporter) do
    with {:ok, source} <- Sources.fetch(source_name),
         {:ok, cell} <- Results.cell(source.name, query_id, row, column) do
      LeakReport
      |> Ash.Changeset.for_create(:report, %{
        source: source.name,
        query_id: query_id,
        row: row,
        column: column,
        cell: %{"value" => cell},
        note: note,
        reporter_id: reporter && reporter.id
      })
      |> Ash.create!(authorize?: false)

      {:ok, %{reported: true}}
    end
  end

  defp lookup(source, alias) do
    case Aliases.lookup(source, alias) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, "Unknown alias #{inspect(alias)} for source #{inspect(source)}."}
    end
  end

  defp catalog(source, refresh?) do
    case Catalog.get(source, refresh?) do
      {:ok, catalog} -> {:ok, catalog}
      {:error, error} -> {:error, database_error(source.name, error, 0)}
    end
  end

  defp parse(sql) do
    case PgQuery.parse(sql) do
      {:ok, %{stmts: [%{stmt: %PgQuery.Node{node: {kind, _}} = statement}]}}
      when kind in [:select_stmt, :explain_stmt] ->
        case Enum.find(relations(statement, []), &(&1 in @blocked_relations)) do
          nil -> {:ok, statement}
          name -> {:error, "#{name} exposes sample column values and is not available."}
        end

      {:ok, %{stmts: [_]}} ->
        {:error, "Only SELECT and EXPLAIN statements are allowed."}

      {:ok, %{stmts: _}} ->
        {:error, "Send exactly one statement."}

      {:error, %{message: message, cursorpos: position}} ->
        {:error, "Syntax error at position #{position}: #{message}"}
    end
  end

  defp relations(%PgQuery.RangeVar{relname: name}, acc), do: [name | acc]

  defp relations(%_{} = struct, acc),
    do: struct |> Map.from_struct() |> Map.values() |> relations(acc)

  defp relations({_tag, value}, acc), do: relations(value, acc)
  defp relations(list, acc) when is_list(list), do: Enum.reduce(list, acc, &relations/2)
  defp relations(_other, acc), do: acc

  defp execute(source, statement, sql, params, limit) do
    sql =
      if select?(statement),
        do: "#{@select_prefix}#{sql}\n) AS anonimized_mcp_query LIMIT #{limit + 1}",
        else: sql

    Postgrex.prepare_execute(Sources.connection(source), "", sql, params)
  end

  defp select?(statement), do: match?(%PgQuery.Node{node: {:select_stmt, _}}, statement)

  # Data exceptions (class 22) quote the offending input; drop the quotes.
  defp database_error(
         source,
         %Postgrex.Error{postgres: %{code: code, pg_code: pg_code} = pg},
         shift
       ) do
    message =
      if String.starts_with?(pg_code, "22"),
        do: String.replace(pg.message, ~r/"[^"]*"|'[^']*'/, "<value>"),
        else: Masking.scrub(source, pg.message)

    position =
      case pg[:position] do
        nil ->
          ""

        pos ->
          " at position #{max(String.to_integer(to_string(pos)) - shift, 1)}"
      end

    "Database error #{pg_code} (#{code})#{position}: #{message}"
  end

  defp database_error(_source, %DBConnection.ConnectionError{}, _shift),
    do: "The database is unreachable or the query timed out."

  defp database_error(_source, _error, _shift), do: "The query failed."
end
