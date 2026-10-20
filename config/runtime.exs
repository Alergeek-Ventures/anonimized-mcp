import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/anonimized_mcp start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :anonimized_mcp, AnonimizedMcpWeb.Endpoint, server: true
end

config :anonimized_mcp, AnonimizedMcpWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :anonimized_mcp, AnonimizedMcpWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/anonimized_mcp_web/router\.ex$"E,
        ~r"lib/anonimized_mcp_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

# Google sign-in is optional outside production: the sign-in page also
# offers a password there.
if config_env() != :prod do
  config :anonimized_mcp,
    google_client_id: System.get_env("GOOGLE_CLIENT_ID"),
    google_client_secret: System.get_env("GOOGLE_CLIENT_SECRET")
end

if config_env() == :prod do
  # Every setting comes from the environment, which the deploying app's CI
  # fills from its secret store.

  # Public URL of this instance; the OAuth issuer, the MCP resource and the
  # Google callback derive from it.
  phx_url = System.fetch_env!("PHX_URL")
  %URI{scheme: scheme, host: host, port: port} = URI.parse(phx_url)

  config :anonimized_mcp, AnonimizedMcpWeb.Endpoint,
    url: [scheme: scheme, host: host, port: port],
    check_origin: [phx_url],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    # Also keys the HMAC of aliases.
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")

  # The gateway's own database: operators, OAuth clients and tokens, leak reports.
  config :anonimized_mcp, AnonimizedMcp.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "5"))

  config :anonimized_mcp,
    token_signing_secret: System.fetch_env!("TOKEN_SIGNING_SECRET"),
    oauth2_signing_secret: System.fetch_env!("OAUTH2_SIGNING_SECRET"),
    oauth2_issuer_url: phx_url,
    oauth2_resource_url: phx_url <> "/mcp",
    google_client_id: System.fetch_env!("GOOGLE_CLIENT_ID"),
    google_client_secret: System.fetch_env!("GOOGLE_CLIENT_SECRET")

  # The database agents query, through a read-only role. One instance serves
  # one app; the source is named after the database.
  source_url = System.fetch_env!("SOURCE_URL")

  sources = %{
    String.trim_leading(URI.parse(source_url).path, "/") => [
      url: source_url,
      description: System.get_env("SOURCE_DESCRIPTION", "")
    ]
  }

  config :anonimized_mcp, :sources, sources
end
