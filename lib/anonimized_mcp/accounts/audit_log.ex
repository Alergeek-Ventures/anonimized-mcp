defmodule AnonimizedMcp.Accounts.AuditLog do
  use Ash.Resource,
    otp_app: :anonimized_mcp,
    domain: AnonimizedMcp.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication.AuditLogResource]

  postgres do
    table "auth_audit_log"
    repo AnonimizedMcp.Repo

    # Every sign-in counts the recent failures for its email.
    custom_indexes do
      index [:identity, :logged_at]
    end
  end

  audit_log do
    # Brute-force checks read only the last few minutes; the rest is history.
    log_lifetime 30

    # Write each event at once, so failed sign-ins count immediately instead
    # of after the next batch.
    write_batching do
      enabled? false
    end
  end

  actions do
    defaults [:read]
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end
end
