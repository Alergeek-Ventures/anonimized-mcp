defmodule AnonimizedMcp.MaskingTest do
  use ExUnit.Case, async: true

  alias AnonimizedMcp.Masking
  alias AnonimizedMcp.Masking.{Aliases, Composites, Lineage, Patterns}

  @text {Postgrex.Extensions.Raw, nil}
  @json {Postgrex.Extensions.JSONB, nil}
  @alias ~r/^[A-Z_]+_[a-z2-7]{8}$/

  defp mask(names, rows, types \\ nil),
    do: Masking.mask("test", names, types || Enum.map(names, fn _ -> @text end), rows)

  # Masks `rows` as the result of `sql` in a source of its own.
  defp mask_query(sql, columns, rows) do
    {:ok, %{stmts: [%{stmt: statement}]}} = PgQuery.parse(sql)
    source = "lineage-#{System.unique_integer([:positive])}"
    types = Enum.map(columns, fn _ -> @text end)
    lineage = Lineage.columns(statement, columns)
    Masking.mask(source, columns, types, rows, lineage: lineage)
  end

  test "aliases identifiers with a valid checksum and keeps technical values" do
    [[note]] =
      mask(["note"], [
        [
          "Invoice FV/12/10/2026 for NIP 5260250274, IBAN PL61109010140000071219812874, " <>
            "jan@example.com, record 1b4e28ba-2fa1-11d2-883f-0016d3cca427 at 2026-10-18T09:12:44Z, 1230.00 PLN"
        ]
      ])

    assert note =~ ~r/NIP TAX_ID_[a-z2-7]{8}, IBAN IBAN_[a-z2-7]{8}, EMAIL_[a-z2-7]{8}/
    assert note =~ "FV/12/10/2026"

    assert note =~
             "record 1b4e28ba-2fa1-11d2-883f-0016d3cca427 at 2026-10-18T09:12:44Z, 1230.00 PLN"
  end

  test "masks profile links and phone numbers" do
    for text <- [
          "https://github.com/someone",
          "https://www.linkedin.com/in/some-one-123/",
          "linkedin.com/in/someone",
          "https://example.slack.com/team/U01ABCDEF",
          "+48 600 12 34 56",
          "+1 (555) 123-4567",
          "+420 12 345 67 89",
          "+48600123456",
          "60 123-45-67",
          "(22) 123 45 67",
          "(22) 123-45-67"
        ] do
      assert [{0, len, type}] = Patterns.spans(text), text
      assert len == byte_size(String.trim_trailing(text, "/")) or len == byte_size(text), text
      assert type in ["PROFILE", "PHONE"], text
    end

    assert [] = Patterns.spans("https://github.com")
    assert [] = Patterns.spans("version 1.2.3 released 2026-10-19, order +5 items")
  end

  test "masks EU VAT numbers by country prefix and length" do
    for text <-
          ~w(SE559460010701 DE123456789 FR12345678901 NL123456789B01 ATU12345678 CHE-123.456.789) do
      assert [{0, len, "TAX_ID"}] = Patterns.spans(text), text
      assert len == byte_size(text), text
    end

    assert [] = Patterns.spans("DE12345 SE1234 version FR2")
  end

  test "digit patterns need a valid checksum" do
    assert [{0, 11, "PESEL"}] = Patterns.spans("44051401359")
    assert [] = Patterns.spans("44051401358")
  end

  test "finds names in free text and reuses their alias elsewhere" do
    [[name], [note]] =
      mask(["text"], [
        ["Jan Kowalski"],
        ["Kontakt: Jan Kowalski, tel. 600 123 456. Płaci po terminie."]
      ])

    assert name =~ ~r/^NAME_[a-z2-7]{8}$/
    assert note =~ ~r/^Kontakt: #{name}, tel\. PHONE_[a-z2-7]{8}\. Płaci po terminie\.$/
  end

  test "keeps currency and country codes readable, also as JSON keys" do
    codes = ~w(AED HUF RON MAD ZAR JOD XAU PL SA)

    assert [[^codes, rates]] =
             mask(["codes", "rates"], [[codes, Map.new(codes, &{&1, "1.5"})]], [@text, @json])

    assert Map.keys(rates) |> Enum.sort() == Enum.sort(codes)
  end

  test "finds names written in capitals only" do
    assert [[name]] = mask(["name"], [["JAN KOWALSKI"]])
    assert name =~ ~r/^NAME_[a-z2-7]{8}$/
  end

  test "keeps whitespace around a masked value visible" do
    assert [[masked]] = mask(["tax_id"], [["5260250274 "]])
    assert masked =~ ~r/^TAX_ID_[a-z2-7]{8} $/
  end

  test "withholds credentials by column name, JSON key and shape" do
    [[password, args, error]] =
      mask(
        ["hashed_password", "args", "error"],
        [
          [
            "$argon2id$v=19$m=65536,t=3,p=4$abc",
            %{"invoice_id" => 42, "encryption_key" => "abc", "nested" => %{"api_token" => "x"}},
            "auth failed for eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N"
          ]
        ],
        [@text, @json, @text]
      )

    assert password == "[secret]"

    assert args == %{
             "invoice_id" => 42,
             "encryption_key" => "[secret]",
             "nested" => %{"api_token" => "[secret]"}
           }

    assert error == "auth failed for [secret]"
  end

  test "returns composite values as lists" do
    assert [[["PLN", "123.45"]]] = mask(["amount"], [[{"PLN", Decimal.new("123.45")}]])
  end

  test "aliases dates in birth date columns" do
    assert [[birth, issued]] =
             mask(["birth_date", "issued_on"], [[~D[1980-05-17], ~D[2026-10-01]]])

    assert birth =~ ~r/^BIRTHDATE_[a-z2-7]{8}$/
    assert issued == ~D[2026-10-01]
  end

  test "masks arrays, JSON and composites in birth date columns without raising" do
    assert [[dates, info, record, text]] =
             mask(
               ["birth_dates", "birth_info", "birth_record", "birthday"],
               [
                 [
                   [~D[1987-03-14], nil, ~D[1990-01-02]],
                   %{"date" => "1980-05-17", "note" => nil},
                   {~D[1980-05-17], 3},
                   "17 maja 1980"
                 ]
               ]
             )

    assert [first, nil, second] = dates
    assert first =~ ~r/^BIRTHDATE_/ and second =~ ~r/^BIRTHDATE_/
    assert %{"date" => "BIRTHDATE_" <> _, "note" => nil} = info
    assert [<<"BIRTHDATE_", _::binary>>, <<"BIRTHDATE_", _::binary>>] = record
    assert text =~ ~r/^BIRTHDATE_/
  end

  test "keeps the credential and birth date rules through aggregates, expressions and aliases" do
    row = [1, ~D[1980-05-17], "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"]

    assert [[1, birth, "[secret]"]] =
             mask_query(
               "SELECT id, min(birth_date), coalesce(otp_secret, '') FROM customers GROUP BY id, otp_secret",
               ["id", "min", "coalesce"],
               [row]
             )

    assert birth =~ ~r/^BIRTHDATE_/

    assert [[1, birth, "[secret]"]] =
             mask_query(
               "SELECT id, birth_date AS dob, otp_secret AS mfa FROM customers",
               ["id", "dob", "mfa"],
               [row]
             )

    assert birth =~ ~r/^BIRTHDATE_/

    assert [["[secret]", "[secret]"]] =
             mask_query(
               "SELECT x, meta->>'otp_secret' FROM (SELECT otp_secret AS x, meta FROM customers) s",
               ["x", "?column?"],
               [["JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP", "JBSWY3DPEHPK3PXP"]]
             )

    assert [[birth, text]] =
             mask_query(
               "SELECT * FROM (SELECT min(birth_date), birth_date::text || ' r.' FROM customers) s",
               ["min", "?column?"],
               [[~D[1980-05-17], "1980-05-17 r."]]
             )

    assert birth =~ ~r/^BIRTHDATE_/
    assert text =~ ~r/^BIRTHDATE_[a-z2-7]{8} r\.$/
  end

  test "keeps counts, checks and unrelated columns of queries that read credentials" do
    assert [[2, false, "Faktura", ~D[2026-10-01]]] =
             mask_query(
               "SELECT count(otp_secret), otp_secret IS NULL AS missing, title, created_on " <>
                 "FROM customers WHERE birth_date > '1990-01-01' AND token <> '' GROUP BY 2, 3, 4",
               ["count", "missing", "title", "created_on"],
               [[2, false, "Faktura", ~D[2026-10-01]]]
             )

    assert [[~D[2026-10-01], "Faktura"]] =
             mask_query("SELECT * FROM invoices", ["created_on", "title"], [
               [~D[2026-10-01], "Faktura"]
             ])
  end

  test "treats columns it cannot trace as possibly credentials and birth dates" do
    assert [["[secret]", birth, 7]] =
             mask_query(
               "SELECT n, d, i FROM customers AS c(i, n, d)",
               ["n", "d", "i"],
               [["JBSWY3DPEHPK3PXP", ~D[1980-05-17], 7]]
             )

    assert birth =~ ~r/^BIRTHDATE_/

    assert [["[secret]"]] =
             mask_query("SELECT c::text FROM customers c", ["c"], [["(1,JBSWY3DPEHPK3PXP)"]])
  end

  test "applies column name rules to the fields of whole-row values" do
    config = Application.fetch_env!(:anonimized_mcp, AnonimizedMcp.Repo)

    conn =
      start_supervised!(
        {Postgrex, Keyword.take(config, [:hostname, :port, :username, :password, :database])}
      )

    Postgrex.transaction(conn, fn conn ->
      Postgrex.query!(
        conn,
        "CREATE TEMP TABLE customers (id uuid, name text, birth_date date, otp_secret text) ON COMMIT DROP",
        []
      )

      Postgrex.query!(
        conn,
        "INSERT INTO customers VALUES ('1b4e28ba-2fa1-11d2-883f-0016d3cca427', 'Jan Kowalski', " <>
          "'1980-05-17', 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP')",
        []
      )

      sql = "SELECT c, array_agg(c) AS cs FROM customers c GROUP BY c"
      {:ok, query, result} = Postgrex.prepare_execute(conn, "", sql, [])
      {:ok, %{stmts: [%{stmt: statement}]}} = PgQuery.parse(sql)

      assert [[row, [row]]] =
               Masking.mask("composites", query.columns, query.result_types, result.rows,
                 lineage: Lineage.columns(statement, query.columns),
                 fields: Composites.fields(conn, query.result_oids, query.result_types)
               )

      assert ["1b4e28ba-2fa1-11d2-883f-0016d3cca427", name, birth, "[secret]"] = row
      assert name =~ ~r/^NAME_/
      assert birth =~ ~r/^BIRTHDATE_/
    end)
  end

  test "finds surnames in capitals inside lower-case text" do
    source = "capitals"
    t = [@text]
    [[name]] = Masking.mask(source, ["name"], t, [["Anna Kozłowska"]])
    assert [[note]] = Masking.mask(source, ["note"], t, [["Odbiór osobisty: KOZŁOWSKA"]])
    assert note =~ ~r/^Odbiór osobisty: NAME_[a-z2-7]{8}$/
    assert name =~ @alias

    text = "duplicate account merged into WÓJCIK"
    assert [[note]] = Masking.mask("capitals-fresh", ["note"], t, [[text]])
    assert note =~ ~r/^duplicate account merged into NAME_[a-z2-7]{8}$/

    assert [[note]] = Masking.mask(source, ["note"], t, [["Invoice FV/12/2026, NIP 5260250274"]])
    assert note =~ ~r/^Invoice FV\/12\/2026, NIP TAX_ID_[a-z2-7]{8}$/
  end

  test "matches known names in any capitalisation that starts with a capital" do
    source = "known-case"
    alias = Aliases.alias_for(source, "NAME", "Maja Wiśniewska")
    text = "wysłane do WIŚNIEWSKIEJ 17 maja, kontakt: MAJA WIŚNIEWSKA"

    # Byte offsets: WIŚNIEWSKIEJ at 12, "maja" at 29, MAJA WIŚNIEWSKA at 44.
    spans = Masking.known_spans(source, text)
    assert {12, 13, "NAME"} in spans
    assert {44, 16, {:alias, alias}} in spans
    refute Enum.any?(spans, &match?({29, _, _}, &1))

    assert [[note]] = Masking.mask(source, ["note"], [@text], [[text]])
    assert note =~ ~r/^wysłane do [A-Z]+_[a-z2-7]{8} 17 maja, kontakt: [A-Z]+_[a-z2-7]{8}$/
  end

  test "detects personal data in inet, tsvector and numeric values" do
    source = "types"
    Aliases.alias_for(source, "NAME", "Jan Kowalski")

    assert [[ip, net, lexemes, pesel, amount, interval]] =
             Masking.mask(
               source,
               ~w(ip net search pesel amount wait),
               List.duplicate(@text, 6),
               [
                 [
                   %Postgrex.INET{address: {83, 12, 45, 67}, netmask: nil},
                   %Postgrex.INET{address: {8193, 3512, 0, 0, 0, 0, 0, 0}, netmask: 32},
                   [
                     %Postgrex.Lexeme{word: "jan.kowalski@example.com", positions: [{3, nil}]},
                     %Postgrex.Lexeme{word: "kowalski", positions: [{2, nil}]},
                     %Postgrex.Lexeme{word: "faktura", positions: [{1, nil}]}
                   ],
                   Decimal.new("44051401359"),
                   Decimal.new("1230.00"),
                   %Postgrex.Interval{days: 3}
                 ]
               ]
             )

    assert ip =~ ~r/^IP_[a-z2-7]{8}$/
    assert net == "2001:db8::/32"
    assert [email, name, "faktura"] = lexemes
    assert email =~ ~r/^EMAIL_/ and name =~ ~r/^NAME_/
    assert pesel =~ ~r/^PESEL_/
    assert amount == "1230.00"
    assert interval =~ "days: 3"
  end

  test "keeps masking working with thousands of known names" do
    source = "many-names"

    for n <- 1..10_000 do
      surname = n |> Integer.digits(26) |> Enum.map(&(?a + &1)) |> List.to_string()
      Aliases.alias_for(source, "NAME", "Ewa Zieliń" <> surname)
    end

    Aliases.alias_for(source, "NAME", "Ewa Brzęczyszczykiewicz")

    assert [[note]] =
             Masking.mask(source, ["note"], [@text], [["Rozmowa z Brzęczyszczykiewiczem, 3 dni"]])

    assert note =~ ~r/^Rozmowa z NAME_[a-z2-7]{8}, 3 dni$/
  end

  test "matches declined short surnames of known names" do
    source = "short-names"
    Aliases.alias_for(source, "NAME", "Ewa Kot")
    Aliases.alias_for(source, "NAME", "Adam Mak")
    t = [@text]

    for {text, masked} <- [
          {"Rozmawiałem z Kotem, obiecał zapłacić.",
           ~r/^Rozmawiałem z NAME_[a-z2-7]{8}, obiecał/},
          {"Przekazano sprawę Kotowi.", ~r/^Przekazano sprawę NAME_[a-z2-7]{8}\.$/},
          {"Spotkanie u Makiem i u Kocie", ~r/u NAME_[a-z2-7]{8} i u NAME_[a-z2-7]{8}$/}
        ] do
      assert [[note]] = Masking.mask(source, ["note"], t, [[text]])
      assert note =~ masked, text
    end

    for text <- ["Mój kot śpi, kotek też.", "Kotlet z makiem"] do
      assert [[^text]] = Masking.mask(source, ["note"], t, [[text]])
    end
  end

  test "masks first names in file names, slugs and declined prose" do
    alias AnonimizedMcp.Masking.FirstNames

    for {text, names} <- [
          {"invoice_march_acme_marta_zielinska.pdf", ["marta", "zielinska"]},
          {"2024-07-tomek-fv.pdf", ["tomek"]},
          {"kamil/abc-12-fix-login", ["kamil"]},
          {"rozmowa z tomkiem o planie", ["tomkiem"]},
          {"Spotkanie z Kasią i Piotrem", ["Kasią", "Piotrem"]}
        ] do
      found = for {s, l, "NAME"} <- FirstNames.spans(text), do: binary_part(text, s, l)
      assert found == names, text
    end

    for text <- [
          "mark_sync_failed",
          "max_attempts reached",
          "Kawa różnych marek",
          "od 3 do 5 maja",
          "fix all-data sync_all_transactions",
          "0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d"
        ] do
      assert FirstNames.spans(text) == [], text
    end
  end

  test "aliases account numbers with a failed checksum in account columns" do
    for value <- ["12 3456 7890 1234 5678 9012 3456", "12-1234567-1234567890123456"] do
      assert [[account]] = mask(["seller_account_number"], [[value]])
      assert account =~ @alias, value
    end
  end

  test "aliases street lines in address columns and after a street prefix" do
    assert [[address]] = mask(["mail_address"], [["Kwiatowa 7/14\n00-001 Warszawa"]])
    refute address =~ "Kwiatowa"

    assert [{start, len, "ADDRESS"}] = Patterns.spans("dostawa na ul. Długa 12/3 jutro")
    assert binary_part("dostawa na ul. Długa 12/3 jutro", start, len) == "ul. Długa 12/3"
  end

  test "masks lines naming health care" do
    for text <- [
          "Gabinet Psychoterapii Dziecięcej",
          "Nadmorskie Centrum Zdrowia Psychi",
          "NIEPUBLICZNY GABINET LEKARSKI LEK. MED"
        ] do
      assert [{0, len, "SENSITIVE"}] = Patterns.spans(text), text
      assert len == byte_size(text), text
    end

    assert [] = Patterns.spans("Poradnik dla turystów")
  end

  test "matches short known values only as whole words" do
    source = "whole-words-#{System.unique_integer([:positive])}"
    Aliases.alias_for(source, "NAME", "Inka")
    Aliases.alias_for(source, "ADDRESS", "Kraków")
    t = [@text]

    assert [["Opłata INKASO"]] = Masking.mask(source, ["note"], t, [["Opłata INKASO"]])

    assert [["Kraków. Spacerownik"]] =
             Masking.mask(source, ["note"], t, [["Kraków. Spacerownik"]])

    assert [[note]] = Masking.mask(source, ["note"], t, [["Dla Inka, pilne"]])
    assert note =~ ~r/^Dla NAME_[a-z2-7]{8}, pilne$/
  end

  test "masks personal data in JSON keys and keeps ordinary keys" do
    assert [[prefs]] =
             mask(["prefs"], [[%{"jan.kowalski@example.com" => "owner", "invoice_id" => 42}]], [
               @json
             ])

    assert [{email, "owner"}, {"invoice_id", 42}] = Enum.sort_by(prefs, &elem(&1, 0))
    assert email =~ ~r/^EMAIL_/
  end
end
