defmodule AnonimizedMcp.Masking.Identifiers do
  @moduledoc """
  Checksum validation for Polish identifiers (NIP, PESEL, REGON, ID card and
  passport numbers), IBAN/NRB account numbers and payment cards. Detectors
  use it to tell real identifiers from arbitrary digit runs, and value checks
  use it to report validity without the value.
  """

  @doc "Returns whether `value` is a NIP with a valid checksum (digits only, optional PL prefix)."
  @spec nip?(String.t()) :: boolean()
  def nip?(value) do
    case digits(String.replace_prefix(value, "PL", "")) do
      [_, _, _, _, _, _, _, _, _, check] = d ->
        weighted(d, [6, 5, 7, 2, 3, 4, 5, 6, 7]) |> rem(11) == check

      _ ->
        false
    end
  end

  @doc "Returns whether `value` is a PESEL with a valid checksum."
  @spec pesel?(String.t()) :: boolean()
  def pesel?(value) do
    case digits(value) do
      [_, _, _, _, _, _, _, _, _, _, check] = d ->
        rem(10 - rem(weighted(d, [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]), 10), 10) == check

      _ ->
        false
    end
  end

  @doc "Returns whether `value` is a 9 or 14 digit REGON with a valid checksum."
  @spec regon?(String.t()) :: boolean()
  def regon?(value) do
    case digits(value) do
      [_, _, _, _, _, _, _, _, check] = d ->
        regon_check(d, [8, 9, 2, 3, 4, 5, 6, 7], check)

      [_, _, _, _, _, _, _, _, _, _, _, _, _, check] = d ->
        regon_check(d, [2, 4, 8, 5, 0, 9, 7, 3, 6, 1, 2, 4, 8], check)

      _ ->
        false
    end
  end

  @doc """
  Returns whether `value` is an IBAN with a valid mod-97 checksum. A bare
  26-digit NRB is checked as a Polish IBAN.
  """
  @spec iban?(String.t()) :: boolean()
  def iban?(value) do
    compact = value |> String.replace(" ", "") |> String.upcase()

    compact =
      if String.match?(compact, ~r/^\d{26}$/), do: "PL" <> compact, else: compact

    with true <- String.match?(compact, ~r/^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$/),
         {head, rest} = String.split_at(compact, 4) do
      (rest <> head)
      |> String.to_charlist()
      |> Enum.map_join(fn
        c when c in ?0..?9 -> <<c>>
        c -> Integer.to_string(c - ?A + 10)
      end)
      |> String.to_integer()
      |> rem(97) == 1
    end
  end

  @doc """
  Returns whether `value` is a Polish ID card number (`ABA300000`): three
  letters and six digits, the first digit checking the rest with weights
  7, 3, 1 and letters counted from A=10. A space after the letters is allowed.
  """
  @spec id_card?(String.t()) :: boolean()
  def id_card?(value), do: document?(value, ~r/^[A-Z]{3}\d{6}$/, [7, 3, 1, 9, 7, 3, 1, 7, 3])

  @doc """
  Returns whether `value` is a Polish passport number (`CC7999486`): two
  letters and seven digits, the first digit checking the rest the same way.
  A space after the letters is allowed.
  """
  @spec passport?(String.t()) :: boolean()
  def passport?(value), do: document?(value, ~r/^[A-Z]{2}\d{7}$/, [7, 3, 9, 1, 7, 3, 1, 7, 3])

  @doc """
  Returns whether `value` (digits, optionally grouped by spaces or hyphens)
  is a payment card number: a known issuer prefix and length, and a valid
  Luhn checksum. The prefix check keeps millisecond timestamps, barcodes
  and `20241018120000_` migration versions out.
  """
  @spec card?(String.t()) :: boolean()
  def card?(value) do
    compact = String.replace(value, [" ", "-"], "")
    d = digits(compact)
    length(d) in card_lengths(compact) and luhn(d) == 0
  end

  # Visa, Amex, Diners/JCB, Mastercard, Maestro/Discover/UnionPay. Lengths
  # are the ones in use, so EAN-13 barcodes (590...) stay readable.
  defp card_lengths("4" <> _), do: [16, 19]
  defp card_lengths("34" <> _), do: [15]
  defp card_lengths("37" <> _), do: [15]
  defp card_lengths("3" <> _), do: 14..19
  defp card_lengths("5" <> <<c>> <> _) when c in ?1..?5, do: [16]
  defp card_lengths("5" <> _), do: 16..19
  defp card_lengths("6" <> _), do: 16..19

  defp card_lengths("2" <> _ = value) do
    case Integer.parse(String.slice(value, 0, 4)) do
      {prefix, ""} when prefix in 2221..2720 -> [16]
      _ -> []
    end
  end

  defp card_lengths(_), do: []

  defp luhn(digits) do
    digits
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn
      {d, i} when rem(i, 2) == 1 and d > 4 -> d * 2 - 9
      {d, i} when rem(i, 2) == 1 -> d * 2
      {d, _} -> d
    end)
    |> Enum.sum()
    |> rem(10)
  end

  # The check digit has weight 9, which is -1 mod 10, so the whole sum is 0.
  defp document?(value, shape, weights) do
    compact = String.replace(value, " ", "", global: false)

    String.match?(compact, shape) and
      compact
      |> String.to_charlist()
      |> Enum.map(fn
        c when c in ?0..?9 -> c - ?0
        c -> c - ?A + 10
      end)
      |> weighted(weights)
      |> rem(10) == 0
  end

  defp regon_check(digits, weights, check) do
    sum = weighted(digits, weights) |> rem(11)
    rem(sum, 10) == check
  end

  defp digits(value) do
    if String.match?(value, ~r/^\d+$/),
      do: value |> String.graphemes() |> Enum.map(&String.to_integer/1),
      else: []
  end

  defp weighted(digits, weights),
    do: digits |> Enum.zip(weights) |> Enum.map(fn {d, w} -> d * w end) |> Enum.sum()
end
