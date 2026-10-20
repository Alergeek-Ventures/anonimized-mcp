defmodule AnonimizedMcp.Accounts.UserIdentity do
  use Ash.Resource,
    otp_app: :anonimized_mcp,
    domain: AnonimizedMcp.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication.UserIdentity]

  user_identity do
    user_resource AnonimizedMcp.Accounts.User
  end

  postgres do
    table "user_identities"
    repo AnonimizedMcp.Repo
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end
end
