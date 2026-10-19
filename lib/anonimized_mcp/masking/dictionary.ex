defmodule AnonimizedMcp.Masking.Dictionary do
  @moduledoc """
  Preloads the alias map with the distinct values of every column the policy
  marks as personal. Names in free text ("Przelew od Jana Kowalskiego") have
  no pattern to detect, but they usually belong to someone stored in a
  structured column; with the dictionary loaded, text scrubbing recognises
  them even in an agent's first query. Values never leave this node.
  """

  alias AnonimizedMcp.Masking.{Aliases, Policy}
  alias AnonimizedMcp.Sources

  @ttl_ms :timer.minutes(10)
  @per_column 50_000

  @doc "Loads the dictionary of `source` unless it was loaded recently."
  @spec ensure_loaded(Sources.t(), AnonimizedMcp.Sources.Catalog.t()) :: :ok
  def ensure_loaded(source, catalog) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, source.name}, nil) do
      loaded_at when is_integer(loaded_at) and now - loaded_at < @ttl_ms ->
        :ok

      _ ->
        load(source, catalog)
        :persistent_term.put({__MODULE__, source.name}, now)
    end
  end

  defp load(source, catalog) do
    conn = Sources.connection(source)

    for {table, %{columns: columns}} <- catalog,
        %{name: column, type: type} <- columns,
        {:pii, alias_type} <- [Policy.classify(source, table, column, type)],
        type in ["text", "character varying", "citext"] do
      sql =
        "SELECT DISTINCT #{quote_ident(column)} FROM #{quote_table(table)} " <>
          "WHERE #{quote_ident(column)} IS NOT NULL LIMIT #{@per_column}"

      # A column that cannot be read only weakens free-text scrubbing.
      with {:ok, %{rows: rows}} <- Postgrex.query(conn, sql, []) do
        for [value] <- rows,
            String.trim(value) != "",
            do: Aliases.alias_for(source.name, alias_type, String.trim(value))
      end
    end

    :ok
  end

  defp quote_table(table),
    do: table |> String.split(".", parts: 2) |> Enum.map_join(".", &quote_ident/1)

  defp quote_ident(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
