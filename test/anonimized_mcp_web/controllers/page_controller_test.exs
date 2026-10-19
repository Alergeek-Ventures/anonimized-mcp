defmodule AnonimizedMcpWeb.PageControllerTest do
  use AnonimizedMcpWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ ~s(id="mcp-url")
  end
end
