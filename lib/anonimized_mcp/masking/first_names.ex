defmodule AnonimizedMcp.Masking.FirstNames do
  @moduledoc """
  Finds the first names the model misses: capitalised names and their
  declined or diminutive forms in prose ("z Tomkiem"), and lower-case names
  glued into file names and branch slugs (`invoice_<name>_<surname>.pdf`,
  `<name>/abc-12-fix`). In a file name the word joined right after a first
  name is taken for the surname.

  The names are the first names of living people in the PESEL registry borne
  by at least 100 people
  ([dane.gov.pl, dataset 1667](https://dane.gov.pl/pl/dataset/1667), CC0,
  as of 2026-01-20), plus common diminutives below that count. Lower-case
  words only count where they are glued with `_`, `-`, `/`, `.` or `\\`,
  make up the whole value or are declined after a preposition, so prose such
  as "różnych marek" stays readable; upper-case ones need four letters.
  """

  @external_resource path = Path.expand("../../../priv/masking/first_names.txt", __DIR__)
  @names path |> File.read!() |> String.split("\n", trim: true) |> MapSet.new()

  # Registry names that are mostly something else: months, places, common
  # words, and words in identifiers and products (mark_sync_failed, Ruby).
  @not_names ~w(may jun jan june july august january can per mark max bar van guy rose urban
                marine frank tea angel prince ram dean grace joy ran vital eve ion robin amber
                ruby mate hung sol nato mai leu wit ala daisy jason ada aurora aria alexa
                mercedes kai chen yang chanel pola lada rada noga inna ani sami rana mina lew
                luna nadzieja róża wiara jagoda kalina lilia gaja ucha miła dana rosa nick zara
                said german christian muslim islam jesus francisco diego virginia carolina
                georgia india asia israel austin orlando florence milan victoria salvador
                jordan lucia blanca roma)

  @months ~w(styczen styczeń luty marzec kwiecien kwiecień maj czerwiec lipiec sierpien
             sierpień wrzesien wrzesień pazdziernik październik listopad grudzien grudzień
             stycznia lutego marca kwietnia maja czerwca lipca sierpnia września
             wrzesnia października pazdziernika listopada grudnia
             february march april september october november december)

  @masculine ~w(owie owi ami ach iem em ów om ie a u y i)
  @feminine ~w(ii ię ią ie y i ę ą o u)
  @softened [
    {"dzie", ["d", "da"]},
    {"cie", ["t", "ta"]},
    {"rze", ["r", "ra"]},
    {"dze", ["ga"]},
    {"ce", ["ka"]},
    {"le", ["ł", "ła"]}
  ]

  @word ~r/(?<![\p{L}\p{N}])\p{L}{3,}(?![\p{L}\p{N}])/u
  @glue ["_", "-", "/", ".", "\\"]
  @file_name ~r/^[^\s\/]+\.[A-Za-z0-9]{2,4}$/
  @preposition ~r/(?:^|[^\p{L}])(?:z|ze|dla|od|do|u|o|przez|przy|za)\s+$/iu

  @type span :: {start :: non_neg_integer(), length :: pos_integer(), String.t()}

  @doc "Returns the spans of first names and surnames next to them in `text`."
  @spec spans(String.t()) :: [span()]
  def spans(text) do
    words =
      for [{start, len}] <- Regex.scan(@word, text, return: :index),
          do: {start, len, binary_part(text, start, len)}

    words
    |> Enum.zip(Enum.drop(words, 1) ++ [nil])
    |> Enum.flat_map(fn {{start, len, word}, next} ->
      if first_name?(text, start, len, word),
        do: [{start, len, "NAME"} | surname(text, start + len, word, next)],
        else: []
    end)
    |> Enum.uniq()
  end

  defp first_name?(text, start, len, word) do
    lower = String.downcase(word)

    name?(lower) and
      cond do
        lower == word ->
          glued?(text, start, len) or (start == 0 and len == byte_size(text)) or
            (declined?(word) and after_preposition?(text, start))

        String.upcase(word) == word ->
          String.length(word) >= 4

        true ->
          String.capitalize(word) == word
      end
  end

  defp name?(word),
    do:
      word not in @not_names and word not in @months and
        Enum.any?(bases(word), &(&1 not in @not_names and &1 in @names))

  # The nominative forms `word` can be declined from: Tomkiem -> tomek,
  # Piotrze -> piotr, Julii -> julia, Kasię -> kasia, Marcie -> marta.
  defp bases(word) do
    masculine =
      for suffix <- @masculine,
          stem = strip(word, suffix),
          stem,
          b <- [stem, fleeting(stem)],
          do: b

    feminine = for suffix <- @feminine, stem = strip(word, suffix), stem, do: stem <> "a"

    softened =
      for {suffix, endings} <- @softened,
          stem = strip(word, suffix),
          stem,
          e <- endings,
          b <- [stem <> e, fleeting(stem) <> e],
          do: b

    # Soft feminine stems keep their i: Kasi, Kasię -> kasia.
    soft = if String.ends_with?(word, "i"), do: [word <> "a"], else: []

    [word | soft ++ masculine ++ feminine ++ softened]
  end

  defp strip(word, suffix) do
    if String.ends_with?(word, suffix) and String.length(word) - String.length(suffix) >= 2,
      do: String.slice(word, 0, String.length(word) - String.length(suffix))
  end

  # The vowel that drops in declension: tomk -> tomek, pawł -> paweł.
  defp fleeting(stem), do: String.slice(stem, 0..-2//1) <> "e" <> String.last(stem)

  # Lower-case prose: a declined name after a preposition ("z tomkiem",
  # "dla kasi"). The nominative stays readable, as it is more often a word.
  defp declined?(word), do: word not in @names

  defp after_preposition?(text, start),
    do: Regex.match?(@preposition, binary_part(text, 0, start))

  defp glued?(text, start, len),
    do: byte_at(text, start - 1) in @glue or byte_at(text, start + len) in @glue

  defp byte_at(text, at) when at >= 0 and at < byte_size(text), do: binary_part(text, at, 1)
  defp byte_at(_text, _at), do: nil

  defp surname(text, stop, word, {next_start, next_len, next})
       when next_start == stop + 1 and next_len >= 4 do
    if String.downcase(word) == word and String.downcase(next) == next and
         Regex.match?(@file_name, text) and binary_part(text, stop, 1) in ["_", "-"] and
         next not in @months and
         next not in @not_names,
       do: [{next_start, next_len, "NAME"}],
       else: []
  end

  defp surname(_text, _stop, _word, _next), do: []
end
