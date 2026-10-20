# Creates an operator account for local development.
#
#     mix run priv/repo/seeds.exs
#
# Its password is public (README) and passwords exist only in dev and test;
# production signs in with Google.

if Mix.env() not in [:dev, :test] do
  Mix.raise("Seeds are for dev and test; #{Mix.env()} signs in with Google.")
end

email = "dev@alergeek.ventures"

Ash.Seed.seed!(AnonimizedMcp.Accounts.User, %{
  email: email,
  hashed_password: Bcrypt.hash_pwd_salt("dev-password-123")
})

IO.puts("Operator #{email} created")
