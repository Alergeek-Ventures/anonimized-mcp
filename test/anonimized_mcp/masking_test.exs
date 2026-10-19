defmodule AnonimizedMcp.MaskingTest do
  use ExUnit.Case, async: true

  alias AnonimizedMcp.Masking
  alias AnonimizedMcp.Masking.Patterns

  @text {Postgrex.Extensions.Raw, nil}
  @json {Postgrex.Extensions.JSONB, nil}

  defp mask(names, rows, types \\ nil),
    do: Masking.mask("test", names, types || Enum.map(names, fn _ -> @text end), rows)

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

  test "masks profile links and international phone numbers" do
    for text <- [
          "https://github.com/someone",
          "https://www.linkedin.com/in/some-one-123/",
          "linkedin.com/in/someone",
          "+48 600 12 34 56",
          "+1 (555) 123-4567",
          "+420 12 345 67 89",
          "+48600123456",
          "60 123-45-67"
        ] do
      assert [{0, len, type}] = Patterns.spans(text), text
      assert len == byte_size(String.trim_trailing(text, "/")) or len == byte_size(text), text
      assert type in ["PROFILE", "PHONE"], text
    end

    assert [] = Patterns.spans("https://github.com")
    assert [] = Patterns.spans("version 1.2.3 released 2026-10-19, order +5 items")
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

  test "aliases dates in birth date columns" do
    assert [[birth, issued]] =
             mask(["birth_date", "issued_on"], [[~D[1980-05-17], ~D[2026-10-01]]])

    assert birth =~ ~r/^BIRTHDATE_[a-z2-7]{8}$/
    assert issued == ~D[2026-10-01]
  end
end
