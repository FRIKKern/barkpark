defmodule Barkpark.Repo.Migrations.AddActorIdentityToPaperEvents do
  @moduledoc """
  Requester↔accepter identity tie for `paper_events`
  (task-cefcbf5b3a9b1665).

  Before this migration a `simplify-accept` / `simplify-reject` row named a
  branch and nothing else: no actor, no pointer at the request it decides, no
  record of whether anyone checked. A downstream consumer reading the event
  stream as approval could not tell a requester's own decision from a
  bystander's forgery.

  Four ADDITIVE nullable columns, no backfill:

    * `actor_kind` / `actor_id` — the authenticated principal behind the row
      (`PaperViewer` viewer `:kind` + `:id`). NULL = a legacy or unattributed
      row.
    * `request_event_id` — the originating `simplify-request` this row
      decides. NULL on requests and on legacy decisions.
    * `authorization` — the decision the server recorded when it wrote the
      row: `"authorized"` (every tie checked) or `"unverified"` (nobody
      checked — the row is explicitly NON-authoritative). NULL on legacy rows,
      which `Events.authoritative_decision?/1` also reads as non-authoritative.

  Legacy rows keep NULL on all four and are therefore never authoritative —
  which is the intended migration policy: history is preserved and demoted,
  never retro-blessed.

  `MANIFEST.sha256` is regenerated with this commit (migration_manifest_test).
  """
  use Ecto.Migration

  def change do
    alter table(:paper_events) do
      add :actor_kind, :string
      add :actor_id, :string
      add :request_event_id, :binary_id
      add :authorization, :string
    end

    # The replay/idempotency read: "has this request already been decided?"
    create index(:paper_events, [:request_event_id])
  end
end
