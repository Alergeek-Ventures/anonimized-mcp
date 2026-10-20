defmodule AnonimizedMcp.Masking.PatternsTest do
  use ExUnit.Case, async: true

  alias AnonimizedMcp.Masking.{Identifiers, Patterns}

  test "masks Luhn-valid payment cards, contiguous or grouped" do
    for text <- [
          "4111111111111111",
          "4111 1111 1111 1111",
          "4111-1111-1111-1111",
          "5555555555554444",
          "378282246310005",
          "3782 822463 10005"
        ] do
      assert [{0, len, "CARD"}] = Patterns.spans(text), text
      assert len == byte_size(text), text
    end

    assert [{6, 16, "CARD"}] = Patterns.spans("karta 4111111111111111.")
    # Not Luhn-valid, a millisecond timestamp, an EAN-13 barcode, a migration version.
    assert [] = Patterns.spans("4111111111111112")
    assert [] = Patterns.spans("1729245600000 5901234123457")
    refute Identifiers.card?("20241018120004")
  end

  test "masks Polish phone numbers written without '+', after PESEL" do
    for text <- ["48601234567", "0048601234567", "tel. 48601234567"] do
      assert [{_, _, "PHONE"}] = Patterns.spans(text), text
    end

    assert [{0, 11, "PESEL"}] = Patterns.spans("48010112340")
    assert [{0, 12, "PHONE"}] = Patterns.spans("+48601234567")
  end

  test "masks Polish ID card and passport numbers with a valid check digit" do
    for text <-
          ~w(ABA300000 ABS123456 EK1234567 EA1234567 CC7999486) ++
            ["ABS 123456", "ZS 0123456"] do
      assert [{0, len, "ID"}] = Patterns.spans(text), text
      assert len == byte_size(text), text
    end

    assert [{36, 9, "ID"}] = Patterns.spans("Weryfikacja tożsamości: nr dowodu ABS123456")
    assert [] = Patterns.spans("DEF654321 AB9876543 ABA300001 INV123456")
  end

  test "finds digit identifiers in file names and keys" do
    for {text, span} <- [
          {"skan_44051401359.pdf", {5, 11, "PESEL"}},
          {"umowa_44051401359_podpisana.pdf", {6, 11, "PESEL"}},
          {"44051401359_2", {0, 11, "PESEL"}},
          {"44051401359-1", {0, 11, "PESEL"}},
          {"faktura_5261040828.pdf", {8, 10, "TAX_ID"}},
          {"PL5261040828-korekta.xml", {0, 12, "TAX_ID"}},
          {"regon_123456785.pdf", {6, 9, "REGON"}}
        ] do
      assert [^span] = Patterns.spans(text), text
    end

    assert [{0, 13, "TAX_ID"}] = Patterns.spans("526-104-08-28")
  end

  test "digit identifiers still need a checksum and a non-alphanumeric boundary" do
    assert [] = Patterns.spans("skan_44051401358.pdf")
    assert [] = Patterns.spans("a44051401359 440514013590 x5261040828")
    # A REGON-valid migration version.
    assert Identifiers.regon?("20241018120002")
    assert [] = Patterns.spans("20241018120002_create_users.exs")
    assert [] = Patterns.spans("1b4e28ba-2fa1-11d2-883f-0016d3cca427")
  end

  test "masks full and compressed IPv6 addresses" do
    for text <- ["2001:0db8:85a3:0000:0000:8a2e:0370:7334", "2a02:a311:4c3::1", "2001:db8::1"] do
      assert [{0, len, "IP"}] = Patterns.spans(text), text
      assert len == byte_size(text), text
    end

    assert [] = Patterns.spans("::1 at 10:30 and 10:30:45, Foo::Bar, '1'::bigint, x::text")
  end

  test "Polish document check digits follow the official weights" do
    assert Identifiers.id_card?("ABA300000")
    assert Identifiers.id_card?("ABS 123456")
    refute Identifiers.id_card?("ABA400000")
    refute Identifiers.id_card?("AB1300000")
    assert Identifiers.passport?("CC7999486")
    refute Identifiers.passport?("CC8999486")
    refute Identifiers.passport?("C17999486")
  end
end
