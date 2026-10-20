defmodule AnonimizedMcpWeb.OauthRateLimitTest do
  use AnonimizedMcpWeb.ConnCase, async: false

  # Limits are 5 per bucket in config/test.exs. Each test uses fresh addresses,
  # because the counters outlive a test.
  defp unique_ip do
    n = System.unique_integer([:positive])
    {0x2001, 0xDB8, 0, 0, 0, 0, div(n, 0x10000), rem(n, 0x10000)}
  end

  defp request(ip, path, params) do
    build_conn()
    |> Map.put(:remote_ip, ip)
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end

  defp register(ip), do: request(ip, "/oauth/register", %{client_name: "x"})
  defp token(ip), do: request(ip, "/oauth/token", %{grant_type: "authorization_code"})

  test "refuses registration past the limit for that address" do
    ip = unique_ip()
    for _ <- 1..5, do: assert(register(ip).status == 400)

    conn = register(ip)
    assert %{"error" => "too_many_requests"} = json_response(conn, 429)
    assert [_seconds] = get_resp_header(conn, "retry-after")

    assert register(unique_ip()).status == 400
  end

  test "counts token requests separately from registration" do
    ip = unique_ip()
    for _ <- 1..5, do: assert(token(ip).status in 400..401)

    assert %{"error" => "too_many_requests"} = json_response(token(ip), 429)
    assert register(ip).status == 400
  end
end
