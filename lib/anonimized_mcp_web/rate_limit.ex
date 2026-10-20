defmodule AnonimizedMcpWeb.RateLimit do
  # Counters live in ETS, so limits apply per node.
  use Hammer, backend: :ets
end
