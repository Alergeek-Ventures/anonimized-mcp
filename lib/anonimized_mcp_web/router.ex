defmodule AnonimizedMcpWeb.Router do
  use AnonimizedMcpWeb, :router

  use AshAuthentication.Phoenix.Router
  use AshAuthentication.Phoenix.Oauth2Server.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AnonimizedMcpWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
    plug :set_actor, :user
  end

  pipeline :oauth_api do
    plug :accepts, ["json"]
    plug AnonimizedMcpWeb.OauthRateLimit
  end

  pipeline :mcp do
    plug AshAuthentication.Phoenix.Oauth2Server.BearerPlug,
      oauth2_server: AnonimizedMcp.Oauth2Server,
      scope: "mcp"

    plug AshAuthentication.Phoenix.Oauth2Server.RequireScopePlug,
      oauth2_server: AnonimizedMcp.Oauth2Server,
      scope: "mcp"
  end

  # Consent must come before the protocol routes, which own /oauth.
  scope "/" do
    pipe_through :browser
    oauth2_server_consent_routes(oauth2_server: AnonimizedMcp.Oauth2Server)
  end

  scope "/" do
    pipe_through :oauth_api
    oauth2_server_protocol_routes(oauth2_server: AnonimizedMcp.Oauth2Server)
  end

  scope "/mcp" do
    pipe_through :mcp

    forward "/", AshAi.Mcp.Router,
      tools: [:list_sources, :describe_schema, :query, :check_value, :report_leak],
      otp_app: :anonimized_mcp
  end

  scope "/", AnonimizedMcpWeb do
    pipe_through :browser

    get "/", PageController, :home
    auth_routes AuthController, AnonimizedMcp.Accounts.User, path: "/auth"

    sign_out_route AuthController, "/sign-out"

    sign_in_route auth_routes_prefix: "/auth",
                  on_mount: [{AnonimizedMcpWeb.LiveUserAuth, :live_no_user}]
  end
end
