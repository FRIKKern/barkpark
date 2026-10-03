defmodule BarkparkWeb.TokenIdentityController do
  @moduledoc """
  `GET /v1/tokens/current` — the bearer token describes itself: id, label,
  permissions, expiry, home workspace and every workspace seat it holds
  (task-7d4d405e0ee4bcbf).

  A token with permissions but no seat answers 403 `not_a_member` on every
  workspace route, and nothing used to show that state without database
  access. `bp whoami` reads this route and prints the memberships (`-o json`
  carries them as `memberships`).

  The caller sees only its own row: no id is taken from the request. The
  secret and its hash are never selected.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Members

  def show(conn, _params) do
    token = conn.assigns.api_token

    json(conn, %{
      token: %{
        id: token.id,
        label: token.label,
        kind: token.kind,
        permissions: token.permissions || [],
        expires_at: token.expires_at,
        workspace_id: token.workspace_id,
        workspace: home_slug(token.workspace_id)
      },
      memberships: Members.token_memberships(token.id)
    })
  end

  defp home_slug(nil), do: nil

  defp home_slug(workspace_id) do
    case Tenancy.get_workspace_by_id(workspace_id) do
      %{slug: slug} -> slug
      _ -> nil
    end
  end
end
