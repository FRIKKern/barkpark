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

  # v1 structured error envelope (code + request_id + message) for every error
  # path — the same contract as the content endpoints. Was bare `%{error: "…"}`
  # strings that carried no request_id and no machine-keyable code.
  action_fallback BarkparkWeb.FallbackController

  alias Barkpark.Secrets

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
      case Secrets.put(name, value, actor: actor(conn), scope: scope) do
        {:ok, _rec} ->
          json(conn, %{ok: true})

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
