defmodule AnonimizedMcp.SeedsTest do
  use AnonimizedMcp.DataCase, async: false

  @seeds "priv/repo/seeds.exs"

  setup do
    on_exit(fn -> Mix.env(:test) end)
  end

  test "seeds the public operator only in dev and test" do
    Mix.env(:prod)
    assert_raise Mix.Error, ~r/signs in with Google/, fn -> Code.eval_file(@seeds) end
    assert Ash.read!(AnonimizedMcp.Accounts.User, authorize?: false) == []
  end
end
