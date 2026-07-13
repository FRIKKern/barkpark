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
  The write-admission decision for a workspace.

    * `{:error, :suspended}` — the hard suspend flag is set (checked first).
    * `{:error, :quota_exceeded}` — a cap is configured and the workspace's
      document count has reached it.
    * `:ok` — otherwise (including the common uncapped, un-suspended case).

  Reads the `suspended` flag off the passed struct (fresh from `ResolveWorkspace`
  at request time — no extra query); only a configured, non-nil `quota` triggers
  a count query.
  """
  @spec check(Workspace.t()) :: :ok | {:error, :suspended | :quota_exceeded}
  def check(%Workspace{suspended: true}), do: {:error, :suspended}

  def check(%Workspace{} = ws) do
    if within_quota?(ws), do: :ok, else: {:error, :quota_exceeded}
  end

  @doc """
  Whether the workspace is under its document-count quota.

  A suspended workspace is never within quota. A workspace with no `quota`
  (`NULL`) is unlimited → always within quota. Otherwise the live document count
  is compared against the cap.
  """
  @spec within_quota?(Workspace.t()) :: boolean()
  def within_quota?(%Workspace{suspended: true}), do: false
  def within_quota?(%Workspace{quota: nil}), do: true

  def within_quota?(%Workspace{id: id, quota: quota}) when is_integer(quota) do
    usage(id) < quota
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
  """
  @spec reinstate(Workspace.t()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def reinstate(%Workspace{} = ws) do
    ws
    |> Ecto.Changeset.change(%{suspended: false, suspended_reason: nil, suspended_at: nil})
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
