defmodule BarkparkCloud.Web.SiteDomainTxtProofTest do
  @moduledoc """
  Owner ruling #29 (2026-10-03, "DNS TXT check"): a site claims a domain only
  after its team proves control by publishing
  `_barkpark-verify.<domain> TXT "barkpark-verify=<token>"`.

  The hole: before this, any member of any team could claim `bigcustomer.com`
  for a site with no proof, and the real owner then got `domain_taken`
  platform-wide with no way back.

    * unproven → 409 `domain_verification_required` naming the record; nothing
      claimed; the token is STABLE across retries
    * the right TXT → 200, claimed; a wrong TXT or a resolver failure → refused
    * a domain the site already holds (pre-ruling data) stays idempotent
    * the CREATE door refuses an unproven domain and writes no row
    * RECLAIM: a proven owner takes back a name another team's site squatted —
      unless DNS also backs the holder; a barkpark custom_host is never reclaimed
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, DomainOwnership, DomainProofHelper, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @domain "bigcustomer.com"

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_with(role) do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {team, token}
  end

  defp site_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    {:ok, site} =
      Registry.create_site(bp, %{name: "Shop #{n}", slug: "shop-#{n}", framework: "nextjs"})

    {bp, site}
  end

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp add_domain(site, domain, token),
    do: call(:post, "/v1/sites/#{site.id}/domains", %{domain: domain}, token)

  defp body(conn), do: Jason.decode!(conn.resp_body)
  defp holds?(site, domain), do: domain in Registry.get_site(site.id).domains

  describe "POST /v1/sites/:id/domains — the proof" do
    test "unproven → 409 naming the record; nothing claimed; the token is stable across retries" do
      {team, token} = team_with("member")
      {_bp, site} = site_fixture(team)

      first = add_domain(site, @domain, token)
      assert first.status == 409
      b1 = body(first)
      assert b1["error"] == "domain_verification_required"
      assert b1["verification"]["txt_name"] == "_barkpark-verify.bigcustomer.com"
      assert "barkpark-verify=" <> _ = b1["verification"]["txt_value"]
      assert b1["detail"] =~ "_barkpark-verify.bigcustomer.com"
      refute holds?(site, @domain)

      second = add_domain(site, @domain, token)
      assert body(second)["verification"]["txt_value"] == b1["verification"]["txt_value"]
    end

    test "the right TXT record → 200 and the domain is claimed" do
      {team, token} = team_with("member")
      {_bp, site} = site_fixture(team)
      DomainProofHelper.publish(@domain, [DomainProofHelper.value_for(team.id, @domain)])

      conn = add_domain(site, @domain, token)

      assert conn.status == 200, conn.resp_body
      assert holds?(site, @domain)
    end

    test "a WRONG TXT value is refused, and shows what DNS answered" do
      {team, token} = team_with("member")
      {_bp, site} = site_fixture(team)
      DomainProofHelper.publish(@domain, ["barkpark-verify=someone-elses-token"])

      conn = add_domain(site, @domain, token)

      assert conn.status == 409
      assert body(conn)["observed_txt"] == ["barkpark-verify=someone-elses-token"]
      refute holds?(site, @domain)
    end

    test "a resolver failure is unproven (fail closed)" do
      {team, token} = team_with("member")
      {_bp, site} = site_fixture(team)
      DomainOwnership.put_txt_dns(fn _ -> raise "SERVFAIL" end)

      assert add_domain(site, @domain, token).status == 409
      refute holds?(site, @domain)
    end

    test "a domain the site ALREADY holds (pre-ruling data) stays idempotent with no TXT" do
      {team, token} = team_with("member")
      {_bp, site} = site_fixture(team)
      {:ok, site} = Registry.add_site_domain(site, "legacy.example.org")

      assert add_domain(site, "legacy.example.org", token).status == 200
      assert holds?(site, "legacy.example.org")
    end
  end

  describe "POST /v1/sites — the create door" do
    test "an unproven domain → 409 with its record, and NO site row" do
      {team, token} = team_with("owner")
      n = System.unique_integer([:positive])
      {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

      conn =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "Shop", framework: "nextjs", domains: [@domain]},
          token
        )

      assert conn.status == 409
      assert [%{"txt_name" => "_barkpark-verify.bigcustomer.com"}] = body(conn)["verifications"]
      assert Registry.list_sites(bp) == []
    end

    test "a proven domain creates (201)" do
      {team, token} = team_with("owner")
      n = System.unique_integer([:positive])
      {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
      DomainProofHelper.publish(@domain, [DomainProofHelper.value_for(team.id, @domain)])

      conn =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "Shop", framework: "nextjs", domains: [@domain]},
          token
        )

      assert conn.status == 201, conn.resp_body
    end
  end

  describe "the reclaim path" do
    # A squat from BEFORE the ruling: written straight through add_site_domain/2.
    defp squatted do
      {squat_team, _} = team_with("member")
      {_bp, squat_site} = site_fixture(squat_team)
      {:ok, squat_site} = Registry.add_site_domain(squat_site, @domain)
      {squat_team, squat_site}
    end

    test "the proven owner takes the name back from another team's site" do
      {_squat_team, squat_site} = squatted()
      {owner_team, token} = team_with("member")
      {_bp, site} = site_fixture(owner_team)
      DomainProofHelper.publish(@domain, [DomainProofHelper.value_for(owner_team.id, @domain)])

      conn = add_domain(site, @domain, token)

      assert conn.status == 200, conn.resp_body
      assert holds?(site, @domain)
      refute holds?(squat_site, @domain)
    end

    test "no reclaim while DNS ALSO backs the holder — 409 domain_taken, nothing moves" do
      {squat_team, squat_site} = squatted()
      {owner_team, token} = team_with("member")
      {_bp, site} = site_fixture(owner_team)

      DomainProofHelper.publish(@domain, [
        DomainProofHelper.value_for(owner_team.id, @domain),
        DomainProofHelper.value_for(squat_team.id, @domain)
      ])

      conn = add_domain(site, @domain, token)

      assert conn.status == 409
      assert body(conn)["error"] == "domain_taken"
      assert holds?(squat_site, @domain)
      refute holds?(site, @domain)
    end

    test "a barkpark custom_host is never reclaimed through a site domain" do
      {other_team, _} = team_with("owner")
      n = System.unique_integer([:positive])

      {:ok, other_bp} =
        Registry.register_barkpark(other_team, %{name: "BP #{n}", slug: "bp-#{n}"})

      {:ok, _} = Registry.set_custom_host(other_bp, @domain)

      {owner_team, token} = team_with("member")
      {_bp, site} = site_fixture(owner_team)
      DomainProofHelper.publish(@domain, [DomainProofHelper.value_for(owner_team.id, @domain)])

      conn = add_domain(site, @domain, token)

      assert conn.status == 409
      assert body(conn)["error"] == "domain_taken"
      assert Registry.get_barkpark(other_bp.id).custom_host == @domain
    end
  end
end
