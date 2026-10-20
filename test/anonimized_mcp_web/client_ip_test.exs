defmodule AnonimizedMcpWeb.ClientIpTest do
  use AnonimizedMcpWeb.ConnCase, async: true

  alias AnonimizedMcpWeb.ClientIp

  defp client_ip(conn, peer, forwarded \\ nil) do
    conn = %{conn | remote_ip: peer}
    conn = if forwarded, do: put_req_header(conn, "x-forwarded-for", forwarded), else: conn
    ClientIp.call(conn, ClientIp.init([])).remote_ip
  end

  test "behind a proxy, takes the client the proxy appended", %{conn: conn} do
    assert client_ip(conn, {172, 18, 0, 2}, "198.51.100.1, 203.0.113.7") == {203, 0, 113, 7}
    assert client_ip(conn, {172, 18, 0, 2}) == {172, 18, 0, 2}
  end

  test "a direct client cannot choose its address with a header", %{conn: conn} do
    assert client_ip(conn, {203, 0, 113, 7}, "198.51.100.1") == {203, 0, 113, 7}
  end
end
