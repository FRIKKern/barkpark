defmodule BarkparkWeb.Plugs.RequireWithinQuota do
  @moduledoc """
  Per-workspace quota gate at the mutate seam (perfect-plan-build W1, charter
  D11/D12). Halts a write with a JSON error envelope when the resolved workspace
  is suspended or over its document quota, BEFORE the request reaches the
  controller.

  ## Placement

  Runs AFTER the workspace scope is resolved (so `conn.assigns[:current_workspace]`
  is set) and BEFORE `RequireWritePermission`, in all THREE mutate pipelines —
  `:scoped_mutate` (docs) AND `:scoped_media_mutate` (scoped media) AND the flat
  `:media_mutate` (legacy media). This is the ONLY seam that covers both content
  and media: media writes go straight to `Barkpark.Media.upload/3` (a raw
  `Repo.insert`), never through `Content.apply_mutations`, so a Content-context
  hook can't gate them (charter D11, REFUTED).

  The flat standalone `:media_mutate` pipeline (legacy `/media/*`,
  `/v1/media/:dataset/*`) has no `ResolveWorkspace` — it once fell straight to
  `AssignDefaultScope` (the seeded Default Workspace), so a quota check there
  would have misattributed every legacy write to one workspace. That hole
  (`bpb-flat-media-quota-hole`, charter D14) is now CLOSED by
  `DeriveWorkspaceFromToken`, which stamps `:current_workspace` from the caller's
  `api_token.workspace_id` BEFORE `AssignDefaultScope` (D30 — token-derive, not
  the ambiguous `dataset` slug). A nil-workspace_id token still falls back to the
  Default Workspace, so this plug meters the flat media write against the token's
  OWN workspace with no regression on the legacy path.

  ## Metering (charter D12)

  On an ALLOWED media write the plug emits one `[:barkpark, :media, :mutate]`
  telemetry event tagged with `workspace_id` — the media path has no
  `:telemetry.span` of its own, so this is the single point that meters it.
  Doc writes are already metered by the `[:barkpark, :content, :mutate]` span,
  so `:scoped_mutate` wires the plug WITHOUT `meter: :media` and emits nothing
  here (no double count). Pass `meter: :media` only on the media pipeline.

  ## Block reasons

    * suspended → 403 `workspace_suspended` (the audit line was written at
      suspend time by `Quota.suspend/2`; the gate does not re-emit).
    * over quota → 402 `quota_exceeded`; the gate writes a
      `workspace.quota_exceeded` audit line so the wall being hit is observable.
    * oversize batch → 422 `batch_too_large` (see below), written BEFORE the
      quota is consulted so an absurd batch is refused on shape, not on money.

  ## Room for the WHOLE batch, not room for one

  `Quota.check/1` answered "is there room for at least ONE more document". The
  request behind it carries an unbounded `mutations` list that
  `Content.Mutations.apply_mutations/3` applies in ONE transaction, so a single
  sequential request admitted at cap-1 overshot the cap by N-1
  (`acpc-bl-quota-batch-overshoot-unbounded`: cap 3, usage 2, 25 creates →
  usage 27). No race is needed and no fix to the TOCTOU race removes it.

  The gate now counts the request's ROOM-CONSUMING ops and asks
  `Quota.check(ws, needed)` — "room for N". Two independent bounds, both here:

    1. `@max_mutations` (1000) — a hard cap on `length(mutations)`,
       refused 422 `batch_too_large`. This bound holds even for an UNCAPPED
       (`quota: nil`) workspace, where the quota arm can never fire, and it also
       bounds the single unbounded `Repo.transaction`. The value is the repo's
       existing batch cap (`Barkpark.Plugins.Sheets.Session.max_ops_per_call/0`,
       1000) so the platform carries ONE number; the measured callers sit far
       under it (`bp migrate` 50 by constant, the largest committed seed fixture
       35, paperflow 1, sync applier 1-2 — full census in the PR body).
    2. `Quota.check(ws, needed)` — `usage + needed <= quota`.

  ### Which ops consume room

  `needed` counts ONLY the ops that can add a `documents` row:
  `create`, `createOrReplace`, `createIfNotExists`, `replace`, `publish`,
  `unpublish`. `delete`, `discardDraft` and `patch` are counted as ZERO — a
  document-count quota must never refuse a write that cannot raise the count,
  and refusing deletes at the cap would wedge a full workspace shut. A
  delete-only batch therefore passes even at `usage == quota` (a deliberate
  RELAXATION of the old one-token check, which refused it).

  The count is a conservative UPPER bound: a `createOrReplace` over an existing
  id consumes no room but is counted, so a near-full workspace can be refused a
  batch that would have fit. That is the fail-CLOSED direction, and it is the
  only direction a fence may err in.

  A request with no parsed `mutations` list — every media write, which uploads a
  single file — falls back to `needed = 1`, exactly the old behaviour.

  ### Rejected alternative: per-row quota inside the write transaction

  Option B was to evaluate the quota per mutation inside
  `Content.Mutations.apply_mutations/3`'s `Repo.transaction`. Rejected: it puts
  a `SELECT count(*)` on every row of every batch (N counts per request instead
  of one), it does NOT bound the transaction itself (an oversize batch still
  opens and then rolls back), it leaves the media path — which never enters
  `Content` — ungated, and it moves the tenancy fence out of the plug pipeline
  into the content engine, where the next caller of `apply_mutations/3` inherits
  it only by accident. The fence belongs at the door.

  ### Rejected alternative: a new `too_many_mutations` error code

  The refusal reuses the ALREADY-REGISTERED `batch_too_large` (422), whose
  meaning ("your batch exceeds this endpoint's cap — split and resend") and
  status are identical to what the sheets ops door emits. A new code would have
  added a variant to the public `Error.code` enum and to `docs/api-v1.md` §9 for
  no client-visible gain: nothing a caller does differs between the two.
  """

  import Plug.Conn

  alias Barkpark.Tenancy.Quota

  # The repo's one batch cap, shared with the sheets ops door
  # (Barkpark.Plugins.Sheets.Session.max_ops_per_call/0). NOT aliased across the
  # plugin boundary — a core-pipeline plug must not depend on an optional
  # plugin's module — so the number is restated here with its owner named.
  @max_mutations 1_000

  # Ops that can add a `documents` row. Everything else (delete, discardDraft,
  # patch) consumes ZERO room; see the moduledoc.
  @room_consuming_ops ~w(create createOrReplace createIfNotExists replace publish unpublish)

  @doc """
  The per-request mutation cap enforced by this gate (422 `batch_too_large`).
  """
  @spec max_mutations() :: pos_integer()
  def max_mutations, do: @max_mutations

  def init(opts), do: opts

  def call(conn, opts) do
    case conn.assigns[:current_workspace] do
      %Barkpark.Tenancy.Workspace{} = ws ->
        gate(conn, ws, opts)

      # No workspace resolved (share_public / anonymous-default paths already
      # ran ResolveWorkspace, or an unscoped route). Nothing to meter against —
      # let the downstream auth gates decide. Fail OPEN here, never on a nil.
      _ ->
        conn
    end
  end

  defp gate(conn, ws, opts) do
    case batch_demand(conn) do
      {:error, {:batch_too_large, n}} ->
        halt_with(conn, {:error, {:batch_too_large, n, @max_mutations}})

      {:ok, needed} ->
        quota_gate(conn, ws, opts, needed)
    end
  end

  defp quota_gate(conn, ws, opts, needed) do
    case Quota.check(ws, needed) do
      :ok ->
        meter(conn, ws, opts)

      {:error, :suspended} ->
        halt_with(conn, {:error, {:workspace_suspended, ws.suspended_reason}})

      {:error, :quota_exceeded} ->
        Quota.emit_quota_exceeded(ws)
        halt_with(conn, {:error, {:quota_exceeded, ws.quota}})
    end
  end

  # How many documents can this request add? Reads the ALREADY-PARSED body
  # (Plug.Parsers runs at the endpoint, before the router), so nothing is read
  # off the socket here and a controller that re-reads params sees the same map.
  # Anything that is not a `mutations` list — every media upload, and a
  # malformed body the controller will 400 anyway — falls back to 1, the
  # historical one-token check.
  defp batch_demand(conn) do
    case conn.body_params do
      %{"mutations" => mutations} when is_list(mutations) ->
        case length(mutations) do
          n when n > @max_mutations -> {:error, {:batch_too_large, n}}
          _ -> {:ok, count_room_consuming(mutations)}
        end

      _ ->
        {:ok, 1}
    end
  end

  defp count_room_consuming(mutations) do
    Enum.count(mutations, fn
      m when is_map(m) -> Enum.any?(@room_consuming_ops, &Map.has_key?(m, &1))
      _ -> false
    end)
  end

  # Media path has no span of its own — emit one metered event per allowed
  # media write. Doc pipeline passes no :media meter (its content span covers it).
  defp meter(conn, ws, opts) do
    if Keyword.get(opts, :meter) == :media do
      :telemetry.execute([:barkpark, :media, :mutate], %{count: 1}, %{workspace_id: ws.id})
    end

    conn
  end

  defp halt_with(conn, reason) do
    env = Barkpark.Content.Errors.to_envelope(reason, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
