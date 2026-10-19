defmodule AnonimizedMcp.Masking.Aliases do
  @moduledoc """
  Stable pseudonyms for personal values. An alias is a keyed HMAC of the
  trimmed value, so the same entity gets the same alias in every response and
  after a restart. The alias-to-value map stays in this node's memory: it lets
  agents use aliases in later queries and value checks without seeing values.
  """

  use GenServer

  @table __MODULE__

  @type entry :: %{type: String.t(), canonical: String.t(), variants: [String.t()]}

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Returns the alias of `value` for `source`, remembering the exact raw form."
  @spec alias_for(String.t(), String.t(), String.t()) :: String.t()
  def alias_for(source, type, value) do
    canonical = canonical(type, value)
    key = AnonimizedMcp.Sources.fetch!(source).alias_key

    alias =
      :crypto.mac(:hmac, :sha256, key, type <> ":" <> canonical)
      |> Base.encode32(case: :lower, padding: false)
      |> binary_part(0, 8)
      |> then(&"#{type}_#{&1}")

    variants =
      case :ets.lookup(@table, {source, alias}) do
        [{_, _, _, variants}] -> variants
        [] -> []
      end

    unless value in variants do
      :ets.insert(@table, {{source, alias}, type, canonical, [value | variants]})
    end

    alias
  end

  @doc "Resolves an alias issued for `source`."
  @spec lookup(String.t(), String.t()) :: {:ok, entry()} | :error
  def lookup(source, alias) do
    case :ets.lookup(@table, {source, alias}) do
      [{_, type, canonical, variants}] ->
        {:ok, %{type: type, canonical: canonical, variants: Enum.reverse(variants)}}

      [] ->
        :error
    end
  end

  @doc "Returns `{canonical, alias, type}` for every value aliased so far for `source`."
  @spec known(String.t()) :: [{String.t(), String.t(), String.t()}]
  def known(source) do
    :ets.select(@table, [{{{source, :"$1"}, :"$2", :"$3", :_}, [], [{{:"$3", :"$1", :"$2"}}]}])
  end

  @doc "Regex matching any alias token."
  @spec pattern() :: Regex.t()
  def pattern, do: ~r/\b[A-Z][A-Z_]*_[a-z2-7]{8}\b/

  defp canonical("EMAIL", value), do: value |> String.trim() |> String.downcase()
  defp canonical(_type, value), do: String.trim(value)
end
