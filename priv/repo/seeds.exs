# Creates an operator account for local development.
#
#     mix run priv/repo/seeds.exs

email = System.get_env("OPERATOR_EMAIL", "dev@alergeek.ventures")
password = System.get_env("OPERATOR_PASSWORD", "dev-password-123")

Ash.Seed.seed!(AnonimizedMcp.Accounts.User, %{
  email: email,
  hashed_password: Bcrypt.hash_pwd_salt(password)
})

IO.puts("Operator #{email} created")
