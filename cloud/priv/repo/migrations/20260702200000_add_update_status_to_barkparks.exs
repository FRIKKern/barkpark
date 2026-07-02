defmodule BarkparkCloud.Repo.Migrations.AddUpdateStatusToBarkparks do
  use Ecto.Migration

  # isu-6: per-instance self-update status, mirrored from the instance's OWN
  # verdict (GET /v1/admin/self-update → the "check" block). THE INSTANCE IS THE
  # SOURCE OF TRUTH — it knows its own upstream/fork; the control plane merely
  # caches the last answer so the fleet dashboard can render "update available"
  # without a live fan-out on every page load.
  #
  #   update_state           — "unknown" | "current" | "behind" | "disabled";
  #                            "unknown" also covers pre-feature instances that
  #                            404 the endpoint, and any unreachable/failed check.
  #   update_running_release — the release the instance reports it is running.
  #   update_latest_release  — the newest release its upstream offers.
  #   update_checked_at      — when the control plane last asked.
  def change do
    alter table(:barkparks) do
      add :update_state, :string, null: false, default: "unknown"
      add :update_running_release, :string
      add :update_latest_release, :string
      add :update_checked_at, :utc_datetime_usec
    end
  end
end
