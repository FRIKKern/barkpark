defmodule BarkparkCloud.Repo.Migrations.AddCommitDistanceToBarkparks do
  @moduledoc """
  deploy-reliability W21 (S2): THE PLANE STOPS CALLING A BOX 2,468 COMMITS
  BEHIND `current`.

  ## The green these columns take away

  `barkparks.update_state` is a MIRROR, not a measurement:
  `Registry.refresh_update_status/1` GETs `<instance>/v1/admin/self-update` and
  persists the `"check"` block verbatim. The box compares its own RELEASE TAG
  against the newest tag it can see, so a box whose tag matches self-certifies
  `current` no matter how many commits of `main` it is missing —
  `git_commit` appears nowhere in that function.

  Re-derived at build time against `origin/main` tip `572d51e13`, three oracles
  agreeing to the unit (`git rev-list --count <served>..origin/main`, the
  positional index in `git log`, and the GitHub compare API's `ahead_by`), from
  the survey's 2026-08-08T03:05Z reading of the six live rows:

      Guerrilla  2673eb009      4 behind
      gyl        f3ee2984d    227 behind
      jarl       952106581    592 behind
      dooodo     e221e7dd5    886 behind
      Gyldendal  c80168100  2,468 behind
      muscle-1   (NULL)       agent offline, git_commit ""

  ALL SIX read `update_state: "current"` at `0.2.25 == 0.2.25`, and four of them
  additionally read bucket healthy / status ok. 2,468 commits of drift and 4
  commits of drift render as the same string.

  ## Why NEW columns and not a fifth `update_state` rung

  `@update_states` is `~w(unknown current behind disabled)` with six live
  consumers, three of them CONTROL FLOW. A scratch ExUnit run measured a fifth
  rung: the rollout candidate query (`registry.ex:3874`,
  `where: b.update_state == "behind"`) returns the row at `"behind"` and **nil**
  at a new value — a box graded stale by commit distance would be permanently
  excluded from the very rollout that would fix it — and ONE staging box in the
  new rung flips `staging_gate_open?/0` (`registry.ex:4102-4114`) from true to
  FALSE, freezing every prod advancement fail-CLOSED. So the verdict lands in
  its own columns and `update_state` keeps meaning exactly what it means today.

  ## The three columns

    * `commit_distance` — how many commits ON `main` the served commit does NOT
      have (the compare API's `ahead_by` for `<served>...main`). NULL is
      LOAD-BEARING: it means UNMEASURED, and it is what an empty/NULL
      `git_commit`, a 404 on an unknown sha, and a rate-limit refusal all land.
      A zero here would re-mint the unearned green in a fresh column on
      muscle-1, the one box already lying hardest.
    * `commit_ancestry` — the rung: `current` | `behind` | `ahead_of_main` |
      `diverged` | `unknown`. `ahead_of_main`/`diverged` mean the box serves
      code that is NOT on `main` — a loud row with no reporter today.
    * `commit_distance_checked_at` — when we last asked. Distinct from
      `update_checked_at`, which stamps the box's own self-graded verdict; a
      fresh mirror timestamp says nothing about whether the distance is fresh.

  ## Why this ALTER is safe on the live table

  `barkparks` is a control-plane table of SIX rows. Every column here is
  NULLABLE with NO default, so the `ALTER` is a catalog-only update (no table
  rewrite, no per-row work) and there is nothing to backfill: a pre-sweep row is
  honestly unmeasured until the first hourly `UpdateStatusWorker` tick writes
  it. No index — nothing queries these columns yet, and an index with no reader
  is write cost for nothing.

  MIGRATION ORDER: the LEAD orders this one. It assumes no deploy window.
  """

  use Ecto.Migration

  def change do
    alter table(:barkparks) do
      add :commit_distance, :integer
      add :commit_ancestry, :string
      add :commit_distance_checked_at, :utc_datetime_usec
    end
  end
end
