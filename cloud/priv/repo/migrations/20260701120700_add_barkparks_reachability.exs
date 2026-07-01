defmodule BarkparkCloud.Repo.Migrations.AddBarkparksReachability do
  use Ecto.Migration

  # Server-side staleness detection (the ServerManagerJob analog).
  #
  # The push-only ingest has no way to notice an agent going SILENT: nothing
  # flips agent_status→offline when /v1/agent/report simply stops arriving, so a
  # wedged instance stays falsely "online/up" forever. These two columns are the
  # debounce + alert-latch the StalenessWorker keys off — direct ports of
  # Coolify's servers.unreachable_count / unreachable_notification_sent
  # (2023_10_08_111819_add_server_unreachable_count.php).
  #
  #   unreachable_count             — consecutive missed-heartbeat ticks; the
  #                                   worker flips only at >= :health_down_after_count
  #                                   (absorbs a single transient miss).
  #   unreachable_notification_sent — one-alert latch; set on the offline flip,
  #                                   reset when the agent reports again, so we
  #                                   email once per outage, not once per minute.
  def change do
    alter table(:barkparks) do
      add :unreachable_count, :integer, null: false, default: 0
      add :unreachable_notification_sent, :boolean, null: false, default: false
    end

    # The worker scans by (agent_status, last_seen_at). A partial index on the
    # hot predicate keeps the per-minute scan an index range-scan even as the
    # fleet grows — only "online" rows are ever candidates.
    create index(:barkparks, [:last_seen_at],
             where: "agent_status = 'online'",
             name: :barkparks_online_last_seen_idx
           )
  end
end
