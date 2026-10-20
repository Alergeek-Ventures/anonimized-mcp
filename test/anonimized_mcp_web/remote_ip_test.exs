defmodule AnonimizedMcpWeb.RemoteIpTest do
  use AnonimizedMcpWeb.ConnCase, async: true

  defp remote_ip(conn), do: AnonimizedMcpWeb.Endpoint.call(conn, []).remote_ip

  test "takes the client address the proxy appended to X-Forwarded-For", %{conn: conn} do
    conn = %{conn | remote_ip: {172, 18, 0, 2}}

    assert {203, 0, 113, 7} =
             conn
             |> put_req_header("x-forwarded-for", "198.51.100.1, 203.0.113.7")
             |> remote_ip()

    assert {172, 18, 0, 2} = remote_ip(conn)
  end
end
