defmodule AnonimizedMcpWeb.LiveUserAuth do
  @moduledoc """
  Keeps signed-in operators away from the sign-in page.
  """

  import Phoenix.Component
  use AnonimizedMcpWeb, :verified_routes

  def on_mount(:live_no_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end
end
