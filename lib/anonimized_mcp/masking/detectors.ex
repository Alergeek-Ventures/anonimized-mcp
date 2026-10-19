defmodule AnonimizedMcp.Masking.Detectors do
  @moduledoc """
  Finds structured personal data and credentials inside free text: e-mails,
  phone numbers, IBAN/NRB, NIP, PESEL, REGON and bearer tokens. Digit-based
  identifiers only count when their checksum holds, so amounts, dates and
  record numbers stay readable.
  """

  alias AnonimizedMcp.Masking.Identifiers

  # Earlier detectors win when matches overlap.
  @detectors [
    {"SECRET", ~r/\beyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}/, nil},
    {"EMAIL", ~r/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/u, nil},
    {"IBAN", ~r/\b(?:[A-Z]{2} ?)?\d{2}(?: ?\d{4}){6}\b/, :iban?},
    {"PESEL", ~r/(?<!\d)\d{11}(?!\d)/, :pesel?},
    {"TAX_ID",
     ~r/(?<![\d-])(?:PL)?(?:\d{10}|\d{3}-\d{3}-\d{2}-\d{2}|\d{3}-\d{2}-\d{2}-\d{3})(?![\d])/,
     :nip?},
    {"REGON", ~r/(?<!\d)(?:\d{14}|\d{9})(?!\d)/, :regon?},
    {"PHONE",
     ~r/(?:\+48[ -]?\d{3}[ -]?\d{3}[ -]?\d{3}|(?<![\d-])\d{3}[ -]\d{3}[ -]\d{3}(?![\d-]))/, nil}
  ]

  @type span :: {start :: non_neg_integer(), length :: pos_integer(), type :: String.t()}

  @doc "Returns non-overlapping detected spans in `text`, as byte offsets, ordered by position."
  @spec spans(String.t()) :: [span()]
  def spans(text) do
    @detectors
    |> Enum.flat_map(fn {type, regex, validator} ->
      regex
      |> Regex.scan(text, return: :index)
      |> Enum.map(fn [{start, len}] -> {start, len, type} end)
      |> Enum.filter(fn {start, len, _} -> valid?(validator, binary_part(text, start, len)) end)
    end)
    |> Enum.reduce([], fn {start, len, _} = span, kept ->
      if Enum.any?(kept, fn {s, l, _} -> start < s + l and s < start + len end),
        do: kept,
        else: [span | kept]
    end)
    |> Enum.sort()
  end

  defp valid?(nil, _value), do: true

  defp valid?(validator, value),
    do: apply(Identifiers, validator, [String.replace(value, ~r/[ -]/, "")])
end
