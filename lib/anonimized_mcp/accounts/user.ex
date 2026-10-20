defmodule AnonimizedMcp.Accounts.User do
  use Ash.Resource,
    otp_app: :anonimized_mcp,
    domain: AnonimizedMcp.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  # Staff sign in with their Google Workspace account (`:google_domain`).
  # Passwords exist only in dev and test, where there is no Google client.
  @password? Application.compile_env(:anonimized_mcp, :password_sign_in?, false)

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end

      # Records sign-in attempts; the password strategy counts its failures.
      # Sensitive arguments (password, tokens) are left out by the add-on.
      audit_log do
        audit_log_resource AnonimizedMcp.Accounts.AuditLog
        include_strategies if(@password?, do: [:password], else: []) ++ [:remember_me, :google]
        ip_privacy_mode :truncate
      end
    end

    tokens do
      enabled? true
      token_resource AnonimizedMcp.Accounts.Token
      signing_secret AnonimizedMcp.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      if @password? do
        password :password do
          identity_field :email
          hash_provider AshAuthentication.BcryptProvider
          # Operators are created with priv/repo/seeds.exs, not by self-registration.
          registration_enabled? false
          # Refuse sign-in for an email after 5 failures within 5 minutes.
          brute_force_strategy {:audit_log, :audit_log}
          audit_log_window 5
          audit_log_max_failures 5
        end
      end

      remember_me :remember_me

      google :google do
        client_id AnonimizedMcp.Secrets
        client_secret AnonimizedMcp.Secrets
        redirect_uri AnonimizedMcp.Secrets
        identity_resource AnonimizedMcp.Accounts.UserIdentity
        # Asks for the email and narrows the account picker to the Workspace;
        # WorkspaceAccount enforces the domain.
        authorization_params AnonimizedMcp.Secrets
      end
    end
  end

  postgres do
    table "users"
    repo AnonimizedMcp.Repo
  end

  actions do
    defaults [:read]

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    if @password? do
      read :sign_in_with_password do
        description "Attempt to sign in using a email and password."
        get? true

        argument :email, :ci_string do
          description "The email to use for retrieving the user."
          allow_nil? false
        end

        argument :password, :string do
          description "The password to check for the matching user."
          allow_nil? false
          sensitive? true
        end

        argument :remember_me, :boolean do
          description "Whether to generate a remember me token"
          allow_nil? true
        end

        # refuses the attempt when the audit log has too many recent failures
        prepare {AshAuthentication.AddOn.AuditLog.IdentityBruteForcePreparation,
                 action_name: :sign_in_with_password}

        # validates the provided email and password and generates a token
        prepare AshAuthentication.Strategy.Password.SignInPreparation

        # generates a remember me token if the remember_me argument is true
        prepare {AshAuthentication.Strategy.RememberMe.MaybeGenerateTokenPreparation,
                 strategy_name: :remember_me}

        metadata :token, :string do
          description "A JWT that can be used to authenticate the user."
          allow_nil? false
        end
      end

      read :sign_in_with_token do
        # In the generated sign in components, we validate the
        # email and password directly in the LiveView
        # and generate a short-lived token that can be used to sign in over
        # a standard controller action, exchanging it for a standard token.
        # This action performs that exchange. If you do not use the generated
        # liveviews, you may remove this action, and set
        # `sign_in_tokens_enabled? false` in the password strategy.

        description "Attempt to sign in using a short-lived sign in token."
        get? true

        argument :token, :string do
          description "The short-lived sign in token."
          allow_nil? false
          sensitive? true
        end

        # validates the provided sign in token and generates a token
        prepare AshAuthentication.Strategy.Password.SignInWithTokenPreparation

        metadata :token, :string do
          description "A JWT that can be used to authenticate the user."
          allow_nil? false
        end
      end
    end

    create :register_with_google do
      argument :user_info, :map, allow_nil?: false
      argument :oauth_tokens, :map, allow_nil?: false, sensitive?: true
      upsert? true
      upsert_identity :unique_email

      validate AnonimizedMcp.Accounts.WorkspaceAccount
      change AshAuthentication.GenerateTokenChange
      change AshAuthentication.Strategy.OAuth2.IdentityChange

      change {AshAuthentication.Strategy.OAuth2.UserInfoToAttributes, fields: [:email]}
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :hashed_password, :string do
      sensitive? true
    end
  end

  identities do
    identity :unique_email, [:email]
  end
end
