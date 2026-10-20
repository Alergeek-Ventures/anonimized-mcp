defmodule AnonimizedMcp.SeedsTest do
  use AnonimizedMcp.DataCase, async: false

  @seeds "priv/repo/seeds.exs"

  setup do
    password = System.get_env("OPERATOR_PASSWORD")
    System.delete_env("OPERATOR_PASSWORD")

    on_exit(fn ->
      Mix.env(:test)
      if password, do: System.put_env("OPERATOR_PASSWORD", password)
    end)
  end

  test "refuses the public default password outside dev and test" do
    Mix.env(:prod)
    assert_raise Mix.Error, ~r/OPERATOR_PASSWORD/, fn -> Code.eval_file(@seeds) end
    assert Ash.read!(AnonimizedMcp.Accounts.User, authorize?: false) == []
  end

  test "seeds an operator with an explicit password anywhere" do
    Mix.env(:prod)
    System.put_env("OPERATOR_PASSWORD", "a-long-random-password")
    ExUnit.CaptureIO.capture_io(fn -> Code.eval_file(@seeds) end)
    assert [_operator] = Ash.read!(AnonimizedMcp.Accounts.User, authorize?: false)
  end
end
