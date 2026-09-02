defmodule BarkparkCloud.Repo.Migrations.AddGitCommitFirstSeenAtToBarkparks do
  use Ecto.Migration

  # dr-w22-bl — WHEN did this box start serving the sha it serves now?
  #
  # The fact already exists on disk: every 60 s agent beat is inserted
  # append-only into `agent_events` with the FULL report (`git_commit`
  # included) and `AgentRetentionWorker` keeps 14 days of it. MEASURED on prod
  # 2026-09-01: 132,120 rows, oldest 2026-08-18T03:30:20Z, newest
  # 2026-09-01T23:19:22Z — a real 14-day-and-20-hour window, and the retention
  # cron is genuinely firing (7 completed `AgentRetentionWorker` jobs, latest
  # 2026-09-01T03:30:00Z).
  #
  # Its ONLY reader is `GET /v1/barkparks/:id/events`, which is
  # `Auth.require_user` and hard-caps a page at 200 rows — 3 h 06 m of a 14-day
  # history, on a surface NARROWER than the fleet list every PAT-holding reader
  # already uses. This column materialises the one datum an operator actually
  # asks the history for, on the row itself, so `GET /v1/barkparks`
  # (require_user_or_pat + read) can answer it without paging anything and
  # without widening the events route's auth.
  #
  # NULL means UNMEASURED, never "now" — the same contract `commit_distance`
  # carries on this table. Every row is NULL at migration time by construction:
  # a box that has not changed sha since this shipped has no OBSERVED first
  # appearance, and back-stamping the deploy instant would manufacture a
  # freshness reading nobody measured. The value appears the first time a box
  # beats a sha DIFFERENT from the one stored on its row.
  def change do
    alter table(:barkparks) do
      add :git_commit_first_seen_at, :utc_datetime_usec
    end
  end
end
