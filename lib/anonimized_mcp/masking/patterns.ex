defmodule AnonimizedMcp.Masking.Patterns do
  @moduledoc """
  Finds personal data and credentials that have a fixed shape: e-mails,
  phone numbers, IBAN/NRB, NIP, PESEL, REGON, IP addresses, password hashes,
  JWTs and long random tokens. Digit-based identifiers only count when their
  checksum holds, so amounts, dates and record numbers stay readable.
  """

  alias AnonimizedMcp.Masking.Identifiers

  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  # Earlier patterns win when matches overlap.
  @patterns [
    {"EMAIL", ~r/(?<![\w.+-])[\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}(?![\w-])/u, nil},
    # Profile links name a person; other URLs stay readable.
    {"PROFILE",
     ~r/(?:https?:\/\/)?(?:www\.)?(?:github\.com|gitlab\.com|linkedin\.com\/in|x\.com|twitter\.com|facebook\.com|instagram\.com)\/[^\s\/?#"'<>]+\/?/i,
     nil},
    {:secret, ~r/\beyJ[\w-]+\.[\w-]+\.[\w-]+/, nil},
    {:secret, ~r/\$(?:argon2(?:id|i|d)|2[aby])\$[^\s"'}]+/, nil},
    {"IBAN",
     ~r/\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,4})?\b|\b\d{2}(?: ?\d{4}){6}\b/i,
     :iban},
    {"PESEL", ~r/(?<![\w-])\d{11}(?![\w-])/, :pesel},
    {"TAX_ID",
     ~r/(?<![\w-])(?:PL)?(?:\d{10}|\d{3}-\d{3}-\d{2}-\d{2}|\d{3}-\d{2}-\d{2}-\d{3})(?![\w-])/,
     :nip},
    {"REGON", ~r/(?<![\w-])(?:\d{14}|\d{9})(?![\w-])/, :regon},
    {"IP", ~r/\b(?:\d{1,3}\.){3}\d{1,3}\b/, :ipv4},
    {"IP", ~r/(?<![\w:])(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}(?![\w:])/, nil},
    # International numbers in any grouping: +48 600 12 34 56, +1 (555) 123-4567.
    {"PHONE", ~r/(?<![\w+])\+\d{1,3}(?:[ .-]?\(?\d{1,4}\)?){2,6}(?!\w)/, :phone_digits},
    {"PHONE", ~r/(?<!\w)(?:\+\d{2} ?)?(?:\(?\d{3}\)?[ -]?\d{3}[ -]?\d{3,4})(?:x\d+)?(?!\w)/, nil},
    {"PHONE", ~r/(?<![\w-])\d{2,3}[ -]\d{2,3}[ -]\d{2}[ -]\d{2}(?![\w-])/, nil},
    # Random tokens mix cases and digits; single-case runs are mostly hashes,
    # module names and ids that debugging needs. UUIDs are record ids too.
    {:secret,
     ~r/(?<![\w$\/.+=-])(?=[\w+=-]*\d)(?=[\w+=-]*[a-z])(?=[\w+=-]*[A-Z])[\w+=-]{24,}(?![\w$\/.+=-])/,
     :not_uuid}
  ]

  @type span :: {start :: non_neg_integer(), length :: pos_integer(), String.t() | :secret}

  @doc "Returns non-overlapping spans in `text`, as byte offsets, ordered by position."
  @spec spans(String.t()) :: [span()]
  def spans(text) do
    @patterns
    |> Enum.flat_map(fn {type, regex, check} ->
      for [{start, len}] <- Regex.scan(regex, text, return: :index),
          valid?(check, binary_part(text, start, len)),
          do: {start, len, type}
    end)
    |> Enum.reduce([], fn {start, len, _} = span, kept ->
      if Enum.any?(kept, fn {s, l, _} -> start < s + l and s < start + len end),
        do: kept,
        else: [span | kept]
    end)
    |> Enum.sort()
  end

  defp valid?(nil, _value), do: true
  defp valid?(:iban, value), do: Identifiers.iban?(value)
  defp valid?(:pesel, value), do: Identifiers.pesel?(value)
  defp valid?(:nip, value), do: Identifiers.nip?(String.replace(value, "-", ""))
  defp valid?(:regon, value), do: Identifiers.regon?(value)
  defp valid?(:not_uuid, value), do: not Regex.match?(@uuid, value)

  defp valid?(:phone_digits, value),
    do: (value |> String.replace(~r/\D/, "") |> byte_size()) in 8..15

  defp valid?(:ipv4, value),
    do: value |> String.split(".") |> Enum.all?(&(String.to_integer(&1) < 256))
end
