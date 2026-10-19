defmodule AnonimizedMcp.Debugging do
  @moduledoc """
  The MCP tools agents use to debug applications through their databases.
  """

  use Ash.Domain, otp_app: :anonimized_mcp, extensions: [AshAi]

  tools do
    tool :list_sources, AnonimizedMcp.Debugging.Database, :list_sources
    tool :describe_schema, AnonimizedMcp.Debugging.Database, :describe_schema
    tool :query, AnonimizedMcp.Debugging.Database, :query
    tool :check_value, AnonimizedMcp.Debugging.Database, :check_value
    tool :report_leak, AnonimizedMcp.Debugging.Database, :report_leak
  end

  resources do
    resource AnonimizedMcp.Debugging.Database
    resource AnonimizedMcp.Debugging.LeakReport
  end
end
