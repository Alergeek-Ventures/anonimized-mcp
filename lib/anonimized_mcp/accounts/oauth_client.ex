defmodule AnonimizedMcp.Accounts.OauthClient do
  use Ash.Resource,
    otp_app: :anonimized_mcp,
    domain: AnonimizedMcp.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.Oauth2Server.ClientResource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "oauth_clients"
    repo AnonimizedMcp.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :register do
      accept [
        :client_name,
        :redirect_uris,
        :grant_types,
        :response_types,
        :token_endpoint_auth_method,
        :scope
      ]
    end

    create :register_cimd do
      upsert? true
      upsert_identity :by_cimd_url

      accept [
        :cimd_url,
        :client_name,
        :redirect_uris,
        :grant_types,
        :response_types,
        :token_endpoint_auth_method,
        :scope
      ]
    end

    # Replaces the library's action, which removes only stale CIMD clients:
    # registration is open, so also remove registered clients that no
    # operator approved within a day.
    destroy :expunge_expired do
      change filter(
               expr(
                 (not is_nil(cimd_url) and not is_nil(last_used_at) and
                    last_used_at < ago(30, :day)) or
                   (is_nil(cimd_url) and inserted_at < ago(1, :day) and not exists(consents, true))
               )
             )
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    # Anyone can register a client, so its metadata is bounded.
    attribute :client_name, :string do
      allow_nil? false
      public? true
      constraints max_length: 200
    end

    attribute :redirect_uris, {:array, :string} do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 10, items: [max_length: 2048]
    end

    attribute :grant_types, {:array, :string} do
      public? true
    end

    attribute :response_types, {:array, :string} do
      public? true
    end

    attribute :token_endpoint_auth_method, :string do
      public? true
    end

    attribute :scope, :string do
      public? true
    end

    attribute :cimd_url, :string do
      public? true
    end

    attribute :last_used_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :consents, AnonimizedMcp.Accounts.OauthConsent do
      destination_attribute :client_id
    end
  end

  identities do
    identity :by_cimd_url, [:cimd_url]
  end
end
