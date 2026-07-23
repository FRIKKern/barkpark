defmodule BarkparkWeb.AppTokenController do
  @moduledoc """
  Admin-gated mint of a member-shaped, workspace-bound app token (mobile
  charter D4) — the instance half of the two-endpoint app-token exchange.

  `POST /v1/auth/app-tokens` — bearer-authed (`:require_token` verified the
  token and assigned `:api_token`), then gated on the bearer holding `admin`
  (the `mint_login_ticket` idiom: a lesser token gets the same generic
  unauthorized, no privilege oracle). The expected caller is the Barkpark Cloud
  control plane using the STORED per-instance admin token server-side — the
  member never sees an admin credential, only the minted member-shaped token.

  What one mint does, in order:

    1. JIT-provisions the cloud identity: `Sso.find_or_create_user/1` (race-safe,
       charter D5) plus an idempotent `member` workspace membership for the USER
       principal — the "your cloud account is a member on your instance" seat.
    2. Mints via the EXISTING `Auth.create_token/5` — atomic token +
       `role=member` membership for the TOKEN principal (D9: member-shaped
       row-level; `role_for_permissions/1` only grants `admin` when the list
       carries `admin`, which this endpoint can never mint).

  SECURITY — the permission set is capped by a hard allowlist
  (`read`/`write`/`chat`, ratified R2). A body asking for `admin` (or anything
  else) is a 422, never a policy decision: `RequireChatAccess` checks `admin`
  FIRST and resolves such a token to `:global`, so a single smuggled `admin`
  entry would mint a tenant-less operator credential through a member-reachable
  proxy. Deliberately NOT delegated to `Auth.create_chat_token/3` — that is the
  connector mint and its `["chat"]` set is D48-frozen; this endpoint mints the
  app-token set and nothing else.

  The plaintext token is returned ONCE in the 201 body and is never recoverable
  after (only its SHA256 hash is persisted). The raw token is NEVER logged and
  never audited — the audit event records THAT a mint happened.
  """
  use BarkparkWeb, :controller

  alias Barkpark.{Audit, Auth, Sso, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.ErrorResponse

  @app_token_permissions ~w(read write chat)
  @app_token_prefix "bpapp_"

  @doc """
  Mint an app token bound to a workspace, as `email`'s JIT-provisioned identity.

  Body: `{"email": string, "workspace": slug-or-id?, "permissions": list?,
  "label": string?, "dataset": string?}`.

    * `email` is required — the cloud account the token is minted FOR.
    * `workspace` (slug or id) defaults to the Default Workspace; fail-closed
      422 when neither resolves (a workspace-less `chat`-carrying token is the
      tenant-less credential this surface must never mint).
    * `permissions` defaults to `#{inspect(@app_token_permissions)}` and must be
      a non-empty subset of it — `admin` is unmintable here by construction.
    * `dataset` defaults to `"production"`; `label` to `"app:" <> email`.

  201 → `{"token": raw, "workspace_id": ..., "permissions": [...],
  "expires_at": null}` — exactly the payload the Cloud proxy relays.
  """
  def create(conn, params) do
    token = conn.assigns.api_token

    if Auth.has_permission?(token, "admin") do
      mint(conn, params)
    else
      # mint_login_ticket idiom: a non-admin bearer gets the same generic
      # unauthorized as a bad token — this route never confirms tiers.
      ErrorResponse.emit(conn, {:error, :unauthorized})
    end
  end

  defp mint(conn, params) do
    with {:ok, email} <- fetch_email(params),
         {:ok, permissions} <- fetch_permissions(params),
         {:ok, workspace} <- resolve_workspace(params) do
      # JIT MEMBER (charter D5): the identity first, then its member seat.
      # `create_membership` is idempotent-by-constraint — an existing seat hits
      # the unique index and is left as-is (the `Sso.jit_provision/3` pattern).
      user = Sso.find_or_create_user(email)
      _ = TenancyAuth.create_membership(workspace.id, user.id, "member", "user")

      raw = @app_token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      label = fetch_label(params, email)
      dataset = fetch_dataset(params)

      case Auth.create_token(raw, label, dataset, permissions, workspace.id) do
        {:ok, minted} ->
          # Credential lifecycle event (the `revoke_token` twin): THAT a mint
          # happened, for whom, into which workspace — never the token value.
          Audit.emit(%{
            category: "token",
            action: "app_token_minted",
            subject: minted.id,
            actor_type: "user",
            actor_id: user.id,
            workspace_id: workspace.id,
            metadata: %{"email" => email, "label" => label, "permissions" => permissions}
          })

          conn
          |> put_status(:created)
          |> json(%{
            token: raw,
            workspace_id: workspace.id,
            permissions: permissions,
            expires_at: nil
          })

        {:error, _changeset} ->
          unprocessable(conn, "could not mint token")
      end
    else
      {:error, :email_required} ->
        unprocessable(conn, "email is required and must be a non-empty string")

      {:error, :invalid_permissions} ->
        unprocessable(
          conn,
          "permissions must be a non-empty subset of #{inspect(@app_token_permissions)}"
        )

      {:error, :workspace_not_found} ->
        unprocessable(conn, "workspace could not be resolved")
    end
  end

  defp fetch_email(%{"email" => email}) when is_binary(email) do
    case String.trim(email) do
      "" -> {:error, :email_required}
      trimmed -> if trimmed =~ "@", do: {:ok, trimmed}, else: {:error, :email_required}
    end
  end

  defp fetch_email(_), do: {:error, :email_required}

  defp fetch_permissions(%{"permissions" => perms}) when is_list(perms) do
    if perms != [] and Enum.all?(perms, &(is_binary(&1) and &1 in @app_token_permissions)) do
      # Keep the canonical order (and dedupe) so the minted list is stable
      # whatever order the caller sent.
      {:ok, Enum.filter(@app_token_permissions, &(&1 in perms))}
    else
      {:error, :invalid_permissions}
    end
  end

  defp fetch_permissions(%{"permissions" => _}), do: {:error, :invalid_permissions}
  defp fetch_permissions(_), do: {:ok, @app_token_permissions}

  # `workspace` accepts a slug (the Cloud proxy sends its stored bootstrap
  # workspace slug) or an id; absent/null falls back to the Default Workspace.
  # No resolvable workspace → fail closed (422), never an unbound token.
  defp resolve_workspace(params) do
    case params["workspace"] do
      slug_or_id when is_binary(slug_or_id) and slug_or_id != "" ->
        case Tenancy.get_workspace_by_slug(slug_or_id) || Tenancy.get_workspace_by_id(slug_or_id) do
          nil -> {:error, :workspace_not_found}
          workspace -> {:ok, workspace}
        end

      _ ->
        case Tenancy.get_default_workspace() do
          nil -> {:error, :workspace_not_found}
          workspace -> {:ok, workspace}
        end
    end
  end

  defp fetch_label(%{"label" => label}, _email) when is_binary(label) and label != "" do
    label
  end

  defp fetch_label(_, email), do: "app:" <> email

  defp fetch_dataset(%{"dataset" => dataset}) when is_binary(dataset) and dataset != "",
    do: dataset

  defp fetch_dataset(_), do: "production"

  defp unprocessable(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "unprocessable", message: message}})
  end
end
