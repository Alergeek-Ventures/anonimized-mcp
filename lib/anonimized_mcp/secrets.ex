defmodule AnonimizedMcp.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        AnonimizedMcp.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:anonimized_mcp, :token_signing_secret)
  end

  def secret_for([:issuer_url], AnonimizedMcp.Oauth2Server, _opts, _context) do
    Application.fetch_env(:anonimized_mcp, :oauth2_issuer_url)
  end

  def secret_for([:resource_url], AnonimizedMcp.Oauth2Server, _opts, _context) do
    Application.fetch_env(:anonimized_mcp, :oauth2_resource_url)
  end

  def secret_for([:signing_secret], AnonimizedMcp.Oauth2Server, _opts, _context) do
    Application.fetch_env(:anonimized_mcp, :oauth2_signing_secret)
  end
end
