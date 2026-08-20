defmodule BarkparkWeb.ChatTokenController do
  @moduledoc """
  Admin-gated mint of a workspace-bound `chat` API token (Connectors D36).

  `POST /w/:workspace_slug/p/:project_slug/v1/chat/tokens` — wired under the
  `:scoped_admin` pipeline (RequireToken + RequireWorkspaceRole), so only an
  owner/admin of the resolved `current_workspace` can reach it. It exists so a
  connector install (Slack/Discord/Telegram/…) can be handed a credential that
  belongs to ONE tenant, instead of the bridge driving every workspace with a
  single global operator token.

  WHY A SEPARATE CONTROLLER — `TokenController` mints from a READ-ONLY allowlist
  (`public-read`, `read`) and its moduledoc states it is NOT a privilege-mint;
  widening it to `chat` would blur that guarantee. This controller mints exactly
  one permission set and nothing else.

  SECURITY — the permission set is HARDCODED to `#{inspect(["chat"])}`, and it
  is hardcoded in exactly ONE place: `Barkpark.Auth.create_chat_token/3` (D48).
  This controller DELEGATES to it and holds no permission literal of its own.
  That extraction is not tidying — it is the fix for a live escalation seam:
  `Auth.create_token/5` mints whatever list it is handed, so while the literal
  lived here, the endpoint was safe and every in-process caller (Studio's Connect
  button, a Mix task) was one keystroke from `["admin"]`, which
  `TenancyAuth.role_for_permissions/1` would then turn into an `admin` membership
  row — a token that can mint more tokens.

  The request body cannot influence the permissions: no `permissions` key is
  read, so a body asking for `admin` is silently irrelevant rather than a policy
  decision. That matters because `RequireChatAccess` checks `admin` FIRST and
  resolves such a token to `:global`, and `StudioChat` stamps
  `owner_workspace_id = NULL` for a `:global` scope — a single `admin` entry in
  that list would silently re-open the tenant-less-session bug this endpoint
  exists to close. This suite is therefore the protective test for BOTH callers.

  A `chat` token grants exactly one thing: the ability to drive `/v1/chat`
  sessions owned by THIS workspace (`RequireChatAccess` resolves it to
  `{:workspace, ws}`, and the store seal confines every read/write to
  `owner_workspace_id`). It carries no read/write/admin authority over content.
  `Auth.create_token/5` also inserts a `workspace_memberships` row for the
  minted token — role `member` (`role_for_permissions/1` only grants `admin`
  when the permission list carries `admin`), which is the tenancy grant that
  makes the workspace binding real.

  The plaintext token is returned ONCE in the 201 body and is never recoverable
  after (only its SHA256 hash is persisted). The raw token is NEVER logged.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Auth

  @doc """
  Mint a `chat` token bound to the resolved workspace.

  Body: `{"label": string, "dataset": "production"}`.

    * `label` is required and must be a non-empty string.
    * `dataset` defaults to `"production"`.
    * `permissions` in the body is IGNORED — the mint is always whatever
      `Auth.chat_permissions/0` says, which is `#{inspect(["chat"])}`.

  201 → `{"token": raw, "label": ..., "permissions": ["chat"], "dataset": ...,
  "workspace": <workspace_slug>}`.
  """
  def create(conn, params) do
    workspace = conn.assigns[:current_workspace]

    with {:ok, label} <- fetch_label(params),
         dataset when is_binary(dataset) <- fetch_dataset(params),
         %{id: ws_id, slug: ws_slug} <- workspace do
      # DELEGATE (D48). The raw token is generated INSIDE the context fn — the
      # controller never chooses the permissions and never chooses the entropy.
      case Auth.create_chat_token(label, dataset, ws_id) do
        {:ok, raw, _token} ->
          conn
          |> put_status(:created)
          |> json(%{
            token: raw,
            label: label,
            permissions: Auth.chat_permissions(),
            dataset: dataset,
            workspace: ws_slug
          })

        {:error, _reason} ->
          unprocessable(conn, "could not mint token")
      end
    else
      {:error, :missing_label} ->
        unprocessable(conn, "label is required and must be a non-empty string")

      nil ->
        # current_workspace assign missing — the scoped pipeline should have set
        # it. Fail closed rather than mint a workspace-less chat token: a `chat`
        # token with a NULL workspace_id is exactly the tenant-less credential
        # this endpoint exists to prevent.
        unprocessable(conn, "workspace could not be resolved")
    end
  end

  defp fetch_label(%{"label" => label}) when is_binary(label) do
    case String.trim(label) do
      "" -> {:error, :missing_label}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_label(_), do: {:error, :missing_label}

  defp fetch_dataset(%{"dataset" => dataset}) when is_binary(dataset) do
    case String.trim(dataset) do
      "" -> "production"
      trimmed -> trimmed
    end
  end

  defp fetch_dataset(_), do: "production"

  defp unprocessable(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "unprocessable", message: message}})
  end
end
