# Creates an operator account for local development.
#
#     mix run priv/repo/seeds.exs
#
# The default password is public (README), so anywhere but dev and test the
# password must come from OPERATOR_PASSWORD.

email = System.get_env("OPERATOR_EMAIL", "dev@alergeek.ventures")

password =
  case {System.get_env("OPERATOR_PASSWORD"), Mix.env()} do
    {nil, env} when env in [:dev, :test] ->
      "dev-password-123"

    {nil, env} ->
      Mix.raise("Set OPERATOR_PASSWORD to seed an operator in #{env}; the default is public.")

    {password, _env} ->
      password
  end

Ash.Seed.seed!(AnonimizedMcp.Accounts.User, %{
  email: email,
  hashed_password: Bcrypt.hash_pwd_salt(password)
})

IO.puts("Operator #{email} created")
