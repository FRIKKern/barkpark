defmodule BarkparkWeb.TokenSelfController do
  @moduledoc """
  `GET /v1/auth/token` — the calling token describes itself (task-bc2541aca8541ff1).

  `GET /v1/auth/me` needs a login session, so an API or app token could not ask
  what it may do; a Studio listed every app token with an admin token to find
  out. This answers for the bearer alone: its permissions, tier, dataset,
  workspace, and its seat there (role and what the seat lets it do). Never the
  hash, never the label (an app token's label carries an email).
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  def show(conn, _params) do
    token = conn.assigns.api_token
    ws_id = Map.get(token, :workspace_id)

    json(conn, %{
      id: token.id,
      name: Map.get(token, :name),
      kind: Map.get(token, :kind),
      permissions: token.permissions || [],
      tier: TenancyAuth.tier_of(token),
      dataset: token.dataset,
      # true = the token is refused on every other dataset; false = `dataset`
      # is only the mint default and binds nothing (task-4418b517649a58ce).
      dataset_bound: token.dataset_bound == true,
      expires_at: token.expires_at,
      workspace: workspace(ws_id),
      seat: seat(token, ws_id)
    })
  end

  defp workspace(nil), do: nil

  defp workspace(ws_id) do
    case Tenancy.get_workspace_by_id(ws_id) do
      %{id: id, slug: slug} -> %{id: id, slug: slug}
      _ -> %{id: ws_id, slug: nil}
    end
  end

  defp seat(_token, nil), do: nil

  defp seat(token, ws_id) do
    case TenancyAuth.membership(token, ws_id) do
      nil ->
        nil

      membership ->
        %{role: membership.role, can: TenancyAuth.seat_capabilities(token, membership, ws_id)}
    end
  end
end
