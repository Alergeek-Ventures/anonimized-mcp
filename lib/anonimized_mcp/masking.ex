defmodule AnonimizedMcp.Masking do
  @moduledoc """
  Turns a raw query result into one that is safe to hand to an external
  agent, without knowing anything about the schema. Every text value,
  including strings inside JSON and arrays, goes through checksum-validated
  patterns and a local NER model; what they find becomes a stable alias such
  as `NAME_k3j9x2ab`, or `[secret]` for credentials. Values already aliased in
  this source are then replaced wherever else they appear, also in declined
  forms of names, so a name the model caught once stays masked elsewhere.

  Two column-name rules need no configuration: columns and JSON keys named
  like credentials are withheld, and dates in columns named like birth dates
  are aliased.
  """

  alias AnonimizedMcp.Masking.{Aliases, Ner, Patterns}

  @secret "[secret]"
  @secret_name ~r/password|passwd|secret|token|api_?key|private_key|credential|encryption_key|^iv$|_iv$|otp|signature|session_key|cookie/
  @birth_name ~r/birth/

  # Record ids and timestamps are what debugging joins on; the model
  # sometimes takes them for account numbers.
  @record_id ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}(?::?\d{2})?)?/i

  @doc "Masks `rows`; `names` are the column names and `types` the Postgrex result types."
  @spec mask(String.t(), [String.t()], list(), [list()]) :: [list()]
  def mask(source, names, types, rows) do
    kinds = Enum.zip_with(names, types, &column_kind/2)
    rows = Enum.map(rows, fn row -> Enum.zip_with([row, kinds, types], &cell/1) end)

    texts = rows |> Enum.flat_map(fn row -> Enum.flat_map(row, &texts/1) end) |> Enum.uniq()
    masker = masker(source, texts)
    Enum.map(rows, fn row -> Enum.map(row, &apply_masker(masker, &1)) end)
  end

  @doc "Masks one piece of free text, such as a database error message."
  @spec scrub(String.t(), String.t()) :: String.t()
  def scrub(source, text), do: source |> masker([text]) |> apply_masker({:text, text})

  defp column_kind(name, type) do
    name = name |> Macro.underscore() |> String.downcase()

    cond do
      Regex.match?(@secret_name, name) -> :secret
      Regex.match?(@birth_name, name) -> :birthdate
      match?({Postgrex.Extensions.UUID, _}, type) -> :uuid
      true -> :plain
    end
  end

  # Cells become a tree of `{:text, string}` leaves, which need detection,
  # and plain values, which are returned as they are.
  defp cell([nil, _kind, _type]), do: nil
  defp cell([_value, :secret, _type]), do: @secret

  defp cell([value, :uuid, _type]),
    do: if(is_list(value), do: Enum.map(value, &Ecto.UUID.load!/1), else: Ecto.UUID.load!(value))

  defp cell([value, :birthdate, _type]), do: {:alias, "BIRTHDATE", to_string(plain(value))}
  defp cell([value, :plain, _type]), do: leaf(value)

  defp leaf(nil), do: nil
  defp leaf(list) when is_list(list), do: Enum.map(list, &leaf/1)

  defp leaf(value) when is_binary(value) do
    if String.valid?(value), do: {:text, value}, else: "<#{byte_size(value)} bytes>"
  end

  defp leaf(%{} = map) when not is_struct(map) do
    Map.new(map, fn {key, value} ->
      if Regex.match?(
           @secret_name,
           key |> to_string() |> Macro.underscore() |> String.downcase()
         ),
         do: {key, if(value == nil, do: nil, else: @secret)},
         else: {key, leaf(value)}
    end)
  end

  # Long numbers can be PESELs, NIPs or phone numbers stored as integers.
  defp leaf(value) when is_integer(value) and abs(value) >= 100_000_000,
    do: {:number, value}

  defp leaf(value), do: plain(value)

  defp plain(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp plain(%mod{} = value) when mod in [Date, Time, NaiveDateTime, DateTime], do: value

  defp plain(%_{} = value),
    do: if(String.Chars.impl_for(value), do: to_string(value), else: inspect(value))

  defp plain(value), do: value

  defp texts({:text, text}), do: [text]
  defp texts({:number, number}), do: [Integer.to_string(number)]
  defp texts(list) when is_list(list), do: Enum.flat_map(list, &texts/1)

  defp texts(%{} = map) when not is_struct(map),
    do: map |> Map.values() |> Enum.flat_map(&texts/1)

  defp texts(_value), do: []

  # Detects every text once, registers the aliases, then builds the
  # replacement of each text from what was detected plus the values already
  # known in this source.
  defp masker(source, texts) do
    detected = texts |> Enum.zip(spans(texts)) |> Map.new()

    for {text, spans} <- detected,
        {start, len, type} <- spans,
        is_binary(type),
        do: Aliases.alias_for(source, type, binary_part(text, start, len))

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
      detected: detected,
      exact: exact,
      matcher: if(exact != %{}, do: :binary.compile_pattern(Map.keys(exact))),
      stems: if(stems != [], do: Regex.compile!("\\b(?:#{Enum.join(stems, "|")})\\w*", "u"))
    }
  end

  @doc """
  Returns what patterns and the model detect in each text, as byte-offset
  spans with an alias type or `:secret`. Overlapping detections are merged
  into one span typed by the pattern, so a match neither finds whole on its
  own (`001-611-224-9658x469`) is still masked whole.
  """
  @spec spans([String.t()]) :: [[{non_neg_integer(), pos_integer(), String.t() | :secret}]]
  def spans(texts) do
    prose = Enum.filter(texts, &String.match?(&1, ~r/\p{L}/u))
    names = prose |> Enum.zip(Ner.spans(prose)) |> Map.new()

    Enum.map(texts, fn text ->
      names = outside_record_ids(text, Map.get(names, text, []))
      merge(Patterns.spans(text) ++ names)
    end)
  end

  defp merge(spans) do
    spans
    |> Enum.reduce([], fn {start, len, type}, merged ->
      {overlapping, rest} =
        Enum.split_with(merged, fn {s, l, _} -> start < s + l and s < start + len end)

      Enum.reduce(overlapping, [{start, len, type}], fn {s, l, t}, [{ms, ml, _}] ->
        stop = max(s + l, ms + ml)
        [{min(s, ms), stop - min(s, ms), t}]
      end) ++ rest
    end)
    |> Enum.sort()
  end

  defp outside_record_ids(text, spans) do
    protected = Regex.scan(@record_id, text, return: :index) |> Enum.map(&hd/1)

    Enum.reject(spans, fn {s, l, _} ->
      Enum.any?(protected, fn {ps, pl} -> s >= ps and s + l <= ps + pl end)
    end)
  end

  defp apply_masker(masker, {:text, text}), do: replace(masker, text)

  defp apply_masker(masker, {:alias, type, value}),
    do: Aliases.alias_for(masker.source, type, value)

  defp apply_masker(masker, {:number, number}) do
    text = Integer.to_string(number)

    case replace(masker, text) do
      ^text -> number
      masked -> masked
    end
  end

  defp apply_masker(masker, list) when is_list(list),
    do: Enum.map(list, &apply_masker(masker, &1))

  defp apply_masker(masker, %{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, apply_masker(masker, value)} end)

  defp apply_masker(_masker, value), do: value

  defp replace(masker, text) do
    detected = Map.fetch!(masker.detected, text)

    exact =
      if masker.matcher,
        do: text |> :binary.matches(masker.matcher) |> Enum.map(fn {s, l} -> {s, l, :known} end),
        else: []

    stems =
      if masker.stems,
        do:
          masker.stems
          |> Regex.scan(text, return: :index)
          |> Enum.map(fn [{s, l}] -> {s, l, "NAME"} end),
        else: []

    (detected ++ exact ++ stems)
    |> non_overlapping()
    |> Enum.sort(:desc)
    |> Enum.reduce(text, fn {start, len, type}, acc ->
      found = binary_part(acc, start, len)

      replacement =
        case type do
          :secret -> @secret
          :known -> Map.fetch!(masker.exact, found)
          type -> Aliases.alias_for(masker.source, type, found)
        end

      binary_part(acc, 0, start) <>
        replacement <> binary_part(acc, start + len, byte_size(acc) - start - len)
    end)
  end

  # Earlier spans win.
  defp non_overlapping(spans) do
    spans
    |> Enum.reduce([], fn {start, len, _} = span, kept ->
      if Enum.any?(kept, fn {s, l, _} -> start < s + l and s < start + len end),
        do: kept,
        else: [span | kept]
    end)
    |> Enum.sort()
  end
end
