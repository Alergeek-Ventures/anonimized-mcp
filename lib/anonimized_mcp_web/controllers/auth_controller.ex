defmodule AnonimizedMcpWeb.AuthController do
  use AnonimizedMcpWeb, :controller
  use AshAuthentication.Phoenix.Controller

  def success(conn, _activity, user, _token) do
    return_to = get_session(conn, :return_to) || ~p"/"

    conn
    |> delete_session(:return_to)
    |> store_in_session(user)
    |> assign(:current_user, user)
    |> put_flash(:info, "You are now signed in")
    |> redirect(to: return_to)
  end

  def failure(conn, activity, _reason) do
    message =
      case activity do
        {:google, _phase} -> "Sign in with an alergeek.ventures Google account"
        _password -> "Incorrect email or password"
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end

  def sign_out(conn, _params) do
    return_to = get_session(conn, :return_to) || ~p"/"

    conn
    |> clear_session(:anonimized_mcp)
    |> put_flash(:info, "You are now signed out")
    |> redirect(to: return_to)
  end
end
