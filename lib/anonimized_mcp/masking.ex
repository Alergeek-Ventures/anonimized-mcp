defmodule AnonimizedMcp.Masking do
  @moduledoc """
  Turns a raw query result into one that is safe to hand to an external
  agent, without knowing anything about the schema. Every text value,
  including strings inside JSON and arrays, JSON keys, IP addresses and
  search lexemes, goes through checksum-validated patterns and a local NER
  model; what they find becomes a stable alias such as `NAME_k3j7x2ab`, or
  `[secret]` for credentials. Values already aliased in this source are then
  replaced wherever else they appear, in any capitalisation and also in
  declined forms of names, so a name the model caught once stays masked
  elsewhere.

  Column-name rules need no configuration: columns, composite fields and
  JSON keys named like credentials are withheld, and dates in columns named
  like birth dates are aliased. In columns named like account numbers any
  long digit run is aliased, valid checksum or not, and in columns named
  like addresses so is every street line. With the statement's lineage the
  credential and birth-date rules also
  cover columns derived from such columns under another label
  (`min(birth_date)`, `coalesce(otp_secret, '')`, `birth_date AS dob`):
  their text is withheld, their dates aliased, and their numbers, booleans
  and other dates kept, since counts and checks are what debugging needs.
  """

  alias AnonimizedMcp.Masking.{Aliases, FirstNames, Lineage, Ner, Patterns}

  @secret "[secret]"
  @secret_name ~r/password|passwd|secret|token|api_?key|private_key|credential|encryption_key|^iv$|_iv$|otp|signature|session_key|cookie/
  @birth_name ~r/birth/
  @account_name ~r/iban|bban|nrb|account_number|account_no|bank_account|rachun/
  @address_name ~r/(?<!email_)(?<!ip_)(?<!mac_)address|street|adres|ulica/

  # In account columns any long digit run is an account number, also one
  # whose checksum fails because of a typo or an extraction error.
  @account_number ~r/(?<![\p{L}\p{N}])(?:[A-Z]{2} ?)?\d[\d \-]{8,}\d(?!\p{N})/u

  # In address columns a word followed by a house number is a street line
  # (Długa 12/3); postal codes start with digits and stay.
  @street ~r/(?<![\p{L}\p{N}_])\p{L}[\p{L}\p{M}.'\- ]*\p{L}\.?\s+\d{1,4}[a-zA-Z]?(?:\s*\/\s*\d{1,4}[a-zA-Z]?)?(?![\p{N}-])/u

  # Record ids and timestamps are what debugging joins on; the model
  # sometimes takes them for account numbers.
  @record_id ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}(?::?\d{2})?)?/i

  # Dates written out in text, as derived birth dates arrive after a cast.
  @date ~r/(?<!\d)(?:\d{4}[-.\/]\d{1,2}[-.\/]\d{1,2}|\d{1,2}[-.\/]\d{1,2}[-.\/]\d{4})(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}(?::?\d{2})?)?)?(?!\d)/
  @dates [Date, NaiveDateTime, DateTime]

  # One alternation of every known name outgrows PCRE's pattern size limit
  # at a few thousand names, so name regexes are compiled in chunks.
  @chunk 500

  # Short names (Kot, Ewa) only match with Polish case endings, as whole
  # words, and only for names of people, so common words they prefix stay.
  @masculine_endings ~w(a u owi em iem ie owie ów om ami ach y i)
  @feminine_endings ~w(y i ie ę ą o u)
  @softened %{"t" => "cie", "d" => "dzie", "r" => "rze", "ł" => "le"}
  @not_short_names ~w(pan pani pana panu dr mgr inż prof ks ul al the and van von der den del mr mrs ms sir may june july mark will bill rose)

  # Capitals that label identifiers and amounts rather than name anyone.
  @labels ~w(NIP REGON PESEL KRS IBAN NRB BIC SWIFT VAT KSEF EIN SSN TIN PLN EUR USD GBP CHF FV ID PL OK)

  @doc """
  Masks `rows`; `names` are the column names and `types` the Postgrex result
  types. Options: `:lineage`, the names each column may derive from
  (`Lineage.columns/2`), and `:fields`, the field tree of each column
  (`Composites.fields/3`), for composite values.
  """
  @spec mask(String.t(), [String.t()], list(), [list()], keyword()) :: [list()]
  def mask(source, names, types, rows, opts \\ []) do
    lineage = Keyword.get_lazy(opts, :lineage, fn -> Enum.map(names, fn _ -> [] end) end)
    fields = Keyword.get_lazy(opts, :fields, fn -> Enum.map(names, fn _ -> nil end) end)
    kinds = Enum.zip_with([names, types, lineage, fields], &column_kind/1)
    rows = Enum.map(rows, fn row -> Enum.zip_with(row, kinds, &cell(source, &1, &2)) end)

    texts = rows |> Enum.flat_map(fn row -> Enum.flat_map(row, &texts/1) end) |> Enum.uniq()
    masker = masker(source, texts)
    Enum.map(rows, fn row -> Enum.map(row, &apply_masker(masker, &1)) end)
  end

  @doc "Masks one piece of free text, such as a database error message."
  @spec scrub(String.t(), String.t()) :: String.t()
  def scrub(source, text), do: source |> masker([text]) |> apply_masker({:text, text})

  defp column_kind([name, type, lineage, field]) do
    derived =
      for {rule, regex} <- [secret: @secret_name, birthdate: @birth_name],
          Enum.any?(lineage, &(&1 == Lineage.unknown() or named?(regex, &1))),
          do: rule

    derived =
      derived ++
        for {rule, regex} <- [account: @account_name, address: @address_name],
            named?(regex, name) or
              Enum.any?(lineage, &(&1 != Lineage.unknown() and named?(regex, &1))),
            do: rule

    cond do
      named?(@secret_name, name) -> :secret
      named?(@birth_name, name) -> :birthdate
      field == :uuid or match?({Postgrex.Extensions.UUID, _}, type) -> :uuid
      composite?(field) -> {:fields, field}
      true -> {:plain, derived}
    end
  end

  defp composite?({:record, _fields}), do: true
  defp composite?({:array, elem}), do: composite?(elem)
  defp composite?(_field), do: false

  # Cells become a tree of leaves that need detection (`{:text, string}`,
  # `{:lexeme, word}`, `{:number, integer}`, `{:map, pairs}`) and plain
  # values, which are returned as they are. Nothing here may raise: an
  # exception message would carry the raw cell into the logs.
  defp cell(_source, nil, _kind), do: nil
  defp cell(_source, _value, :secret), do: @secret
  defp cell(_source, value, :uuid), do: uuid(value)
  defp cell(source, value, :birthdate), do: birth(source, value)
  defp cell(source, value, {:fields, field}), do: fields(source, value, field)
  defp cell(source, value, {:plain, derived}), do: value |> leaf() |> derive(source, derived)

  defp uuid(nil), do: nil
  defp uuid(list) when is_list(list), do: Enum.map(list, &uuid/1)

  defp uuid(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> leaf(value)
    end
  end

  # A birth-named column aliases its scalars whole; inside JSON only the
  # dates are aliased and the rest is detected as usual.
  defp birth(_source, nil), do: nil
  defp birth(source, list) when is_list(list), do: Enum.map(list, &birth(source, &1))
  defp birth(source, tuple) when is_tuple(tuple), do: birth(source, Tuple.to_list(tuple))

  defp birth(source, %{} = map) when not is_struct(map),
    do: map |> leaf() |> derive(source, [:birthdate])

  defp birth(_source, value), do: {:alias, "BIRTHDATE", string(value)}

  defp fields(_source, nil, _field), do: nil

  defp fields(source, list, {:array, elem}) when is_list(list),
    do: Enum.map(list, &fields(source, &1, elem))

  defp fields(source, tuple, {:record, named})
       when is_tuple(tuple) and tuple_size(tuple) == length(named) do
    Enum.zip_with(Tuple.to_list(tuple), named, fn
      value, {nil, field} ->
        kind = if composite?(field), do: {:fields, field}, else: {:plain, [:secret, :birthdate]}
        cell(source, value, kind)

      value, {name, field} ->
        cell(source, value, column_kind([name, nil, [], field]))
    end)
  end

  defp fields(source, value, _field),
    do: value |> leaf() |> derive(source, [:secret, :birthdate])

  defp leaf(nil), do: nil
  defp leaf(list) when is_list(list), do: Enum.map(list, &leaf/1)

  # Composite types, such as money_with_currency, arrive as tuples.
  defp leaf(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> leaf()
  defp leaf(value) when is_binary(value), do: text(value)

  # Keys are detected too: per-person maps key on e-mails and names.
  defp leaf(%{} = map) when not is_struct(map) do
    {:map,
     Enum.map(map, fn
       {key, nil} -> {text(key), nil}
       {key, value} -> {text(key), if(named?(@secret_name, key), do: @secret, else: leaf(value))}
     end)}
  end

  # Long numbers can be PESELs, NIPs or phone numbers stored as integers.
  defp leaf(value) when is_integer(value) and abs(value) >= 100_000_000,
    do: {:number, value}

  defp leaf(%Postgrex.INET{address: address, netmask: netmask}) do
    case :inet.ntoa(address) do
      {:error, _} -> {:text, inspect(address)}
      ip -> {:text, "#{ip}#{if netmask, do: "/#{netmask}"}"}
    end
  end

  defp leaf(%Postgrex.Lexeme{word: word}) when is_binary(word), do: {:lexeme, word}

  defp leaf(%Decimal{} = d) do
    number = Decimal.to_string(d, :normal)

    if Decimal.integer?(d) and Decimal.compare(Decimal.abs(d), 100_000_000) != :lt,
      do: {:text, number},
      else: number
  end

  defp leaf(%mod{} = value) when mod in [Time | @dates], do: value
  defp leaf(%_{} = value), do: text(string(value))
  defp leaf(value), do: value

  defp text(value) when is_binary(value) do
    if String.valid?(value), do: {:text, value}, else: "<#{byte_size(value)} bytes>"
  end

  defp text(value), do: value

  defp string(value) when is_binary(value), do: value
  defp string(%Decimal{} = d), do: Decimal.to_string(d, :normal)

  defp string(value) do
    if String.Chars.impl_for(value) && not is_list(value),
      do: to_string(value),
      else: inspect(value)
  end

  # Applies the credential and birth-date rules to a column that derives
  # from such a column under another label.
  defp derive(leaves, _source, []), do: leaves

  defp derive(list, source, derived) when is_list(list),
    do: Enum.map(list, &derive(&1, source, derived))

  defp derive({:map, pairs}, source, derived),
    do: {:map, Enum.map(pairs, fn {key, value} -> {key, derive(value, source, derived)} end)}

  defp derive({kind, value} = leaf, source, derived) when kind in [:text, :lexeme, :number] do
    cond do
      :secret in derived -> @secret
      kind == :text -> derive_text(source, value, derived)
      kind == :number and :account in derived -> {:alias, "IBAN", Integer.to_string(value)}
      true -> leaf
    end
  end

  defp derive(%mod{} = date, _source, derived) when mod in @dates do
    if :birthdate in derived, do: {:alias, "BIRTHDATE", to_string(date)}, else: date
  end

  defp derive(value, _source, _derived), do: value

  defp derive_text(source, text, derived) do
    text =
      for {rule, regex, type} <- [
            {:account, @account_number, "IBAN"},
            {:address, @street, "ADDRESS"}
          ],
          rule in derived,
          reduce: text do
        acc ->
          Regex.replace(regex, acc, fn found ->
            if rule == :account and digit_count(found) < 10,
              do: found,
              else: Aliases.alias_for(source, type, found)
          end)
      end

    if :birthdate in derived, do: birth_text(source, text), else: {:text, text}
  end

  defp digit_count(text), do: text |> String.replace(~r/\D/, "") |> byte_size()

  defp birth_text(source, text) do
    if text =~ @date and text |> String.replace(@date, "") |> String.trim() == "",
      do: {:alias, "BIRTHDATE", text},
      else: {:text, Regex.replace(@date, text, &Aliases.alias_for(source, "BIRTHDATE", &1))}
  end

  defp named?(regex, name),
    do: Regex.match?(regex, name |> to_string() |> Macro.underscore() |> String.downcase())

  defp texts({:text, text}), do: [text]
  defp texts({:lexeme, word}), do: [word]
  defp texts({:number, number}), do: [Integer.to_string(number)]

  defp texts({:map, pairs}),
    do: Enum.flat_map(pairs, fn {key, value} -> texts(key) ++ texts(value) end)

  defp texts(list) when is_list(list), do: Enum.flat_map(list, &texts/1)
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

    source
    |> Aliases.cached(:masker, &known_matchers/1)
    |> Map.merge(%{source: source, detected: detected})
  end

  defp known_matchers(known) do
    # A one-word address is a place name, which stays readable elsewhere,
    # and a lower-case word found once in a file name or slug is more often
    # a common word elsewhere.
    exact =
      for {canonical, alias, type} <- known,
          byte_size(canonical) >= 4,
          not (type == "ADDRESS" and String.match?(canonical, ~r/^\p{L}+$/u)),
          not String.match?(canonical, ~r/^\p{Ll}+$/u),
          do: {canonical, alias}

    folded = Enum.group_by(exact, fn {canonical, _} -> String.downcase(canonical) end)

    bounded =
      for {canonical, _, "ADDRESS"} <- known, into: MapSet.new(), do: String.downcase(canonical)

    words =
      for {canonical, _, type} <- known,
          type in ["NAME", "COMPANY"],
          word <- String.split(canonical, ~r/[\s,.]+/u),
          uniq: true,
          do: {word, type}

    stems =
      for {word, _} <- words,
          String.length(word) >= 5,
          uniq: true,
          do: String.slice(word, 0..-2//1)

    short =
      for {word, "NAME"} <- words,
          String.match?(word, ~r/^\p{Lu}\p{Ll}{2,3}$/u),
          String.downcase(word) not in @not_short_names,
          uniq: true,
          do: short_forms(word)

    %{
      exact: folded,
      cased: Map.new(exact),
      bounded: bounded,
      matcher: if(folded != %{}, do: :binary.compile_pattern(Map.keys(folded))),
      cased_matcher: if(exact != [], do: :binary.compile_pattern(Map.keys(Map.new(exact)))),
      stem_set: MapSet.new(stems),
      stems: stems |> Enum.map(&Regex.escape/1) |> chunks("\\w*"),
      short: chunks(short, "\\b")
    }
  end

  # Kot: Kota, Kotowi, Kotem, Kocie; Ewa: Ewy, Ewie, Ewę.
  defp short_forms(word) do
    {stem, endings} =
      if String.ends_with?(word, "a"),
        do: {String.slice(word, 0..-2//1), ["a" | @feminine_endings]},
        else: {word, ["" | @masculine_endings]}

    softened =
      case Map.fetch(@softened, String.last(word)) do
        {:ok, ending} -> ["|", Regex.escape(String.slice(word, 0..-2//1) <> ending)]
        :error -> []
      end

    IO.iodata_to_binary([Regex.escape(stem), "(?:", Enum.join(endings, "|"), ")" | softened])
  end

  defp chunks(alternatives, suffix) do
    alternatives
    |> Enum.chunk_every(@chunk)
    |> Enum.map(&Regex.compile!("\\b(?:#{Enum.join(&1, "|")})#{suffix}", "iu"))
  end

  @doc """
  Returns what patterns and the model detect in each text, as byte-offset
  spans with an alias type or `:secret`. Overlapping detections are merged
  into one span typed by the pattern, so a match neither finds whole on its
  own (`001-611-224-9658x469`) is still masked whole.
  """
  @spec spans([String.t()]) :: [[{non_neg_integer(), pos_integer(), String.t() | :secret}]]
  def spans(texts) do
    # A lone word of up to three capitals is a code (ZAR, HUF, PL), which the
    # model can take for a name or company; patterns still look at it.
    prose =
      Enum.filter(
        texts,
        &(String.match?(&1, ~r/\p{L}/u) and not String.match?(&1, ~r/^\s*\p{Lu}{1,3}\s*$/u))
      )

    model = Enum.map(prose, &model_case/1)

    # Words in capitals inside lower-case text ("odbiór: KOZŁOWSKA") get a
    # second pass with those words in title case. Only what it finds on
    # them counts, so the changed context cannot add detections elsewhere.
    tokens =
      for {text, shown} <- Enum.zip(prose, model),
          shown == text,
          {titled, words} = token_case(text),
          words != [],
          do: {text, titled, words}

    second =
      Enum.zip_with(tokens, tokens |> Enum.map(&elem(&1, 1)) |> Ner.spans(), fn
        {text, _titled, words}, spans ->
          {text, Enum.filter(spans, fn {s, l, _} -> overlaps?({s, l}, words) end)}
      end)

    names =
      Enum.reduce(second, prose |> Enum.zip(Ner.spans(model)) |> Map.new(), fn
        {text, spans}, acc -> Map.update!(acc, text, &(&1 ++ spans))
      end)

    Enum.map(texts, fn text ->
      names = outside_record_ids(text, Map.get(names, text, []))
      merge(Patterns.spans(text) ++ names ++ FirstNames.spans(text))
    end)
  end

  # The model relies on capitals, so text written in capitals only
  # ("JAN KOWALSKI") is shown to it in title case. Offsets must not move, so
  # this only happens when the byte size stays the same.
  defp model_case(text) do
    titled = Regex.replace(~r/\p{L}+/u, text, &String.capitalize/1)

    if not String.match?(text, ~r/\p{Ll}/u) and byte_size(titled) == byte_size(text),
      do: titled,
      else: text
  end

  # Words joined to digits, dashes or slashes are parts of identifiers
  # (FV/12/2026, INV-2026-1), and labels of identifiers stay in capitals:
  # in title case the model takes "Nip" for a name.
  defp token_case(text) do
    words =
      for [{start, len}] <-
            Regex.scan(~r/(?<![\p{L}\p{N}_\/-])\p{Lu}{2,}(?![\p{L}\p{N}_\/-])/u, text,
              return: :index
            ),
          word = binary_part(text, start, len),
          titled = String.capitalize(word),
          word not in @labels and byte_size(titled) == len,
          do: {start, len, titled}

    titled =
      Enum.reduce(words, text, fn {start, len, word}, acc ->
        binary_part(acc, 0, start) <>
          word <> binary_part(acc, start + len, byte_size(acc) - start - len)
      end)

    {titled, Enum.map(words, fn {start, len, _} -> {start, len} end)}
  end

  defp overlaps?({start, len}, ranges),
    do: Enum.any?(ranges, fn {s, l} -> start < s + l and s < start + len end)

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

  defp apply_masker(masker, {:text, text}), do: replace(masker, text, false)

  # Postgres lower-cases lexemes, so known values match them in any case.
  defp apply_masker(masker, {:lexeme, word}), do: replace(masker, word, true)

  defp apply_masker(masker, {:alias, type, value}),
    do: Aliases.alias_for(masker.source, type, value)

  defp apply_masker(masker, {:number, number}) do
    text = Integer.to_string(number)

    case replace(masker, text, false) do
      ^text -> number
      masked -> masked
    end
  end

  defp apply_masker(masker, {:map, pairs}) do
    Map.new(pairs, fn {key, value} ->
      {apply_masker(masker, key), apply_masker(masker, value)}
    end)
  end

  defp apply_masker(masker, list) when is_list(list),
    do: Enum.map(list, &apply_masker(masker, &1))

  defp apply_masker(_masker, value), do: value

  defp replace(masker, text, any_case?) do
    (Map.fetch!(masker.detected, text) ++ known_spans(masker, text, any_case?))
    |> non_overlapping()
    |> Enum.sort(:desc)
    |> Enum.reduce(text, fn {start, len, type}, acc ->
      replacement =
        case type do
          :secret -> @secret
          {:alias, alias} -> alias
          type -> Aliases.alias_for(masker.source, type, binary_part(acc, start, len))
        end

      binary_part(acc, 0, start) <>
        replacement <> binary_part(acc, start + len, byte_size(acc) - start - len)
    end)
  end

  @doc false
  # Spans of values already aliased in `source`; the benchmark reads them.
  @spec known_spans(String.t(), String.t()) :: [{non_neg_integer(), pos_integer(), term()}]
  def known_spans(source, text),
    do: source |> Aliases.cached(:masker, &known_matchers/1) |> known_spans(text, false)

  # Exact values, stems of long name words and declined short names. A
  # known value matches in another capitalisation only where it starts with
  # a capital, as names do, so a known "Maja" leaves "17 maja" alone.
  defp known_spans(masker, text, any_case?) do
    names =
      for regex <- masker.stems ++ masker.short,
          [{start, len}] <- Regex.scan(regex, text, return: :index),
          found = binary_part(text, start, len),
          any_case? or capitalized?(found) or stem_of?(masker.stem_set, found),
          do: {start, len, "NAME"}

    exact_spans(masker, text, any_case?) ++ names
  end

  defp exact_spans(%{matcher: nil}, _text, _any_case?), do: []

  defp exact_spans(masker, text, any_case?) do
    folded = String.downcase(text)

    if byte_size(folded) == byte_size(text) do
      for {start, len} <- :binary.matches(folded, masker.matcher),
          key = binary_part(folded, start, len),
          found = binary_part(text, start, len),
          String.downcase(found) == key,
          whole_word?(masker, key, text, start, len),
          alias = pick(Map.fetch!(masker.exact, key), found, any_case?),
          alias != nil,
          do: {start, len, {:alias, alias}}
    else
      for {start, len} <- :binary.matches(text, masker.cased_matcher),
          found = binary_part(text, start, len),
          whole_word?(masker, String.downcase(found), text, start, len),
          do: {start, len, {:alias, Map.fetch!(masker.cased, found)}}
    end
  end

  # Long names also match glued to other words, as bank transfers write
  # them (JANKOWALSKI); short values and addresses only as whole words, so a
  # known "Inka" or "San Francisco, Ca" leaves "INKASO" and "California"
  # alone.
  defp whole_word?(masker, key, text, start, len) do
    (len >= 6 and key not in masker.bounded) or bounded?(text, start, len)
  end

  defp bounded?(text, start, len) do
    not Regex.match?(~r/\p{L}\z/u, binary_part(text, 0, start)) and
      not Regex.match?(~r/^\p{L}/u, binary_part(text, start + len, byte_size(text) - start - len))
  end

  # Lower-case forms of a known single word stay: they are more often a
  # common word than the name.
  defp pick(candidates, found, any_case?) do
    case List.keyfind(candidates, found, 0) do
      {_, alias} ->
        alias

      nil ->
        {canonical, alias} = hd(candidates)

        if any_case? or capitalized?(found) or not String.match?(canonical, ~r/^\p{L}+$/u),
          do: alias
    end
  end

  defp capitalized?(text), do: String.match?(text, ~r/^\p{Lu}/u)

  # Stems still match their own case: a lower-case company word
  # ("budowlana") keeps matching its lower-case forms.
  defp stem_of?(stems, found) do
    length = String.length(found)
    length >= 4 and Enum.any?(4..length, &MapSet.member?(stems, String.slice(found, 0, &1)))
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
