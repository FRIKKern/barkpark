defmodule BarkparkWeb.FleetSupportTokenController do
  @moduledoc """
  Admin-gated mint + revoke of a per-SUPPORT ledger token (Personal Dev Fleet,
  Wave C — PDF-D57/D60).

  Two endpoints, both mounted under `[:api, :require_admin]` (see `router.ex`):

    * `POST /v1/fleet/support-tokens` `{"name": string}` → `201 {token, token_id,
      name}` — mints a WRITE-capable `api_token` (label `fleet-support-<name>`)
      so a remote support machine can claim/pulse/stamp/close tasks on the main's
      ledger as a DISTINCT, attributable actor. The raw secret is returned ONCE
      in the 201 body and is never recoverable after (only its SHA-256 hash is
      persisted) — same one-time-return contract as every other mint here.
    * `DELETE /v1/fleet/support-tokens/:token_id` → `200 {token_id, revoked: true}`
      — revokes the token (`Auth.revoke_token/1` stamps `revoked_at`, so
      `verify_token/1` rejects it thereafter). `404` on an unknown/garbage id.

  WHY write is fine here (contrast `TokenController`, which is deliberately
  read-only): the admin gate governs WHO may mint, not the scope of the minted
  token. A support's write authority is intended — it exists to do work on the
  ledger — and is made REMOVABLE by the revoke endpoint at teardown. Per PDF-D57
  the fleet/task verbs are bearer-only by design; this controller adds NO
  token-scope machinery.

  ## Revoke confinement (arpss / SECURITY)

  `Barkpark.Auth.revoke_token/1` is an UNSCOPED primitive — it resolves any
  `api_tokens` row by raw id, and 9+ of its call sites have no HTTP actor, so it
  must stay that way. The confinement therefore lives HERE, in the one place
  that has a caller: `DELETE /:token_id` resolves the target row FIRST and
  revokes it only when BOTH hold —

    1. **FAMILY** — the row's label carries the `fleet-support-` prefix this
       controller's own mint writes. Without it the admin gate was a global
       credential kill switch: any UUID in `api_tokens` (another tenant's PAT, a
       share EDIT token, a chat/connector token, another admin's token) was a
       valid target for this route.
    2. **OBJECT AUTHZ** — the caller is a workspace ADMIN of the TARGET ROW's
       workspace, via the canonical `Barkpark.Tenancy.Auth.workspace_admin?/2`
       chokepoint (membership ROLE, not the token's global `permissions[]`). The
       `:require_admin` pipeline is instance-wide and workspace-blind, so a
       workspace-A-bound admin token passed it and could revoke workspace-B rows.

  Every denial — malformed id, missing row, wrong family, foreign workspace — is
  the SAME 404 `no token with that id`, byte-identical to a missing row, so an
  opaque token id never becomes an existence oracle. A row with a NULL
  `workspace_id` is not revocable through this surface (nil is a denial, never a
  pass).

  OPERATOR CONTRACT (unchanged for the actor this route exists to serve, but
  worth stating because the CLI reads a 404 as "already gone"): `create/2` binds
  the minted token to `conn.assigns[:current_workspace]`, which on this FLAT
  route is the seeded Default (`AssignDefaultScope`). So the admin who can mint
  here can revoke here whenever it holds an admin/owner membership in that same
  workspace — which `Auth.create_token/5` writes for every admin token minted
  into it. A globally-`admin` token with NO membership in the target's workspace
  is exactly the workspace-A-bound attacker of the finding, and is denied.

  The raw token is NEVER logged.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # A support token exists to work the ledger: read to poll ready tasks, write to
  # claim/pulse/stamp/close them. NOT admin — it can never mint more tokens.
  @support_permissions ~w(read write)

  # THE support-token family discriminator. `api_tokens` has no `kind` column
  # that separates a support token from any other bearer (`kind` is the
  # api/ticket TIER, not the family), so the label prefix IS the family — and it
  # is declared ONCE here so the mint that WRITES it and the revoke that ASSERTS
  # it can never drift apart.
  @support_label_prefix "fleet-support-"

  @doc """
  Mint a write-capable support token.

  Body: `{"name": string}` (required, non-empty). The stored label is
  `fleet-support-<name>`; the token is bound to the admin's resolved workspace
  (falling back to the seeded Default via `Auth.create_token/5`) on the
  `production` dataset.

  201 → `{"token": raw, "token_id": id, "name": name}`.
  """
  def create(conn, params) do
    case fetch_name(params) do
      {:ok, name} ->
        raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        label = @support_label_prefix <> name
        workspace_id = conn.assigns[:current_workspace] && conn.assigns[:current_workspace].id

        case Auth.create_token(raw, label, "production", @support_permissions, workspace_id) do
          {:ok, token} ->
            conn
            |> put_status(:created)
            |> json(%{token: raw, token_id: token.id, name: name})

          {:error, _reason} ->
            unprocessable(conn, "could not mint support token")
        end

      {:error, :missing_name} ->
        unprocessable(conn, "name is required and must be a non-empty string")
    end
  end

  @doc """
  Revoke a SUPPORT token by id — confined (see the @moduledoc's "Revoke
  confinement" section). The target row must be in the `fleet-support-` family
  AND live in a workspace the caller admins.

  Idempotent-safe on the caller's side: an unknown or malformed id is a clean
  `404` (never a 500 — the `:binary_id` cast is guarded by `Repo.uuid_or_nil/1`
  before any `Repo.get`). Every denial is that SAME 404, so the response never
  distinguishes "no such row" from "not yours" / "not a support token".

  200 → `{"token_id": id, "revoked": true}`.
  """
  def delete(conn, %{"token_id" => token_id}) do
    case revocable_target(conn, token_id) do
      {:ok, %ApiToken{} = target} ->
        # Hand the RESOLVED row to the primitive (its `%ApiToken{}` arm), not the
        # raw id — a re-lookup by id would reopen the unscoped resolution this
        # guard exists to close.
        case Auth.revoke_token(target) do
          {:ok, revoked} ->
            json(conn, %{token_id: revoked.id, revoked: true})

          {:error, _changeset} ->
            unprocessable(conn, "could not revoke token")
        end

      :error ->
        not_found(conn, "no token with that id")
    end
  end

  # Resolve `token_id` to a row this caller may revoke, or `:error`. The four
  # failure modes (uncastable id, missing row, wrong family, foreign workspace)
  # deliberately COLLAPSE into one `:error` so the caller cannot tell them apart.
  defp revocable_target(conn, token_id) do
    with id when is_binary(id) <- Repo.uuid_or_nil(token_id),
         %ApiToken{} = target <- Repo.get(ApiToken, id),
         true <- support_family?(target),
         true <- workspace_admin?(conn, target.workspace_id) do
      {:ok, target}
    else
      _ -> :error
    end
  end

  # (1) FAMILY. Fail closed on a NULL label — an unlabelled row is not a support
  # token.
  defp support_family?(%ApiToken{label: label}) when is_binary(label),
    do: String.starts_with?(label, @support_label_prefix)

  defp support_family?(_), do: false

  # (2) OBJECT AUTHZ, through the canonical chokepoint. Deliberately NOT a
  # `target.workspace_id == caller_workspace_id` equality: a token's
  # `workspace_id` is a BACKFILL DEFAULT (`Auth.create_token/5` falls back to the
  # seeded Default when none is supplied), so equality would read as a tenancy
  # statement it does not make. Membership ROLE is the grant.
  defp workspace_admin?(conn, workspace_id) do
    actor = conn.assigns[:api_token]

    case {actor, Repo.uuid_or_nil(workspace_id)} do
      {%ApiToken{}, ws_id} when is_binary(ws_id) -> TenancyAuth.workspace_admin?(actor, ws_id)
      _ -> false
    end
  end

  defp fetch_name(%{"name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :missing_name}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_name(_), do: {:error, :missing_name}

  defp unprocessable(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "unprocessable", message: message}})
  end

  defp not_found(conn, message) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: message}})
  end
end
