defmodule Barkpark.Audit do
  @moduledoc """
  The tenant-wide, append-only, tamper-evident audit event bus.

  `emit/1` is the ONLY write path. There is no update or delete: the table is
  immutable at the DB layer (a `BEFORE UPDATE/DELETE` trigger) and rows form a
  per-workspace sha256 hash chain (`hash = sha256(prev_hash <> canonical(row))`,
  see `Barkpark.Audit.Chain`). Silent tampering with history is therefore
  detectable via `verify_chain/1`.

  ## Why synchronous, not fire-and-forget

  Emit runs a single advisory-locked insert, atomic with the audited change
  when called inside the caller's transaction (the content mutate path). This
  is deliberate: a hash chain must be serialized to be correct, and an audit
  row must not be lost on a crash between request-return and a background
  write. The cost is one indexed insert under a per-workspace advisory lock —
  negligible latency, and it can never drift from the change it records.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.Audit.{Chain, Event}

  # Advisory-lock key prefix, folded into the hash so audit-chain locks never
  # collide with other advisory locks (e.g. the per-task locks) in the system.
  @lock_prefix "barkpark.audit.chain:"
  @nil_ws_key "\x00global"

  @doc """
  Append one event to the audit log. Accepts a map with:

    * `:category` (required) — one of `Barkpark.Audit.Event.categories/0`
    * `:action` (required) — the per-category verb
    * `:subject`, `:actor_type`, `:actor_id`, `:workspace_id`, `:project_id`,
      `:metadata` (all optional; `metadata` defaults to `%{}`)
    * `:occurred_at` (optional; stamped to now when absent)

  Serializes on a per-workspace advisory lock, chains the sha256 hash off the
  workspace's last row, and inserts. Returns `{:ok, %Event{}}` or
  `{:error, term}`. Safe to call inside an enclosing `Repo.transaction` — it
  opens a savepoint, so a failed emit rolls back only itself.
  """
  # @canonical capability:audit-emit aka:audit,trail,tamper,security-log
  @spec emit(map()) :: {:ok, Event.t()} | {:error, term()}
  def emit(attrs) when is_map(attrs) do
    fields = normalize(attrs)

    Repo.transaction(fn ->
      lock_chain(fields.workspace_id)
      prev = last_hash(fields.workspace_id)
      hash = Chain.hash(fields, prev)

      attrs =
        fields
        |> Map.put(:prev_hash, prev)
        |> Map.put(:hash, hash)

      case Repo.insert(Event.insert_changeset(attrs)) do
        {:ok, event} -> event
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Verify the hash chain for `workspace_id` (pass `nil` for the global/no-tenant
  chain). Returns `:ok` or `{:error, {:broken_at, id}}`.
  """
  @spec verify_chain(String.t() | nil) :: :ok | {:error, {:broken_at, term()}}
  def verify_chain(workspace_id) do
    Repo.all(
      from e in Event,
        where:
          fragment("? IS NOT DISTINCT FROM ?", e.workspace_id, type(^workspace_id, Ecto.UUID)),
        order_by: [asc: e.id]
    )
    |> Chain.verify()
  end

  @doc "The most recent audit events across all workspaces (admin activity view)."
  @spec recent(non_neg_integer()) :: [Event.t()]
  def recent(limit \\ 20) do
    Repo.all(from e in Event, order_by: [desc: e.id], limit: ^limit)
  end

  @doc "Recent audit events attributed to an organization (via metadata), newest first."
  @spec recent_for_org(binary(), non_neg_integer()) :: [Event.t()]
  def recent_for_org(org_id, limit \\ 20) when is_binary(org_id) do
    Repo.all(
      from e in Event,
        where: fragment("?->>'organization_id' = ?", e.metadata, ^org_id),
        order_by: [desc: e.id],
        limit: ^limit
    )
  end

  @doc "List events for a workspace, newest first (a simple read surface)."
  @spec list_for_workspace(String.t() | nil, keyword()) :: [Event.t()]
  def list_for_workspace(workspace_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Repo.all(
      from e in Event,
        where:
          fragment("? IS NOT DISTINCT FROM ?", e.workspace_id, type(^workspace_id, Ecto.UUID)),
        order_by: [desc: e.id],
        limit: ^limit
    )
  end

  # ── internals ──────────────────────────────────────────────────────────

  # Transaction-scoped advisory lock keyed on the workspace, so concurrent
  # emits for the SAME workspace serialize on the chain tail (and the empty
  # first-row case is safe) while different workspaces never contend.
  defp lock_chain(workspace_id) do
    # crc32 → 0..2^32-1, which fits a bigint (the single-arg lock form); the
    # two-int4 form would overflow for keys above 2^31.
    key = :erlang.crc32(@lock_prefix <> (workspace_id || @nil_ws_key))
    Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [key])
  end

  defp last_hash(workspace_id) do
    Repo.one(
      from e in Event,
        where:
          fragment("? IS NOT DISTINCT FROM ?", e.workspace_id, type(^workspace_id, Ecto.UUID)),
        order_by: [desc: e.id],
        limit: 1,
        select: e.hash
    ) || Chain.genesis()
  end

  defp normalize(attrs) do
    %{
      category: fetch_s(attrs, :category),
      action: fetch_s(attrs, :action),
      subject: fetch_s(attrs, :subject),
      actor_type: fetch_s(attrs, :actor_type),
      actor_id: fetch_s(attrs, :actor_id),
      workspace_id: fetch_s(attrs, :workspace_id),
      project_id: fetch_s(attrs, :project_id),
      metadata: get(attrs, :metadata) || %{},
      occurred_at: get(attrs, :occurred_at) || DateTime.utc_now()
    }
  end

  defp get(attrs, key), do: Map.get(attrs, key, Map.get(attrs, to_string(key)))

  defp fetch_s(attrs, key) do
    case get(attrs, key) do
      nil -> nil
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end
end
