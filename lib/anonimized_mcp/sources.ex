defmodule AnonimizedMcp.Sources do
  @moduledoc """
  Configured databases agents can debug. A source needs only a URL; each has
  its own small connection pool. The connection is read-only at session
  level, but the database role must be read-only too; the session settings
  are only a second line of defence.

      config :anonimized_mcp, :sources, %{
        "app" => [
          url: "postgres://debug_reader:...@host/app",
          description: "Production database of App"
        ]
      }
  """

  @enforce_keys [:name, :url]
  defstruct [:name, :url, description: ""]

  @type t :: %__MODULE__{name: String.t(), url: String.t(), description: String.t()}

  @session_parameters [
    default_transaction_read_only: "on",
    statement_timeout: "15s",
    lock_timeout: "1s",
    idle_in_transaction_session_timeout: "5s",
    application_name: "anonimized_mcp"
  ]

  @doc "Returns all configured sources."
  @spec all() :: [t()]
  def all do
    :anonimized_mcp
    |> Application.get_env(:sources, %{})
    |> Enum.map(fn {name, opts} -> struct!(__MODULE__, [{:name, name} | opts]) end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Returns the source called `name`."
  @spec fetch(String.t()) :: {:ok, t()} | {:error, String.t()}
  def fetch(name) do
    case Enum.find(all(), &(&1.name == name)) do
      nil ->
        {:error, "Unknown source #{inspect(name)}. Call list_sources for the available ones."}

      source ->
        {:ok, source}
    end
  end

  @doc """
  Returns the key aliases of `source` are derived from. It comes from the
  endpoint's `secret_key_base`, so aliases survive restarts and differ
  between sources without extra configuration.
  """
  @spec alias_key(String.t()) :: binary()
  def alias_key(source) do
    secret = Application.fetch_env!(:anonimized_mcp, AnonimizedMcpWeb.Endpoint)[:secret_key_base]
    :crypto.mac(:hmac, :sha256, secret, "anonimized_mcp aliases:" <> source)
  end

  @doc "Returns the connection pool of a source."
  @spec connection(t()) :: GenServer.name()
  def connection(%__MODULE__{name: name}), do: {:via, Registry, {__MODULE__.Registry, name}}

  @doc "Child specs for the source registry and one pool per source."
  @spec child_specs() :: [Supervisor.child_spec()]
  def child_specs do
    pools =
      Enum.map(all(), fn source ->
        opts =
          Ecto.Repo.Supervisor.parse_url(source.url) ++
            [name: connection(source), pool_size: 2, parameters: @session_parameters]

        Supervisor.child_spec({Postgrex, opts}, id: {__MODULE__, source.name})
      end)

    [{Registry, keys: :unique, name: __MODULE__.Registry} | pools]
  end
end
