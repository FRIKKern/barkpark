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

  `expires_at` is the instant the session stops working
  (task-4c981126f9255b29): the earlier of the session row's own `expires_at`
  and its birth plus the strictest `absolute_lifetime_seconds` of the
  organizations governing the user. The verify path refuses the session at
  that instant, so a client such as Studio can end its own session at the
  same moment. It is computed on each read, so a changed policy shows here
  on the next call.

  `publish` follows the seat's write, except on a draft-only seat: a
  `contributor` writes drafts but cannot publish, unpublish or delete a
  published document, and `seat_capabilities/3` reports that as
  `publish: false`. It is spelled out so a client need not know the rule.
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
      expires_at: session_end(session, user),
      seats: Enum.flat_map(TenancyAuth.list_workspaces_for(user), &session_seat(user, &1))
    })
  end

  # The session's absolute end: its row expiry, or sooner when an org policy
  # caps its age from birth (`UserSession.absolute_expired_for_window?/3`).
  defp session_end(nil, _user), do: nil

  defp session_end(session, user) do
    case Tenancy.org_session_policy_for_user(user.id) do
      %{absolute_lifetime_seconds: max} when is_integer(max) and max > 0 ->
        earliest(
          session.expires_at,
          session.inserted_at && DateTime.add(session.inserted_at, max, :second)
        )

      _ ->
        session.expires_at
    end
  end

  defp earliest(nil, b), do: b
  defp earliest(a, nil), do: a
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

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

  # A seat that writes also publishes, unless seat_capabilities/3 already
  # answered `publish` (a contributor seat writes drafts but never publishes).
  defp with_publish(%{write: write} = can), do: Map.put_new(can, :publish, write)
  defp with_publish(can), do: can
end
