defmodule AnonimizedMcp.Gateway.Literals do
  @moduledoc """
  Lets agents filter by aliases. Every string literal that contains an alias
  is replaced by a bind parameter holding the literal with each alias swapped
  for its value, so `WHERE email = 'EMAIL_k3j7x2ab'` and
  `WHERE tax_id = 'TAX_ID_q7m2c4ze '` (note the space) work while the value
  never appears in SQL text, logs or error positions.
  """

  alias AnonimizedMcp.Masking.Aliases

  @doc "Returns the rewritten SQL and its parameters."
  @spec substitute(String.t(), String.t()) ::
          {:ok, String.t(), [String.t()]} | {:error, String.t()}
  def substitute(sql, source) do
    {:ok, %{tokens: tokens}} = PgQuery.scan(sql)

    if Enum.any?(tokens, &(&1.token == :PARAM)) do
      {:error, "Bind parameters ($1) are not supported; write values or aliases as literals."}
    else
      tokens
      |> Enum.filter(&(&1.token == :SCONST))
      |> Enum.map(&{&1, binary_part(sql, &1.start, &1.end - &1.start)})
      |> Enum.filter(fn {_, text} ->
        String.starts_with?(text, "'") and Regex.match?(Aliases.pattern(), text)
      end)
      |> Enum.reduce_while({[], []}, fn {token, text}, {replacements, params} ->
        case resolve(text, source) do
          {:ok, value} ->
            {:cont, {[{token, "$#{length(params) + 1}"} | replacements], params ++ [value]}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:error, message} -> {:error, message}
        {replacements, params} -> {:ok, splice(sql, replacements), params}
      end
    end
  end

  defp resolve(literal, source) do
    content = literal |> String.slice(1..-2//1) |> String.replace("''", "'")

    Aliases.pattern()
    |> Regex.split(content, include_captures: true)
    |> Enum.reduce_while({:ok, ""}, fn part, {:ok, acc} ->
      if Regex.match?(Aliases.pattern(), part) do
        case Aliases.lookup(source, part) do
          {:ok, %{canonical: value}} ->
            {:cont, {:ok, acc <> value}}

          :error ->
            {:halt,
             {:error,
              "Unknown alias #{part}. Aliases come from earlier responses of this source."}}
        end
      else
        {:cont, {:ok, acc <> part}}
      end
    end)
  end

  # Replacements are ordered last-first, so earlier byte offsets stay valid.
  defp splice(sql, replacements) do
    Enum.reduce(replacements, sql, fn {token, replacement}, acc ->
      binary_part(acc, 0, token.start) <>
        replacement <> binary_part(acc, token.end, byte_size(acc) - token.end)
    end)
  end
end
