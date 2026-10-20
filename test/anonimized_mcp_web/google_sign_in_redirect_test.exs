defmodule AnonimizedMcpWeb.GoogleSignInRedirectTest do
  use AnonimizedMcpWeb.ConnCase, async: false

  setup do
    Application.put_env(:anonimized_mcp, :google_client_id, "synthetic-client")
    Application.put_env(:anonimized_mcp, :google_client_secret, "synthetic-secret")

    on_exit(fn ->
      Application.delete_env(:anonimized_mcp, :google_client_id)
      Application.delete_env(:anonimized_mcp, :google_client_secret)
    end)
  end

  test "asks Google for the email of a Workspace account" do
    location = build_conn() |> get("/auth/user/google") |> redirected_to()
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert "email" in String.split(query["scope"])
    assert query["hd"] == "alergeek.ventures"
    assert query["redirect_uri"] =~ ~r{/auth/user/google/callback$}
  end
end
