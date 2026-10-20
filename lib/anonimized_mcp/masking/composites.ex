defmodule AnonimizedMcp.Masking.Composites do
  @moduledoc """
  Field names of composite result columns, such as the row of
  `SELECT c FROM customers c`, so masking can apply its column-name rules to
  each field. Postgrex decodes composites to bare tuples; their names come
  from `pg_attribute`, looked up only when a result holds a named composite.
  """

  @fields_sql """
  SELECT t.oid::bigint, array_agg(a.attname::text ORDER BY a.attnum)
  FROM pg_type t
  JOIN pg_attribute a ON a.attrelid = t.typrelid AND a.attnum > 0 AND NOT a.attisdropped
  WHERE t.oid = ANY($1::bigint[]::oid[])
  GROUP BY t.oid
  """

  @typedoc """
  A record's fields as `{name, field}`, where `name` is nil when the lookup
  failed, an array's element, a UUID, or nil for anything else.
  """
  @type field :: {:record, [{String.t() | nil, field()}]} | {:array, field()} | :uuid | nil

  @doc "Returns the field tree of each result column, given Postgrex result oids and types."
  @spec fields(DBConnection.conn(), [non_neg_integer()], list()) :: [field()]
  def fields(conn, oids, types) do
    trees = Enum.zip_with(oids || [], types || [], &tree/2)

    names =
      case trees |> Enum.flat_map(&records/1) |> Enum.uniq() do
        [] ->
          %{}

        records ->
          case Postgrex.query(conn, @fields_sql, [records]) do
            {:ok, %{rows: rows}} -> Map.new(rows, fn [oid, names] -> {oid, names} end)
            {:error, _error} -> %{}
          end
      end

    Enum.map(trees, &name(&1, names))
  end

  defp tree(oid, {Postgrex.Extensions.Record, field_oids, field_types, _size}),
    do: tree(oid, {Postgrex.Extensions.Record, field_oids, field_types})

  defp tree(oid, {Postgrex.Extensions.Record, field_oids, field_types})
       when is_list(field_oids) and is_list(field_types),
       do: {:record, oid, Enum.zip_with(field_oids, field_types, &tree/2)}

  defp tree(_oid, {Postgrex.Extensions.Array, [elem_oid], [elem_type], _size}),
    do: tree(nil, {Postgrex.Extensions.Array, [elem_oid], [elem_type]})

  defp tree(_oid, {Postgrex.Extensions.Array, [elem_oid], [elem_type]}) do
    case tree(elem_oid, elem_type) do
      nil -> nil
      elem -> {:array, elem}
    end
  end

  defp tree(_oid, {Postgrex.Extensions.UUID, _}), do: :uuid
  defp tree(_oid, Postgrex.Extensions.UUID), do: :uuid
  defp tree(_oid, _type), do: nil

  defp records({:record, oid, fields}), do: [oid | Enum.flat_map(fields, &records/1)]
  defp records({:array, elem}), do: records(elem)
  defp records(_tree), do: []

  defp name({:record, oid, fields}, names) do
    field_names = Map.get(names, oid, [])

    field_names =
      if length(field_names) == length(fields),
        do: field_names,
        else: List.duplicate(nil, length(fields))

    {:record, Enum.zip_with(field_names, fields, &{&1, name(&2, names)})}
  end

  defp name({:array, elem}, names), do: {:array, name(elem, names)}
  defp name(tree, _names), do: tree
end
