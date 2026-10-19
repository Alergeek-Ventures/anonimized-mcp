defmodule AnonimizedMcp.Debugging.Database do
  @moduledoc """
  Generic actions behind the MCP tools. Failures are returned as an `error`
  field rather than raised: the message is already safe to show, and raising
  would hand it to error logging and generic tool-error rendering.
  """

  use Ash.Resource, domain: AnonimizedMcp.Debugging, authorizers: [Ash.Policy.Authorizer]

  alias AnonimizedMcp.Gateway

  @masking_note """
  Personal data is replaced by stable aliases such as NAME_k3j9x2ab or TAX_ID_q7m2c4ze: the same \
  value always gets the same alias, so aliases can be joined, grouped and compared across \
  responses. Whitespace around a value is kept around its alias. Secrets show as [secret]. \
  Ids, amounts, states, timestamps and technical text are returned as stored.\
  """

  actions do
    action :list_sources, {:array, :map} do
      description "List the databases available for debugging. Start here."
      run fn _input, _context -> {:ok, Gateway.list_sources()} end
    end

    action :describe_schema, :map do
      description """
      Describe a source's schema. Without `table`, lists every readable table with its columns \
      and estimated row count. With `table` (e.g. "users" or "oban.oban_jobs"), returns column \
      types, foreign keys and how each column is masked.
      """

      argument :source, :string, allow_nil?: false

      argument :table, :string,
        description: "Optional table, schema-qualified when not in public."

      argument :refresh, :boolean, default: false, description: "Reload after schema changes."

      run fn input, _context ->
        respond(
          Gateway.describe(
            input.arguments.source,
            input.arguments[:table],
            input.arguments.refresh
          )
        )
      end
    end

    action :query, :map do
      description """
      Run one read-only SELECT (or EXPLAIN) against a source and get rows back. #{@masking_note}

      To filter by a masked value, write its alias inside a string literal: \
      `WHERE email = 'EMAIL_k3j9x2ab'`, `WHERE tax_id LIKE 'TAX_ID_q7m2c4ze%'`. The alias is \
      swapped for the real value inside the database only. Results are limited to `limit` rows \
      (default 100, max 500); `truncated` tells whether more exist. Queries time out after 15s.
      """

      argument :source, :string, allow_nil?: false

      argument :sql, :string,
        allow_nil?: false,
        description: "A single SELECT or EXPLAIN statement."

      argument :limit, :integer, default: 100

      run fn input, _context ->
        args = input.arguments
        respond(Gateway.query(args.source, args.sql, args.limit))
      end
    end

    action :check_value, :map do
      description """
      Inspect the value behind an alias without revealing it: length, whitespace, invisible \
      characters, letter case, digits only, and NIP/PESEL/REGON/IBAN/e-mail validity. With \
      `compare_with`, also tells whether two aliased values are equal, equal ignoring case, or \
      equal ignoring whitespace and dashes. Use it to explain failed validations or mismatches.
      """

      argument :source, :string, allow_nil?: false
      argument :alias, :string, allow_nil?: false
      argument :compare_with, :string, description: "Another alias to compare with."

      run fn input, _context ->
        args = input.arguments
        respond(Gateway.check_value(args.source, args.alias, args[:compare_with]))
      end
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  defp respond({:ok, result}), do: {:ok, result}
  defp respond({:error, message}), do: {:ok, %{error: message}}
end
