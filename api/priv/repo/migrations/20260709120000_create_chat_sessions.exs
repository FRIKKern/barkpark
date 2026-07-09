defmodule Barkpark.Repo.Migrations.CreateChatSessions do
  use Ecto.Migration

  @moduledoc """
  Studio Claude chat — the session INDEX + display history (epic
  studio-claude-chat, wave 1, charter D6/D7).

  Two tables, NO HTTP route ever (LiveView reads `Repo` directly, org_admin_live
  prior art). The doc route was disqualified by evidence: the private-schema
  query gate is any-token, so a read-only worker could read admin chat
  transcripts (cwd, tool inputs, host paths). An Ecto table with no route is
  admin-gated by construction — forfeiting bp-CLI/revisions access to these
  transcripts is the D4 benefit, not a cost. Never add an HTTP route or export
  path over these tables.

  `chat_sessions.id` is the CLI-minted session UUID (`--session-id`/`--resume`
  key AND the row PK — one identity, no cursor column). Rows are created on the
  FIRST user send, never on mount. `chat_messages` holds OUR rendered display
  history (`source_markdown`, re-rendered on read so the improving paper engine
  wins); the CLI keeps model memory in its own transcript store.
  """

  def change do
    create table(:chat_sessions, primary_key: false) do
      # The CLI-minted session UUID — we generate it (D2), so it is known before
      # the first byte and needs no wire-protocol scraping.
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false, default: "New chat"
      # "default" until an AI/human title lands; the clobber guard (D13) only
      # overwrites a "default" title, never a human rename.
      add :title_source, :string, null: false, default: "default"
      add :cwd, :string
      add :mode, :string, null: false, default: "plan"
      add :model, :string
      # active (idle, resumable) | working (a turn is running) | exited (offline)
      add :status, :string, null: false, default: "active"
      add :last_active_at, :utc_datetime_usec
      # Denormalized sidebar columns — the list renders without loading messages.
      add :summary, :string
      add :message_count, :integer, null: false, default: 0
      add :input_tokens, :bigint, null: false, default: 0
      add :output_tokens, :bigint, null: false, default: 0
      add :total_cost_usd, :float, null: false, default: 0.0

      timestamps(type: :utc_datetime_usec)
    end

    # Sidebar recency ordering (status pill + latest-first).
    create index(:chat_sessions, [:status, :last_active_at])

    create table(:chat_messages) do
      add :session_id,
          references(:chat_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      # Monotonic per-session order; unique so a double-append can't collide.
      add :seq, :integer, null: false
      # user | assistant | tool  (approval/system ephemera stay live-only, w1).
      add :role, :string, null: false
      # The source markdown — never rendered HTML (D7: re-render on read).
      add :source_markdown, :text, null: false, default: ""
      # Tool inputs, usage, result-frame fields.
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:chat_messages, [:session_id, :seq])
  end
end
