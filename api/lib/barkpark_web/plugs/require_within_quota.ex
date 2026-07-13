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
  """

  import Plug.Conn

  alias Barkpark.Tenancy.Quota

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
    case Quota.check(ws) do
      :ok ->
        meter(conn, ws, opts)

      {:error, :suspended} ->
        halt_with(conn, {:error, {:workspace_suspended, ws.suspended_reason}})

      {:error, :quota_exceeded} ->
        Quota.emit_quota_exceeded(ws)
        halt_with(conn, {:error, {:quota_exceeded, ws.quota}})
    end
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
