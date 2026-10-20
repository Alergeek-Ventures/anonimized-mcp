defmodule AnonimizedMcp.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {AshAuthentication.Oauth2Server.Supervisor, [otp_app: :anonimized_mcp]},
        AnonimizedMcpWeb.Telemetry,
        AnonimizedMcp.Repo,
        {DNSCluster, query: Application.get_env(:anonimized_mcp, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: AnonimizedMcp.PubSub},
        AnonimizedMcp.Masking.Aliases,
        AnonimizedMcp.Masking.Ner,
        AnonimizedMcp.Gateway.Results,
        {AnonimizedMcpWeb.RateLimit, clean_period: :timer.minutes(10)}
      ] ++
        AnonimizedMcp.Sources.child_specs() ++
        [
          AnonimizedMcpWeb.Endpoint,
          {AshAuthentication.Supervisor, [otp_app: :anonimized_mcp]}
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AnonimizedMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AnonimizedMcpWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
