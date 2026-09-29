defmodule Barkpark.Repo.Migrations.AddScopeSourceToDocuments do
  use Ecto.Migration

  # SCOPE-RESOLUTION PROVENANCE (task-b389fe352e013dce, the follow-up to
  # task-e6523cc7154304f0 whose criterion 1 closed UNMEASURABLE).
  #
  # WHAT THIS COLUMN RECORDS: which arm of
  # `Barkpark.Content.WriteScope.resolve_write_scope_with_source/1` produced the
  # `workspace_id` sitting beside it on this row.
  #
  #   * "explicit"         — the caller NAMED a `:workspace_id`.
  #   * "inferred"         — no scope key, but an attributable principal with
  #                          exactly one workspace membership; the door inferred it.
  #   * "instance_wide"    — a boot/internal seat DECLARED `instance_wide: true`.
  #   * "default_fallback" — the residual: no scope key, no principal, no
  #                          declaration. THIS is the population nobody could
  #                          count before, because it wrote bytes identical to
  #                          an "explicit" write that happened to name Default.
  #   * "inherited"        — copied from a source row on a publish/unpublish
  #                          transition whose own provenance predates this column.
  #
  # ADDITIVE AND NULLABLE, WITH NO BACKFILL — deliberately. See below.
  #
  # ── THE PRE-CHANGE ROWS ARE PERMANENTLY AMBIGUOUS ──────────────────────────
  #
  # Every row that existed before this migration gets `scope_source IS NULL`,
  # and that NULL is the honest answer, not a gap to be filled later.
  #
  # The measurement on the box at 2026-09-22 was: 527 of 3,959 documents (13.31%)
  # carry the Default workspace. That figure is `fallback UNION deliberate-Default`
  # — a CEILING on the fallback population, never the population. No backfill can
  # split it, because the only thing that distinguished the two arms was the opts
  # list at the instant of the write, and nothing persisted it: `documents` has no
  # provenance column (that is what this migration fixes), `documents.owner_id` is
  # NULL on all 3,959, and `revisions.actor_user_id` is NULL on all 11,253. There
  # is no join key to recover, so there is no method to state.
  #
  # `revisions.actor_kind` / `actor_id` / `actor_label` (migration
  # 20260904120000) do NOT close this either. They record WHO wrote, not HOW the
  # scope resolved: a user-authenticated write that explicitly names Default and
  # a user-authenticated write that falls into it both carry
  # `actor_kind = "user"`. They narrow nothing on this axis, and they live on
  # `revisions`, not on `documents`. Those columns are kept as the ACTOR surface;
  # this one is the SCOPE-RESOLUTION surface. They answer different questions, so
  # they cannot disagree.
  #
  # CONSEQUENCE FOR ANY FUTURE COUNT: a query over `scope_source` measures only
  # rows written AFTER this migration. Rows with `scope_source IS NULL` must be
  # reported as their own bucket — UNMEASURED — and never folded into either
  # side. A number that mixes provenance-bearing and provenance-less rows
  # without saying which is which is worse than no number.
  #
  # NO INDEX: the column exists to be COUNTED, in occasional analytic
  # `GROUP BY scope_source` queries over a table in the low thousands, never in
  # a hot WHERE clause. An index would cost every write for a query nobody runs
  # per-request.
  #
  # `MANIFEST.sha256` is regenerated with this commit (migration_manifest_test).
  def up do
    alter table(:documents) do
      add :scope_source, :string, null: true
    end
  end

  def down do
    alter table(:documents) do
      remove :scope_source
    end
  end
end
