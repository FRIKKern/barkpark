defmodule BarkparkCloud.Web.RouterSiteDoctorTest do
  @moduledoc """
  GET /v1/sites/:id/doctor (ssw8-site-doctor) — the read-only per-substrate
  census, and the three honesty laws that make it worth reading.

  The arms that matter are the ones that would go green on a DISHONEST doctor
  unless they are written down:

    * a read that could not be PERFORMED reports `unknown` WITH its reason and
      NEVER `absent` — asserted in BOTH directions, because "unknown" is only
      meaningful if the same substrate CAN say `absent` when the box actually
      answered;
    * a node-kind site is `not_applicable` on `current_release` (the slot model
      has no `current` symlink) while a static site with the same nil pointer is
      `absent` — the branch is proven to DISCRIMINATE, not merely to exist;
    * every `absent` row carries a non-empty repair string.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, StudioLinkFakeHttpClient}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @instance_url "https://acme.barkpark.cloud"
  @instance_admin_token "instance-admin-token-plaintext"

  ## ── fixtures (same shapes as router_sites_test.exs) ─────────────────────────

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp user_with_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp live_barkpark(team) do
    team
    |> barkpark_fixture()
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> BarkparkCloud.Repo.update!()
  end

  defp static_site(bp, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(
        bp,
        Enum.into(attrs, %{
          name: "Blog #{n}",
          slug: "blog-#{n}",
          kind: "static",
          framework: "astro",
          bootstrap_workspace: "acme",
          bootstrap_project: "blog",
          bootstrap_dataset: "production",
          read_token: "bpt_public_read_xyz"
        })
      )

    site
  end

  defp node_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(
        bp,
        Enum.into(%{}, %{
          name: "SSR #{n}",
          slug: "ssr-#{n}",
          kind: "node",
          framework: "nextjs",
          bootstrap_workspace: "acme",
          bootstrap_project: "app",
          bootstrap_dataset: "production",
          read_token: "bpt_public_read_xyz"
        })
      )

    site
    |> Ecto.Changeset.change(port_base: 7002)
    |> BarkparkCloud.Repo.update!()
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp doctor(site, token) do
    conn(:get, "/v1/sites/#{site.id}/doctor")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp substrate(body, key) do
    Enum.find(body["substrates"], &(&1["key"] == key)) ||
      flunk("no `#{key}` substrate in #{inspect(Enum.map(body["substrates"], & &1["key"]))}")
  end

  # The box, programmed by PATH: the scoped content-query probe (the read token's
  # liveness), the admin webhook list, and the site's own live URL.
  defp program_box(site, opts) do
    StudioLinkFakeHttpClient.program(%{
      "/w/acme/p/blog/v1/data/query/production/post?limit=1&count=true" =>
        Keyword.get(opts, :query, {:ok, %{status: 200, body: ~s({"count":1,"total":7})}}),
      "/w/acme/p/app/v1/data/query/production/post?limit=1&count=true" =>
        Keyword.get(opts, :query, {:ok, %{status: 200, body: ~s({"count":1,"total":7})}}),
      "/v1/webhooks/production" =>
        Keyword.get(
          opts,
          :webhooks,
          {:ok,
           %{
             status: 200,
             body:
               Jason.encode!(%{
                 "webhooks" => [%{"id" => "wh_1", "name" => "site-autodeploy-#{site.id}"}]
               })
           }}
        ),
      "/sites/#{site.slug}/" =>
        Keyword.get(opts, :live, {:ok, %{status: 200, body: "<html></html>"}})
    })
  end

  ## ── ARM 1: the report, team-scoped and read-only ────────────────────────────

  test "a fully-wired site reports every substrate, and nothing is absent but the deploy history" do
    {user, team} = user_with_team()
    bp = live_barkpark(team)
    site = static_site(bp)
    program_box(site, [])

    conn = doctor(site, login_token(user))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body["site"]["id"] == site.id
    assert body["site"]["kind"] == "static"

    keys = Enum.map(body["substrates"], & &1["key"])

    for want <- ~w(cp_row instance content_binding read_token content_read
                   content_webhook webhook_secret deployments current_release live_url) do
      assert want in keys, "the report omits the `#{want}` substrate (has #{inspect(keys)})"
    end

    assert substrate(body, "cp_row")["state"] == "present"
    assert substrate(body, "instance")["state"] == "present"
    assert substrate(body, "content_binding")["state"] == "present"
    assert substrate(body, "read_token")["state"] == "present"
    assert substrate(body, "content_read")["state"] == "present"
    assert substrate(body, "content_webhook")["state"] == "present"
    assert substrate(body, "live_url")["state"] == "present"

    # A never-deployed site is the shape the census found four times over: a CP
    # row and (at most) a bare directory.
    assert substrate(body, "deployments")["state"] == "absent"
    assert substrate(body, "current_release")["state"] == "absent"
    assert body["ok"] == false
  end

  test "a wrong-team caller gets the same 404 as a nonexistent id — no existence leak" do
    {_owner, team} = user_with_team()
    bp = live_barkpark(team)
    site = static_site(bp)

    {stranger, _other_team} = user_with_team()
    stranger_token = login_token(stranger)

    wrong_team = doctor(site, stranger_token)
    assert wrong_team.status == 404
    assert Jason.decode!(wrong_team.resp_body) == %{"error" => "not_found"}

    absent =
      conn(:get, "/v1/sites/#{Ecto.UUID.generate()}/doctor")
      |> put_req_header("authorization", "Bearer #{stranger_token}")
      |> Router.call(@opts)

    assert absent.status == 404
    assert absent.resp_body == wrong_team.resp_body
  end

  test "it is read-only: the site row is byte-identical after the report" do
    {user, team} = user_with_team()
    bp = live_barkpark(team)
    site = static_site(bp)
    program_box(site, webhooks: {:ok, %{status: 200, body: ~s({"webhooks":[]})}})

    assert doctor(site, login_token(user)).status == 200
    after_run = Registry.get_team_site(team, site.id)

    assert Map.take(after_run, [
             :content_webhook_secret_encrypted,
             :read_token_encrypted,
             :current_deployment_id,
             :updated_at
           ]) ==
             Map.take(site, [
               :content_webhook_secret_encrypted,
               :read_token_encrypted,
               :current_deployment_id,
               :updated_at
             ])
  end

  ## ── ARM 2: three-valued — unknown is NOT absent ─────────────────────────────

  test "a read that could not be performed says UNKNOWN with a reason, never ABSENT" do
    {user, team} = user_with_team()
    # An instance with NO url: relay_admin/relay_as both refuse :not_live, so
    # every box-side read is unperformable.
    bp = barkpark_fixture(team)
    site = static_site(bp)

    conn = doctor(site, login_token(user))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    for key <- ~w(content_read content_webhook live_url) do
      s = substrate(body, key)

      assert s["state"] == "unknown",
             "`#{key}` reported #{s["state"]} for a read that never happened — " <>
               "an unperformable read must be UNKNOWN, never a verdict (#{s["detail"]})"

      assert is_binary(s["detail"]) and s["detail"] != "",
             "`#{key}` is unknown with no reason — the reason is the whole point"
    end

    assert body["unknown_count"] >= 3
    assert "content_webhook" in body["unreadable"]
  end

  test "the SAME substrate says ABSENT when the box actually answered — the unknown arm is not vacuous" do
    {user, team} = user_with_team()
    bp = live_barkpark(team)
    site = static_site(bp)

    # The box answered with a list, and this site's row is not in it. That is a
    # measurement, so it is a claim: absent.
    program_box(site, webhooks: {:ok, %{status: 200, body: ~s({"webhooks":[]})}})

    answered = Jason.decode!(doctor(site, login_token(user)).resp_body)
    assert substrate(answered, "content_webhook")["state"] == "absent"

    # Same site, same everything, box down on that one call.
    program_box(site, webhooks: {:ok, %{status: 502, body: "bad gateway"}})

    down = Jason.decode!(doctor(site, login_token(user)).resp_body)

    assert substrate(down, "content_webhook")["state"] == "unknown",
           "a 502 on the webhook list was read as a verdict — the repair for `absent` is a WRITE, " <>
             "so a write made on the strength of a failed read is the duplicate-webhook hazard this split prevents"
  end

  ## ── ARM 3: honesty law 2 — branch on kind ───────────────────────────────────

  test "a node site is NOT reported missing its `current` symlink, while a static site with the same nil pointer IS" do
    {user, team} = user_with_team()
    bp = live_barkpark(team)

    node = node_site(bp)
    program_box(node, [])
    node_body = Jason.decode!(doctor(node, login_token(user)).resp_body)
    node_row = substrate(node_body, "current_release")

    assert node_row["state"] == "not_applicable",
           "a node site was reported #{node_row["state"]} on `current_release` — it uses the SLOT model " <>
             "(blue/green on port_base) and has no `current` symlink at all; the naive check yields six " <>
             "false absences on today's fleet"

    assert node_row["detail"] =~ "slot model"

    # The discriminator: the SAME nil current_deployment_id on a static site is a
    # real absence. Without this the not_applicable above could be unconditional.
    stat = static_site(bp)
    program_box(stat, [])
    stat_body = Jason.decode!(doctor(stat, login_token(user)).resp_body)

    assert substrate(stat_body, "current_release")["state"] == "absent",
           "the kind branch is unconditional — it exempts a static site too, so it proves nothing"
  end

  ## ── ARM 4: honesty law 3 — every absence names its repair ───────────────────

  test "every absent substrate names a repair verb, or says outright that none exists" do
    {user, team} = user_with_team()
    bp = live_barkpark(team)

    # A site missing as much as the CP can express: no binding, no read token, no
    # content secret, no deployments.
    {:ok, bare} =
      Registry.create_site(bp, %{
        name: "Bare",
        slug: "bare-#{System.unique_integer([:positive])}",
        kind: "static",
        framework: "astro"
      })

    program_box(bare, [])
    body = Jason.decode!(doctor(bare, login_token(user)).resp_body)

    absent = Enum.filter(body["substrates"], &(&1["state"] == "absent"))

    assert absent != [], "the fixture produced no absences — this arm would pass vacuously"

    for s <- absent do
      assert is_binary(s["repair"]) and String.trim(s["repair"]) != "",
             "`#{s["key"]}` is absent and names no repair — an absence a reader cannot act on is a complaint"
    end

    # And the one that must NOT be promised: ensure_content_webhook/2 REVEALS a
    # secret and never mints one, so it is not the fix for a site with none.
    binding = substrate(body, "content_binding")
    assert binding["state"] == "absent"
    assert binding["repair"] =~ "NO repair verb exists"
  end

  # auto-proof's EXACT defect, inverted: a bound site whose content-publish secret
  # is gone. `create_site/2` mints one for every bound site, so the column is
  # nulled by hand — the only way to reach the shape the live census found.
  test "a bound site with NO content-publish secret names the operator mint, and never promises ensure_content_webhook/2" do
    {user, team} = user_with_team()
    bp = live_barkpark(team)

    site =
      static_site(bp)
      |> Ecto.Changeset.change(content_webhook_secret_encrypted: nil)
      |> BarkparkCloud.Repo.update!()

    program_box(site, webhooks: {:ok, %{status: 200, body: ~s({"webhooks":[]})}})
    body = Jason.decode!(doctor(site, login_token(user)).resp_body)

    secret = substrate(body, "webhook_secret")
    assert secret["state"] == "absent"
    assert secret["repair"] =~ "content-secrets/mint"
    assert secret["repair"] =~ "OPERATOR-only"

    # THE PROMISE THAT MUST NOT BE MADE. `ensure_content_webhook/2` REVEALS a
    # secret and never mints one, so on a site with none it returns :noop. Naming
    # it as the fix would be a repair the codebase cannot perform.
    hook = substrate(body, "content_webhook")
    assert hook["state"] == "absent"
    assert hook["repair"] =~ "REVEALS a secret and never mints one"
    assert hook["repair"] =~ "NO repair verb exists"
  end

  test "a container site is not blamed for substrates it does not have" do
    {user, team} = user_with_team()
    bp = live_barkpark(team)

    {:ok, ctr} =
      Registry.create_site(bp, %{
        name: "App",
        slug: "app-#{System.unique_integer([:positive])}",
        kind: "container",
        framework: "nextjs"
      })

    program_box(ctr, [])
    body = Jason.decode!(doctor(ctr, login_token(user)).resp_body)

    for key <- ~w(content_binding read_token content_read content_webhook webhook_secret) do
      assert substrate(body, key)["state"] == "not_applicable",
             "a container site was blamed for `#{key}`, which it never has"
    end
  end
end
