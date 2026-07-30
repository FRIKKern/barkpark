defmodule BarkparkCloud.Web.PatTouchAuthzTest do
  @moduledoc """
  The PAT twin of `router_session_touch_test.exs`.

  THE DEFECT (measured at router level before this fix). `last_used_at` is the
  liveness claim the tokens card renders (`'used ' + fmtTokenDate(...)`, app.js),
  so it asserts the platform SERVED this credential. But authentication runs
  strictly BEFORE authorization: `Auth.require_user_or_pat/2` called
  `Accounts.verify_personal_access_token/1`, which stamped `last_used_at`
  UNCONDITIONALLY, and only THEN did `Auth.require_ability/2` evaluate the
  credential's abilities and answer `forbidden(conn)`. A read-only PAT could be
  REFUSED 403 by a write-gated route and still print as freshly used.

  No throttle at the write site can reach this case — an IDLE credential
  SATISFIES a staleness guard. The test below backdates a full hour (60x the 60s
  window) precisely so a throttle would happily fire; only the status gate holds
  it.

  THE FIX. The PAT branch now verifies with `touch: false` and defers the stamp
  to `Plug.Conn.register_before_send/2`, gated on `conn.status < 400` — the first
  point where the response decision is known. Exactly the placement the session
  branch already had; the asymmetry lived inside one `cond`.

  Assertion shape is mirrored from the session twin: backdate to a KNOWN instant
  and pin EXACT equality, which no clock resolution can fake.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.UserToken
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  ## Fixtures

  # An owner + a fresh team + a site, so the write-gated route has a real target
  # to be refused ON (a 403 that only ever came from a missing resource would
  # prove nothing about the ability gate).
  defp scope do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "pat-touch-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "Site #{n}", slug: "site-#{n}"})

    %{user: user, team: team, site: site}
  end

  defp pat(%{user: user, team: team}, abilities) do
    {:ok, plaintext, stored} =
      Accounts.create_personal_access_token(user, team, %{
        name: "pat-touch-#{System.unique_integer([:positive])}",
        abilities: abilities
      })

    {plaintext, stored}
  end

  defp pat_row(%UserToken{id: id}), do: Repo.get!(UserToken, id)

  # Backdate the PAT row to a KNOWN instant and hand it back. The assertion is
  # then "still EXACTLY that instant".
  defp backdate!(%UserToken{id: id}, seconds) do
    at = DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:microsecond)

    {1, _} = Repo.update_all(from(t in UserToken, where: t.id == ^id), set: [last_used_at: at])

    at
  end

  defp call(method, path, body, token) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  ## The instance — a REFUSED PAT request must not claim activity

  describe "a REFUSED PAT request and last_used_at" do
    test "a 403 from the ability gate does NOT advance the stamp" do
      s = scope()
      {plaintext, stored} = pat(s, ["read"])

      # Idle for an hour: 60x the throttle window, so a throttle at the write
      # site would happily fire here. Only the status gate can hold this.
      idle_since = backdate!(stored, 3600)

      # PATCH /v1/sites/:id is write-gated; a read PAT authenticates and is then
      # refused — the exact shape the tokens card lied about.
      conn = call(:patch, "/v1/sites/#{s.site.id}", %{name: "Renamed"}, plaintext)

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "forbidden"

      assert %UserToken{last_used_at: ^idle_since} = pat_row(stored), """
      a REFUSED PAT advanced last_used_at — the tokens card would print \
      "used just now" for a credential the platform just 403'd.
      """
    end

    test "a 401 from an unknown bearer stamps nothing on the real token either" do
      s = scope()
      {_plaintext, stored} = pat(s, ["read"])
      idle_since = backdate!(stored, 3600)

      conn = call(:get, "/v1/me", nil, "bpc_pat_not-a-real-token")

      assert conn.status == 401
      assert %UserToken{last_used_at: ^idle_since} = pat_row(stored)
    end
  end

  ## The positive direction — an ALLOWED PAT request MUST still claim activity

  describe "an ALLOWED PAT request and last_used_at" do
    test "a 200 DOES advance the stamp" do
      s = scope()
      {plaintext, stored} = pat(s, ["read"])
      idle_since = backdate!(stored, 3600)

      conn = call(:get, "/v1/me", nil, plaintext)
      assert conn.status == 200

      %UserToken{last_used_at: after_call} = pat_row(stored)

      assert DateTime.compare(after_call, idle_since) == :gt,
             "an allowed PAT request left the stamp cold — liveness is now under-reported"
    end

    test "two allowed requests inside the 60s window produce exactly ONE write" do
      s = scope()
      {plaintext, stored} = pat(s, ["read"])
      backdate!(stored, 3600)

      assert call(:get, "/v1/me", nil, plaintext).status == 200
      %UserToken{last_used_at: first} = pat_row(stored)

      assert call(:get, "/v1/me", nil, plaintext).status == 200
      %UserToken{last_used_at: second} = pat_row(stored)

      assert DateTime.compare(first, second) == :eq, """
      the second request inside the throttle window wrote again — every poll of \
      the console amplifies to an UPDATE.
      """
    end
  end

  ## The unit beneath the router — the :touch option itself

  describe "Accounts.verify_personal_access_token/2 :touch" do
    test "touch: false verifies without stamping; the arity-1 default still stamps" do
      s = scope()
      {plaintext, stored} = pat(s, ["read"])
      idle_since = backdate!(stored, 3600)

      assert {_user, %UserToken{}} =
               Accounts.verify_personal_access_token(plaintext, touch: false)

      assert %UserToken{last_used_at: ^idle_since} = pat_row(stored)

      assert {_user, %UserToken{}} = Accounts.verify_personal_access_token(plaintext)
      %UserToken{last_used_at: after_eager} = pat_row(stored)
      assert DateTime.compare(after_eager, idle_since) == :gt
    end

    test "touch_pat_last_used/1 is a no-op for an unknown plaintext" do
      s = scope()
      {_plaintext, stored} = pat(s, ["read"])
      idle_since = backdate!(stored, 3600)

      assert :ok = Accounts.touch_pat_last_used("bpc_pat_nope")
      assert :ok = Accounts.touch_pat_last_used(nil)
      assert %UserToken{last_used_at: ^idle_since} = pat_row(stored)
    end
  end
end
