defmodule BarkparkCloud.Web.RouterRollbackTest do
  @moduledoc """
  isu-w6 — `POST /v1/barkparks/:id/rollback`: the control plane relays a
  blue/green rollback trigger to the instance's `POST /v1/admin/rollback`
  server-side with the STORED admin token (the self-update seam) and relays
  the instance's verdict. Proves the W6 contract:

    * happy path: instance 202 {status,target_sha} → our 202 {status,
      target_sha, pinned_release}; the CP has ATOMICALLY pinned
      pinned_release = the instance-REPORTED target_sha (D16); the decrypted
      admin bearer was used; a one-row status refresh is enqueued; the admin
      token never leaks
    * a PINNED box CAN roll back — no pin precondition; the fresh pin
      replaces the stale one (rollback re-pins by design)
    * typed refusals relay VERBATIM (D23): 409 no_previous_slot /
      already_running / not_supported — and the pin is NEVER touched on 409
    * 503 matched on the BODY: feature_not_configured → 503 not_enabled;
      a bare proxy 503 → 502 instance_unavailable
    * the fleet-wide halt does NOT gate manual rollback (D18)
    * ADMIN gate: plain member → 403 (instance never called); team scope
      fail-closed: wrong-team admin gets the SAME 404 as a nonexistent id;
      unauthenticated → 401; not-live → 409 not_live; transport failure →
      502 instance_unreachable
    * cch-w54-bl: a BILLING-SUSPENDED box is refused 409 `suspended` BEFORE the
      relay — zero upstream requests, the credential never on the wire, the pin
      untouched
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router
  alias BarkparkCloud.Workers.UpdateStatusWorker

  @opts Router.init([])

  @password "correct-horse-battery"
  @instance_admin_token "instance-admin-token-plaintext"
  @instance_url "https://prod.barkpark.cloud"
  # The 40-hex sha the instance's preflight reports as the rollback target.
  @target_sha String.duplicate("ab", 20)

  ## Fixtures (mirror RouterSelfUpdateTest's)

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team(role \\ "owner") do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {user, team}
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  # A LIVE instance: url + host set, encrypted admin token stored (what the
  # provision-succeed path writes). `url` carries a unique index, so a second
  # live box in the same test must pass its own.
  defp live_barkpark(team, url \\ @instance_url) do
    team
    |> barkpark_fixture()
    |> Ecto.Changeset.change(
      url: url,
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> Repo.update!()
  end

  defp call(method, path, token) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp rollback(bp_id, token), do: call(:post, "/v1/barkparks/#{bp_id}/rollback", token)

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp instance_202,
    do: {:ok, %{status: 202, body: ~s({"status":"started","target_sha":"#{@target_sha}"})}}

  describe "POST /v1/barkparks/:id/rollback — happy path" do
    test "instance 202 → 202 {status,target_sha,pinned_release}; pin = the REPORTED sha; bearer used; refresh enqueued; token never leaks" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([instance_202()])

      conn = rollback(bp.id, token)

      assert conn.status == 202

      assert json_body(conn) == %{
               "status" => "started",
               "target_sha" => @target_sha,
               "pinned_release" => @target_sha
             }

      # PIN ATOMICITY (D16): by the time the 202 answer lands, the row is
      # ALREADY pinned at the instance-REPORTED target — the rollout worker
      # can never silently re-update the rolled-back box.
      assert Registry.get_barkpark(bp.id).pinned_release == @target_sha

      # The instance-side trigger was called correctly: POST on the rollback
      # admin endpoint, the DECRYPTED admin token as bearer, empty-object body.
      assert [req] = StudioLinkFakeHttpClient.requests()
      assert req.method == :post
      assert req.url == @instance_url <> "/v1/admin/rollback"
      assert req.body == "{}"

      assert {"Authorization", "Bearer " <> @instance_admin_token} =
               List.keyfind(req.headers, "Authorization", 0)

      # The admin token itself must NEVER appear in the response.
      refute conn.resp_body =~ @instance_admin_token

      # A one-row status refresh is queued so the fleet row reflects the flip.
      assert_enqueued(worker: UpdateStatusWorker, args: %{"barkpark_id" => bp.id})
    end

    test "a PINNED box CAN roll back — the fresh pin replaces the stale one (no pin precondition)" do
      {user, team} = user_with_team()

      bp =
        team
        |> live_barkpark()
        |> Ecto.Changeset.change(pinned_release: "v0.2.24")
        |> Repo.update!()

      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([instance_202()])

      conn = rollback(bp.id, token)

      assert conn.status == 202
      assert json_body(conn)["pinned_release"] == @target_sha
      assert Registry.get_barkpark(bp.id).pinned_release == @target_sha
    end

    test "the fleet-wide halt does NOT gate manual rollback (D18)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      {:ok, _} = Registry.set_autoupdate_halted(true)
      assert Registry.autoupdate_halted?()

      StudioLinkFakeHttpClient.program([instance_202()])

      conn = rollback(bp.id, token)

      assert conn.status == 202
      assert Registry.get_barkpark(bp.id).pinned_release == @target_sha
    end
  end

  describe "POST /v1/barkparks/:id/rollback — typed refusals (D23)" do
    test "instance 409 codes relay VERBATIM and the pin is NEVER touched" do
      {user, team} = user_with_team()

      bp =
        team
        |> live_barkpark()
        |> Ecto.Changeset.change(pinned_release: "v0.2.24")
        |> Repo.update!()

      {:ok, token} = Accounts.create_user_session_token(user)

      for code <- ["no_previous_slot", "already_running", "not_supported"] do
        StudioLinkFakeHttpClient.program([
          {:ok, %{status: 409, body: ~s({"error":{"code":"#{code}"}})}}
        ])

        conn = rollback(bp.id, token)

        assert conn.status == 409
        assert json_body(conn)["error"]["code"] == code
        # The refusal left the pin exactly where it was — no phantom re-pin.
        assert Registry.get_barkpark(bp.id).pinned_release == "v0.2.24"
      end

      # An UNPINNED box refused stays unpinned too.
      bp2 = live_barkpark(team, "https://prod-2.barkpark.cloud")

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 409, body: ~s({"error":{"code":"no_previous_slot"}})}}
      ])

      assert rollback(bp2.id, token).status == 409
      assert Registry.get_barkpark(bp2.id).pinned_release == nil

      # None of the refusals queued a refresh (only a started flip does).
      refute_enqueued(worker: UpdateStatusWorker)
    end

    test "503 is matched on the BODY: feature_not_configured → not_enabled; bare proxy 503 → 502" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 503, body: ~s({"error":{"code":"feature_not_configured"}})}}
      ])

      conn = rollback(bp.id, token)
      assert conn.status == 503
      assert json_body(conn)["error"]["code"] == "not_enabled"

      # A 503 WITHOUT the instance envelope is the box's front proxy during a
      # restart window — relays as unavailable, never as "flip the env var".
      StudioLinkFakeHttpClient.program([{:ok, %{status: 503, body: "<html>maintenance</html>"}}])
      conn = rollback(bp.id, token)
      assert conn.status == 502
      assert json_body(conn)["error"]["code"] == "instance_unavailable"

      assert Registry.get_barkpark(bp.id).pinned_release == nil
    end

    test "outside-contract instance answers → 502 instance_error (pre-rollback 404, unknown 409 code, 500)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      cases = [
        # A pre-W6 instance 404s the admin endpoint — never invent semantics.
        {404, ~s({"error":{"code":"not_found"}})},
        {409, ~s({"error":{"code":"surprise"}})},
        {500, ~s({"error":{"code":"runner_start_failed"}})}
      ]

      for {status, body} <- cases do
        StudioLinkFakeHttpClient.program([{:ok, %{status: status, body: body}}])
        conn = rollback(bp.id, token)

        assert conn.status == 502
        assert json_body(conn)["error"]["code"] == "instance_error"
      end

      assert Registry.get_barkpark(bp.id).pinned_release == nil
      refute_enqueued(worker: UpdateStatusWorker)
    end

    test "transport failure → 502 instance_unreachable, pin untouched" do
      {user, team} = user_with_team()

      bp =
        team
        |> live_barkpark()
        |> Ecto.Changeset.change(pinned_release: "v0.2.24")
        |> Repo.update!()

      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([{:error, {:http_client, :timeout}}])
      conn = rollback(bp.id, token)

      assert conn.status == 502
      assert json_body(conn)["error"]["code"] == "instance_unreachable"
      assert Registry.get_barkpark(bp.id).pinned_release == "v0.2.24"
    end

    test "not-live instance (no url yet) → 409 not_live" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = rollback(bp.id, token)
      assert conn.status == 409
      assert json_body(conn)["error"]["code"] == "not_live"
    end

    test "live row without a stored admin token → 404 no_admin_token with actionable detail" do
      {user, team} = user_with_team()

      bp =
        team
        |> barkpark_fixture()
        |> Ecto.Changeset.change(url: @instance_url, host: "203.0.113.10")
        |> Repo.update!()

      {:ok, token} = Accounts.create_user_session_token(user)

      conn = rollback(bp.id, token)
      assert conn.status == 404
      assert json_body(conn)["error"]["code"] == "no_admin_token"
      assert json_body(conn)["error"]["detail"] =~ "re-provision"
    end
  end

  describe "POST /v1/barkparks/:id/rollback — billing suspension" do
    test "SUSPENDED box → 409 suspended; ZERO upstream requests; credential never on the wire; pin untouched" do
      {user, team} = user_with_team()

      bp =
        team
        |> live_barkpark()
        |> Ecto.Changeset.change(
          suspended: true,
          suspended_reason: "billing_lapsed",
          pinned_release: "v0.2.24"
        )
        |> Repo.update!()

      {:ok, token} = Accounts.create_user_session_token(user)

      # Program the 202 the box WOULD have answered: a refusal that moved below
      # the relay would still 409 on some other arm, so the WIRE is the proof.
      StudioLinkFakeHttpClient.program([instance_202()])

      conn = rollback(bp.id, token)

      # THE WIRE FIRST (cch-w54-bl): nothing reached the instance — the stored
      # admin credential was never decrypted for a suspended box.
      assert StudioLinkFakeHttpClient.requests() == []

      assert conn.status == 409
      assert json_body(conn) == %{"ok" => false, "error" => %{"code" => "suspended"}}
      refute conn.resp_body =~ @instance_admin_token

      # A refusal re-pins nothing and schedules nothing.
      assert Registry.get_barkpark(bp.id).pinned_release == "v0.2.24"
      refute_enqueued(worker: UpdateStatusWorker)
    end
  end

  describe "POST /v1/barkparks/:id/rollback — auth + team scope" do
    test "a plain team member → 403, instance never called, pin untouched" do
      {_owner, team} = user_with_team()
      bp = live_barkpark(team)

      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")
      {:ok, token} = Accounts.create_user_session_token(member)

      StudioLinkFakeHttpClient.program([])
      conn = rollback(bp.id, token)

      assert conn.status == 403
      assert StudioLinkFakeHttpClient.requests() == []
      assert Registry.get_barkpark(bp.id).pinned_release == nil
    end

    test "cross-team: an admin of ANOTHER team gets the same 404 as a nonexistent id (no leak)" do
      {_user_b, team_b} = user_with_team()
      bp_b = live_barkpark(team_b)

      {user_a, _team_a} = user_with_team()
      {:ok, token_a} = Accounts.create_user_session_token(user_a)

      StudioLinkFakeHttpClient.program([])
      wrong_team = rollback(bp_b.id, token_a)
      nonexistent = rollback(Ecto.UUID.generate(), token_a)

      assert wrong_team.status == 404
      assert nonexistent.status == 404
      assert json_body(wrong_team) == json_body(nonexistent)

      # And the instance was never called for either.
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "no token → 401" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      conn = rollback(bp.id, nil)
      assert conn.status == 401
    end
  end
end
