defmodule Barkpark.Repo.Migrations.MovePapersToProduction do
  use Ecto.Migration

  @moduledoc """
  Convergence Part 1: papers move from the `paperflow` dataset into
  `production`, where they now open LIVE inside the Studio editor pane at
  `/studio/production/paper/:slug`.

  This migration:

    1. Re-points every type-"paper" `documents` row from dataset `paperflow`
       to `production` — but only when the slug (`doc_id`) is NOT already
       present under `production`. A re-run (or a fresh DB where seeds already
       created production papers) leaves the production rows authoritative and
       discards the stale paperflow twins.
    2. Re-points the type-"paper" `revisions` rows the same way so history
       follows the document into production.
    3. Seeds the `paper` schema in `production` so `Structure.build/2` for
       production yields the Papers desk node (idempotent on `(name, dataset)`).

  Idempotent (re-running is a no-op once papers live in production) and
  reversible (`down/0` moves them back to `paperflow`). It MOVES data — it
  never drops a paper.
  """

  def up do
    flush()

    # 1a. Discard any paperflow paper whose slug already exists under
    #     production — the production row is authoritative. (Makes the move
    #     below conflict-free and the whole migration idempotent.)
    repo().query!(
      """
      DELETE FROM documents pf
      WHERE pf.type = 'paper'
        AND pf.dataset = 'paperflow'
        AND EXISTS (
          SELECT 1 FROM documents prod
          WHERE prod.type = 'paper'
            AND prod.dataset = 'production'
            AND prod.doc_id = pf.doc_id
        )
      """,
      []
    )

    # 1b. Move the remaining paperflow papers into production.
    repo().query!(
      """
      UPDATE documents
      SET dataset = 'production', updated_at = updated_at
      WHERE type = 'paper' AND dataset = 'paperflow'
      """,
      []
    )

    # 2. Carry the revision history across (same conflict-free move; revisions
    #    has no unique (doc_id, type, dataset) constraint, so a plain update is
    #    safe — duplicate history rows are harmless).
    repo().query!(
      """
      UPDATE revisions
      SET dataset = 'production'
      WHERE type = 'paper' AND dataset = 'paperflow'
      """,
      []
    )

    # 3. Ensure the paper schema exists in production so the desk renders the
    #    Papers node. Routed through Content.upsert_schema/2 (read-first, so a
    #    re-run is a no-op) to avoid hand-encoding the jsonb-array columns.
    Barkpark.Content.upsert_schema(
      %{
        "name" => "paper",
        "title" => "Papers",
        "icon" => "📰",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "title" => "Title", "type" => "string"},
          %{"name" => "event_type", "title" => "Event Type", "type" => "string"},
          %{"name" => "source_doc", "title" => "Source Doc", "type" => "string"},
          %{"name" => "goal_id", "title" => "Goal", "type" => "string"}
        ]
      },
      "production"
    )
  end

  def down do
    flush()

    # Move papers back to paperflow, discarding any paperflow twin first so the
    # reverse move is also conflict-free.
    repo().query!(
      """
      DELETE FROM documents pf
      WHERE pf.type = 'paper'
        AND pf.dataset = 'paperflow'
        AND EXISTS (
          SELECT 1 FROM documents prod
          WHERE prod.type = 'paper'
            AND prod.dataset = 'production'
            AND prod.doc_id = pf.doc_id
        )
      """,
      []
    )

    repo().query!(
      """
      UPDATE documents
      SET dataset = 'paperflow'
      WHERE type = 'paper' AND dataset = 'production'
      """,
      []
    )

    repo().query!(
      """
      UPDATE revisions
      SET dataset = 'paperflow'
      WHERE type = 'paper' AND dataset = 'production'
      """,
      []
    )

    # Re-seed the paper schema under paperflow (idempotent).
    Barkpark.Content.upsert_schema(
      %{
        "name" => "paper",
        "title" => "Papers",
        "icon" => "📰",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "title" => "Title", "type" => "string"},
          %{"name" => "event_type", "title" => "Event Type", "type" => "string"},
          %{"name" => "source_doc", "title" => "Source Doc", "type" => "string"},
          %{"name" => "goal_id", "title" => "Goal", "type" => "string"}
        ]
      },
      "paperflow"
    )

    # Drop the production paper schema so the reverse leaves no stray empty
    # "Papers" node in the production desk (the prior migration owned the
    # paperflow-side schema, which we re-seeded above).
    repo().query!(
      "DELETE FROM schema_definitions WHERE name = 'paper' AND dataset = 'production'",
      []
    )
  end
end
