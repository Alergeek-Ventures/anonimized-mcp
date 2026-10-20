defmodule AnonimizedMcp.Masking.Lineage do
  @moduledoc """
  Finds, from the parsed statement, the column names each result column may
  derive from, so the credential and birth-date rules of masking also hold
  for `min(birth_date)`, `coalesce(otp_secret, '')` or `birth_date AS dob`,
  whose result labels no longer say what they hold.

  Postgres reports the source table and attribute of a result column only
  for plain column references, and Postgrex does not expose even that, so
  lineage comes from the statement. It errs towards more names: everything
  a select-list expression mentions counts, including `CASE` conditions,
  scalar subqueries and string constants shaped like column names
  (`data->>'otp_secret'`), and output names are followed through
  subqueries, CTEs and column alias lists. Where a column cannot be traced,
  such as a whole-row reference cast to text or a table whose columns were
  renamed with an alias list, its lineage holds `"*"`, which masking treats
  as possibly both a credential and a birth date.
  """

  @unknown "*"

  # Functions that keep a whole-row argument's field names, so masking can
  # apply the column-name rules to their keys.
  @structural ~w(to_json to_jsonb row_to_json json_agg jsonb_agg array_agg)

  @doc "Returns, for each result label, the names its column may derive from."
  @spec columns(PgQuery.Node.t(), [String.t()]) :: [MapSet.t(String.t())]
  def columns(%PgQuery.Node{node: {:select_stmt, select}} = statement, labels) do
    relations = relations(statement, MapSet.new())
    deps = deps(statement, relations, %{})
    everything = deps |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    derived_tables? = derived_tables?(statement)

    by_label = fn label ->
      label = String.downcase(label)

      cond do
        Map.has_key?(deps, label) -> MapSet.new([label])
        # A star over plain tables yields their real column names.
        not derived_tables? -> MapSet.new([label])
        true -> everything
      end
    end

    outputs =
      case outputs(select, relations) do
        {:ok, outputs} -> place(outputs, labels, by_label)
        :error -> nil
      end

    (outputs || Enum.map(labels, fn _ -> everything end))
    |> Enum.map(&closure(&1, deps))
  end

  def columns(_statement, labels), do: Enum.map(labels, fn _ -> MapSet.new() end)

  @doc "The lineage name standing for a column that could not be traced."
  @spec unknown() :: String.t()
  def unknown, do: @unknown

  # Select-list entries are positional except where a star expands to an
  # unknown number of columns; those take their lineage from their label.
  defp place(outputs, labels, by_label) do
    {before, rest} = Enum.split_while(outputs, &(&1 != :star))
    tail = rest |> Enum.reverse() |> Enum.take_while(&(&1 != :star)) |> Enum.reverse()
    middle = length(labels) - length(before) - length(tail)

    cond do
      rest == [] and length(outputs) == length(labels) ->
        outputs

      rest != [] and middle >= 0 ->
        before ++
          (labels |> Enum.drop(length(before)) |> Enum.take(middle) |> Enum.map(by_label)) ++
          tail

      true ->
        nil
    end
  end

  defp outputs(%PgQuery.SelectStmt{op: op, larg: larg, rarg: rarg}, relations)
       when op not in [nil, :SETOP_NONE] do
    with {:ok, left} <- outputs(larg, relations),
         {:ok, right} <- outputs(rarg, relations),
         true <- length(left) == length(right) and :star not in left and :star not in right do
      {:ok, Enum.zip_with(left, right, &MapSet.union/2)}
    else
      _ -> :error
    end
  end

  defp outputs(%PgQuery.SelectStmt{values_lists: [_ | _] = rows}, relations) do
    rows
    |> Enum.map(fn %PgQuery.Node{node: {:list, %PgQuery.List{items: items}}} ->
      Enum.map(items, &names(&1, relations))
    end)
    |> Enum.zip_with(&Enum.reduce(&1, MapSet.new(), fn set, acc -> MapSet.union(set, acc) end))
    |> then(&{:ok, &1})
  end

  defp outputs(%PgQuery.SelectStmt{target_list: targets}, relations) do
    {:ok,
     Enum.map(targets, fn %PgQuery.Node{node: {:res_target, %PgQuery.ResTarget{val: val}}} ->
       if star?(val), do: :star, else: names(val, relations)
     end)}
  end

  defp outputs(_other, _relations), do: :error

  defp star?(%PgQuery.Node{node: {:column_ref, %PgQuery.ColumnRef{fields: fields}}}),
    do: match?(%PgQuery.Node{node: {:a_star, _}}, List.last(fields))

  defp star?(_val), do: false

  # Output name => names its expression mentions, for every select list and
  # column alias list in the statement.
  defp deps(%PgQuery.SelectStmt{target_list: targets} = select, relations, acc) do
    acc =
      Enum.reduce(targets, acc, fn
        %PgQuery.Node{node: {:res_target, %PgQuery.ResTarget{name: name, val: val}}}, acc ->
          key = if name in [nil, ""], do: figure(val), else: name
          if key, do: add(acc, key, names(val, relations)), else: acc

        _other, acc ->
          acc
      end)

    select |> Map.from_struct() |> Map.values() |> deps(relations, acc)
  end

  defp deps(%PgQuery.RangeSubselect{subquery: query, alias: alias} = range, relations, acc) do
    acc = renamed(alias_columns(alias), query, relations, acc)
    range |> Map.from_struct() |> Map.values() |> deps(relations, acc)
  end

  defp deps(
         %PgQuery.CommonTableExpr{aliascolnames: columns, ctequery: query} = cte,
         relations,
         acc
       ) do
    acc = renamed(Enum.map(columns, &string/1), query, relations, acc)
    cte |> Map.from_struct() |> Map.values() |> deps(relations, acc)
  end

  defp deps(%PgQuery.RangeVar{alias: alias}, _relations, acc),
    do: Enum.reduce(alias_columns(alias), acc, &add(&2, &1, MapSet.new([@unknown])))

  defp deps(%PgQuery.RangeFunction{alias: alias} = range, relations, acc) do
    from = range |> Map.from_struct() |> Map.delete(:alias) |> names(relations)
    acc = Enum.reduce(alias_columns(alias), acc, &add(&2, &1, from))
    range |> Map.from_struct() |> Map.values() |> deps(relations, acc)
  end

  defp deps(%_{} = struct, relations, acc),
    do: struct |> Map.from_struct() |> Map.values() |> deps(relations, acc)

  defp deps(%{} = map, relations, acc), do: map |> Map.values() |> deps(relations, acc)
  defp deps({_tag, value}, relations, acc), do: deps(value, relations, acc)

  defp deps(list, relations, acc) when is_list(list),
    do: Enum.reduce(list, acc, &deps(&1, relations, &2))

  defp deps(_other, _relations, acc), do: acc

  defp closure(names, deps), do: expand(MapSet.to_list(names), names, deps)

  defp expand([], seen, _deps), do: seen

  defp expand([name | rest], seen, deps) do
    new = deps |> Map.get(name, MapSet.new()) |> MapSet.difference(seen)
    expand(MapSet.to_list(new) ++ rest, MapSet.union(seen, new), deps)
  end

  defp renamed([], _query, _relations, acc), do: acc

  defp renamed(columns, %PgQuery.Node{node: {:select_stmt, select}} = query, relations, acc) do
    positional =
      case outputs(select, relations) do
        {:ok, outputs} -> if :star in outputs, do: nil, else: outputs
        :error -> nil
      end

    all = names(query, relations)

    columns
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {column, i}, acc ->
      add(acc, column, (positional && Enum.at(positional, i)) || all)
    end)
  end

  defp renamed(columns, query, relations, acc),
    do: Enum.reduce(columns, acc, &add(&2, &1, names(query, relations)))

  defp alias_columns(%PgQuery.Alias{colnames: columns}), do: Enum.map(columns, &string/1)
  defp alias_columns(_alias), do: []

  defp add(acc, key, names),
    do: Map.update(acc, String.downcase(key), names, &MapSet.union(&1, names))

  # Column names an expression mentions. Function and type names are not
  # column names and are skipped.
  defp names(term, relations), do: names(term, relations, MapSet.new())

  defp names(%PgQuery.Node{node: {_tag, inner}}, relations, acc),
    do: names(inner, relations, acc)

  defp names(%PgQuery.ColumnRef{fields: fields}, relations, acc) do
    case Enum.map(fields, &string/1) do
      [name] when is_binary(name) ->
        if whole_row?(name, relations), do: MapSet.put(acc, @unknown), else: put(acc, name)

      parts ->
        Enum.reduce(parts, acc, fn
          nil, acc -> MapSet.put(acc, @unknown)
          part, acc -> put(acc, part)
        end)
    end
  end

  # `(c).birth_date` selects one field of a whole row.
  defp names(%PgQuery.A_Indirection{arg: arg, indirection: indirection}, relations, acc) do
    fields = indirection |> Enum.map(&string/1) |> Enum.filter(& &1)
    acc = Enum.reduce(fields, acc, &put(&2, &1))

    acc =
      if fields != [] and whole_row_ref?(arg, relations),
        do: acc,
        else: names(arg, relations, acc)

    names(indirection, relations, acc)
  end

  defp names(%PgQuery.FuncCall{funcname: funcname, args: args} = call, relations, acc) do
    name = funcname |> List.last() |> string()

    args =
      if name in @structural,
        do: Enum.reject(args, &whole_row_ref?(&1, relations)),
        else: args

    call |> Map.from_struct() |> Map.put(:args, args) |> Map.values() |> names(relations, acc)
  end

  defp names(%PgQuery.A_Const{val: {:sval, %PgQuery.String{sval: value}}}, _relations, acc) do
    if String.match?(value, ~r/^[A-Za-z_][A-Za-z0-9_]*$/), do: put(acc, value), else: acc
  end

  # A subquery inside an expression contributes what it selects, not what
  # it filters on.
  defp names(%PgQuery.SelectStmt{} = select, relations, acc) do
    [select.target_list, select.values_lists, select.larg, select.rarg]
    |> names(relations, acc)
  end

  defp names(%PgQuery.ResTarget{val: val}, relations, acc), do: names(val, relations, acc)
  defp names(%PgQuery.A_Star{}, _relations, acc), do: MapSet.put(acc, @unknown)
  defp names(%PgQuery.String{}, _relations, acc), do: acc
  defp names(%PgQuery.TypeName{}, _relations, acc), do: acc

  defp names(%_{} = struct, relations, acc),
    do: struct |> Map.from_struct() |> Map.values() |> names(relations, acc)

  defp names(%{} = map, relations, acc), do: map |> Map.values() |> names(relations, acc)
  defp names({_tag, value}, relations, acc), do: names(value, relations, acc)

  defp names(list, relations, acc) when is_list(list),
    do: Enum.reduce(list, acc, &names(&1, relations, &2))

  defp names(_other, _relations, acc), do: acc

  defp put(acc, name), do: MapSet.put(acc, String.downcase(name))

  defp whole_row?(name, relations), do: MapSet.member?(relations, String.downcase(name))

  defp whole_row_ref?(
         %PgQuery.Node{node: {:column_ref, %PgQuery.ColumnRef{fields: [field]}}},
         relations
       ) do
    name = string(field)
    is_binary(name) and whole_row?(name, relations)
  end

  defp whole_row_ref?(_node, _relations), do: false

  # Table, alias and CTE names: a bare column reference to one of them is a
  # whole row.
  defp relations(%PgQuery.RangeVar{relname: name, alias: alias}, acc),
    do: acc |> MapSet.put(String.downcase(name)) |> alias_name(alias)

  defp relations(%PgQuery.RangeSubselect{alias: alias} = range, acc),
    do: range |> Map.from_struct() |> Map.values() |> relations(alias_name(acc, alias))

  defp relations(%PgQuery.RangeFunction{alias: alias} = range, acc),
    do: range |> Map.from_struct() |> Map.values() |> relations(alias_name(acc, alias))

  defp relations(%PgQuery.JoinExpr{alias: alias} = join, acc),
    do: join |> Map.from_struct() |> Map.values() |> relations(alias_name(acc, alias))

  defp relations(%PgQuery.CommonTableExpr{ctename: name} = cte, acc),
    do: cte |> Map.from_struct() |> Map.values() |> relations(MapSet.put(acc, name))

  defp relations(%_{} = struct, acc),
    do: struct |> Map.from_struct() |> Map.values() |> relations(acc)

  defp relations(%{} = map, acc), do: map |> Map.values() |> relations(acc)
  defp relations({_tag, value}, acc), do: relations(value, acc)
  defp relations(list, acc) when is_list(list), do: Enum.reduce(list, acc, &relations/2)
  defp relations(_other, acc), do: acc

  defp alias_name(acc, %PgQuery.Alias{aliasname: name}) when name not in [nil, ""],
    do: MapSet.put(acc, String.downcase(name))

  defp alias_name(acc, _alias), do: acc

  defp derived_tables?(term) do
    case term do
      %PgQuery.RangeSubselect{} -> true
      %PgQuery.RangeFunction{} -> true
      %PgQuery.CommonTableExpr{} -> true
      %PgQuery.RangeVar{alias: %PgQuery.Alias{colnames: [_ | _]}} -> true
      %_{} = struct -> struct |> Map.from_struct() |> Map.values() |> derived_tables?()
      {_tag, value} -> derived_tables?(value)
      list when is_list(list) -> Enum.any?(list, &derived_tables?/1)
      _other -> false
    end
  end

  # The name Postgres gives an unnamed select-list entry (FigureColname).
  defp figure(%PgQuery.Node{node: {_tag, inner}}), do: figure(inner)

  defp figure(%PgQuery.ColumnRef{fields: fields}),
    do: fields |> List.last() |> string()

  defp figure(%PgQuery.A_Indirection{arg: arg, indirection: indirection}) do
    case indirection |> Enum.map(&string/1) |> Enum.filter(& &1) do
      [] -> figure(arg)
      fields -> List.last(fields)
    end
  end

  defp figure(%PgQuery.FuncCall{funcname: funcname}), do: funcname |> List.last() |> string()

  defp figure(%PgQuery.TypeCast{arg: arg, type_name: %PgQuery.TypeName{names: names}}) do
    case figure(arg) do
      name when name in [nil, "?column?"] -> names |> List.last() |> string()
      name -> name
    end
  end

  defp figure(%PgQuery.CaseExpr{}), do: "case"
  defp figure(%PgQuery.CoalesceExpr{}), do: "coalesce"
  defp figure(%PgQuery.MinMaxExpr{op: :IS_GREATEST}), do: "greatest"
  defp figure(%PgQuery.MinMaxExpr{}), do: "least"
  defp figure(%PgQuery.NullIfExpr{}), do: "nullif"
  defp figure(%PgQuery.A_ArrayExpr{}), do: "array"
  defp figure(%PgQuery.RowExpr{}), do: "row"
  defp figure(%PgQuery.SubLink{sub_link_type: :EXISTS_SUBLINK}), do: "exists"
  defp figure(%PgQuery.SubLink{sub_link_type: :ARRAY_SUBLINK}), do: "array"

  defp figure(%PgQuery.SubLink{
         sub_link_type: :EXPR_SUBLINK,
         subselect: %PgQuery.Node{node: {:select_stmt, %PgQuery.SelectStmt{target_list: [t | _]}}}
       }) do
    case t do
      %PgQuery.Node{node: {:res_target, %PgQuery.ResTarget{name: name, val: val}}} ->
        if name in [nil, ""], do: figure(val), else: name

      _other ->
        "?column?"
    end
  end

  defp figure(%PgQuery.SQLValueFunction{op: op}),
    do: op |> to_string() |> String.replace_prefix("SVFOP_", "") |> String.downcase()

  defp figure(_expr), do: "?column?"

  defp string(%PgQuery.Node{node: {:string, %PgQuery.String{sval: value}}}), do: value
  defp string(_node), do: nil
end
