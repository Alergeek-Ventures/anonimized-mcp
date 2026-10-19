defmodule AnonimizedMcp.Debugging.LeakReport do
  @moduledoc """
  A masked cell an agent flagged as still showing personal data. The cell is
  copied from the stored result, never from the agent, so reports can be
  reviewed and turned into detector training data.
  """

  use Ash.Resource,
    domain: AnonimizedMcp.Debugging,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "leak_reports"
    repo AnonimizedMcp.Repo
  end

  actions do
    defaults [:read]

    create :report do
      accept [:source, :query_id, :row, :column, :cell, :note]
      argument :reporter_id, :uuid
      change manage_relationship(:reporter_id, :reporter, type: :append)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :source, :string, allow_nil?: false
    attribute :query_id, :string, allow_nil?: false
    attribute :row, :integer, allow_nil?: false
    attribute :column, :string, allow_nil?: false
    attribute :cell, :map, allow_nil?: false
    attribute :note, :string
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :reporter, AnonimizedMcp.Accounts.User
  end
end
