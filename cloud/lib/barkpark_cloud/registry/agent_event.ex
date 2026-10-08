defmodule BarkparkCloud.Registry.AgentEvent do
  @moduledoc """
  One entry in a Barkpark's append-only agent event stream — the audit trail of
  what the on-box agent reported (a health beat, a status flip, a disk-space
  report) plus the control-plane's own `verify` runs. Belongs to one Barkpark.

  Append-only: there is `inserted_at` but NO `updated_at`. An event is a fact at
  a point in time; it is written once and never mutated. `payload` is a free map
  stored as jsonb, so each `type` can carry whatever shape it needs without a
  schema migration per event kind.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # THE ALLOWLIST IS A DECLARED CAPABILITY — EVERY WORD IN IT MUST BE REACHABLE.
  #
  # `backup` and `tls` were declared here from this schema's creation commit and
  # were REMOVED in cch-w51-bl. They never had a producer: no call site in the
  # whole repo has ever passed either to `Registry.record_event/3` outside a
  # test, and neither had a consumer either — no `cloud/lib` path read an event
  # of that type. No `BackupProbe` exists; the health beat's `backup_ok` key is
  # an unwired constant false (router.ex, the agent-report handler says so in
  # its own comment), and the only other `tls`/`backup` strings in `cloud/lib`
  # belong to DIFFERENT vocabularies entirely — a domain-verification stage
  # name and an SMTP encryption mode. Wave 51 had already stripped their console
  # titles for the same reason; this is the server half of that fix. Nothing was
  # stranded: `type` is a plain string column with NO check constraint, so
  # narrowing this list tightens the changeset on WRITE only and cannot reject
  # or corrupt a row that already exists.
  #
  # `content` was declared here for a single CONSUMER:
  # `Accounts.published_doc?/1` queried `agent_events` for `type == "content"`
  # with `published_count > 0` to derive the onboarding checklist's "published
  # a doc" step, OR'd with the user-ack path (`Accounts.ack_onboarding_step/2`).
  # No producer ever wrote it — the agent's HTTP surface (/v1/agent/report,
  # /commands, /results, /space) has no content endpoint — and charter D902
  # ruled that NO producer would be built (ticking a checkbox you ticked
  # yourself is an honest self-report; inventing an agent endpoint to observe
  # it is the "build the actor before deciding the effect" trap the wave
  # refused). task-71a5ed0d3734d592 (2026-10-08) struck the consumer instead:
  # the automatic arm never fired in the wild and implied a measurement the
  # product never took, so `published_doc?/1` is gone and the step is reached
  # ONLY through the ack control (which the console's "Mark as done" button,
  # cch-w55-bl, already made reachable). `content` now has neither a producer
  # nor a consumer, so it follows `backup`/`tls` out of the allowlist — same
  # reasoning, same precedent, same test (`agent_event_test.exs`'s closed-
  # vocabulary check) that would have caught it staying behind.
  #
  # `verify` (C8/D53) is the on-demand readiness proof: `BarkparkCloud.Verify`
  # re-runs the golden-path probe suite over HTTPS and appends the full result
  # envelope (payload carries `ok`, `reachable`, `probes`) so "ready" becomes a
  # claim the operator can re-issue, and every run lands on the instance's event
  # timeline. Unlike the agent-posted types above, this one is control-plane
  # authored (no on-box coupling — D16 holds).
  #
  # `space` (D58) is the on-box agent's DISK-consumption payload, posted to
  # `/v1/agent/space` on its own slow (15-minute) cadence — root used/total,
  # journal bytes, the PG size + its biggest named relations, and the sites tree
  # with its biggest slugs. It rides its OWN type rather than the 60s health
  # beat on purpose: the health payload is read up to 200 rows at a time by the
  # metrics chart, and folding a per-slug list into it would detoast a large
  # jsonb on every chart render. Its row NEVER moves health columns — a box
  # whose disk probe succeeds while its BEAT is dead must not read as alive.
  #
  # Pinned in BOTH directions by `test/barkpark_cloud/registry/agent_event_test.exs`:
  # every word here must have a producer or a consumer in `cloud/lib`, and every
  # producer's type must be declared here (an undeclared one is rejected by the
  # `validate_inclusion` below and its row is silently never written). That test
  # is an OR — it cannot tell a producer-backed word from a consumer-only one,
  # so a word quietly losing its only producer (or only consumer) is invisible
  # to it as long as the other arm still holds.
  # `agent_event_producer_census_test.exs` is the per-type half: it carries the
  # expected producer-backedness of EVERY word here and reds on either change.
  @types ~w(health status verify space)

  # Append-only stream: stamp inserted_at, never updated_at.
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "agent_events" do
    field :type, :string
    field :payload, :map, default: %{}

    belongs_to :barkpark, BarkparkCloud.Registry.Barkpark

    timestamps()
  end

  @type t :: %__MODULE__{}

  def types, do: @types

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:type, :payload, :barkpark_id])
    |> validate_required([:type, :barkpark_id])
    |> validate_inclusion(:type, @types)
    |> assoc_constraint(:barkpark)
  end
end
