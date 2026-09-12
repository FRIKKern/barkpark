defmodule BarkparkWeb.GithubStatusController do
  @moduledoc """
  GitHub sync-health status (design paper `bp-github-bridge-epic-charter`,
  Wave 6 — observability). Mounted by the github plugin's `register_routes/1`
  on the `:token` bucket at `GET /v1/plugins/github/status` — a bearer-gated
  OPERATOR READ (NOT `:admin`), the read twin of the adopt POST, so
  `bp github status` runs with a normal operator token.

  ## Contract (D5 — read-only)

  `status/2` is a pure READ: it NEVER mutates the ledger, never writes a
  `mutation_event`, and never reads a GitHub field back. It returns the current
  sync-health snapshot — open conflicts by kind, per-dataset cursor lag, and
  mirror queue depth — assembled entirely from Barkpark-side state
  (`github_sync_conflicts`, the outbound cursor, the `github_mirror` Oban queue).

    * no required params — the endpoint always answers
    * the snapshot is ALWAYS pinned to the caller's OWN token dataset
      (`conn.assigns.api_token.dataset`, default `"production"`) — D18. This is
      the flat `:token` bucket (`[:api, :require_token]`), whose `:api`
      AssignDefaultScope seeds `current_workspace` to the DEFAULT regardless of
      the bearer, so a scope helper would read that Default, not the token — the
      token's own `dataset` string is the only trustworthy per-caller scope here.
    * a `?dataset=<name>` param can only ever RESTATE the token's own dataset; a
      blank OR a foreign dataset can NOT widen the read past the bearer's scope.
      (A token owns exactly one dataset, so there is nothing narrower to select.)

  ## Membership fence (github-bridge-w9-health-workspace-isolation)

  The token dataset string alone was never isolation: a dataset slug is unique
  per PROJECT, so every workspace gets a `"production"` and two of them shared
  one another's open-conflict backlog under that name. On top of the D18 dataset
  pin, `status/2` now also passes the bearer's OWN membership set —
  `Tenancy.list_workspaces_for/1`, the fail-closed membership primitive
  `WorkspaceController` uses — down to `Health.snapshot/1`, which admits only
  conflict rows owned by one of those workspaces (or unattributed, see
  `Health`'s moduledoc).

  `list_workspaces_for/1` INNER-JOINs `workspace_memberships`, so it is
  fail-CLOSED in shape: a token with no membership row yields `[]` and the fence
  is an empty set, never "all workspaces". That empty answer is passed through
  as an empty LIST — deliberately not as `nil`, which is `Health`'s "no fence"
  sentinel; collapsing the two would turn a member-of-nothing token into a
  whole-fleet reader, the exact inversion this slice exists to prevent.

  The outbound CURSOR half of the snapshot is NOT membership-fenced, and that is
  a property of the cursor, not an omission: `Github.Cursor` stores ONE
  `sync_push_cursors` row per `{source, dataset}` with a deliberately NULL
  `workspace_id` (charter D55), because the drain it tracks reads
  `mutation_events` by dataset across every workspace sharing the slug. There is
  no per-workspace cursor to isolate; making one is a re-keying of the mirror
  drain, not a read filter.

  ## Status mapping

    * always `200 {ok: true, health: <snapshot>}`

  A field is left ABSENT from the snapshot when its source is unknown, never
  fabricated — the honest-failure-state discipline. The endpoint answers `200`
  even when the plugin is dark, so an operator can always ask "is anything
  wired?" and get a truthful (possibly empty) health map.

  ## Health seam

  `status/2` calls the health snapshot through a private seam so a controller
  test can assert dispatch + shape without exercising the real
  `Barkpark.Plugins.Github.Health` (which reads Postgres + the Oban queue).
  Override with `config :barkpark, :github_status_fun, fun/1` in test (the
  adopt controller's `:github_adopt_fun` precedent). Absent → the real Health
  module, resolved dynamically so a build without the sibling Health module
  present still compiles clean — the call resolves at request time. The seam is
  a 1-arity function of the (possibly `nil`) dataset filter, matching
  `Health.snapshot/1`.
  """

  use BarkparkWeb, :controller

  @doc """
  Return the current GitHub sync-health snapshot. Read-only — see the moduledoc.

  The snapshot is pinned to the caller's OWN token dataset (D18): a blank or
  foreign `?dataset=` can never widen the read past the bearer's scope.
  """
  def status(conn, params) do
    requested = blank_to_nil(Map.get(params, "dataset"))

    filter = [
      dataset: effective_dataset(conn, requested),
      workspace_ids: member_workspace_ids(conn)
    ]

    json(conn, %{ok: true, health: status_fun().(filter)})
  end

  # The bearer's OWN workspace memberships, as ids. Resolved through
  # `Tenancy.list_workspaces_for/1` (an INNER JOIN on `workspace_memberships`),
  # so a workspace the token holds no membership row for is UNREACHABLE rather
  # than merely filtered out. No token in the conn (a direct controller unit call
  # outside the pipeline) → `[]`, the fail-closed answer, not `nil`.
  defp member_workspace_ids(conn) do
    conn.assigns[:api_token]
    |> Barkpark.Tenancy.list_workspaces_for()
    |> Enum.map(& &1.id)
  end

  # Constrain the effective dataset to the bearer's OWN token dataset (D18) so a
  # blank or foreign `?dataset=` cannot widen a status read to whole-fleet
  # health/conflicts. On the flat `:token` bucket `RequireToken` always assigns
  # `:api_token`, whose `:dataset` defaults to "production" — so this is the
  # trustworthy per-caller scope (unlike the `:api`-seeded Default workspace,
  # which `ScopeHelpers.scope_opts/1` would read and leak past). A token whose
  # dataset is somehow nil/blank pins to "production" (the schema default),
  # NEVER to the caller's param. Only when there is no token at all (a direct
  # controller unit call outside the pipeline) does the requested param stand.
  defp effective_dataset(conn, requested) do
    case conn.assigns[:api_token] do
      %{dataset: ds} when is_binary(ds) and ds != "" -> ds
      %{} -> "production"
      _ -> requested
    end
  end

  # Health seam: overridable in test via app env, else the real module. The
  # module is resolved dynamically so a build without the sibling Health module
  # present still compiles clean — the call resolves at request time, by which
  # point the module is loaded.
  defp status_fun do
    Application.get_env(:barkpark, :github_status_fun) || (&default_status/1)
  end

  defp default_status(dataset) do
    mod = Module.concat(Barkpark.Plugins.Github, Health)
    mod.snapshot(dataset)
  end

  # A blank ?dataset= (empty or all-whitespace) means "no filter" — coerce it to
  # nil so the health snapshot returns the whole-fleet view rather than filtering
  # to a dataset named "".
  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(v) when is_binary(v) do
    if String.trim(v) == "", do: nil, else: v
  end

  defp blank_to_nil(v), do: v
end
