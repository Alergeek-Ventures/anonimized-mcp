defmodule AnonimizedMcp.Gateway.Lineage do
  @moduledoc """
  Works out which table columns feed each output column of a SELECT, so
  masking follows the data through aliases, `*`, joins, CTEs, subqueries,
  set operations and expressions such as `concat(u.email, '')` or
  `row_to_json(u)`.

  The result is conservative where it is cheap to be: any reference that
  cannot be resolved marks the output `unknown?`, and a whole-row reference
  (`row_to_json(u)`) depends on every column of that row.
  """

  @type ref :: {table :: String.t(), column :: String.t()}
  @type output :: %{
          name: String.t() | nil,
          refs: MapSet.t(ref()),
          direct: ref() | nil,
          count?: boolean(),
          json_key: String.t() | nil,
          unknown?: boolean()
        }

  defp output(attrs \\ []),
    do:
      Map.merge(
        %{
          name: nil,
          refs: MapSet.new(),
          direct: nil,
          count?: false,
          json_key: nil,
          unknown?: false
        },
        Map.new(attrs)
      )

  @doc """
  Returns one entry per output column of `statement` (a parsed `PgQuery.Node`),
  or `:unknown` when the column count cannot be determined.
  """
  @spec outputs(PgQuery.Node.t(), AnonimizedMcp.Sources.Catalog.t()) :: [output()] | :unknown
  def outputs(%PgQuery.Node{node: {:select_stmt, select}}, catalog) do
    outputs = select(select, catalog, %{}, [])
    if Enum.any?(outputs, &(&1 == :star)), do: :unknown, else: outputs
  rescue
    # Shapes this module does not model (e.g. data-modifying CTEs) are rejected
    # by the read-only role anyway; masking then treats every column as unknown.
    _ -> :unknown
  end

  def outputs(_statement, _catalog), do: :unknown

  # `outer` is the enclosing query's scope, visible to correlated subqueries
  # and LATERAL items.
  defp select(%PgQuery.SelectStmt{op: op} = s, catalog, ctes, outer) when op != :SETOP_NONE do
    ctes = with_ctes(s.with_clause, catalog, ctes)
    left = select(s.larg, catalog, ctes, outer)
    right = select(s.rarg, catalog, ctes, outer)

    if :star in left or :star in right or length(left) != length(right) do
      [:star]
    else
      Enum.zip_with(left, right, &merge/2)
    end
  end

  defp select(%PgQuery.SelectStmt{values_lists: [_ | _] = values}, _catalog, _ctes, _outer) do
    %PgQuery.Node{node: {:list, %{items: items}}} = hd(values)
    Enum.map(items, fn _ -> output() end)
  end

  defp select(%PgQuery.SelectStmt{} = s, catalog, ctes, outer) do
    ctes = with_ctes(s.with_clause, catalog, ctes)

    scope =
      Enum.reduce(s.from_clause, [], fn item, scope ->
        scope ++ bindings(item, catalog, ctes, scope ++ outer)
      end)

    Enum.flat_map(s.target_list, &target(&1, scope ++ outer, catalog, ctes))
  end

  defp with_ctes(nil, _catalog, ctes), do: ctes

  defp with_ctes(%PgQuery.WithClause{ctes: list, recursive: recursive}, catalog, ctes) do
    Enum.reduce(list, ctes, fn %PgQuery.Node{node: {:common_table_expr, cte}}, acc ->
      relation =
        if recursive do
          :unknown
        else
          %PgQuery.Node{node: {:select_stmt, query}} = cte.ctequery
          derived(select(query, catalog, acc, []), cte.aliascolnames)
        end

      Map.put(acc, cte.ctename, relation)
    end)
  end

  defp derived(outputs, colnames) do
    if :star in outputs do
      :unknown
    else
      names = Enum.map(colnames, &string/1)
      {:derived, Enum.with_index(outputs, fn out, i -> {Enum.at(names, i, out.name), out} end)}
    end
  end

  # FROM items become `{name, relation}` bindings; relation is a table, a
  # derived relation with named outputs, or :unknown.
  defp bindings(%PgQuery.Node{node: {:range_var, rv}}, catalog, ctes, _visible) do
    name = alias_name(rv.alias) || rv.relname

    relation =
      cond do
        rv.schemaname == "" and Map.has_key?(ctes, rv.relname) ->
          Map.fetch!(ctes, rv.relname)

        true ->
          table = "#{if rv.schemaname == "", do: "public", else: rv.schemaname}.#{rv.relname}"

          case Map.fetch(catalog, table) do
            {:ok, %{columns: columns}} -> {:table, table, Enum.map(columns, & &1.name)}
            :error -> :unknown
          end
      end

    [{name, relation}]
  end

  defp bindings(%PgQuery.Node{node: {:join_expr, join}}, catalog, ctes, visible) do
    left = bindings(join.larg, catalog, ctes, visible)
    left ++ bindings(join.rarg, catalog, ctes, left ++ visible)
  end

  defp bindings(%PgQuery.Node{node: {:range_subselect, sub}}, catalog, ctes, visible) do
    %PgQuery.Node{node: {:select_stmt, query}} = sub.subquery
    colnames = if sub.alias, do: sub.alias.colnames, else: []
    [{alias_name(sub.alias), derived(select(query, catalog, ctes, visible), colnames)}]
  end

  defp bindings(%PgQuery.Node{node: {_other, item}}, _catalog, _ctes, _visible),
    do: [{alias_name(Map.get(item, :alias)), :unknown}]

  defp alias_name(%PgQuery.Alias{aliasname: name}) when name != "", do: name
  defp alias_name(_), do: nil

  defp target(%PgQuery.Node{node: {:res_target, %{val: val, name: name}}}, scope, catalog, ctes) do
    case column_ref(val) do
      [:star] ->
        Enum.flat_map(scope, &expand/1)

      [relation, :star] ->
        scope |> Enum.filter(&(elem(&1, 0) == relation)) |> Enum.flat_map(&expand/1)

      _ ->
        [%{expression(val, scope, catalog, ctes) | name: output_name(name, val)}]
    end
  end

  # The column name Postgres gives an output, needed to resolve CTE and subquery columns.
  defp output_name(name, _val) when name != "", do: name

  defp output_name(_name, val) do
    case val do
      %PgQuery.Node{node: {:column_ref, _}} -> val |> column_ref() |> List.last()
      %PgQuery.Node{node: {:func_call, %{funcname: names}}} -> names |> List.last() |> string()
      _ -> "?column?"
    end
  end

  defp expand({_name, {:table, table, columns}}),
    do: Enum.map(columns, &output(name: &1, refs: MapSet.new([{table, &1}]), direct: {table, &1}))

  defp expand({_name, {:derived, outputs}}), do: Enum.map(outputs, &elem(&1, 1))
  defp expand({_name, :unknown}), do: [:star]

  defp expression(val, scope, catalog, ctes) do
    resolved =
      val
      |> collect([])
      |> Enum.map(fn
        {:column, fields} ->
          resolve(fields, scope)

        {:sublink, query} ->
          query |> select(catalog, ctes, scope) |> Enum.reduce(output(), &merge/2)
      end)
      |> Enum.reduce(output(), &merge/2)

    direct =
      with [_ | _] = fields <- column_ref(val),
           %{direct: {_, _} = ref} <- resolve(fields, scope),
           do: ref,
           else: (_ -> nil)

    %{resolved | direct: direct, count?: count?(val), json_key: json_key(val)}
  end

  defp resolve(fields, scope) do
    case fields do
      [column] ->
        scope
        |> Enum.map(&lookup(&1, column))
        |> Enum.reject(&is_nil/1)
        |> or_whole_row(scope, column)

      [relation, :star] ->
        whole_row(scope, relation)

      [relation, column] ->
        lookup_in(scope, relation, column)

      [_schema, relation, column] ->
        lookup_in(scope, relation, column)

      _ ->
        []
    end
    |> case do
      [] -> output(unknown?: true)
      [single] -> single
      many -> many |> Enum.reduce(output(), &merge/2) |> Map.put(:direct, nil)
    end
  end

  # A bare relation name used as a value (`row_to_json(u)`) is a whole-row reference.
  defp or_whole_row([], scope, name), do: whole_row(scope, name)
  defp or_whole_row(found, _scope, _name), do: found

  defp whole_row(scope, relation) do
    scope
    |> Enum.filter(&(elem(&1, 0) == relation))
    |> Enum.flat_map(&expand/1)
    |> Enum.map(fn
      :star -> output(unknown?: true)
      out -> out
    end)
  end

  defp lookup_in(scope, relation, column) do
    case Enum.filter(scope, &(elem(&1, 0) == relation)) do
      [] ->
        []

      bindings ->
        bindings |> Enum.map(&lookup(&1, column)) |> Enum.map(&(&1 || output(unknown?: true)))
    end
  end

  defp lookup({_name, {:table, table, columns}}, column) do
    if column in columns,
      do: output(name: column, refs: MapSet.new([{table, column}]), direct: {table, column})
  end

  defp lookup({_name, {:derived, outputs}}, column) do
    Enum.find_value(outputs, fn {name, out} -> if name == column, do: out end)
  end

  defp lookup({_name, :unknown}, _column), do: output(unknown?: true)

  defp merge(a, b) do
    %{
      name: a.name,
      refs: MapSet.union(a.refs, b.refs),
      direct: nil,
      count?: false,
      json_key: nil,
      unknown?: a.unknown? or b.unknown?
    }
  end

  defp collect(%PgQuery.Node{node: {:column_ref, %{fields: fields}}}, acc),
    do: [{:column, Enum.map(fields, &field/1)} | acc]

  defp collect(
         %PgQuery.Node{
           node: {:sub_link, %{subselect: %PgQuery.Node{node: {:select_stmt, s}}} = link}
         },
         acc
       ),
       do: collect(link.testexpr, [{:sublink, s} | acc])

  defp collect(%_{} = struct, acc),
    do: struct |> Map.from_struct() |> Map.values() |> collect(acc)

  defp collect({_tag, value}, acc), do: collect(value, acc)
  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect(_other, acc), do: acc

  defp column_ref(%PgQuery.Node{node: {:column_ref, %{fields: fields}}}),
    do: Enum.map(fields, &field/1)

  defp column_ref(_), do: nil

  defp field(%PgQuery.Node{node: {:a_star, _}}), do: :star
  defp field(node), do: string(node)

  defp string(%PgQuery.Node{node: {:string, %{sval: value}}}), do: value

  defp count?(%PgQuery.Node{node: {:func_call, %{funcname: names}}}),
    do: names |> List.last() |> string() == "count"

  defp count?(_), do: false

  # `data->>'email'` and `data->'email'` take the masking of the key they extract.
  defp json_key(%PgQuery.Node{node: {:a_expr, %{kind: :AEXPR_OP, name: [op], rexpr: rexpr}}}) do
    with operator when operator in ["->", "->>"] <- string(op),
         %PgQuery.Node{node: {:a_const, %{val: {:sval, %{sval: key}}}}} <- rexpr do
      key
    else
      _ -> nil
    end
  end

  defp json_key(_), do: nil
end
