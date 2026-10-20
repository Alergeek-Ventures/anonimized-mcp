defmodule AnonimizedMcp.Accounts do
  use Ash.Domain,
    otp_app: :anonimized_mcp

  resources do
    resource AnonimizedMcp.Accounts.Token
    resource AnonimizedMcp.Accounts.User
    resource AnonimizedMcp.Accounts.AuditLog
    resource AnonimizedMcp.Accounts.OauthClient
    resource AnonimizedMcp.Accounts.OauthAuthorizationCode
    resource AnonimizedMcp.Accounts.OauthRefreshToken
    resource AnonimizedMcp.Accounts.OauthConsent
  end
end
