defmodule BarkparkCloud.Accounts.AuditEvent do
  @moduledoc """
  One append-only entry in a Team's audit trail — a security/account-relevant
  action and WHO did it: a member invited or removed, a role changed, an
  invitation revoked or accepted, a subscription activated or canceled, an agent
  token minted or revoked, a site or instance created or deleted, a Barkpark
  taken live.

  Append-only: there is `inserted_at`, never `updated_at`. An audit event is a
  fact at a point in time — written once, never mutated (contrast Coolify's
  `activity_log`, whose `description` row is a live streaming SSH-process buffer
  that `updated_at`-advances on every stdout chunk). Enforced two ways: the
  schema drops `updated_at` (below), and the migration installs a BEFORE
  UPDATE/DELETE trigger so a raw SQL mutation is rejected at the DB, not just by
  Ecto. `metadata` is a free jsonb map so each `action` carries its own context
  (the email invited, old/new role, plan, IP) with no per-action migration.

  `actor_user_id` is NULLABLE: system / webhook-driven actions (e.g. a
  Stripe-fired subscription change) have no human actor, and an actor's account
  deletion must not erase the audit fact — only nilify its FK (see the
  migration's `on_delete: :nilify_all`).

  Modeled field-for-field on the append-only `Registry.AgentEvent` (binary_id
  PK, jsonb map, `updated_at: false`), but tenant-scoped to a `Team` and
  carrying an actor — improving on Coolify's JSON `properties->team_id` with a
  real `team_id` FK.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # The closed verb vocabulary. Dotted `<noun>.<verb>` so the UI can group by
  # noun and a typo is a changeset error (validate_inclusion), not a silent new
  # category. Extend it in cloud/priv/audit-actions.json as new audited
  # call-sites land (the derivation is below) — the routes wired today
  # are the member / invitation / token / subscription / site / barkpark seams
  # (including the OC24 instance-lifecycle triggers: retry / verify /
  # studio-link / site-url / self-update / rollback / autoupdate / domain /
  # vercel-deploy / resurrect);
  # the twofa pair (the account 2FA confirm / disable routes) is PRODUCED —
  # it was called "reserved" here long after its call-sites were wired.
  # The `env_var.created` / `env_var.deleted` pair LEFT the vocabulary with the
  # team env-var feature (ruled 2026-09-02, zero prod rows ever): its only
  # producers were the three deleted `/v1/env-vars` routes, so leaving the verbs
  # declared would have reddened the vocabulary census as a third zero-producer
  # verb — a verb with no producer must leave the vocabulary too.
  # `oauth.linked` LEFT that residue under
  # cch-w53-bl-oauth-linked-needs-a-branch-reporting-return: its blocker was a
  # bare `{:ok, user}` return that could not tell a LINK from a BIRTH, and once
  # `Accounts.get_or_create_user_from_oauth/1` reported its branch the router's
  # `audit_oauth_linked/4` could produce the verb on the `:linked` arm alone.
  # Only `email.verified` is still declared without a producer; it is named
  # individually, with a MACHINE-CHECKED rationale (an anchor that must resolve
  # plus a blocker that must stay absent), in
  # test/barkpark_cloud/audit_vocabulary_census_test.exs's @producerless — which
  # reds if a SECOND zero-producer verb joins it.
  #
  # WIRE-VOCABULARY MAP (cch-w63-s8), so this epic does not ship the drift it
  # exists to stop. `barkpark.credentials_refused` is the AUDIT name for the fact
  # the WIRE calls `identity_refused`: the box answered our stored admin
  # credential 401, so the control plane refused to spend it again and the write
  # never left the plane (`Barkpark.update_unavailable_reason` rung
  # "identity_refused"; the self-update and rollback routes relay 409
  # `%{code: "identity_refused"}`). The two words are ONE fact in two
  # vocabularies — the wire says WHY the request never went, the audit register
  # says WHAT was refused, to WHOM, and by WHOSE hand. The sibling wire word
  # `suspended` is a DIFFERENT fact (the plane withholds attention; the box was
  # never asked and never spoke) and deliberately gets no verb here. Reconciling
  # the two vocabularies is the open row
  # `cch-w58-bl-two-unavailable-vocabularies-name-one-fact`; this comment is the
  # MAP, not the merge.
  # THE VOCABULARY IS NO LONGER A HAND-LIST HERE (cch-w65). It is DERIVED, at
  # compile time, from cloud/priv/audit-actions.json — the SOLE authority for the
  # audit register's verbs. That same table also carries each verb's console
  # sentence fragment, and design/emit.mjs emits those into the ACTION_LABELS
  # region of cloud/priv/static/app.js. So the closed server vocabulary and the
  # console's labels are two OUTPUTS of one file rather than two hand-kept lists:
  # neither side greps the other's syntax, and a label for a verb this allowlist
  # does not declare has nowhere to live — a row IS the declaration and its label
  # rides on that row. Adding a verb: append a row to the JSON, run
  # `node design/emit.mjs --write`, commit app.js + design/emit-manifest.json.
  #
  # @external_resource makes a table edit recompile this module, so the
  # `validate_inclusion(:action, @actions)` below cannot go stale against it.
  # (Compile-time-read precedent in this app: the router's
  # @providers_capabilities_fixture.) The read is compile-time ONLY — but a
  # compile-time read still happens INSIDE the image build: the control-plane
  # image builds from cloud/ alone (cloud/docker-compose.yml `build: .`; the
  # Dockerfile COPYs mix.exs mix.lock config lib priv into /app), so this module
  # can only ever read files that live UNDER cloud/. The table lived in design/
  # once (cch-w65) and that broke every cp deploy — /design/audit-actions.json
  # does not exist in-container (cch-w69-s1, D841/D842). Hence cloud/priv/: it
  # rides the existing `COPY priv priv` layer and expands to
  # /app/priv/audit-actions.json at image-build compile time.
  # scripts/cloud-path-escape-check.sh now makes any repo-root read from a
  # cloud/lib reader FATAL, so this cannot silently recur.
  @audit_actions_manifest Path.expand("../../../priv/audit-actions.json", __DIR__)
  @external_resource @audit_actions_manifest
  @audit_actions_table @audit_actions_manifest
                       |> File.read!()
                       |> Jason.decode!()
                       |> Map.fetch!("actions")

  # The shape gate, at COMPILE time, so a malformed table is a build failure and
  # never a silently-shrunk vocabulary. design/check.mjs Part 0 asserts the SAME
  # invariants on the JS side (`auditActions()` in design/emit.mjs); this arm is
  # the one that matters for the server, because the value it guards is the closed
  # set `changeset/2` enforces. The keys this raises over are exactly the three
  # states a row can be in: a verb, a label, and — when the label is null — the
  # machine-checked rationale that makes "unlabelled on purpose" (charter D582) a
  # declaration rather than a discipline.
  Enum.each(@audit_actions_table, fn row ->
    verb = row["verb"]

    unless is_binary(verb) and Regex.match?(~r/^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/, verb) do
      raise "cloud/priv/audit-actions.json: #{inspect(row)} has no dotted <noun>.<verb> `verb` slug."
    end

    unless Map.has_key?(row, "label") do
      raise "cloud/priv/audit-actions.json: #{verb} states no `label` key at all. Every declared " <>
              "verb declares its console label explicitly — a string, or null WITH a " <>
              "`reason_code` and a `reason`. An absent key is the silent third state the " <>
              "single-table shape exists to remove."
    end

    if is_nil(row["label"]) and
         not (is_binary(row["reason_code"]) and is_binary(row["reason"]) and
                String.length(row["reason"]) >= 60) do
      raise "cloud/priv/audit-actions.json: #{verb} has `label: null` and no substantive " <>
              "`reason_code` + `reason`. Charter D582 blessed the raw dotted slug as HONEST, " <>
              "not as unexplained: an unlabelled verb has to say why in the table."
    end
  end)

  @actions Enum.map(@audit_actions_table, & &1["verb"])

  if length(Enum.uniq(@actions)) != length(@actions) do
    raise "cloud/priv/audit-actions.json declares a verb twice: " <>
            inspect(@actions -- Enum.uniq(@actions)) <>
            ". The vocabulary is a set; a duplicate row means one of the two labels is dead."
  end

  # Append-only stream: stamp inserted_at, never updated_at (mirrors AgentEvent).
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "audit_events" do
    field :action, :string
    # Loose string target — the polymorphic subject may be a Site, a Barkpark, a
    # Subscription, a TeamMembership, or an AgentToken (mixed PK types). No FK on
    # the target: it is a reference LABEL, and the target row may be deleted (a
    # `site.deleted` event must outlive the site it records).
    field :target_type, :string
    field :target_id, :string
    field :metadata, :map, default: %{}

    belongs_to :team, BarkparkCloud.Accounts.Team
    belongs_to :actor_user, BarkparkCloud.Accounts.User

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "The closed `action` vocabulary — the only verbs `changeset/2` accepts."
  def actions, do: @actions

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:action, :target_type, :target_id, :metadata, :team_id, :actor_user_id])
    |> validate_required([:action, :team_id])
    |> validate_inclusion(:action, @actions)
    |> assoc_constraint(:team)
    |> assoc_constraint(:actor_user)
  end
end
