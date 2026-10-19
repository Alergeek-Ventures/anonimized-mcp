defmodule AnonimizedMcp.Masking.Policy do
  @moduledoc """
  Decides how a column is masked. Per-source overrides (`"table.column"` or
  `"schema.table.column"`) come first; otherwise name conventions shared by
  our apps apply. Name rules only cover text-like and JSON columns, so ids,
  amounts, flags and timestamps stay visible unless a source says otherwise.

  Kinds:
    * `:plain` - returned as is, text still goes through detectors
    * `:secret` - never returned
    * `{:pii, type}` - replaced by a stable alias such as `EMAIL_k3j9x2ab`
  """

  @type kind :: :plain | :secret | {:pii, String.t()}

  @text_types ~w(text character\ varying character citext json jsonb _text _varchar _citext _jsonb _json)

  @people_tables ~w(users user customers customer clients client contacts contact counterparties
                    counterparty organizations organization companies company employees employee
                    people persons person members member accounts)

  @secret ~r/password|passwd|secret|token|api_?key|private_key|credential|encryption_key|^iv$|_iv$|otp|signature|session_key|cookie/
  @rules [
    {~r/pesel/, "PESEL"},
    {~r/(^|_)(nip|tax_id|vat_id|vat_number|regon)$/, "TAX_ID"},
    {~r/iban|account_number|bank_account|(creditor|debtor|recipient|sender)_account/, "IBAN"},
    {~r/e_?mail/, "EMAIL"},
    {~r/phone|mobile|(^|_)tel$|fax/, "PHONE"},
    {~r/address|street|postal_code|zip_code|postcode/, "ADDRESS"},
    {~r/birth/, "BIRTHDATE"},
    {~r/(^|_)ip(_address)?$|remote_ip/, "IP"},
    {~r/(^|_)(first|given|last|sur|full|middle|maiden|nick|owner|creditor|debtor|buyer|seller|recipient|sender|contact|display|legal|company|person)_?name$/,
     "NAME"},
    {~r/^surname$/, "NAME"}
  ]

  @doc "Returns the masking kind of `column` in `table` (\"schema.table\") of type `type`."
  @spec classify(AnonimizedMcp.Sources.t(), String.t(), String.t(), String.t()) :: kind()
  def classify(source, table, column, type) do
    [schema, relation] = String.split(table, ".", parts: 2)

    override =
      Map.get(source.columns, "#{table}.#{column}") ||
        if(schema == "public", do: Map.get(source.columns, "#{relation}.#{column}"))

    cond do
      override -> override
      type in @text_types -> by_name(column, relation)
      true -> :plain
    end
  end

  @doc "Classifies a JSON key or an unqualified name by naming convention only."
  @spec by_name(String.t(), String.t() | nil) :: kind()
  def by_name(name, relation \\ nil) do
    name = name |> Macro.underscore() |> String.downcase()

    cond do
      Regex.match?(@secret, name) ->
        :secret

      rule = Enum.find(@rules, fn {regex, _} -> Regex.match?(regex, name) end) ->
        {:pii, elem(rule, 1)}

      name == "name" and relation in @people_tables ->
        {:pii, "NAME"}

      true ->
        :plain
    end
  end
end
