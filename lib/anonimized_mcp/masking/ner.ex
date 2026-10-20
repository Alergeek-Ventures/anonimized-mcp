defmodule AnonimizedMcp.Masking.Ner do
  @moduledoc """
  Finds names, addresses and other personal data in free text with
  [bardsai/eu-pii-anonimization-multilang-v2](https://huggingface.co/bardsai/eu-pii-anonimization-multilang-v2),
  a token classifier for 24 EU languages run on CPU through ONNX Runtime.

  The model files are downloaded once into the user cache directory, pinned
  to one revision and checked against their SHA-256. Decoding follows the
  model's own `pii_detector.py`: sliding windows, one label per word from the
  mean of its sub-token probabilities, and adjacent words of one type merged
  unless the next one looks like the start of a new entity.
  """

  use GenServer

  require Logger

  @repo "bardsai/eu-pii-anonimization-multilang-v2"
  @revision "5e61416e77675881185767fc0c67759d48b35592"
  @files %{
    "config.json" => nil,
    "tokenizer.json" => "609d8f4c067cd3950f88594c5a802616cea245823836ef5848ee4fc40aab5b6f",
    "onnx/model_quantized.onnx" =>
      "1ee975af537a3ae507769703c03fc83880cce7e2706bc6d2dc1fd9db861acfa1"
  }

  @window 510
  @stride 128
  @batch 16

  # Amounts, invoice references, places, roles and personal attributes are
  # what diagnosis depends on; everything else the model finds is masked.
  @kept ~w(FINANCIAL_AMOUNT DOCUMENT_REFERENCE LOCATION PERSON_ROLE_OR_TITLE PERSON_ATTRIBUTE)

  @alias_types %{
    "PERSON_NAME" => "NAME",
    "PERSON_ALIAS" => "NAME",
    "PROPER_NAME" => "NAME",
    "CONTACT_HANDLE" => "NAME",
    "ORGANIZATION_NAME" => "COMPANY",
    "POSTAL_ADDRESS" => "ADDRESS",
    "GEO_LOCATION" => "ADDRESS",
    "EMAIL_ADDRESS" => "EMAIL",
    "PHONE_NUMBER" => "PHONE",
    "DATE_OF_BIRTH" => "BIRTHDATE",
    "IP_ADDRESS" => "IP",
    "BANK_ACCOUNT_IDENTIFIER" => "IBAN",
    "PAYMENT_CARD" => "CARD",
    "IDENTIFYING_LINK" => "URL",
    "AUTH_SECRET" => :secret,
    "PAYMENT_CARD_SECURITY" => :secret
  }

  # Model types without a specific alias: identifiers become ID, special
  # categories (health, beliefs, ...) become SENSITIVE.
  @id_types ~w(PERSON_IDENTIFIER ACCOUNT_IDENTIFIER DOCUMENT_IDENTIFIER VEHICLE_IDENTIFIER
               DEVICE_IDENTIFIER ORGANIZATION_IDENTIFIER)

  # Types the reference decoder only accepts with at least two digits.
  @digit_types ~w(PERSON_IDENTIFIER BANK_ACCOUNT_IDENTIFIER PAYMENT_CARD ACCOUNT_IDENTIFIER
                  DOCUMENT_IDENTIFIER VEHICLE_IDENTIFIER)

  # Polish vehicle plates: a voivodeship letter and district code, then five
  # characters starting with a digit (WA 12345, KR 7XY12) or, after a
  # three-letter code, four mixing letters and digits (WPI A123). ORD1234 and
  # FV/2024/03/117 do not fit.
  @plate ~r/^[BCDEFGKLNOPRSTWZ](?:[A-Z] ?\d[A-Z0-9]{4}|[A-Z]{2} ?(?:\d[A-Z0-9]{4}|(?=[A-Z0-9]{0,3}[A-Z])(?=[A-Z0-9]{0,3}\d)[A-Z0-9]{4}))$/

  @word ~r/[^\s,;|"<>()\[\]{}*^]+/u
  @edges ~r/^[(\[{<"'«„]*(.*?)[)\]}>"'».,;:!?]*$/su
  @urlish ~r/(https?:\/\/|www\.|\w\.[a-z]{2,}\b|\/\w)/iu

  @type span :: {start :: non_neg_integer(), length :: pos_integer(), String.t() | :secret}

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # Loading is synchronous, so nothing is served before the model can mask it.
  @impl true
  def init(nil) do
    dir = download()
    {:ok, tokenizer} = Tokenizers.Tokenizer.from_file(Path.join(dir, "tokenizer.json"))

    labels =
      dir |> Path.join("config.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("id2label")

    labels =
      Enum.map(0..(map_size(labels) - 1), fn i ->
        case Map.fetch!(labels, to_string(i)) do
          "O" -> {nil, false}
          "B-" <> type -> {type, true}
          "I-" <> type -> {type, false}
        end
      end)

    :persistent_term.put(__MODULE__, %{
      model: Ortex.load(Path.join(dir, "onnx/model_quantized.onnx")),
      tokenizer: tokenizer,
      labels: labels,
      bos: Tokenizers.Tokenizer.token_to_id(tokenizer, "<bos>"),
      eos: Tokenizers.Tokenizer.token_to_id(tokenizer, "<eos>"),
      pad: Tokenizers.Tokenizer.token_to_id(tokenizer, "<pad>")
    })

    {:ok, nil}
  end

  @doc """
  Returns the personal data spans of each text, as byte offsets with an alias
  type or `:secret`.
  """
  @spec spans([String.t()]) :: [[span()]]
  def spans(texts) do
    ner = :persistent_term.get(__MODULE__)

    windows =
      texts
      |> Enum.with_index()
      |> Enum.flat_map(fn {text, i} -> Enum.map(windows(ner, text), &{i, &1}) end)

    probabilities =
      windows
      |> Enum.sort_by(fn {_, {ids, _}} -> length(ids) end)
      |> Enum.chunk_every(@batch)
      |> Enum.flat_map(&run(ner, &1))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    texts
    |> Enum.with_index()
    |> Enum.map(fn {text, i} -> decode(ner, text, Map.get(probabilities, i, [])) end)
  end

  defp windows(ner, text) do
    {:ok, encoding} = Tokenizers.Tokenizer.encode(ner.tokenizer, text, add_special_tokens: false)
    ids = Tokenizers.Encoding.get_ids(encoding)
    offsets = Tokenizers.Encoding.get_offsets(encoding)
    tokens = Enum.zip(ids, offsets)

    starts =
      if length(tokens) <= @window,
        do: [0],
        else: Enum.take_every(0..(length(tokens) - @stride - 1)//1, @window - @stride)

    Enum.map(starts, fn start ->
      {ids, offsets} = tokens |> Enum.slice(start, @window) |> Enum.unzip()
      {[ner.bos | ids] ++ [ner.eos], offsets}
    end)
  end

  defp run(ner, batch) do
    width = batch |> Enum.map(fn {_, {ids, _}} -> length(ids) end) |> Enum.max()

    {ids, mask} =
      batch
      |> Enum.map(fn {_, {ids, _}} ->
        padding = width - length(ids)

        {ids ++ List.duplicate(ner.pad, padding),
         List.duplicate(1, length(ids)) ++ List.duplicate(0, padding)}
      end)
      |> Enum.unzip()

    {logits} = Ortex.run(ner.model, {Nx.tensor(ids, type: :s64), Nx.tensor(mask, type: :s64)})
    logits = logits |> Nx.backend_transfer(Nx.BinaryBackend) |> Nx.to_list()

    Enum.zip_with(batch, logits, fn {i, {_, offsets}}, rows ->
      # Drop the scores of <bos>, <eos> and padding.
      {i, Enum.zip(offsets, rows |> tl() |> Enum.take(length(offsets)))}
    end)
  end

  # Per token: the probability of each entity type (B and I pooled) and of a
  # B label, accumulated at the token's first non-space byte.
  defp decode(ner, text, windows) do
    by_start =
      for window <- windows,
          {{start, stop}, logits} <- window,
          stop > start,
          reduce: %{} do
        acc ->
          start = skip_space(text, start, stop)
          {types, b} = pool(ner.labels, softmax(logits))

          Map.update(acc, start, {types, 1, b}, fn {t, n, bm} ->
            {Map.merge(t, types, fn _, x, y -> x + y end), n + 1, bm + b}
          end)
      end

    @word
    |> Regex.scan(text, return: :index)
    |> Enum.flat_map(fn [{start, len}] -> trim_word(text, start, start + len) end)
    |> Enum.reduce([], fn {ws, we}, spans -> label_word(by_start, text, ws, we, spans) end)
    |> Enum.reverse()
    |> Enum.filter(fn {s, e, type} -> valid?(binary_part(text, s, e - s), type) end)
    |> Enum.flat_map(fn {s, e, type} ->
      case Map.fetch(@alias_types, type) do
        # The model often calls plates references; invoice numbers stay.
        _ when type == "DOCUMENT_REFERENCE" ->
          if plate?(binary_part(text, s, e - s)), do: [{s, e - s, "ID"}], else: []

        _ when type in @kept ->
          []

        {:ok, alias_type} ->
          [{s, e - s, alias_type}]

        :error when type in @id_types ->
          [{s, e - s, "ID"}]

        :error ->
          [{s, e - s, "SENSITIVE"}]
      end
    end)
  end

  defp label_word(by_start, text, ws, we, spans) do
    scored = for s <- ws..(we - 1)//1, entry = by_start[s], do: entry

    with [{_, first_count, first_b} | _] <- scored,
         {types, count} = sum(scored),
         {type, p} = Enum.max_by(types, &elem(&1, 1)),
         true <- p >= count - Enum.sum(Map.values(types)) do
      case spans do
        [{ps, pe, ^type} | rest] when first_b / first_count < 0.5 ->
          gap = binary_part(text, pe, ws - pe)

          if Regex.match?(~r/^[ ,\-\/.()]*$/, gap),
            do: [{ps, we, type} | rest],
            else: [{ws, we, type} | spans]

        _ ->
          [{ws, we, type} | spans]
      end
    else
      _ -> spans
    end
  end

  defp sum(entries) do
    Enum.reduce(entries, {%{}, 0}, fn {t, n, _b}, {acc, count} ->
      {Map.merge(acc, t, fn _, x, y -> x + y end), count + n}
    end)
  end

  defp softmax(logits) do
    max = Enum.max(logits)
    exps = Enum.map(logits, &:math.exp(&1 - max))
    total = Enum.sum(exps)
    Enum.map(exps, &(&1 / total))
  end

  defp pool(labels, probabilities) do
    Enum.zip_reduce(labels, probabilities, {%{}, 0.0}, fn
      {nil, _}, _p, acc ->
        acc

      {type, b?}, p, {types, b} ->
        {Map.update(types, type, p, &(&1 + p)), if(b?, do: b + p, else: b)}
    end)
  end

  # Byte-BPE offsets include the leading space.
  defp skip_space(text, start, stop) do
    if start < stop - 1 and binary_part(text, start, 1) in [" ", "\t", "\n", "\r"],
      do: skip_space(text, start + 1, stop),
      else: start
  end

  defp trim_word(text, start, stop) do
    case Regex.run(@edges, binary_part(text, start, stop - start), return: :index) do
      [_, {_, 0}] -> []
      [_, {offset, len}] -> [{start + offset, start + offset + len}]
    end
  end

  defp valid?(value, "IDENTIFYING_LINK"), do: Regex.match?(@urlish, value)
  defp valid?(value, "PHONE_NUMBER"), do: digit_count(value) >= 5
  defp valid?(value, type) when type in @digit_types, do: digit_count(value) >= 2
  defp valid?(_value, _type), do: true

  # Text in capitals reaches the model title-cased (Kr 7Xy12).
  defp plate?(value) do
    upper = String.upcase(value)

    value in [upper, Regex.replace(~r/\p{L}+/u, upper, &String.capitalize/1)] and
      Regex.match?(@plate, upper)
  end

  defp digit_count(value), do: value |> String.replace(~r/\D/, "") |> byte_size()

  defp download do
    dir = Path.join(:filename.basedir(:user_cache, "anonimized_mcp"), "bardsai-#{@revision}")

    for {file, sha256} <- @files, path = Path.join(dir, file), not File.exists?(path) do
      Logger.info("Downloading #{@repo} #{file}")
      File.mkdir_p!(Path.dirname(path))
      partial = path <> ".part"
      url = "https://huggingface.co/#{@repo}/resolve/#{@revision}/#{file}"
      Req.get!(url, into: File.stream!(partial), receive_timeout: :timer.minutes(10))

      if sha256 && sha256 != partial |> File.stream!(2_097_152) |> sha256() do
        File.rm!(partial)
        raise "#{file} of #{@repo} does not match its pinned SHA-256"
      end

      File.rename!(partial, path)
    end

    dir
  end

  defp sha256(stream) do
    stream
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
