defmodule AnonimizedMcp.Accounts.WorkspaceAccount do
  @moduledoc """
  Admits a Google account only if it belongs to the `:domain` Workspace and
  Google has verified its email. The `hd` claim names the Workspace; the
  `hd` authorization parameter only narrows the account picker.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, opts, _context) do
    domain = Keyword.fetch!(opts, :domain)
    user_info = Ash.Changeset.get_argument(changeset, :user_info) || %{}

    if user_info["hd"] == domain and user_info["email_verified"] == true and
         String.ends_with?(String.downcase(user_info["email"] || ""), "@" <> domain),
       do: :ok,
       else: {:error, field: :email, message: "is not a verified #{domain} account"}
  end
end
