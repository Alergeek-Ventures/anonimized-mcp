defmodule AnonimizedMcp.Masking.Patterns do
  @moduledoc """
  Finds personal data and credentials that have a fixed shape: e-mails,
  profile links, phone numbers, IBAN/NRB, NIP and EU VAT numbers, PESEL,
  REGON, IP addresses, password hashes, JWTs and long random tokens. Digit-based identifiers only count when their
  checksum holds, so amounts, dates and record numbers stay readable.
  """

  alias AnonimizedMcp.Masking.Identifiers

  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  # Earlier patterns win when matches overlap.
  @patterns [
    {"EMAIL", ~r/(?<![\w.+-])[\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}(?![\w-])/u, nil},
    # Profile links name a person; other URLs stay readable.
    {"PROFILE",
     ~r/(?:https?:\/\/)?(?:www\.)?(?:github\.com|gitlab\.com|linkedin\.com\/in|x\.com|twitter\.com|facebook\.com|instagram\.com|[\w-]+\.slack\.com\/team)\/[^\s\/?#"'<>]+\/?/i,
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
    # EU VAT numbers outside Poland: country prefix and that country's length.
    # A sole trader's number can be their personal number.
    {"TAX_ID",
     ~r/(?<![\w-])(?:AT ?U\d{8}|BE ?[01]\d{9}|BG ?\d{9,10}|CY ?\d{8}[A-Z]|CZ ?\d{8,10}|DE ?\d{9}|DK ?\d{8}|EE ?\d{9}|EL ?\d{9}|ES ?[A-Z0-9]\d{7}[A-Z0-9]|FI ?\d{8}|FR ?[A-Z0-9]{2}\d{9}|HR ?\d{11}|HU ?\d{8}|IE ?\d[A-Z0-9+*]\d{5}[A-Z]{1,2}|IT ?\d{11}|LT ?(?:\d{9}|\d{12})|LU ?\d{8}|LV ?\d{11}|MT ?\d{8}|NL ?\d{9}B\d{2}|PT ?\d{9}|RO ?\d{2,10}|SE ?\d{12}|SI ?\d{8}|SK ?\d{10}|XI ?\d{9}(?:\d{3})?|GB ?\d{9}(?:\d{3})?|CHE[ -]?\d{3}\.?\d{3}\.?\d{3})(?![\w-])/,
     nil},
    {"IP", ~r/\b(?:\d{1,3}\.){3}\d{1,3}\b/, :ipv4},
    {"IP", ~r/(?<![\w:])(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}(?![\w:])/, nil},
    # International numbers in any grouping: +48 600 12 34 56, +1 (555) 123-4567.
    {"PHONE", ~r/(?<![\w+])\+\d{1,3}(?:[ .-]?\(?\d{1,4}\)?){2,6}(?!\w)/, :phone_digits},
    {"PHONE", ~r/(?<!\w)(?:\+\d{2} ?)?(?:\(?\d{3}\)?[ -]?\d{3}[ -]?\d{3,4})(?:x\d+)?(?!\w)/, nil},
    {"PHONE", ~r/(?<![\w-])\d{2,3}[ -]\d{2,3}[ -]\d{2}[ -]\d{2}(?![\w-])/, nil},
    # Polish landlines with the area code in brackets: (22) 123 45 67.
    {"PHONE", ~r/\(\d{2}\) ?\d{3}[ -]?\d{2}[ -]?\d{2}(?![\w-])/, nil},
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
