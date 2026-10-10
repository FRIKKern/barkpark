defmodule BarkparkWeb.TokenSelfController do
  @moduledoc """
  `GET /v1/auth/token` — the calling token describes itself (task-bc2541aca8541ff1).

  `GET /v1/auth/me` needs a login session, so an API or app token could not ask
  what it may do; a Studio listed every app token with an admin token to find
  out. This answers for the bearer alone: its permissions, tier, dataset,
  workspace, and its seat there (role and what the seat lets it do). Never the
  hash, never the label (an app token's label carries an email).

  ## A login-session bearer (task-a89ef18ee88ba6a0)

  The token `/v1/auth/login` answers is a user session, and it is a bearer on
  the data API (#22764). Here it describes itself as `kind: "session"`: the
  user, the session's expiry, and every seat the user holds — the same seats
  the session can act on, each with the User arm of
  `Tenancy.Auth.seat_capabilities/3`. A member seat therefore says
  `write: true`, because a member edits in LiveView Studio and a member
  session writes. A member's self-minted PAT is a different principal with
  its own answer (capped at `["read"]` by `Auth.max_pat_permissions_for_role/1`,
  a MINTING policy).

  `publish` is the seat's write: no separate publish action exists, and a seat
  that writes also publishes (in Studio and through mutate). It is spelled out
  so a client need not know that.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Accounts.User
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  def show(conn, _params) do
    case conn.assigns do
      %{api_token: token} when not is_nil(token) -> show_token(conn, token)
      %{current_user: %User{} = user} -> show_session(conn, user)
    end
  end

  defp show_session(conn, user) do
    session = conn.assigns[:current_user_session]

    json(conn, %{
      kind: "session",
      user: %{id: user.id, email: user.email},
      expires_at: session && session.expires_at,
      seats: Enum.flat_map(TenancyAuth.list_workspaces_for(user), &session_seat(user, &1))
    })
  end

  # One seat per workspace the inverse index returns, each read off the row the
  # point lookup just loaded. A seat removed between the two reads is dropped.
  defp session_seat(user, ws) do
    case TenancyAuth.membership(user, ws.id) do
      nil ->
        []

      membership ->
        [
          %{
            workspace: %{id: ws.id, slug: ws.slug},
            role: membership.role,
            can: with_publish(TenancyAuth.seat_capabilities(user, membership, ws.id))
          }
        ]
    end
  end

  defp show_token(conn, token) do
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
        %{
          role: membership.role,
          can: with_publish(TenancyAuth.seat_capabilities(token, membership, ws_id))
        }
    end
  end

  # A seat that writes also publishes; see the moduledoc.
  defp with_publish(%{write: write} = can), do: Map.put(can, :publish, write)
  defp with_publish(can), do: can
end
