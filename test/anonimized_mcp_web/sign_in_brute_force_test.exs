defmodule AnonimizedMcpWeb.SignInBruteForceTest do
  use AnonimizedMcpWeb.ConnCase, async: false

  alias AnonimizedMcp.Accounts.{AuditLog, User}

  @email "operator@example.com"
  @password "correct-horse-battery"

  setup do
    Ash.Seed.seed!(User, %{email: @email, hashed_password: Bcrypt.hash_pwd_salt(@password)})
    :ok
  end

  defp sign_in(password) do
    build_conn()
    |> Map.put(:remote_ip, {203, 0, 113, 7})
    |> post("/auth/user/password/sign_in", %{user: %{email: @email, password: password}})
    |> redirected_to()
  end

  test "refuses the correct password after repeated failures" do
    for _ <- 1..6, do: assert(sign_in("wrong-password") == "/sign-in")
    assert sign_in(@password) == "/sign-in"
  end

  test "accepts the correct password after a few failures" do
    for _ <- 1..4, do: assert(sign_in("wrong-password") == "/sign-in")
    assert sign_in(@password) == "/"
  end

  test "logs attempts without passwords or full addresses" do
    sign_in("wrong-password")
    sign_in(@password)

    entries = Ash.read!(AuditLog, authorize?: false)
    assert entries |> Enum.map(& &1.status) |> Enum.sort() == [:failure, :success]
    assert Enum.all?(entries, &(&1.identity == @email and &1.client_ip == "203.0.113.0/24"))

    stored = inspect(Enum.map(entries, & &1.extra_data))
    refute stored =~ "wrong-password"
    refute stored =~ @password
    refute stored =~ "203.0.113.7"
    # JWTs start with the encoded `{"`
    refute stored =~ "eyJ"
  end
end
