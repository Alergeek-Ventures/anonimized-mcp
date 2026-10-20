defmodule AnonimizedMcp.Sources.Catalog do
  @moduledoc """
  Tables, columns and foreign keys a source's role can read, cached for a few
  minutes, so agents can find their way around without querying
  `information_schema` themselves.
  """

  alias AnonimizedMcp.Sources

  @ttl_ms :timer.minutes(5)

  @type column :: %{name: String.t(), type: String.t(), nullable: boolean()}
  @type table :: %{
          columns: [column()],
          estimated_rows: integer() | nil,
          foreign_keys: [String.t()]
        }
  @type t :: %{String.t() => table()}

  @columns_sql """
  SELECT c.table_schema || '.' || c.table_name, c.column_name,
         CASE WHEN c.data_type IN ('ARRAY', 'USER-DEFINED') THEN c.udt_name ELSE c.data_type END,
         c.is_nullable = 'YES'
  FROM information_schema.columns c
  WHERE c.table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  ORDER BY 1, c.ordinal_position
  """

  @details_sql """
  SELECT n.nspname || '.' || c.relname,
         CASE WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END,
         ARRAY(SELECT pg_get_constraintdef(k.oid) FROM pg_constraint k
               WHERE k.conrelid = c.oid AND k.contype = 'f' ORDER BY k.conname)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  """

  # Every name `x.name` or `(x).name` can select: columns of tables, views and
  # composite types (system catalogs included) and output fields of functions.
  @names_sql """
  SELECT a.attname::text FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
  WHERE NOT a.attisdropped AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'c')
  UNION
  SELECT u.name FROM pg_proc p, unnest(p.proargnames, p.proargmodes) AS u(name, mode)
  WHERE u.mode IN ('o', 'b', 't') AND u.name <> ''
  """

  @doc """
  Returns the names a field selection can refer to in `source`, so the
  gateway can tell `alias.column` from attribute notation calling a function.
  """
  @spec names(Sources.t()) :: {:ok, MapSet.t(String.t())} | {:error, Postgrex.Error.t()}
  def names(%Sources{name: name} = source) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, name, :names}, nil) do
      {loaded_at, names} when now - loaded_at < @ttl_ms ->
        {:ok, names}

      _ ->
        with {:ok, result} <- Postgrex.query(Sources.connection(source), @names_sql, []) do
          names = MapSet.new(result.rows, &hd/1)
          :persistent_term.put({__MODULE__, name, :names}, {now, names})
          {:ok, names}
        end
    end
  end

  @doc "Returns the cached catalog of `source`, loading it when stale or `refresh?`."
  @spec get(Sources.t(), boolean()) :: {:ok, t()} | {:error, Postgrex.Error.t()}
  def get(%Sources{name: name} = source, refresh? \\ false) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, name}, nil) do
      {loaded_at, catalog} when not refresh? and now - loaded_at < @ttl_ms ->
        {:ok, catalog}

      _ ->
        with {:ok, catalog} <- load(source) do
          :persistent_term.put({__MODULE__, name}, {now, catalog})
          {:ok, catalog}
        end
    end
  end

  defp load(source) do
    conn = Sources.connection(source)

    with {:ok, columns} <- Postgrex.query(conn, @columns_sql, []),
         {:ok, details} <- Postgrex.query(conn, @details_sql, []) do
      details = Map.new(details.rows, fn [table, rows, fks] -> {table, {rows, fks}} end)

      catalog =
        columns.rows
        |> Enum.group_by(&hd/1, fn [_, name, type, nullable] ->
          %{name: name, type: type, nullable: nullable}
        end)
        |> Map.new(fn {table, columns} ->
          {rows, fks} = Map.get(details, table, {nil, []})
          {table, %{columns: columns, estimated_rows: rows, foreign_keys: fks}}
        end)

      {:ok, catalog}
    end
  end
end
