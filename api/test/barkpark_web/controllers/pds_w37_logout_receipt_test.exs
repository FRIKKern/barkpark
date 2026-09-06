defmodule BarkparkWeb.PdsW37LogoutReceiptTest do
  @moduledoc """
  PDS-D523 differential — `DELETE /v1/auth/logout` stops asserting success over
  a count it discards.

  `BarkparkWeb.AuthController.logout/2` called
  `Accounts.revoke_user_session_token/1` as a bare expression and answered
  `%{ok: true}` (or the same map plus `slo_url`) unconditionally, so the receipt
  was byte-identical whether the revoke stamped a live session or found nothing
  left to stamp. The callee has carried `{:ok, n}` since PDS-D523; this was its
  only caller that threw it away.

  WHAT THE DOOR CAN ACTUALLY SHOW, STATED. The route sits behind
  `[:user_auth, :require_user]` (router.ex `scope "/v1/auth"`), so the two
  obvious zero cases are UNREACHABLE through it: no bearer 401s before the
  controller runs, and a second logout on a dead token 401s too. Both were
  written as tests first and both failed on a 401 — that is why they are not
  here. The only reachable zero is the RACE the receipt exists to name: the
  session dies between `require_user`'s read and the controller's revoke, and
  the door must not report a kill it did not make. `revoke_between_auth_and_revoke/1`
  drives exactly that, with a one-shot `:telemetry` observer on the repo's query
  event — nothing is stubbed.

  Every assertion compares the RECEIPT against a DIRECT `Repo` read of
  `user_sessions` — never a second endpoint, which would only prove two surfaces
  agree on the same guess.

  MUTATION-PROVEN: hardcoding `revoked: 1` in `logout/2` reds the race test
  below (see the task's mutation evidence).
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Accounts, Repo}
  alias Barkpark.Accounts.UserSession

  @password "correct-horse-battery"

  setup do
    {:ok, user} =
      Accounts.register_user(%{email: "pds-w37-logout@example.com", password: @password})

    {:ok, token} = Accounts.create_user_session_token(user)
    %{user: user, token: token}
  end

  # DIRECT storage reads — the only admissible oracle here.
  defp session_row(token) do
    Repo.one(from(s in UserSession, where: s.token_hash == ^UserSession.hash_token(token)))
  end

  defp revoked_count(user_id) do
    Repo.aggregate(
      from(s in UserSession, where: s.user_id == ^user_id and not is_nil(s.revoked_at)),
      :count
    )
  end

  defp live_count(user_id) do
    Repo.aggregate(
      from(s in UserSession, where: s.user_id == ^user_id and is_nil(s.revoked_at)),
      :count
    )
  end

  defp logout(token) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> delete("/v1/auth/logout")
    |> json_response(200)
  end

  # Attach a one-shot repo-query observer that revokes `token` the moment a
  # SELECT against user_sessions completes — i.e. after `require_user` has
  # already resolved the session and before the controller's own revoke. The
  # controller's `update_all` then stamps NOTHING, which is the only zero this
  # door can reach.
  defp revoke_between_auth_and_revoke(token) do
    hash = UserSession.hash_token(token)
    key = {__MODULE__, :race, make_ref()}

    :telemetry.attach(
      key,
      [:barkpark, :repo, :query],
      fn _event, _measurements, meta, _config ->
        query = to_string(meta[:query] || "")

        if String.starts_with?(query, "SELECT") and query =~ "user_sessions" and
             Process.get(key) == nil do
          Process.put(key, :fired)

          Repo.update_all(
            from(s in UserSession, where: s.token_hash == ^hash and is_nil(s.revoked_at)),
            set: [revoked_at: DateTime.truncate(DateTime.utc_now(), :microsecond)]
          )
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(key) end)
  end

  test "the receipt's `revoked` EQUALS the rows the revoke stamped", %{user: user, token: token} do
    # The oracle must be able to say the other thing: the row is LIVE first.
    assert is_nil(session_row(token).revoked_at)
    assert revoked_count(user.id) == 0

    body = logout(token)

    assert body["ok"] == true
    assert body["revoked"] == 1
    assert body["revoked"] == revoked_count(user.id)
    refute is_nil(session_row(token).revoked_at)
  end

  test "the count is THIS session, not the user's — the other live sessions survive it",
       %{user: user, token: token} do
    for _ <- 1..3, do: {:ok, _} = Accounts.create_user_session_token(user)
    assert live_count(user.id) == 4

    body = logout(token)

    assert body["revoked"] == 1
    assert body["revoked"] == revoked_count(user.id)
    assert live_count(user.id) == 3
  end

  test "the session dies between the auth read and the revoke → the receipt says 0, never 1",
       %{user: user, token: token} do
    revoke_between_auth_and_revoke(token)

    body = logout(token)

    # The logout still SUCCEEDS — the caller is signed out either way — but it
    # no longer claims a kill that another writer made. This is the assertion a
    # hardcoded `revoked: 1` cannot survive.
    assert body["ok"] == true
    assert body["revoked"] == 0
    # The row IS revoked — by the racer, not by this request.
    refute is_nil(session_row(token).revoked_at)
    assert revoked_count(user.id) == 1
  end

  test "`ok` and `slo_url` keep their shape — `revoked` is purely additive", %{token: token} do
    body = logout(token)

    assert body["ok"] == true
    # Non-SAML session: no slo_url key appears, exactly as before.
    refute Map.has_key?(body, "slo_url")
  end
end
