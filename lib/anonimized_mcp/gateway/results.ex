defmodule AnonimizedMcp.Gateway.Results do
  @moduledoc """
  Keeps the most recent masked query results, so an agent can point at a
  cell that still shows personal data by query id, row and column instead of
  quoting it.
  """

  use GenServer

  @table __MODULE__
  @kept 1000

  @type result :: %{source: String.t(), columns: [String.t()], rows: [list()]}

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :ordered_set])
    {:ok, nil}
  end

  @doc "Stores a masked result and returns its id."
  @spec put(result()) :: String.t()
  def put(result) do
    id = System.unique_integer([:positive, :monotonic])
    :ets.insert(@table, {id, result})

    if :ets.info(@table, :size) > @kept, do: :ets.delete(@table, :ets.first(@table))

    "q#{id}"
  end

  @doc "Returns the masked cell at `row` (zero-based) and `column` of a stored result."
  @spec cell(String.t(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, term()} | {:error, String.t()}
  def cell(source, "q" <> id, row, column) do
    with {id, ""} <- Integer.parse(id),
         [{_, %{source: ^source} = result}] <- :ets.lookup(@table, id),
         index when is_integer(index) <- Enum.find_index(result.columns, &(&1 == column)),
         [_ | _] = values <- Enum.at(result.rows, row) || :no_row do
      {:ok, Enum.at(values, index)}
    else
      :no_row -> {:error, "Row #{row} is not in that result."}
      nil -> {:error, "Column #{inspect(column)} is not in that result."}
      _ -> {:error, "Unknown query id for source #{inspect(source)}. #{recent(source)}"}
    end
  end

  def cell(source, _id, _row, _column),
    do: {:error, "Query ids look like q123. #{recent(source)}"}

  # Agents that lose the id of a result can find it by its columns.
  @recent 5

  defp recent(source) do
    recent =
      :ets.foldr(
        fn
          {id, %{source: ^source, columns: columns}}, acc when length(acc) < @recent ->
            ["q#{id} (#{Enum.join(columns, ", ")})" | acc]

          _, acc ->
            acc
        end,
        [],
        @table
      )

    case recent do
      [] -> "There are no recent results for this source."
      _ -> "Most recent results, newest last: " <> Enum.join(Enum.reverse(recent), "; ") <> "."
    end
  end
end
