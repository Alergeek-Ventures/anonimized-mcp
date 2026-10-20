defmodule AnonimizedMcp.Gateway.ReportLeakTest do
  use AnonimizedMcp.DataCase, async: false

  alias AnonimizedMcp.Gateway
  alias AnonimizedMcp.Gateway.Results

  setup do
    sources = Application.get_env(:anonimized_mcp, :sources, %{})

    Application.put_env(:anonimized_mcp, :sources, %{
      "leaky" => [url: "postgres://localhost/leaky"]
    })

    on_exit(fn -> Application.put_env(:anonimized_mcp, :sources, sources) end)

    id =
      Results.put(%{
        source: "leaky",
        columns: ~w(note github id inserted_at attempts owner),
        rows: [
          [
            "Rozmawiałem z Tomkiem Nowakiem",
            "https://github.com/someone",
            "1b4e28ba-2fa1-11d2-883f-0016d3cca427",
            ~U[2026-10-18 09:12:44Z],
            3,
            "NAME_k3j7x2ab"
          ]
        ]
      })

    %{id: id}
  end

  defp report(id, column, row \\ 0), do: Gateway.report_leak("leaky", id, row, column, nil, nil)

  test "stores cells that can hold personal data", %{id: id} do
    assert {:ok, %{reported: true}} = report(id, "note")
    assert {:ok, %{reported: true}} = report(id, "github")
  end

  test "refuses ids, timestamps, numbers and cells that are already masked", %{id: id} do
    assert {:error, "That cell is a record id" <> _} = report(id, "id")
    assert {:error, "That cell is a date or timestamp" <> _} = report(id, "inserted_at")
    assert {:error, "That cell is a number" <> _} = report(id, "attempts")
    assert {:error, "Everything in that cell is already masked" <> _} = report(id, "owner")
  end

  test "points at recent results when the query id is wrong", %{id: id} do
    assert {:error, message} = report("q999999999", "note")
    assert message =~ "Most recent results, newest last: #{id} (note, github, id"
    assert {:error, "Query ids look like q123." <> _} = report("12", "note")
    assert {:error, "Row 4 is not in that result."} = report(id, "note", 4)
  end
end
