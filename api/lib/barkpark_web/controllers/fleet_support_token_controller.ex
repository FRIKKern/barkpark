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

  The raw token is NEVER logged.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Auth

  # A support token exists to work the ledger: read to poll ready tasks, write to
  # claim/pulse/stamp/close them. NOT admin — it can never mint more tokens.
  @support_permissions ~w(read write)

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
        label = "fleet-support-#{name}"
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
  Revoke a support token by id. Idempotent-safe on the caller's side: an unknown
  or malformed id is a clean `404` (never a 500 — `Auth.revoke_token/1` guards
  the `:binary_id` cast).

  200 → `{"token_id": id, "revoked": true}`.
  """
  def delete(conn, %{"token_id" => token_id}) do
    case Auth.revoke_token(token_id) do
      {:ok, revoked} ->
        json(conn, %{token_id: revoked.id, revoked: true})

      {:error, :not_found} ->
        not_found(conn, "no token with that id")

      {:error, _changeset} ->
        unprocessable(conn, "could not revoke token")
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
