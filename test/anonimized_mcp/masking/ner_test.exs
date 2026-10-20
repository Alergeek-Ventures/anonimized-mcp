defmodule AnonimizedMcp.Masking.NerTest do
  use ExUnit.Case, async: true

  alias AnonimizedMcp.Masking

  test "masks plates the model calls document references and keeps invoice numbers" do
    assert [[{7, 8, "ID"}]] = Masking.spans(["Pojazd WA 12345"])
    assert [[{8, 8, "ID"}]] = Masking.spans(["nr rej. KR 7XY12"])
    assert [[{0, 8, "ID"}]] = Masking.spans(["KR 7XY12"])
    assert [[]] = Masking.spans(["FV/2024/03/117"])
    assert [[]] = Masking.spans(["ORD1234"])
  end
end
