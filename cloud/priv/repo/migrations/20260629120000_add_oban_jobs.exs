defmodule BarkparkCloud.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  # oban-substrate: Oban owns its own schema, so we only call its packaged
  # migrator (the same one Oban 2.17 ships, identical to api/'s
  # 20260426100001_create_oban_jobs.exs). up/0 creates the oban_jobs table (+ the
  # oban_job_state enum, the oban_peers table, and the insert-notify trigger) at
  # the latest packaged version; down/0 rolls back to the base (version: 1).
  #
  # The oban_jobs table is intentionally STANDALONE — bigserial id (NOT the app's
  # :binary_id default; Oban's table is exempt and this is correct), no FKs to
  # barkparks/provision_jobs. A job that references a since-deleted barkpark_id is
  # handled in worker logic (the worker re-validates), not by a DB constraint, so
  # a row delete never blocks on an in-flight job — the same discipline
  # provision_jobs uses for its barkpark_id (data the worker re-checks, not a
  # cascade). Timestamp sorts after the latest existing migration
  # (20260628120000_add_kind_to_provision_jobs.exs).
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down(version: 1)
end
