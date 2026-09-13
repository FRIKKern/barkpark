defmodule BarkparkCloud.Repo.Migrations.CreateServingMemories do
  use Ecto.Migration

  # clk-bl-cloud-health-serving-since-is-boot-local — A CLOCK A RESTART CANNOT
  # IMPROVE.
  #
  # /health's `serving_since` was derived from `:erlang.monotonic_time/0` minus
  # `:erlang.system_info(:start_time)`: a PROCESS point sample. Health's own
  # moduledoc records the consequence by run — two BEAMs running that body back
  # to back reported lag 6,334 ms -> 263 ms, `serving_since` moving FORWARD
  # 6.4 s, a 24x "improvement" from changing nothing about what is deployed.
  #
  # This table is where the plane remembers, instead. One row per sha:
  # `first_seen_at` is the instant THIS control plane first observed that sha
  # serving. Restart the BEAM a hundred times — the sha is unchanged, the row is
  # untouched, and the clock keeps running from the deploy that actually changed
  # something. Only a CHANGED sha inserts a new row.
  #
  # ## Why Postgres and not a file
  #
  # `api/`'s `Barkpark.Sites.ServingMemory` writes JSON into the box's deploy
  # run-state dir, which survives because that dir is count-bounded and never
  # wiped. The plane has no such dir: it is a docker container that
  # `deploy/cp-deploy.sh`'s `compose_up_repair` RECREATES, and a recreated
  # container's filesystem is gone (the same disappearance that cost dr-w27 a
  # whole day of digest accounting). The plane's Postgres is the one thing here
  # that outlives a container, and it is already /health's only hard dependency
  # — a serving record it cannot reach is a plane that cannot answer anyway.
  #
  # ## Expand-safe only
  #
  # `deploy/cp-deploy.sh` does NOT run migrations; the Docker CMD does, when the
  # IDLE slot boots while the old slot still serves. A brand-new additive table
  # is legal precisely because the old slot never touches it.
  def change do
    create table(:serving_memories, primary_key: false) do
      # The git object name whose code is EXECUTING — lowercase hex, validated
      # by the writer before it ever reaches here. It is the identity of the
      # row: the whole point is that the SAME sha finds the SAME instant.
      add :sha, :string, primary_key: true, null: false

      # When this plane FIRST saw that sha serving. Written once, never updated:
      # the writer inserts with ON CONFLICT DO NOTHING and then reads back the
      # winner, so two slots racing at a flip agree on the earlier instant
      # rather than the later one.
      add :first_seen_at, :utc_datetime_usec, null: false
    end
  end
end
