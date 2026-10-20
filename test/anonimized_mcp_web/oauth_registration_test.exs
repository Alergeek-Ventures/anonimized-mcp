defmodule AnonimizedMcpWeb.OauthRegistrationTest do
  use AnonimizedMcpWeb.ConnCase, async: false

  alias AnonimizedMcp.Accounts.{OauthClient, OauthConsent}
  alias AshAuthentication.Oauth2Server.ClientResource

  @ash_context %{private: %{ash_authentication?: true}}

  defp register(conn, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/oauth/register", Jason.encode!(params))
  end

  defp clients, do: Ash.read!(OauthClient, context: @ash_context)

  test "registers a client with ordinary metadata", %{conn: conn} do
    conn = register(conn, %{client_name: "Codex", redirect_uris: ["http://127.0.0.1:1455/cb"]})
    assert %{"client_id" => _} = json_response(conn, 201)
  end

  test "refuses oversized metadata without storing it", %{conn: conn} do
    long_name = %{
      client_name: String.duplicate("a", 201),
      redirect_uris: ["https://a.example/cb"]
    }

    assert json_response(register(conn, long_name), 400)

    many_uris = %{client_name: "x", redirect_uris: for(i <- 1..11, do: "https://a.example/#{i}")}
    assert json_response(register(build_conn(), many_uris), 400)

    long_uri = %{
      client_name: "x",
      redirect_uris: ["https://a.example/" <> String.duplicate("a", 2048)]
    }

    assert json_response(register(build_conn(), long_uri), 400)

    assert clients() == []
  end

  test "caps the body of OAuth requests", %{conn: conn} do
    body = %{
      client_name: "x",
      redirect_uris: ["https://a.example/cb"],
      pad: String.duplicate("a", 70_000)
    }

    assert_error_sent 413, fn -> register(conn, body) end
  end

  test "expunges registered clients nobody approved within a day" do
    old = DateTime.add(DateTime.utc_now(), -2, :day)

    [unapproved, approved, fresh] =
      for name <- ~w(unapproved approved fresh) do
        OauthClient
        |> Ash.Changeset.for_create(:register, %{
          client_name: name,
          redirect_uris: ["https://a.example/cb"]
        })
        |> Ash.create!(context: @ash_context)
      end

    OauthConsent
    |> Ash.Changeset.for_create(:grant, %{
      user_id: Ash.UUID.generate(),
      client_id: approved.id,
      scope: "mcp"
    })
    |> Ash.create!(context: @ash_context)

    for client <- [unapproved, approved] do
      Ecto.Adapters.SQL.query!(
        AnonimizedMcp.Repo,
        "UPDATE oauth_clients SET inserted_at = $1 WHERE id = $2",
        [old, Ecto.UUID.dump!(client.id)]
      )
    end

    assert :ok = ClientResource.expunge_expired(OauthClient)
    assert clients() |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([approved.id, fresh.id])
  end
end
