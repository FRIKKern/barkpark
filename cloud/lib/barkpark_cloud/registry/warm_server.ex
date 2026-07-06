defmodule BarkparkCloud.Registry.WarmServer do
  @moduledoc """
  One pre-baked host in the warm pool (dwb-10) — a Barkpark-ready box the Go
  worker created ahead of time so a go-live can ASSIGN an already-booted server
  (≤15s to live) instead of waiting on a cold `hcloud server create`.

  This table is the ATOMIC CLAIM STORE for the pool. The Go worker holds no
  durable state and warm boxes outlive worker restarts, so pool membership +
  claim state must live in a shared, crash-safe place. Hetzner label updates are
  NOT compare-and-swap — two workers could both read a box as free and both flip
  it — which is exactly the collision that leaked the old fixed-name `warm-1`
  pool. Postgres `SELECT … FOR UPDATE SKIP LOCKED LIMIT 1` inside a transaction
  (the same primitive `provision_jobs` claiming uses) makes the claim genuinely
  race-safe: concurrent claimers lock disjoint rows, so at most one wins any row.

  Flat lifecycle (no attempts budget — a warm box is fungible; a failed assign
  just tears the box down and the reconciler re-tops the pool):

      ready ──claim (assign)──▶ claimed ──(row deleted once consumed)
        │
        ├──claim-retire (shrink)──▶ retiring ──(row deleted once box is gone)
        │
        └──claim-refresh (keep-current)──▶ refreshing ──(released back to ready)

    * `ready`    — created + registered by the worker, waiting to be assigned.
    * `claimed`  — an assign popped it via FOR UPDATE SKIP LOCKED; it is that
      go-live's box now. The row is DELETED when the assign consumes the box
      (whether the assign succeeds → live instance, or fails → box torn down).
    * `retiring` — the pool-size reconciler popped it (also SKIP LOCKED, but a
      separate status) to delete an EXCESS warm box. The row is DELETED once the
      Hetzner box is gone.
    * `refreshing` — the self-refresh loop (snapshot-management) popped the
      STALEST ready box to bring its checkout to origin/main in the background,
      so an idle pool box never drifts and a claim almost never rebuilds. UNLIKE
      claimed/retiring, the box RETURNS to `ready` when the refresh finishes
      (`release_warm_server_after_refresh/3`) — it never leaves the pool. This is
      what keeps "the latest Barkpark already installed" true at claim time.

  Because assign claims `ready → claimed`, retire claims `ready → retiring`, and
  refresh claims `ready → refreshing`, and SKIP LOCKED hands each claimer a
  DISTINCT row, a box is never simultaneously assigned + retired + refreshed. A
  refreshing box is OUT of the assignable set (claim selects `ready` only), so a
  go-live never grabs a box mid-rebuild. A crashed mid-consume leaves a stale row
  that `reap_stale_warm_claims/0` recovers: claimed/retiring are DELETED
  (bookkeeping — the Go worker owns the box's lifecycle), while a stale
  `refreshing` is put BACK to `ready` (the box still serves working code, so it
  rejoins the pool rather than being lost).

  The transitions are driven by `BarkparkCloud.Registry`
  (`register_warm_server/2` / `claim_warm_server/1` /
  `claim_warm_server_for_retire/1` / `claim_warm_server_for_refresh/2` /
  `release_warm_server_after_refresh/3` / `delete_warm_server/1`), not by
  arbitrary changeset writes — this schema only validates the shape.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @statuses ~w(ready claimed retiring refreshing)

  schema "warm_servers" do
    # The Hetzner box name — a unique `warm-<rand>` (NEVER a fixed name; the fixed
    # `warm-1` was the old collision). Unique so a re-register of the same box is
    # idempotent rather than a duplicate pool row.
    field :name, :string
    field :ip, :string
    field :status, :string, default: "ready"
    # The claimer's per-claim token, stamped on claim so a row can be traced to
    # the go-live/reconcile run that holds it. Null until claimed.
    field :claim_token, :string
    field :claimed_at, :utc_datetime_usec
    # snapshot-management: when this box's checkout was last brought to
    # origin/main by the self-refresh loop. Null = never refreshed since it
    # entered the pool (the stalest — refreshed first). Drives the "pick the
    # stalest due box" ordering + the min-interval gate.
    field :refreshed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses

  @doc """
  Changeset for registering / transitioning a warm server. `name` and `status`
  are required; `status` is validated against the enumeration; `name` is unique.
  """
  def changeset(warm, attrs) do
    warm
    |> cast(attrs, [:name, :ip, :status, :claim_token, :claimed_at, :refreshed_at])
    |> validate_required([:name, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:name)
  end
end
