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
    lower upper btrim ltrim rtrim length char_length character_length octet_length bit_length
    substring substr left right split_part concat concat_ws format position strpos starts_with
    lpad rpad regexp_like regexp_count regexp_match regexp_matches regexp_substr
    gen_random_uuid pg_typeof num_nulls num_nonnulls
    pg_size_pretty pg_relation_size pg_table_size pg_indexes_size pg_total_relation_size
    pg_database_size
  ))

  @json_prefixes ["json_", "jsonb_"]

  @doc "Parses `sql` and returns the statement if the gateway may run it."
  @spec parse(String.t()) :: {:ok, PgQuery.Node.t()} | {:error, String.t()}
  def parse(sql) do
    case PgQuery.parse(sql) do
      {:ok, %{stmts: [%{stmt: %PgQuery.Node{node: {kind, _}} = statement}]}}
      when kind in [:select_stmt, :explain_stmt] ->
        case statement |> references([]) |> Enum.reverse() |> Enum.find(&refused?/1) do
          nil ->
            {:ok, statement}

          {:relation, name} ->
            {:error, "#{name} exposes sample column values and is not available."}

          {:function, name} ->
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

  defp refused?({:relation, name}), do: name in @blocked_relations
  defp refused?({:cast, type}), do: type == "bytea"

  defp refused?({:function, name}),
    do: name not in @allowed_functions and not String.starts_with?(name, @json_prefixes)

  defp references(%PgQuery.RangeVar{relname: name}, acc), do: [{:relation, name} | acc]

  # Built-in functions may be qualified with pg_catalog; any other schema is
  # application code, which the gateway cannot vouch for.
  defp references(%PgQuery.FuncCall{funcname: funcname} = call, acc) do
    reference =
      case Enum.map(funcname, &name/1) do
        [name] -> {:function, name}
        ["pg_catalog", name] -> {:function, name}
        parts -> {:function, Enum.join(parts, ".")}
      end

    call |> Map.from_struct() |> Map.values() |> references([reference | acc])
  end

  defp references(%PgQuery.TypeCast{type_name: %PgQuery.TypeName{names: names}} = cast, acc) do
    reference = {:cast, names |> List.last() |> name()}
    cast |> Map.from_struct() |> Map.values() |> references([reference | acc])
  end

  defp references(%_{} = struct, acc),
    do: struct |> Map.from_struct() |> Map.values() |> references(acc)

  defp references({_tag, value}, acc), do: references(value, acc)
  defp references(list, acc) when is_list(list), do: Enum.reduce(list, acc, &references/2)
  defp references(_other, acc), do: acc

  defp name(%PgQuery.Node{node: {:string, %PgQuery.String{sval: name}}}), do: name
end
