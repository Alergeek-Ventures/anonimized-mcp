# Runs the gateway's own detection (patterns + bardsai in Elixir) over a
# benchmark corpus and writes predictions that score.py reads as `gateway`.
#
#     mix run bench/gateway.exs corpus.jsonl

alias AnonimizedMcp.Masking

corpus = List.first(System.argv(), "corpus.jsonl")
data = Path.join(__DIR__, "data")
out = Path.join([data, "pred", "gateway--#{Path.rootname(corpus)}.jsonl"])
cells = data |> Path.join(corpus) |> File.stream!() |> Enum.map(&Jason.decode!/1)

# score.py works in characters, the gateway in bytes.
chars = fn text, byte -> text |> binary_part(0, byte) |> String.length() end

lines =
  Enum.map(cells, fn %{"id" => id, "text" => text} ->
    {micros, [spans]} = :timer.tc(fn -> Masking.spans([text]) end)

    spans =
      for {start, len, type} <- spans,
          do: [chars.(text, start), chars.(text, start + len), to_string(type)]

    Jason.encode!(%{id: id, spans: spans, ms: micros / 1000})
  end)

File.mkdir_p!(Path.dirname(out))
File.write!(out, Enum.join(lines, "\n") <> "\n")
File.write!(Path.rootname(out) <> ".meta.json", Jason.encode!(%{model: "gateway", corpus: corpus, cells: length(cells)}))
IO.puts(out)
