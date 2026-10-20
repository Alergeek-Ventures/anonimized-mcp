defmodule AnonimizedMcp.Gateway.Statement do
  @moduledoc """
  Parses an agent's SQL and decides whether the gateway runs it: exactly one
  `SELECT` or `EXPLAIN`, no planner statistics, and only functions that keep
  values recognisable to masking.

  Masking looks at values, so a function that rewrites text beyond
  recognition (`reverse`, `translate`, `encode(..., 'base64')`) would carry a
  name past every detector. Functions are therefore allowed by name rather
  than refused by name: aggregates, window functions, date and time, JSON,
  arrays, numbers, and text functions that return parts of their input
  unchanged. Casts to `bytea` are refused too, since `bytea` prints as hex.
  Attribute notation (`(name).reverse`, `alias.reverse`) is a function call
  too, so a trailing name must be a known column or an allowed function.

  This closes the ordinary paths, not every one: SQL is expressive enough to
  rebuild a value character by character. The threat model is accidental
  leaks, not an agent working against the gateway.
  """

  # Planner statistics hold sample values of every readable column.
  @blocked_relations ~w(pg_stats pg_statistic pg_stats_ext pg_stats_ext_exprs pg_statistic_ext_data)

  @allowed_functions MapSet.new(~w(
    count sum avg min max bool_and bool_or every stddev stddev_pop stddev_samp variance
    var_pop var_samp percentile_cont percentile_disc mode string_agg array_agg
    row_number rank dense_rank percent_rank cume_dist ntile lag lead first_value last_value nth_value
    now clock_timestamp statement_timestamp transaction_timestamp timeofday date_trunc date_part
    date_bin extract age to_char to_date to_timestamp make_date make_time make_timestamp
    make_timestamptz make_interval justify_days justify_hours justify_interval timezone isfinite
    to_json to_jsonb row_to_json array_to_json
    array_length array_lower array_upper array_ndims cardinality array_position array_positions
    array_append array_prepend array_cat array_remove array_to_string string_to_array unnest
    generate_series generate_subscripts
    abs round ceil ceiling floor trunc mod sign div power sqrt ln log exp width_bucket to_number
    lower upper initcap btrim ltrim rtrim length char_length character_length octet_length bit_length
    substring substr left right split_part concat concat_ws format position strpos starts_with
    lpad rpad regexp_like regexp_count regexp_match regexp_matches regexp_substr
    gen_random_uuid pg_typeof num_nulls num_nonnulls
    pg_size_pretty pg_relation_size pg_table_size pg_indexes_size pg_total_relation_size
    pg_database_size
  ))

  @json_prefixes ["json_", "jsonb_"]

  # Case changes weaken detection (the model relies on capitals, token
  # patterns on mixed case), so they may filter, join and sort but not shape
  # what a query returns.
  @case_functions ~w(lower upper initcap)

  @doc """
  Parses `sql` and returns the statement if the gateway may run it.

  `names` are the column and field names of the source. PostgreSQL reads
  `x.name` and `(x).name` as the call `name(x)` when `x` has no such field,
  so a trailing name that is neither a known name nor an allowed function is
  refused.
  """
  @spec parse(String.t(), MapSet.t(String.t())) :: {:ok, PgQuery.Node.t()} | {:error, String.t()}
  def parse(sql, names \\ MapSet.new()) do
    case PgQuery.parse(sql) do
      # EXPLAIN ANALYZE runs the explained statement.
      {:ok,
       %{
         stmts: [
           %{
             stmt: %PgQuery.Node{
               node: {:explain_stmt, %PgQuery.ExplainStmt{query: %PgQuery.Node{node: {kind, _}}}}
             }
           }
         ]
       }}
      when kind != :select_stmt ->
        {:error, "Only SELECT statements can be explained."}

      {:ok, %{stmts: [%{stmt: %PgQuery.Node{node: {kind, _}} = statement}]}}
      when kind in [:select_stmt, :explain_stmt] ->
        references = statement |> references([], :input) |> Enum.reverse()
        names = for {:name, name} <- references, into: names, do: name

        case Enum.find(references, &refused?(&1, names)) do
          nil ->
            {:ok, statement}

          {:relation, name} ->
            {:error, "#{name} exposes sample column values and is not available."}

          {:attribute, name, _context} ->
            {:error,
             "#{name} is not a column here, so `x.#{name}` or `(x).#{name}` would call " <>
               "#{name}(x), which is not available."}

          {:function, name, :output} when name in @case_functions ->
            {:error,
             "#{name}() is not available in the select list, FROM functions or VALUES, " <>
               "where it would weaken masking; use it in WHERE, JOIN, GROUP BY or ORDER BY."}

          {:function, name, _context} ->
            {:error,
             "#{name}() is not available: only functions that keep values recognisable to " <>
               "masking are allowed. Allowed: #{Enum.join(Enum.sort(@allowed_functions), ", ")}, " <>
               "json_* and jsonb_*."}

          {:cast, "bytea"} ->
            {:error, "Casts to bytea are not available; they print values as hex."}
        end

      {:ok, %{stmts: [_]}} ->
        {:error, "Only SELECT and EXPLAIN statements are allowed."}

      {:ok, %{stmts: _}} ->
        {:error, "Send exactly one statement."}

      {:error, %{message: message, cursorpos: position}} ->
        {:error, "Syntax error at position #{position}: #{message}"}
    end
  end

  @doc "Whether the statement is a `SELECT` (as opposed to `EXPLAIN`)."
  @spec select?(PgQuery.Node.t()) :: boolean()
  def select?(statement), do: match?(%PgQuery.Node{node: {:select_stmt, _}}, statement)

  defp refused?({:relation, name}, _names), do: name in @blocked_relations
  defp refused?({:cast, type}, _names), do: type == "bytea"
  defp refused?({:name, _name}, _names), do: false

  defp refused?({:function, name, context}, _names) do
    (name not in @allowed_functions and not String.starts_with?(name, @json_prefixes)) or
      (context == :output and name in @case_functions)
  end

  defp refused?({:attribute, name, context}, names),
    do: not MapSet.member?(names, name) and refused?({:function, name, context}, names)

  # `context` is `:output` wherever a value can become a result column, at
  # any depth: select lists, VALUES rows and functions in FROM.
  defp references(%PgQuery.RangeVar{relname: name, alias: alias}, acc, context),
    do: references(alias, [{:relation, name} | acc], context)

  defp references(
         %PgQuery.SelectStmt{target_list: targets, values_lists: values} = select,
         acc,
         context
       ) do
    acc = references(targets, acc, :output)
    acc = references(values, acc, :output)

    select
    |> Map.from_struct()
    |> Map.drop([:target_list, :values_lists])
    |> Map.values()
    |> references(acc, context)
  end

  defp references(%PgQuery.RangeFunction{} = range, acc, _context),
    do: range |> Map.from_struct() |> Map.values() |> references(acc, :output)

  defp references(%PgQuery.JsonTable{} = table, acc, _context),
    do: table |> Map.from_struct() |> Map.values() |> references(acc, :output)

  # XMLTABLE evaluates XPath, whose string functions (translate) go unchecked.
  defp references(%PgQuery.RangeTableFunc{}, acc, context),
    do: [{:function, "xmltable", context} | acc]

  # Names the statement gives to columns and relations.
  defp references(%PgQuery.ResTarget{name: name} = target, acc, context) when name != "" do
    target |> Map.from_struct() |> Map.values() |> references([{:name, name} | acc], context)
  end

  defp references(%PgQuery.Alias{aliasname: name, colnames: colnames}, acc, _context),
    do: Enum.reduce(colnames, [{:name, name} | acc], &[{:name, name(&1)} | &2])

  defp references(
         %PgQuery.CommonTableExpr{ctename: name, aliascolnames: colnames} = cte,
         acc,
         context
       ) do
    acc = Enum.reduce(colnames, [{:name, name} | acc], &[{:name, name(&1)} | &2])

    cte
    |> Map.from_struct()
    |> Map.delete(:aliascolnames)
    |> Map.values()
    |> references(acc, context)
  end

  defp references(%PgQuery.ColumnDef{colname: name} = column, acc, context) do
    column |> Map.from_struct() |> Map.values() |> references([{:name, name} | acc], context)
  end

  # `(expr).name` calls name(expr) when expr has no field called name.
  defp references(%PgQuery.A_Indirection{indirection: indirection} = node, acc, context) do
    attributes =
      for %PgQuery.Node{node: {:string, %PgQuery.String{sval: name}}} <- indirection,
          do: {:attribute, name, context}

    node
    |> Map.from_struct()
    |> Map.values()
    |> references(Enum.reverse(attributes, acc), context)
  end

  # So does `alias.name` when alias has no column called name.
  defp references(%PgQuery.ColumnRef{fields: [_, _ | _] = fields}, acc, context) do
    case List.last(fields) do
      %PgQuery.Node{node: {:string, %PgQuery.String{sval: name}}} ->
        [{:attribute, name, context} | acc]

      _star ->
        acc
    end
  end

  # Built-in functions may be qualified with pg_catalog; any other schema is
  # application code, which the gateway cannot vouch for.
  defp references(%PgQuery.FuncCall{funcname: funcname} = call, acc, context) do
    name =
      case Enum.map(funcname, &name/1) do
        [name] -> name
        ["pg_catalog", name] -> name
        parts -> Enum.join(parts, ".")
      end

    call
    |> Map.from_struct()
    |> Map.values()
    |> references([{:function, name, context} | acc], context)
  end

  defp references(
         %PgQuery.TypeCast{type_name: %PgQuery.TypeName{names: names}} = cast,
         acc,
         context
       ) do
    reference = {:cast, names |> List.last() |> name()}
    cast |> Map.from_struct() |> Map.values() |> references([reference | acc], context)
  end

  defp references(%_{} = struct, acc, context),
    do: struct |> Map.from_struct() |> Map.values() |> references(acc, context)

  defp references({_tag, value}, acc, context), do: references(value, acc, context)

  defp references(list, acc, context) when is_list(list),
    do: Enum.reduce(list, acc, &references(&1, &2, context))

  defp references(_other, acc, _context), do: acc

  defp name(%PgQuery.Node{node: {:string, %PgQuery.String{sval: name}}}), do: name
end
