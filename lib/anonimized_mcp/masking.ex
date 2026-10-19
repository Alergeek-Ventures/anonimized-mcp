defmodule AnonimizedMcp.Masking do
  @moduledoc """
  Turns a raw query result into one that is safe to hand to an external
  agent. Each output column gets a kind from its lineage and the source
  policy; personal values become stable aliases, secrets are withheld, and
  every remaining string is scrubbed for detectable identifiers and for values
  already aliased in this source. Whitespace around an alias is kept, so
  formatting problems stay visible.
  """

  alias AnonimizedMcp.Masking.{Aliases, Detectors, Policy}
  alias AnonimizedMcp.Sources

  @secret "[secret]"

  @doc """
  Masks `rows`. `outputs` is the lineage of each column (or `:unknown`),
  `types` the Postgrex result types.
  """
  @spec mask(Sources.t(), map(), [String.t()], list(), [list()], list() | :unknown) ::
          {[%{name: String.t(), masking: String.t()}], [list()]}
  def mask(source, catalog, names, types, rows, outputs) do
    outputs =
      if outputs == :unknown or length(outputs) != length(names),
        do: Enum.map(names, fn _ -> :unknown end),
        else: outputs

    kinds = Enum.zip_with(outputs, types, &kind(source, catalog, &1, &2))
    columns = Enum.zip_with(names, kinds, &%{name: &1, masking: describe(&2)})

    # Alias personal columns first, so free text in the same response can be
    # scrubbed of the values they hold.
    cells = Enum.map(rows, fn row -> Enum.zip([row, kinds, types]) end)

    pii_done =
      Enum.map(cells, fn row ->
        Enum.map(row, fn
          {value, :plain, type} -> {:plain, value, type, %{}}
          {value, {:json, keys}, type} -> {:plain, value, type, keys}
          {value, kind, type} -> {:done, value(source.name, kind, value, type)}
        end)
      end)

    # A first pass over text and JSON aliases what it can classify on its own
    # (JSON keys, key-value pairs, identifiers); the real pass then also
    # catches those values where they appear unlabelled in the same response.
    harvest = scrubber(source.name)

    for row <- pii_done,
        {:plain, value, type, keys} <- row,
        do: plain_value(%{harvest | keys: keys}, value, type)

    scrubber = scrubber(source.name)

    rows =
      Enum.map(pii_done, fn row ->
        Enum.map(row, fn
          {:done, value} -> value
          {:plain, value, type, keys} -> plain_value(%{scrubber | keys: keys}, value, type)
        end)
      end)

    {columns, rows}
  end

  @doc "Removes detectable identifiers and already aliased values from free text."
  @spec scrub(String.t(), String.t()) :: String.t()
  def scrub(source, text), do: source |> scrubber() |> scrub_with(text)

  defp scrubber(source) do
    known = Aliases.known(source)

    exact =
      for {canonical, alias, _} <- known,
          byte_size(canonical) >= 4,
          into: %{},
          do: {canonical, alias}

    stems =
      for {canonical, _, type} <- known,
          type in ["NAME", "COMPANY"],
          word <- String.split(canonical, ~r/[\s,.]+/u),
          String.length(word) >= 5,
          uniq: true,
          do: word |> String.slice(0..-2//1) |> Regex.escape()

    %{
      source: source,
      keys: %{},
      exact: exact,
      matcher: if(exact != %{}, do: :binary.compile_pattern(Map.keys(exact))),
      stems: if(stems != [], do: Regex.compile!("\\b(?:#{Enum.join(stems, "|")})\\w*", "u"))
    }
  end

  defp scrub_with(scrubber, text) do
    exact_spans =
      if scrubber.matcher,
        do:
          text |> :binary.matches(scrubber.matcher) |> Enum.map(fn {s, l} -> {s, l, :known} end),
        else: []

    stem_spans =
      if scrubber.stems,
        do:
          scrubber.stems
          |> Regex.scan(text, return: :index)
          |> Enum.map(fn [{s, l}] -> {s, l, "NAME"} end),
        else: []

    (keyed_spans(text) ++ exact_spans ++ Detectors.spans(text) ++ stem_spans)
    |> Enum.reduce([], fn {start, len, _} = span, kept ->
      if Enum.any?(kept, fn {s, l, _} -> start < s + l and s < start + len end),
        do: kept,
        else: [span | kept]
    end)
    |> Enum.sort(:desc)
    |> Enum.reduce(text, fn {start, len, how}, acc ->
      found = binary_part(acc, start, len)

      replacement =
        case how do
          :known -> Map.fetch!(scrubber.exact, found)
          :secret -> @secret
          {:keyed, type} -> alias_preserving_whitespace(scrubber.source, type, found)
          type -> Aliases.alias_for(scrubber.source, type, found)
        end

      binary_part(acc, 0, start) <>
        replacement <> binary_part(acc, start + len, byte_size(acc) - start - len)
    end)
  end

  # Quoted values after a named key, as in serialized JSON (`"email": "…"`),
  # inspected structs (`email: "…"`) and logfmt (`email="…"`), are classified by
  # the key name, the same way JSON columns are.
  # Quotes may be backslash-escaped, as in JSON serialized inside JSON or arrays.
  @keyed ~r/(?:\\*"([A-Za-z_]\w*)\\*"|\b([A-Za-z_]\w*))\s*(?::|=>|=)\s*\\*"([^"\\]*)\\*"/u

  defp keyed_spans(text) do
    @keyed
    |> Regex.scan(text, return: :index)
    |> Enum.flat_map(fn [_, quoted, bare, {start, len}] ->
      {key_start, key_len} = if elem(quoted, 0) >= 0, do: quoted, else: bare

      case Policy.by_name(binary_part(text, key_start, key_len)) do
        _ when len == 0 -> []
        :plain -> []
        :secret -> [{start, len, :secret}]
        {:pii, type} -> [{start, len, {:keyed, type}}]
      end
    end)
  end

  @json_types [Postgrex.Extensions.JSON, Postgrex.Extensions.JSONB]

  defp kind(_source, _catalog, :unknown, _type), do: :plain

  defp kind(source, catalog, %{direct: {table, column}}, _type),
    do: column_kind(source, catalog, table, column)

  defp kind(_source, _catalog, %{count?: true}, _type), do: :plain

  defp kind(source, catalog, %{json_key: key} = output, type) when is_binary(key) do
    case Policy.by_name(key) do
      :plain -> kind(source, catalog, %{output | json_key: nil}, type)
      kind -> kind
    end
  end

  # JSON built from columns (row_to_json, jsonb_build_object, ...) is masked
  # key by key, using the policy of the column each key is named after. Keys
  # named after no column (`jsonb_build_object('x', surname)`) get the most
  # protective kind among the columns that fed the JSON.
  defp kind(source, catalog, %{refs: refs}, {extension, _}) when extension in @json_types do
    keys =
      Map.new(refs, fn {table, column} ->
        {column, column_kind(source, catalog, table, column)}
      end)

    other =
      cond do
        :secret in Map.values(keys) -> :secret
        Enum.any?(Map.values(keys), &match?({:pii, _}, &1)) -> {:pii, "VALUE"}
        true -> :plain
      end

    {:json, Map.put(keys, :other, other)}
  end

  defp kind(source, catalog, %{refs: refs}, _type) do
    kinds = Enum.map(refs, fn {table, column} -> column_kind(source, catalog, table, column) end)

    cond do
      :secret in kinds ->
        :secret

      true ->
        case kinds
             |> Enum.flat_map(fn
               {:pii, t} -> [t]
               _ -> []
             end)
             |> Enum.uniq() do
          [] -> :plain
          [type] -> {:pii, type}
          _ -> {:pii, "VALUE"}
        end
    end
  end

  defp column_kind(source, catalog, table, column) do
    type =
      catalog
      |> Map.fetch!(table)
      |> Map.fetch!(:columns)
      |> Enum.find(&(&1.name == column))
      |> Map.fetch!(:type)

    Policy.classify(source, table, column, type)
  end

  defp describe(:plain), do: "none"
  defp describe({:json, _}), do: "json keys"
  defp describe(:secret), do: "secret"
  defp describe({:pii, type}), do: "alias:#{type}"

  defp value(_source, _kind, nil, _type), do: nil
  defp value(_source, :secret, _value, _type), do: @secret

  defp value(source, kind, list, type) when is_list(list),
    do: Enum.map(list, &value(source, kind, &1, type))

  defp value(source, {:pii, t}, value, _type) when is_binary(value),
    do: alias_preserving_whitespace(source, t, value)

  defp value(source, {:pii, t}, %{} = map, _type) when not is_struct(map),
    do: Aliases.alias_for(source, t, Jason.encode!(map))

  defp value(source, {:pii, t}, value, type),
    do: Aliases.alias_for(source, t, to_string(plain_value(nil, value, type)))

  defp plain_value(_scrubber, nil, _type), do: nil

  defp plain_value(scrubber, list, type) when is_list(list),
    do: Enum.map(list, &plain_value(scrubber, &1, type))

  defp plain_value(_scrubber, value, {Postgrex.Extensions.UUID, _}), do: Ecto.UUID.load!(value)

  defp plain_value(scrubber, value, _type) when is_binary(value) do
    if String.valid?(value), do: scrub_with(scrubber, value), else: "<#{byte_size(value)} bytes>"
  end

  defp plain_value(scrubber, %{} = map, _type) when not is_struct(map), do: json(scrubber, map)
  defp plain_value(_scrubber, value, _type), do: plain(value)

  defp json(scrubber, map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      masked =
        case {key_kind(scrubber.keys, to_string(key)), value} do
          {_, nil} ->
            nil

          {:secret, _} ->
            @secret

          {{:pii, type}, v} when is_binary(v) or is_number(v) ->
            alias_preserving_whitespace(scrubber.source, type, to_string(v))

          {_, v} ->
            json(scrubber, v)
        end

      {key, masked}
    end)
  end

  defp json(scrubber, list) when is_list(list), do: Enum.map(list, &json(scrubber, &1))
  defp json(scrubber, value) when is_binary(value), do: scrub_with(scrubber, value)
  defp json(_scrubber, value), do: value

  defp key_kind(keys, key) do
    Map.get_lazy(keys, key, fn ->
      case Policy.by_name(key) do
        :plain -> Map.get(keys, :other, :plain)
        kind -> kind
      end
    end)
  end

  defp plain(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp plain(%mod{} = value) when mod in [Date, Time, NaiveDateTime, DateTime], do: value

  defp plain(%_{} = value),
    do: if(String.Chars.impl_for(value), do: to_string(value), else: inspect(value))

  defp plain(value), do: value

  defp alias_preserving_whitespace(source, type, value) do
    [_, leading, core, trailing] = Regex.run(~r/^(\s*)(.*?)(\s*)$/su, value)
    if core == "", do: value, else: leading <> Aliases.alias_for(source, type, core) <> trailing
  end
end
