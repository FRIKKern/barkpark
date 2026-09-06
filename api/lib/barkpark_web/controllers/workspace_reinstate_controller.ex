defmodule BarkparkWeb.WorkspaceReinstateController do
  @moduledoc """
  `POST /v1/admin/workspaces/:slug/reinstate` — the operator verb that lifts a
  workspace suspension. The FIRST caller of `Barkpark.Tenancy.Quota.reinstate/1`
  reachable from outside the module (task-7ab3d03b49606f83).

  ## The hole this closes

  `Barkpark.Tenancy.Workers.PlaygroundReaper` suspends every expired
  `tier = "playground"` workspace once a minute (Stage 1,
  `Quota.suspend(ws, "playground_expired")`), write-blocks it for a 24h grace
  window, and then hard-DELETES it (Stage 2). Two places in the tree told the
  user a rescue existed:

    * `playground_reaper.ex` moduledoc — "`bp go-live` can still `reinstate/1`
      it." `bp go-live` provisions a managed cloud instance; `grep -i reinstate
      -- internal/` is empty. It has never called `reinstate/1`.
    * `Barkpark.Content.Errors` — "This workspace is suspended — no writes are
      accepted until an operator reinstates it."

  Before this route `Quota.reinstate/1` had ZERO callers in `lib/`: the only
  exit from the suspended state was `iex` or raw SQL. The grace window existed
  for an action nothing could perform.

  ## THE RULING (orchestrator, binding), quoted verbatim

  > OPTION (a) — instance-operator only. The reinstate route rides the admin
  > tier: `pipe_through([:api, :require_admin, :require_platform_operator])`,
  > exactly like the `/v1/status/incidents` and `/v1/admin/*` groups in
  > api/lib/barkpark_web/router.ex (~line 2077 and 2145 on origin/main). NO
  > workspace-owner self-reinstate path. Reasoning: the playground expired BY
  > POLICY, and a self-service loop around a TTL lets the subject of a limit
  > lift it, which is not a permit widening — it is removing the limit. The
  > smallest permit that fixes the actual defect (a suspended workspace being
  > unrescuable inside its own grace window).

  So this route is `:instance_global` in
  `BarkparkWeb.RequireAdminRouteCensusTest`'s vocabulary and is classified
  there: it takes a `:slug` selector, but lifting a policy suspension is an
  instance-operator primitive, never something the suspended tenant's own admin
  may do. A workspace admin with the `admin` bit and no operator standing gets
  the plug's `403 {"error": {"code": "forbidden", "required":
  "platform_operator"}}` on an ARMED instance.

  ## Why the TTL must move too — the re-suspend defect

  `PlaygroundReaper.run_suspend_stage/1` selects on
  `tier = 'playground' AND expires_at < now() AND suspended = false`. A bare
  `Quota.reinstate/1` flips `suspended` to false and leaves `expires_at` in the
  past — so the reaper's NEXT TICK (once a minute) re-suspends the workspace,
  and the rescue survives under 60 seconds. A reinstate that a timer undoes is
  not a rescue, so this route also pushes an ALREADY-ELAPSED `expires_at`
  forward by the playground mint TTL (48h, `PlaygroundController`'s
  `@ttl_seconds`) — and only then. Concretely:

    * `tier = "playground"` with `expires_at` in the PAST → extended to
      `now + 48h`, `"ttl_extended": true`. The workspace gets a fresh window,
      the reaper's stage-1 predicate no longer matches it, and the operator has
      granted time rather than permanence.
    * anything else (a future `expires_at`, a `NULL` one, a non-playground
      workspace) → `expires_at` UNTOUCHED, `"ttl_extended": false`. A NULL
      never matched `expires_at < now()` in the first place.

  Stage 2 needs no help: it selects on `suspended = true`, and
  `Tenancy.delete_workspace/1`'s id overload re-fetches inside the delete, so a
  reinstate mid-sweep is already a clean `{:error, :not_found}` no-op
  (playground_reaper.ex).

  ## Wire contract

  `200 {"slug", "suspended", "suspended_reason", "suspended_at", "tier",
  "expires_at", "ttl_extended"}` — the workspace's suspension state AFTER the
  call, so the caller reads the outcome rather than inferring it. Idempotent: a
  reinstate of a workspace that was never suspended is a 200 with
  `"suspended": false`. `404 not_found` for an unknown slug.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Quota
  alias Barkpark.Tenancy.Workspace

  # The playground mint TTL, mirrored from `PlaygroundController.@ttl_seconds`.
  # Duplicated as a literal rather than imported so this controller's file set
  # stays disjoint from the provisioning slice's; the two are pinned together by
  # `WorkspaceReinstateControllerTest`.
  @playground_ttl_seconds 48 * 60 * 60

  @doc """
  Lift the suspension on the workspace named by `:slug`.

  Calls `Quota.reinstate/1` (its first non-test caller), then re-arms the
  playground TTL if — and only if — the reaper would otherwise re-suspend the
  row on its next tick. See the moduledoc.
  """
  def create(conn, %{"slug" => slug}) do
    case Tenancy.get_workspace_by_slug(slug) do
      nil ->
        send_error(conn, {:not_found, "workspace not found"}, nil)

      %Workspace{} = ws ->
        case Quota.reinstate(ws) do
          {:ok, reinstated} ->
            {fresh, extended?} = rearm_ttl(reinstated)
            json(conn, payload(fresh, extended?))

          # `reinstate/1` writes booleans/nils through a raw changeset, so the
          # only way here is the row moving under us (a concurrent delete by the
          # reaper's Stage 2, a stale struct). 409 is the honest slot — the
          # canonical `conflict` code with an accurate message, the same
          # override shape `RequirePlatformOperator.deny/1` uses.
          {:error, %Ecto.Changeset{}} ->
            send_error(conn, :conflict, "workspace could not be reinstated")
        end
    end
  end

  # ── internals ──────────────────────────────────────────────────────────

  # Push an ALREADY-ELAPSED playground TTL forward so the reaper's stage-1
  # predicate (tier = 'playground' AND expires_at < now() AND NOT suspended)
  # stops matching. Every other shape is left exactly as it was.
  defp rearm_ttl(%Workspace{tier: "playground", expires_at: %DateTime{} = expires_at} = ws) do
    now = DateTime.utc_now()

    if DateTime.compare(expires_at, now) == :lt do
      fresh = DateTime.add(now, @playground_ttl_seconds, :second)

      case Quota.set_expires_at(ws, fresh) do
        {:ok, updated} -> {updated, true}
        {:error, _} -> {ws, false}
      end
    else
      {ws, false}
    end
  end

  defp rearm_ttl(%Workspace{} = ws), do: {ws, false}

  defp payload(%Workspace{} = ws, extended?) do
    %{
      slug: ws.slug,
      suspended: ws.suspended,
      suspended_reason: ws.suspended_reason,
      suspended_at: ws.suspended_at,
      tier: ws.tier,
      expires_at: ws.expires_at,
      ttl_extended: extended?
    }
  end

  defp send_error(conn, reason, message) do
    env = Barkpark.Content.Errors.to_envelope({:error, reason}, conn)
    body = if message, do: Map.put(env, :message, message), else: env

    conn
    |> put_status(env.status)
    |> json(%{error: Map.delete(body, :status)})
  end
end
