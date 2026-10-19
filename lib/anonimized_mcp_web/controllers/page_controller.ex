defmodule AnonimizedMcpWeb.PageController do
  use AnonimizedMcpWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
