defmodule BarkparkWeb.SecretController do
  @moduledoc """
  Admin-only REST endpoints for cloud run-secrets, serving BOTH tiers of the
  two-tier store (connectors D191–D199):

    * FLAT `/v1/secrets` (`:api` + `:require_admin`) — the instance-GLOBAL
      tier, byte-identical to its pre-scoping behavior.
    * SCOPED `/w/:workspace_slug/p/:project_slug/v1/secrets`
      (`:scoped_api` + `:scoped_admin`) — the per-WORKSPACE tier; a workspace
      admin manages only their workspace's secrets, never the global tier or
      another workspace's.

  The tier is resolved ONCE up front (`resolve_scope/1`) and keys off the
  ROUTE, not the assigns: the flat `:api` pipeline's `AssignDefaultScope`
  puts the migration-seeded Default workspace into `conn.assigns` too, so an
  assign-presence check would silently re-tier the flat surface.

  Routes are admin-gated, so a non-admin caller receives 403 and an
  un-authenticated caller 401 (403/404 on the scoped mirror).

  Unlike `PluginSettingsController` (whose `show` MASKS), `GET …/:name`
  REVEALS the unmasked value and writes a `"reveal"` audit row — that's the
  whole point: an authenticated admin can always retrieve a run-secret. The
  list endpoint stays masked.
  """

  use BarkparkWeb, :controller

  import Ecto.Query, warn: false

  # v1 structured error envelope (code + request_id + message) for every error
  # path — the same contract as the content endpoints. Was bare `%{error: "…"}`
  # strings that carried no request_id and no machine-keyable code.
  action_fallback BarkparkWeb.FallbackController

  alias Barkpark.Repo
  alias Barkpark.Secrets
  alias Barkpark.Secrets.SecretAudit

  # `GET …/:name/audit` pagination — newest-first over the write-only audit
  # log. Bounded so a caller can never pull the whole table in one request; the
  # window rides the [workspace_id, inserted_at] index (migration
  # 20260717070000).
  @default_audit_limit 50
  @max_audit_limit 200

  def index(conn, _params) do
    with {:ok, scope} <- resolve_scope(conn) do
      json(conn, %{secrets: Secrets.list(scope)})
    end
  end

  def show(conn, %{"name" => name}) do
    with {:ok, scope} <- resolve_scope(conn),
         {:ok, value} <- Secrets.reveal(name, actor: actor(conn), scope: scope) do
      json(conn, %{name: name, value: value})
    else
      {:error, :not_found} -> {:error, {:not_found, "secret not found"}}
      {:error, {:not_found, _}} = err -> err
    end
  end

  def update(conn, %{"name" => name, "value" => value}) when is_binary(value) do
    with {:ok, scope} <- resolve_scope(conn) do
      # RECEIPT LAW (pds wave 39 residue): the emitted value DESCENDS FROM THE
      # WRITE RETURN. `Secrets.put/3` already hands back the persisted
      # `SecretRecord` and this discarded it for a bare literal. `ok` now derives
      # from the row's own `updated_at`, and `id` is the store's surrogate
      # binary_id — neither appears anywhere in the request, so reverting to the
      # bare success map drops both keys and the differential reds.
      #
      # NO CIPHERTEXT, EVER: `value` is deliberately absent. `show/2` is the only
      # verb that reveals a secret, and it writes a `"reveal"` audit row to do
      # it — a receipt that leaked the value here would reveal without the stamp.
      case Secrets.put(name, value, actor: actor(conn), scope: scope) do
        {:ok, rec} ->
          json(conn, %{
            ok: not is_nil(rec.updated_at),
            id: rec.id,
            name: rec.name,
            updated_at: rec.updated_at
          })

        {:error, %Ecto.Changeset{}} = err ->
          err
      end
    end
  end

  def update(_conn, _params), do: {:error, :malformed}

  def delete(conn, %{"name" => name}) do
    with {:ok, scope} <- resolve_scope(conn),
         :ok <- Secrets.delete(name, actor: actor(conn), scope: scope) do
      json(conn, %{ok: true})
    else
      {:error, :not_found} -> {:error, {:not_found, "secret not found"}}
      {:error, {:not_found, _}} = err -> err
    end
  end

  @doc """
  The audit trail for `name` within the caller's tier — the read side of the
  write-only `secrets_audit` log (`set`/`reveal`/`delete` stamps). Rows are
  MASKED: metadata only (action, actor, workspace_id, inserted_at), NEVER a
  secret value — the audit schema stores no ciphertext, so there is nothing to
  reveal. Newest-first, paginated (`?limit=&offset=`).

  Tenant-walled through the same `resolve_scope/1` D199 guard as every other
  verb: the flat route reads the GLOBAL tier (`workspace_id IS NULL`), the
  scoped route reads ONLY the caller's workspace. A cross-tenant read — a
  workspace admin querying a name that only exists in another tier — is
  indistinguishable from a name that was never touched: an opaque empty list
  (and a forged/unresolved scope folds into an opaque 404, never a 500).

  No 404 on an unknown name: the audit trail outlives the secret (a `delete`
  stamps a row after the secret is gone), so an empty list is the honest empty
  state, not an error.
  """
  def audit(conn, %{"name" => name} = params) do
    with {:ok, scope} <- resolve_scope(conn) do
      {limit, offset} = page(params)

      rows =
        SecretAudit
        |> where([a], a.name == ^name)
        |> scope_audit(scope)
        |> order_by([a], desc: a.inserted_at)
        |> limit(^limit)
        |> offset(^offset)
        |> Repo.all()
        |> Enum.map(&audit_view/1)

      json(conn, %{name: name, audit: rows, limit: limit, offset: offset})
    end
  end

  # Tier gate for the audit read — mirrors `Barkpark.Secrets.scope_secrets/2`:
  # `:global` is an EXPLICIT `IS NULL` arm (never all-rows), a workspace binary
  # reads only that tenant, anything else fails closed to zero rows. `scope` is
  # already `:global` or a `Repo.uuid_or_nil/1`-guarded binary here (resolve_scope
  # rejects everything else with an opaque 404), so the fail-closed clause is
  # defense-in-depth.
  defp scope_audit(query, :global), do: where(query, [a], is_nil(a.workspace_id))

  defp scope_audit(query, workspace_id) when is_binary(workspace_id),
    do: where(query, [a], a.workspace_id == ^workspace_id)

  defp scope_audit(query, _fail_closed), do: where(query, false)

  # Metadata-only projection — the audit row carries no secret value, so there
  # is nothing to mask; we simply never surface ciphertext.
  defp audit_view(%SecretAudit{
         action: action,
         actor: actor,
         workspace_id: workspace_id,
         inserted_at: inserted_at
       }) do
    %{action: action, actor: actor, workspace_id: workspace_id, inserted_at: inserted_at}
  end

  defp page(params) do
    limit =
      params
      |> Map.get("limit")
      |> to_int(@default_audit_limit)
      |> clamp(1, @max_audit_limit)

    offset =
      params
      |> Map.get("offset")
      |> to_int(0)
      |> max(0)

    {limit, offset}
  end

  defp to_int(nil, default), do: default
  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _rest} -> n
      :error -> default
    end
  end

  defp to_int(_value, default), do: default

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  # D199: resolve the tier ONCE up front, keyed off the ROUTE. The flat route
  # (no :workspace_slug path param) is pinned to :global — NEVER the
  # `current_workspace` assign, which AssignDefaultScope populates with the
  # Default workspace on flat routes too. The scoped route threads the
  # resolved workspace id, guarded through `Repo.uuid_or_nil/1` BEFORE it
  # reaches the Secrets read/write paths: they take scope as a raw binary and
  # a non-UUID raises `Ecto.Query.CastError` — a 500 (see
  # secrets_castgap_contract_test.exs). A forged/garbage id and a scoped
  # route without a resolved workspace both fold into an opaque 404 on EVERY
  # verb; `{:error, :invalid_scope}` never reaches the wire
  # (Content.Errors has no clause for it — its catch-all is a 500).
  defp resolve_scope(conn) do
    if Map.has_key?(conn.path_params, "workspace_slug") do
      with %{id: id} <- conn.assigns[:current_workspace],
           uuid when is_binary(uuid) <- Barkpark.Repo.uuid_or_nil(id) do
        {:ok, uuid}
      else
        _ -> {:error, {:not_found, "secret not found"}}
      end
    else
      {:ok, :global}
    end
  end

  defp actor(conn) do
    case conn.assigns[:api_token] do
      %{id: id} -> to_string(id)
      _ -> nil
    end
  end
end
