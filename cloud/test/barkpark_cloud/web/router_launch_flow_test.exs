defmodule BarkparkCloud.Web.RouterLaunchFlowTest do
  @moduledoc """
  dwb-6 — the launch-with-template response SHAPES the `/new` SPA relies on to
  drive the flow:

    * 201 {barkpark: {id, …}} — the optimistic row + progress step key off the id
    * 402 {error: "no_active_subscription", checkout_path} — the "price before any
      charge" screen (dwb-13 auto-starts the ONE free trial, so this only fires
      once the trial is spent; the SPA then shows tiers + a checkout CTA)
    * 403 {error: "limit_reached", upgrade_path} — the plan-ceiling screen

  These pin the CONTRACT the client parses; the SPA can't be browser-tested here.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing, Registry}
  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_with_team do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  # Mark the team's one free trial as already used so the dwb-13 auto-start returns
  # :trial_used and the 402 stands (mirrors go_live_limit_test.exhaust_trial/1).
  defp exhaust_trial(team) do
    past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:microsecond)

    {1, _} =
      Repo.update_all(
        from(t in Team, where: t.id == ^team.id),
        set: [trial_started_at: past, trial_ends_at: past]
      )

    :ok
  end

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  test "launch with a template → 201 {barkpark:{id}} carrying the chosen template" do
    {user, team} = user_with_team()
    {:ok, _} = Billing.subscribe(team, "supporter")
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = call(:post, "/v1/launch", %{name: "My Blog", template: "blog-starter"}, token)
    assert conn.status == 201
    bp = json_body(conn)["barkpark"]
    assert is_binary(bp["id"])
    assert bp["name"] == "My Blog"

    [row] = Registry.list_barkparks(team)
    assert row.template == "blog-starter"
  end

  test "unentitled + trial spent → 402 {no_active_subscription, checkout_path}" do
    {user, team} = user_with_team()
    exhaust_trial(team)
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = call(:post, "/v1/launch", %{name: "My Blog", template: "blog-starter"}, token)
    assert conn.status == 402
    body = json_body(conn)
    assert body["error"] == "no_active_subscription"
    assert body["checkout_path"] == "/v1/billing/checkout"

    # Nothing provisioned — the entitlement gate precedes any row/job.
    assert Registry.list_barkparks(team) == []
  end

  test "entitled but at the plan ceiling → 403 {limit_reached, upgrade_path}" do
    {user, team} = user_with_team()
    {:ok, _} = Billing.subscribe(team, "free")
    {:ok, token} = Accounts.create_user_session_token(user)

    assert call(:post, "/v1/launch", %{name: "First", template: "blog-starter"}, token).status ==
             201

    conn = call(:post, "/v1/launch", %{name: "Second", template: "blog-starter"}, token)
    assert conn.status == 403
    body = json_body(conn)
    assert body["error"] == "limit_reached"
    assert body["upgrade_path"] == "/v1/billing/checkout"
    assert length(Registry.list_barkparks(team)) == 1
  end

  # task-ef37ebad8249e82a — the /new form labels the name "(optional)" and sends
  # no `name` when the field is left blank. The server used to 422 name_required
  # on exactly that request; it now defaults the name from the template's catalog
  # title. Removing the default in go_live reds every test in this block.
  describe "a nameless launch with a template defaults the name from the template" do
    for {label, extra} <- [
          {"absent", %{}},
          {"empty", %{name: ""}},
          {"whitespace-only", %{name: "   \t "}}
        ] do
      test "#{label} name → 201, named from the template title, clean FQDN" do
        {user, team} = user_with_team()
        {:ok, _} = Billing.subscribe(team, "supporter")
        {:ok, token} = Accounts.create_user_session_token(user)

        conn =
          call(
            :post,
            "/v1/launch",
            Map.put(unquote(Macro.escape(extra)), :template, "blog-starter"),
            token
          )

        assert conn.status == 201, conn.resp_body
        assert json_body(conn)["barkpark"]["name"] == "Blog Starter"

        [row] = Registry.list_barkparks(team)
        assert row.name == "Blog Starter"
        assert row.slug == "blog-starter"
        assert row.template == "blog-starter"
        assert row.url == Barkpark.clean_url("blog-starter")
      end
    end

    test "two teams launching the same template nameless both succeed with distinct FQDNs" do
      {user_a, team_a} = user_with_team()
      {user_b, team_b} = user_with_team()
      {:ok, _} = Billing.subscribe(team_a, "supporter")
      {:ok, _} = Billing.subscribe(team_b, "supporter")
      {:ok, token_a} = Accounts.create_user_session_token(user_a)
      {:ok, token_b} = Accounts.create_user_session_token(user_b)

      assert call(:post, "/v1/launch", %{template: "blog-starter"}, token_a).status == 201
      assert call(:post, "/v1/launch", %{template: "blog-starter"}, token_b).status == 201

      [a] = Registry.list_barkparks(team_a)
      [b] = Registry.list_barkparks(team_b)
      # Clean-first: the first claimant gets the clean label; the second falls
      # back to the globally-unique `<slug>-<team_short_id>` form.
      assert a.url == Barkpark.clean_url("blog-starter")
      assert b.url == Barkpark.provisioning_url({"blog-starter", team_b.id})
      assert a.url != b.url
    end

    test "a given name still wins over the template default" do
      {user, team} = user_with_team()
      {:ok, _} = Billing.subscribe(team, "supporter")
      {:ok, token} = Accounts.create_user_session_token(user)

      assert call(:post, "/v1/launch", %{name: "Mine", template: "blog-starter"}, token).status ==
               201

      assert [%{name: "Mine", slug: "mine"}] = Registry.list_barkparks(team)
    end

    test "no template and no name → 422 name_required (nothing to derive from)" do
      {user, team} = user_with_team()
      {:ok, _} = Billing.subscribe(team, "supporter")
      {:ok, token} = Accounts.create_user_session_token(user)

      for body <- [%{}, %{name: ""}, %{name: "   "}] do
        conn = call(:post, "/v1/launch", body, token)
        assert conn.status == 422
        assert json_body(conn)["error"] == "name_required"
      end

      assert Registry.list_barkparks(team) == []
    end
  end
end
