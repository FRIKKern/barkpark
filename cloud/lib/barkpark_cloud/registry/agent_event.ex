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
  # `content` STAYS, and the difference is not sentiment — it is a live
  # CONSUMER. `Accounts.published_doc?/1` queries `agent_events` for
  # `type == "content"` with `published_count > 0` to derive the onboarding
  # checklist's "published a doc" step. No producer writes it yet, so that step
  # is reached today through the user-ack path (`Accounts.ack_onboarding_step/2`)
  # and tightens automatically the day the on-box agent learns to report
  # content. Dropping the word would be compile-clean — the consumer holds a
  # string literal, not a reference to this list — so the step would go
  # permanently, silently false with no warning and no log. A word with a reader
  # is forward-compat; a word with neither reader nor writer is a lie.
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
  # `validate_inclusion` below and its row is silently never written).
  @types ~w(health status content verify space)

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
