defmodule AnonimizedMcp.Accounts.GoogleSignInTest do
  use AnonimizedMcp.DataCase, async: false

  alias AnonimizedMcp.Accounts.User

  defp register(user_info) do
    User
    |> Ash.Changeset.for_create(
      :register_with_google,
      %{
        user_info: Map.merge(%{"sub" => "1234567890", "email_verified" => true}, user_info),
        oauth_tokens: %{"access_token" => "synthetic-token"}
      },
      context: %{private: %{ash_authentication?: true}}
    )
    |> Ash.create()
  end

  test "signs in a verified Workspace account" do
    assert {:ok, user} =
             register(%{"email" => "ada@alergeek.ventures", "hd" => "alergeek.ventures"})

    assert to_string(user.email) == "ada@alergeek.ventures"
  end

  test "refuses accounts outside the Workspace" do
    assert {:error, %Ash.Error.Invalid{errors: [%{message: "is not a verified " <> _}]}} =
             register(%{"email" => "ada@gmail.com"})

    assert {:error, %Ash.Error.Invalid{errors: [%{message: "is not a verified " <> _}]}} =
             register(%{"email" => "ada@example.com", "hd" => "example.com"})
  end

  test "refuses a domain address without the Workspace claim" do
    assert {:error, %Ash.Error.Invalid{errors: [%{message: "is not a verified " <> _}]}} =
             register(%{"email" => "ada@alergeek.ventures"})
  end

  test "refuses an unverified email" do
    assert {:error, %Ash.Error.Invalid{errors: [%{message: "is not a verified " <> _}]}} =
             register(%{
               "email" => "ada@alergeek.ventures",
               "hd" => "alergeek.ventures",
               "email_verified" => false
             })
  end

  test "admits the configured Workspace" do
    Application.put_env(:anonimized_mcp, :google_domain, "example.com")
    on_exit(fn -> Application.put_env(:anonimized_mcp, :google_domain, "alergeek.ventures") end)

    assert {:ok, _} = register(%{"email" => "ada@example.com", "hd" => "example.com"})

    assert {:error, %Ash.Error.Invalid{}} =
             register(%{"email" => "ada@alergeek.ventures", "hd" => "alergeek.ventures"})
  end
end
