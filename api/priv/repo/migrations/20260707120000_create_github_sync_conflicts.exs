defmodule Barkpark.Repo.Migrations.CreateGithubSyncConflicts do
  use Ecto.Migration

  @moduledoc """
  GitHub bridge — the VISIBLE quarantine substrate (epic charter D7).

  When the ledger and a mirrored GitHub Issue disagree, the ledger still
  WINS — but the disagreement is RECORDED here before it converges, never
  silently overwritten. Three kinds of drift land in this table:

    * `out_of_band_edit` — an issue was hand-edited/closed/relabeled since
      our last mirror write; recorded before the reconciling PATCH.
    * `detached`         — an issue was deleted or transferred out; marked
      and surfaced, NEVER recreated (that would fight a human).
    * `dedup_refused`    — an inbound outsider issue the Tasks dedup seam
      judged a look-alike; no task was born, so it gets a findable
      dead-letter row instead of total silence.

  Deliberately NOT a document and NOT a task mutation: a conflict record is
  out-of-band bookkeeping, so writing one can never re-trigger sync. There is
  no loop surface here. `doc_id` is nullable because a `dedup_refused` intake
  never produced a task. A row is "open" until `resolved_at` is set.
  """

  def change do
    create table(:github_sync_conflicts) do
      add :repo, :text, null: false
      add :issue, :bigint, null: false
      # nullable: a dedup-refused intake has no task yet
      add :doc_id, :text
      add :dataset, :text, null: false
      # one of "out_of_band_edit" | "detached" | "dedup_refused"
      add :kind, :text, null: false
      add :detail, :map, null: false, default: %{}
      # nullable: quarantine is "open" until cleared
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # Look up all conflicts for one issue (dedup + console drill-down).
    create index(:github_sync_conflicts, [:repo, :issue])
    # The open-conflicts feed: WHERE resolved_at IS NULL, filtered by kind.
    create index(:github_sync_conflicts, [:kind, :resolved_at])

    # STRUCTURAL dedup invariant: at most ONE open row per {repo, issue, kind}.
    # A plain FOR UPDATE in the recorder cannot lock a not-yet-existing gap, so
    # two genuinely-concurrent FIRST records for the same key (e.g. an
    # at-least-once webhook REDELIVERY of the same issue) could both read nil
    # and both insert. This partial unique index makes the pile impossible at
    # the DB; the recorder catches the losing insert and converges onto the
    # winner in place. Partial (resolved_at IS NULL) so a resolved key can
    # legitimately re-open as a fresh row.
    create unique_index(:github_sync_conflicts, [:repo, :issue, :kind],
             where: "resolved_at IS NULL",
             name: :github_sync_conflicts_open_key
           )
  end
end
