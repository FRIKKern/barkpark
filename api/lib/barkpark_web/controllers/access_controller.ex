defmodule BarkparkWeb.AccessController do
  @moduledoc """
  JSON API for **airdrop grants** — the `access` capability noun. Wraps
  `Barkpark.Access` for the GRANTOR-driven surface (mint / list / show / revoke)
  and exposes the no-oracle CLAIM for the session/browser path.

  ## Routes & auth

    * `POST   /v1/access`        → `mint/2`   — grantor mints a grant
      (`[:api, :require_token]`; the no-escalation gate lives inside
      `Access.mint/2` — a token can only confer capabilities it holds in the
      body's workspace).
    * `GET    /v1/access`        → `index/2`  — grantor-scoped list for a
      workspace (`?workspace_id=`); the caller must be authorized in it.
    * `GET    /v1/access/:id`    → `show/2`   — grantor-or-workspace-admin read.
    * `DELETE /v1/access/:id`    → `revoke/2` — grantor-or-admin, idempotent.
    * `POST   /v1/access/claim`  → `claim/2`  — the SESSION path
      (`[:user_auth, :require_user]`): an authenticated user binds a grant
      addressed to their email.

  ## Field hygiene (SECURITY)

  Every grant rendered to JSON is field-WHITELISTED by `render_grant/1`; the
  raw-secret `link_token_hash` is NEVER emitted (nor is the raw token, except
  the one-time mint response where `Access.mint/2` returns it). The
  token-existence oracle `Access.lookup_by_token/1` is NEVER a verb.

  ## No-oracle claim

  `claim/2` funnels wrong-account / expired / revoked / used / nonexistent
  through ONE byte-identical JSON error via the SHARED `Access.ClaimFlow` — the
  same decision `BarkparkWeb.GrantController` (the browser flow) runs, so there
  is exactly one no-oracle contract, never re-improvised here.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Access
  alias Barkpark.Access.ClaimFlow
  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth

  # The ONLY grant fields ever serialized. `link_token_hash` (raw-secret hash) is
  # absent BY CONSTRUCTION — a new schema field is invisible until added here.
  @public_fields ~w(id grantor_id grantee_email grantee_user_id workspace_id
                     project_id dataset type doc_id capabilities single_use
                     expires_at claimed_at revoked_at inserted_at updated_at)a

  # Mint accepts only these from the request body. Whitelisting the INPUT blocks
  # mass-assignment of grantee_user_id / claimed_at / revoked_at (grantor_id and
  # link_token_hash are set server-side by Access.mint/2 regardless).
  @mint_fields ~w(grantee_email workspace_id project_id dataset type doc_id
                  capabilities single_use expires_at)

  # ── mint ──────────────────────────────────────────────────────────────────

  def mint(conn, params) do
    principal = conn.assigns[:api_token]
    attrs = Map.take(params, @mint_fields)

    case Access.mint(principal, attrs) do
      {:ok, %{grant: grant, token: raw}} ->
        conn
        |> put_status(:created)
        |> json(%{grant: render_grant(grant), token: raw})

      {:error, :forbidden} ->
        forbidden(conn, "you cannot mint a grant conferring capabilities you do not hold")

      {:error, %Ecto.Changeset{} = changeset} ->
        unprocessable(conn, changeset_message(changeset))
    end
  end

  # ── index (grantor-scoped list) ─────────────────────────────────────────────

  def index(conn, params) do
    principal = conn.assigns[:api_token]

    with workspace_id when is_binary(workspace_id) <- fetch_workspace_id(params),
         :ok <- Auth.authorize(principal, workspace_id, :read) do
      grants = Access.list_grants_for_workspace(workspace_id)
      json(conn, %{grants: Enum.map(grants, &render_grant/1)})
    else
      :missing ->
        unprocessable(conn, "workspace_id is required")

      _ ->
        forbidden(conn, "you are not authorized in that workspace")
    end
  end

  # ── show (grantor-or-admin) ─────────────────────────────────────────────────

  def show(conn, %{"id" => id}) do
    principal = conn.assigns[:api_token]

    case Access.get_grant(id) do
      nil ->
        not_found(conn)

      %Access.Grant{} = grant ->
        if authorized_manager?(principal, grant) do
          json(conn, %{grant: render_grant(grant)})
        else
          forbidden(conn, "only the grantor or a workspace admin may read this grant")
        end
    end
  end

  # ── revoke (grantor-or-admin, idempotent) ───────────────────────────────────

  def revoke(conn, %{"id" => id}) do
    principal = conn.assigns[:api_token]

    case Access.revoke(id, principal) do
      {:ok, grant} -> json(conn, %{grant: render_grant(grant)})
      {:error, :forbidden} -> forbidden(conn, "only the grantor or a workspace admin may revoke")
      {:error, :not_found} -> not_found(conn)
    end
  end

  # ── claim (session path, no-oracle) ─────────────────────────────────────────

  def claim(conn, %{"token" => token}) when is_binary(token) do
    conn = no_store(conn)

    case conn.assigns[:current_user] do
      %User{} = user ->
        case ClaimFlow.resolve(token, user) do
          {:ok, grant} -> json(conn, %{grant: render_grant(grant)})
          :invalid -> invalid_grant(conn)
        end

      _ ->
        # The session pipeline gates this route, so this is defensive only.
        invalid_grant(conn)
    end
  end

  def claim(conn, _params), do: conn |> no_store() |> invalid_grant()

  # ── mine (grantee's own active grants) ──────────────────────────────────────

  # List the ACTIVE grants bound to the authenticated grantee. `:current_user`
  # is resolved by the `:access_principal` pipeline from EITHER a login session
  # OR an OWNED api_token, so this lights up the terminal `bp access mine`. Each
  # grant is field-WHITELISTED by render_grant/1 (never link_token_hash).
  def mine(conn, _params) do
    conn = no_store(conn)

    case conn.assigns[:current_user] do
      %User{id: user_id} ->
        grants = Access.list_active_grants_for_grantee(user_id)
        json(conn, %{grants: Enum.map(grants, &render_grant/1)})

      _ ->
        # The :access_principal pipeline gates this route, so this is defensive.
        invalid_grant(conn)
    end
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp render_grant(%Access.Grant{} = grant) do
    grant
    |> Map.from_struct()
    |> Map.take(@public_fields)
  end

  # Grantor-or-workspace-admin — the same authority Access.revoke enforces.
  defp authorized_manager?(principal, %Access.Grant{} = grant) do
    principal_matches?(principal, grant.grantor_id) or
      Auth.authorize(principal, grant.workspace_id, :admin) == :ok
  end

  defp principal_matches?(%User{id: id}, grantor_id), do: id == grantor_id
  defp principal_matches?(%ApiToken{id: id}, grantor_id), do: id == grantor_id
  defp principal_matches?(_, _), do: false

  defp fetch_workspace_id(%{"workspace_id" => id}) when is_binary(id) and id != "", do: id
  defp fetch_workspace_id(_), do: :missing

  # The single no-oracle failure — byte-identical for every claim failure kind.
  defp invalid_grant(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{code: "invalid_grant", message: "This access link is invalid or has expired."}
    })
  end

  defp forbidden(conn, message) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: %{code: "forbidden", message: message}})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "grant not found"}})
  end

  defp unprocessable(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "unprocessable", message: message}})
  end

  defp changeset_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end
end
