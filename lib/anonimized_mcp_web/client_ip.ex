defmodule AnonimizedMcpWeb.ClientIp do
  @moduledoc """
  Sets `conn.remote_ip` to the client's address, which rate limits and the
  sign-in audit log key on.

  A connection from a public address is the client itself and is kept as it
  is, so a client reaching the app directly cannot choose its IP with a
  header. A connection from a loopback or private address comes from a
  reverse proxy such as Caddy on Coolify; then the client is the rightmost
  public address in `X-Forwarded-For`, which the proxy appends.
  """

  @behaviour Plug

  @proxies ~w(127.0.0.0/8 ::1/128 fc00::/7 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16)
           |> Enum.map(&RemoteIp.Block.parse!/1)

  @impl true
  def init(_opts), do: RemoteIp.init(headers: ~w(x-forwarded-for))

  @impl true
  def call(conn, opts) do
    ip = RemoteIp.Block.encode(conn.remote_ip)

    if Enum.any?(@proxies, &RemoteIp.Block.contains?(&1, ip)),
      do: RemoteIp.call(conn, opts),
      else: conn
  end
end
