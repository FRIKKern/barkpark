defmodule Barkpark.Tenancy.Quota do
  @moduledoc """
  Per-workspace write quota + suspension — the state behind the mutate-seam
  gate `BarkparkWeb.Plugs.RequireWithinQuota` (perfect-plan-build W1, charter
  D11/D13).

  Deliberately a NEW module, NOT `Barkpark.Tenancy`, so the quota slice's file
  set stays disjoint from the delete/audit slices and the three build in
  parallel (charter D16).

  ## What "quota" means

  `workspaces.quota` is a **document-count cap** for the workspace. `NULL` means
  unlimited — the default, so an unconfigured workspace is never blocked. When a
  cap is set, `within_quota?/1` compares it against the live count of documents
  scoped to the workspace.

  ## Two block reasons, one gate

    * **suspended** — a hard operator flag (`suspended: true`). `suspend/2` flips
      it, stamps the reason + timestamp, and writes a `workspace.suspended` line
      to the tamper-evident audit chain. Highest precedence: a suspended
      workspace is over quota regardless of count.
    * **over quota** — document count has reached the cap. The gate emits a
      `workspace.quota_exceeded` audit line at the blocking seam (see
      `emit_quota_exceeded/1`) so an operator can see the wall being hit.

  `check/1` folds both into one `:ok | {:error, :suspended | :quota_exceeded}`
  the plug maps to a JSON error envelope.
  """

  import Ecto.Query, warn: false

  alias Barkpark.{Audit, Repo}
  alias Barkpark.Tenancy.Workspace

  @audit_category "access"

  @doc """
  The write-admission decision for a workspace, for a request that will consume
  `needed` room-consuming writes (default `1` — the historical one-token check).

    * `{:error, :suspended}` — the hard suspend flag is set (checked first).
    * `{:error, :quota_exceeded}` — a cap is configured and the workspace's
      document count leaves less than `needed` room.
    * `:ok` — otherwise (including the common uncapped, un-suspended case, and
      `needed == 0`: a batch that only deletes/patches never consumes room, so a
      quota must never refuse it).

  Reads the `suspended` flag off the passed struct (fresh from `ResolveWorkspace`
  at request time — no extra query); only a configured, non-nil `quota` triggers
  a count query.

  `check(ws)` is `check(ws, 1)` and is byte-identical to the pre-batch-cap
  behaviour: `usage + 1 <= quota` ⟺ `usage < quota`.
  """
  @spec check(Workspace.t(), non_neg_integer()) ::
          :ok | {:error, :suspended | :quota_exceeded}
  def check(ws, needed \\ 1)

  def check(%Workspace{suspended: true}, _needed), do: {:error, :suspended}

  def check(%Workspace{} = ws, needed) when is_integer(needed) and needed >= 0 do
    if room_for?(ws, needed), do: :ok, else: {:error, :quota_exceeded}
  end

  @doc """
  Whether the workspace is under its document-count quota.

  A suspended workspace is never within quota. A workspace with no `quota`
  (`NULL`) is unlimited → always within quota. Otherwise the live document count
  is compared against the cap.
  """
  @spec within_quota?(Workspace.t()) :: boolean()
  def within_quota?(%Workspace{} = ws), do: room_for?(ws, 1)

  @doc """
  Whether the workspace has room for `needed` MORE documents.

  This is the invariant the batch gate needs and `within_quota?/1` could not
  express: "room for at least one more" admitted a request that then wrote N,
  overshooting the cap by N-1. A suspended workspace has room for nothing; an
  uncapped (`NULL` quota) workspace has room for everything; `needed == 0` (a
  delete-only / patch-only batch) is always admitted — a document-count quota
  has no business refusing a write that cannot raise the count.
  """
  @spec room_for?(Workspace.t(), non_neg_integer()) :: boolean()
  def room_for?(%Workspace{suspended: true}, _needed), do: false
  def room_for?(%Workspace{quota: nil}, _needed), do: true
  def room_for?(%Workspace{}, 0), do: true

  def room_for?(%Workspace{id: id, quota: quota}, needed)
      when is_integer(quota) and is_integer(needed) and needed > 0 do
    usage(id) + needed <= quota
  end

  @doc """
  Live document count for the workspace — the quota's usage numerator.
  """
  @spec usage(binary()) :: non_neg_integer()
  def usage(workspace_id) when is_binary(workspace_id) do
    Repo.aggregate(
      from(d in "documents", where: d.workspace_id == type(^workspace_id, :binary_id)),
      :count
    )
  end

  @doc """
  Suspend a workspace: set the flag, stamp the reason + `suspended_at`, and
  write a `workspace.suspended` event to the audit chain. Idempotent-safe — a
  second suspend restamps the reason and appends a fresh audit line.

  Returns `{:ok, %Workspace{}}` or `{:error, Ecto.Changeset.t()}`.
  """
  @spec suspend(Workspace.t(), String.t()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def suspend(%Workspace{} = ws, reason) when is_binary(reason) do
    changeset =
      ws
      |> Ecto.Changeset.change(%{
        suspended: true,
        suspended_reason: reason,
        suspended_at: DateTime.utc_now()
      })

    case Repo.update(changeset) do
      {:ok, updated} ->
        emit_suspended(updated, reason)
        {:ok, updated}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Lift a suspension: clear the flag/reason/timestamp. Additive counterpart to
  `suspend/2`; does NOT emit an audit line here (reserved for a future
  reinstate-audit slice). Returns `{:ok, %Workspace{}}`.

  Called by `BarkparkWeb.WorkspaceReinstateController`
  (`POST /v1/admin/workspaces/:slug/reinstate`, instance-operator only). NOTE
  what it deliberately does NOT do: it never touches `expires_at`, so on a
  `tier = "playground"` row whose TTL has already elapsed the reaper's stage-1
  predicate still matches and the next tick re-suspends it. A caller lifting a
  TTL suspension must pair this with `set_expires_at/2` — the controller does.
  """
  @spec reinstate(Workspace.t()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def reinstate(%Workspace{} = ws) do
    ws
    |> Ecto.Changeset.change(%{suspended: false, suspended_reason: nil, suspended_at: nil})
    |> Repo.update()
  end

  @doc """
  Move (or clear) the workspace's TTL — the `expires_at` the playground reaper
  scans.

  The companion `reinstate/1` needs: `PlaygroundReaper.run_suspend_stage/1`
  selects on `tier = 'playground' AND expires_at < now() AND NOT suspended`, so
  clearing `suspended` alone leaves the row eligible again and the next tick (one
  a minute) re-suspends it. A caller that lifts a TTL suspension must therefore
  also move the TTL, or the rescue lasts under 60 seconds.

  Same raw-changeset write as `set_quota/2` and `reinstate/1` (`change/2` writes
  the field directly). `nil` clears the TTL to "never expires". Emits no audit
  line. Returns `{:ok, %Workspace{}}` or `{:error, Ecto.Changeset.t()}`.
  """
  @spec set_expires_at(Workspace.t(), DateTime.t() | nil) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def set_expires_at(%Workspace{} = ws, at) when is_nil(at) or is_struct(at, DateTime) do
    ws
    |> Ecto.Changeset.change(%{expires_at: at})
    |> Repo.update()
  end

  @doc """
  Set (or clear) the workspace's document-count cap. An integer writes the cap;
  `nil` clears it back to unlimited (`NULL`) — the two documented quota states.

  `workspaces.quota` is deliberately NOT in the changeset cast whitelist (D13),
  so this uses the same raw-changeset bypass as `suspend/2`
  (`Ecto.Changeset.change/2` writes the field directly, dodging the cast). Emits
  NO audit line — mirroring `reinstate/1`, a quota-set is an operator config
  knob, not a security event. Returns `{:ok, %Workspace{}}` or
  `{:error, Ecto.Changeset.t()}`.
  """
  @spec set_quota(Workspace.t(), non_neg_integer() | nil) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def set_quota(%Workspace{} = ws, cap) when is_nil(cap) or is_integer(cap) do
    ws
    |> Ecto.Changeset.change(%{quota: cap})
    |> Repo.update()
  end

  @doc """
  Append a `workspace.quota_exceeded` line to the audit chain. Called by the
  gate at the blocking seam so the wall being hit is observable. Best-effort:
  an audit failure never changes the caller's control flow.
  """
  @spec emit_quota_exceeded(Workspace.t()) :: :ok
  def emit_quota_exceeded(%Workspace{id: id, quota: quota}) do
    Audit.emit(%{
      category: @audit_category,
      action: "workspace.quota_exceeded",
      subject: "workspace:#{id}",
      workspace_id: id,
      metadata: %{"quota" => quota}
    })

    :ok
  end

  defp emit_suspended(%Workspace{id: id}, reason) do
    Audit.emit(%{
      category: @audit_category,
      action: "workspace.suspended",
      subject: "workspace:#{id}",
      workspace_id: id,
      metadata: %{"reason" => reason}
    })

    :ok
  end
end
