defmodule BarkparkWeb.StudioTokenController do
  @moduledoc """
  `POST /v1/auth/studio-tokens` mints the read token an external Studio uses
  as `BARKPARK_TOKEN` (task-7855ed1481992cf6).

  The Studio needs a read token with a seat in its workspace (barkpark-studio
  docs/DEPLOY.md). The scoped `POST /w/:ws/p/:p/v1/tokens` mints one, but only
  for an API token with an owner or admin seat. An instance installed by an
  older deploy.sh has no admin token, and an owner who signs in with SSO holds
  only a login session. This route accepts either credential:

    * an API token that may administer the workspace: an unbound admin token,
      an admin token bound to the default workspace (the instance admin
      token), or a token with an owner or admin seat in the workspace;
    * a login session (`Authorization: Bearer <session token>`) whose user
      has an owner or admin seat in the workspace.

  Anyone else gets 403 `studio_token_forbidden` and nothing is minted. An
  unknown workspace answers the same 403, so the route does not confirm which
  workspaces exist.

  Body: `{"workspace": slug-or-id, "dataset": string?, "label": string?}`.
  The token carries `["read"]` and a `member` seat in the workspace, through
  `Auth.create_token/6`. The raw token is in the 201 body once and is never
  stored or logged; the audit row records the mint and who made it.
  """
  use BarkparkWeb, :controller

  alias Barkpark.{Auth, Tenancy}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.ErrorResponse

  @permissions ["read"]

  def create(conn, params) do
    actor = conn.assigns[:current_user] || conn.assigns[:api_token]

    with {:ok, slug} <- fetch_workspace(params),
         {:ok, workspace} <- resolve(slug),
         :ok <- may_mint(actor, workspace, slug) do
      mint(conn, actor, workspace, params)
    else
      {:error, :workspace_required} ->
        ErrorResponse.emit_fields(conn, :unprocessable_entity, %{
          code: "workspace_required",
          message: "name the Studio's workspace (\"workspace\": slug or id)"
        })

      {:error, {:forbidden, slug}} ->
        ErrorResponse.emit_fields(conn, :forbidden, %{
          code: "studio_token_forbidden",
          message:
            "only an owner or admin of workspace #{inspect(slug)}, or the instance admin " <>
              "token, may mint its Studio token. Nothing was minted",
          hint:
            "sign in as an owner or admin of that workspace, or use the admin token " <>
              "(on a VM: /etc/barkpark/admin-token)"
        })
    end
  end

  defp fetch_workspace(%{"workspace" => ws}) when is_binary(ws) do
    case String.trim(ws) do
      "" -> {:error, :workspace_required}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_workspace(_), do: {:error, :workspace_required}

  defp resolve(slug) do
    case Tenancy.get_workspace_by_slug(slug) || workspace_by_id(slug) do
      nil -> {:error, {:forbidden, slug}}
      workspace -> {:ok, workspace}
    end
  end

  defp workspace_by_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Tenancy.get_workspace_by_id(uuid)
      :error -> nil
    end
  end

  # A login session: the USER's seat decides.
  defp may_mint(%Barkpark.Accounts.User{id: user_id}, %{id: ws_id}, slug) do
    if TenancyAuth.workspace_admin?(user_id, ws_id, :user),
      do: :ok,
      else: {:error, {:forbidden, slug}}
  end

  # An API token: the instance admin token (unbound, or bound to the default
  # workspace, the `AppTokenController.may_mint_into/2` rule), or a token with
  # an owner or admin seat in this workspace.
  defp may_mint(%ApiToken{} = token, %{id: ws_id}, slug) do
    cond do
      instance_admin?(token) -> :ok
      TenancyAuth.workspace_admin?(token, ws_id) -> :ok
      true -> {:error, {:forbidden, slug}}
    end
  end

  defp may_mint(_actor, _ws, slug), do: {:error, {:forbidden, slug}}

  defp instance_admin?(%ApiToken{workspace_id: bound} = token) do
    Auth.has_permission?(token, "admin") and
      (is_nil(bound) or match?(%{id: ^bound}, Tenancy.get_default_workspace()))
  end

  defp mint(conn, actor, workspace, params) do
    raw = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    dataset = string_param(params, "dataset") || "production"
    label = string_param(params, "label") || "studio (#{workspace.slug})"

    opts = [
      actor: if(match?(%ApiToken{}, actor), do: actor),
      dataset_bound: if(string_param(params, "dataset"), do: true)
    ]

    case Auth.create_token(raw, label, dataset, @permissions, workspace.id, opts) do
      {:ok, token} ->
        Auth.audit_token_minted(token, actor)

        conn
        |> put_status(:created)
        |> json(%{
          token: raw,
          id: token.id,
          label: token.label,
          permissions: token.permissions,
          dataset: dataset,
          workspace: workspace.slug,
          expires_at: token.expires_at
        })

      {:error, _reason} ->
        ErrorResponse.emit_fields(conn, :unprocessable_entity, %{
          code: "unprocessable",
          message: "could not mint the Studio token"
        })
    end
  end

  defp string_param(params, key) do
    case params[key] do
      v when is_binary(v) -> if String.trim(v) == "", do: nil, else: String.trim(v)
      _ -> nil
    end
  end
end
