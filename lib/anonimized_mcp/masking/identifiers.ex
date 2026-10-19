defmodule AnonimizedMcp.Masking.Identifiers do
  @moduledoc """
  Checksum validation for Polish identifiers (NIP, PESEL, REGON) and IBAN/NRB
  account numbers. Detectors use it to tell real identifiers from arbitrary
  digit runs, and value checks use it to report validity without the value.
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
