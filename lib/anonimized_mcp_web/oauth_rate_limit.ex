defmodule AnonimizedMcpWeb.OauthRateLimit do
  @moduledoc """
  Limits OAuth protocol requests per client IP. Client registration is
  unauthenticated and stores a row, so it gets a much lower limit than the
  token, revocation and discovery endpoints.

  The key is `conn.remote_ip`. Behind a reverse proxy every request carries the
  proxy's address, so the client IP must first be set from a header written by
  a trusted proxy, for example with a RemoteIp plug in the endpoint.
  """

  @behaviour Plug

  import Plug.Conn

  alias AnonimizedMcpWeb.RateLimit

  # {requests, window in ms}; override per bucket in config.
  @defaults [register: {10, :timer.hours(1)}, other: {60, :timer.minutes(1)}]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    bucket = bucket(conn.path_info)
    {limit, scale} = limit(bucket)
    key = "oauth:#{bucket}:#{:inet.ntoa(conn.remote_ip)}"

    case RateLimit.hit(key, scale, limit) do
      {:allow, _count} -> conn
      {:deny, retry_after} -> deny(conn, retry_after)
    end
  end

  defp bucket(["oauth", "register" | _]), do: :register
  defp bucket(_path_info), do: :other

  defp limit(bucket) do
    :anonimized_mcp
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(bucket, @defaults[bucket])
  end

  defp deny(conn, retry_after) do
    body = %{error: "too_many_requests", error_description: "Too many requests, retry later."}

    conn
    |> put_resp_header("retry-after", Integer.to_string(div(retry_after, 1000) + 1))
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(429, Jason.encode!(body))
    |> halt()
  end
end
