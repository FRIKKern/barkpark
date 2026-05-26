defmodule Barkpark.Auth do
  @moduledoc "Context for API token authentication."

  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  def verify_token(raw_token) do
    hash = ApiToken.hash_token(raw_token)
    now = DateTime.utc_now()

    # Revocation + expiry are enforced in the WHERE clause, not post-filter:
    # a revoked or expired token must look identical to a missing one
    # (`{:error, :unauthorized}`), with no opportunity to leak its existence.
    ApiToken
    |> where([t], t.token_hash == ^hash)
    |> where([t], is_nil(t.revoked_at))
    |> where([t], is_nil(t.expires_at) or t.expires_at > ^now)
    |> Repo.one()
    |> case do
      nil -> {:error, :unauthorized}
      token -> {:ok, token}
    end
  end

  @doc """
  Revoke an API token — sets `revoked_at` to now so `verify_token/1` rejects
  it without a DB delete. Accepts an `ApiToken` struct or a token id. Idempotent
  on an already-revoked token (re-stamps `revoked_at`). The revocation primitive
  — no HTTP route is wired yet.
  """
  @spec revoke_token(ApiToken.t() | binary()) ::
          {:ok, ApiToken.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def revoke_token(%ApiToken{} = token) do
    token
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  def revoke_token(token_id) when is_binary(token_id) do
    case Repo.get(ApiToken, token_id) do
      nil -> {:error, :not_found}
      token -> revoke_token(token)
    end
  end

  @doc """
  Mint an API token. When `workspace_id` is given (the tenancy-aware path),
  the token is bound to that workspace AND a `Barkpark.Tenancy.Membership`
  row is created in the same transaction — role derived from permissions
  ("admin" perm → "admin", else "member"). The token + membership commit
  atomically, so a failed membership insert rolls the token back.

  When `workspace_id` is `nil` the token falls back to the seeded Default
  Workspace if one exists (the backfill's target); when no Default Workspace
  exists the token is created un-bound (no membership) for back-compat with
  pre-tenancy callers and the existing test suite.
  """
  def create_token(raw_token, label, dataset, permissions, workspace_id \\ nil) do
    ws_id = workspace_id || default_workspace_id()

    token_attrs = %{
      token_hash: ApiToken.hash_token(raw_token),
      label: label,
      dataset: dataset,
      permissions: permissions,
      workspace_id: ws_id
    }

    if is_nil(ws_id) do
      %ApiToken{}
      |> ApiToken.changeset(token_attrs)
      |> Repo.insert()
    else
      insert_token_with_membership(token_attrs, ws_id, permissions)
    end
  end

  defp insert_token_with_membership(token_attrs, ws_id, permissions) do
    role = TenancyAuth.role_for_permissions(permissions)

    Repo.transaction(fn ->
      with {:ok, token} <- %ApiToken{} |> ApiToken.changeset(token_attrs) |> Repo.insert(),
           {:ok, _membership} <- TenancyAuth.create_membership(ws_id, token.id, role) do
        token
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp default_workspace_id do
    case Tenancy.get_default_workspace() do
      nil -> nil
      ws -> ws.id
    end
  end

  def list_tokens(dataset) do
    ApiToken
    |> where([t], t.dataset == ^dataset)
    |> Repo.all()
  end

  def has_permission?(token, permission) do
    permission in token.permissions
  end
end
