defmodule BarkparkWeb.Studio.StudioLiveSharesScopeTenancyTest do
  @moduledoc """
  `arpss-w10-bl-shares-add-instance-wide-scope-hole`.

  `Handlers.Shares.shares_add/2` gates on `Caps.admin?/1` — admin of the
  MOUNTED workspace — and then hands `params["scope"]` to
  `Barkpark.Sharing.add_share/1` without ever comparing that scope's workspace
  against the mounted one. `Sharing.parse_scope/1` accepts any slug, so an
  admin of workspace A could declare a public read share over workspace B.

  ## RETRACTED — "Why the SESSION arm is the whole test" (task-9e9b49d5787a90be)

  This moduledoc used to argue, verbatim:

  > The escalation exists ONLY for an account principal. … a token principal
  > already holds instance-wide declare authority by design, and the LiveView
  > path is in fact STRICTER (it also demands a membership). … A token fixture
  > here would certify nothing.

  THAT WAS FALSE WHEN IT WAS WRITTEN, in both halves.

    * "instance-wide declare authority by design" — `cef6ee8465` (#12701,
      2026-08-19) moved `POST`/`DELETE /v1/shares` underneath `:require_admin`:
      `ShareController.create/2` and `delete/2` resolve the SCOPE's workspace
      and demand `Tenancy.Auth.workspace_admin?/2`. A global-`admin` token
      holding a plain `member` row in workspace B gets 403 there. So the token
      arm's authority was NOT instance-wide at the HTTP edge, and the LiveView
      panel was WIDER than its twin, not stricter.
    * "it also demands a membership" — `2f2f7dffcb` (#12695, 2026-08-19) is
      where `Caps.admin?/1`'s token arm acquired the membership requirement,
      and it says so in `caps.ex` verbatim: "arpss-w10 / D22 OVERTURNS the
      former 'the token arm is deliberately membership-FREE'". But that seat is
      read on the MOUNTED workspace, never on the SUBMITTED scope's — which is
      precisely the gap, not a closure of it.

  `bb3b203f58` (#12929, 2026-08-21) added the clamp below and this file with
  the exemption above — TWO DAYS AFTER both commits it contradicts. A "token
  fixture would certify nothing" is the sentence that kept the third door open
  for three days; the token-arm section at the bottom of this file is that
  fixture, and it reproduces a real cross-tenant declare and revoke.

  ## What this file now covers

    * the ACCOUNT arm (`describe "an account admin of ONE workspace"`) — the
      original `arpss-w10` defect;
    * the LIST half (`task-c91e5e19da811fe5`);
    * the TOKEN arm (`task-9e9b49d5787a90be`) — the foreign-scope arm held to
      `ShareController`'s own predicate, with the ghost-share divergence pinned.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Sharing, Tenancy}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Sharing.StoredShare
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    ws_a = create_workspace!("arpss-shares-a-#{System.unique_integer([:positive])}")
    proj_a = create_project!(ws_a, "arpss-shares-pa-#{System.unique_integer([:positive])}")
    ws_b = create_workspace!("arpss-shares-b-#{System.unique_integer([:positive])}")
    proj_b = create_project!(ws_b, "arpss-shares-pb-#{System.unique_integer([:positive])}")

    {default_ws, _default_proj} = ensure_default_scope!()

    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    {:ok,
     conn: conn, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b, default_ws: default_ws}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp account_admin_session!(conn, ws, role) do
    email = "arpss-shares-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  defp mount_on(conn, ws, proj) do
    live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio")
  end

  describe "an account admin of ONE workspace" do
    test "cannot declare a share over a DIFFERENT workspace", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      {_user, conn} = account_admin_session!(conn, ws_a, "admin")
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)

      render_hook(view, "shares-add", %{
        "scope" => "#{ws_b.slug}/default/#{@dataset}",
        "surfaces" => ["papers"]
      })

      refute Sharing.shared?(ws_b.slug, "default", @dataset, :papers),
             "an admin of #{ws_a.slug} declared a public share over #{ws_b.slug}"
    end

    test "cannot REVOKE a share over a DIFFERENT workspace (the availability mirror)", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      # Stand the victim share up directly, as an instance operator would.
      {:ok, _} = Sharing.add_share("#{ws_b.slug}/default/#{@dataset}:papers:read")
      assert Sharing.shared?(ws_b.slug, "default", @dataset, :papers)

      {_user, conn} = account_admin_session!(conn, ws_a, "admin")
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)

      render_hook(view, "shares-remove", %{"scope" => "#{ws_b.slug}/default/#{@dataset}"})

      assert Sharing.shared?(ws_b.slug, "default", @dataset, :papers),
             "an admin of #{ws_a.slug} revoked #{ws_b.slug}'s share"
    end

    test "CAN still declare a share over its OWN workspace (the guard is not a blanket deny)",
         %{conn: conn, ws_a: ws_a, proj_a: proj_a} do
      {_user, conn} = account_admin_session!(conn, ws_a, "admin")
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)

      render_hook(view, "shares-add", %{
        "scope" => "#{ws_a.slug}/#{proj_a.slug}/#{@dataset}",
        "surfaces" => ["papers"]
      })

      assert Sharing.shared?(ws_a.slug, proj_a.slug, @dataset, :papers)
    end
  end

  # ─── THE LIST HALF (task-c91e5e19da811fe5) ──────────────────────────────────
  #
  # The two tests above are the WRITE halves, and `shares_remove/2`'s own comment
  # calls its clamp "the availability mirror of the DISCLOSURE hole". The
  # disclosure direction it names was never closed: `load_share_rows/0` took no
  # scope argument at all, so `shares_open/2` — gated only on `Caps.admin?/1`,
  # i.e. admin of the MOUNTED workspace — assigned the whole instance's share
  # inventory: every workspace/project/dataset publicly shared, plus each one's
  # anonymous `:papers` reader URL.
  #
  # `load_item_links/2`, in the SAME module, was already workspace-scoped
  # (`Links.list_for(ws_id, ...)`). Same file, same panel, opposite treatment.

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp seed_shares!(ws_a, proj_a, ws_b) do
    {:ok, _} = Sharing.add_share("#{ws_b.slug}/default/#{@dataset}:papers:read")
    {:ok, _} = Sharing.add_share("#{ws_a.slug}/#{proj_a.slug}/#{@dataset}:papers:read")
    :ok
  end

  describe "the LIST half — the disclosure direction" do
    test "an account admin of ONE workspace does not SEE another workspace's shares", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      seed_shares!(ws_a, proj_a, ws_b)

      {_user, conn} = account_admin_session!(conn, ws_a, "admin")
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)

      html = render_hook(view, "shares-open", %{})

      refute html =~ ws_b.slug,
             "an admin of #{ws_a.slug} was shown #{ws_b.slug}'s share inventory"

      # OVER-CLAMP CONTROL, same render: the panel is not simply empty.
      assert html =~ "#{ws_a.slug}/#{proj_a.slug}/#{@dataset}",
             "the clamp hid the caller's OWN share"
    end

    # A SECOND DOOR onto the same assign: `?shares=open` opens the panel during
    # mount via `Shared.maybe_open_shares/2`, which called the same unscoped
    # `load_share_rows/0`. Fixing `shares_open/2` alone would leave this one.
    test "the ?shares=open mount door is clamped too", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      seed_shares!(ws_a, proj_a, ws_b)

      {_user, conn} = account_admin_session!(conn, ws_a, "admin")

      {:ok, _view, html} =
        live(conn, "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/#{@dataset}/studio?shares=open")

      refute html =~ ws_b.slug,
             "the ?shares=open mount door served #{ws_b.slug}'s inventory"

      assert html =~ "#{ws_a.slug}/#{proj_a.slug}/#{@dataset}"
    end

    # A THIRD DOOR: both mutate handlers refresh `shares_rows` from the same
    # function after writing.
    test "the refresh after shares-add is clamped too", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      seed_shares!(ws_a, proj_a, ws_b)

      {_user, conn} = account_admin_session!(conn, ws_a, "admin")
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)
      render_hook(view, "shares-open", %{})

      html =
        render_hook(view, "shares-add", %{
          "scope" => "#{ws_a.slug}/#{proj_a.slug}/#{@dataset}",
          "surfaces" => ["papers", "docs"]
        })

      refute html =~ ws_b.slug,
             "the post-add refresh re-served #{ws_b.slug}'s inventory"
    end

    # EXISTENCE, not just bodies. The row COUNT derives from the same list, so a
    # clamped render over an unclamped list would still reveal how many shares
    # exist elsewhere. Asserted on the data, where a count would be computed —
    # the template renders no total today, and this pins that it cannot start
    # leaking one from an unclamped source. Also pins the anonymous reader URL,
    # which is the part of a row that is an entry point rather than a label.
    test "the assign holds ONLY the mounted workspace's rows", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      seed_shares!(ws_a, proj_a, ws_b)

      {_user, conn} = account_admin_session!(conn, ws_a, "admin")
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)
      render_hook(view, "shares-open", %{})

      rows = assigns(view).shares_rows

      assert length(rows) == 1, "expected exactly A's one row, got #{inspect(rows)}"
      assert [%{scope: scope}] = rows
      assert scope == "#{ws_a.slug}/#{proj_a.slug}/#{@dataset}"

      refute Enum.any?(rows, &String.contains?(&1.scope, ws_b.slug))

      refute Enum.any?(rows, fn r -> is_binary(r.url) and String.contains?(r.url, ws_b.slug) end),
             "a foreign share's anonymous reader URL survived the clamp"
    end

    # OVER-CLAMP CONTROL, the by-design arm: a token carrying the global `admin`
    # permission is exactly what `/v1/shares` (`:require_admin`) demands, so it
    # holds instance-wide declare authority and MUST still see the whole
    # inventory. Without this arm the cheapest way to pass every test above is
    # to return [].
    test "a token with instance declare authority still sees EVERY workspace's shares", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      default_ws: default_ws
    } do
      seed_shares!(ws_a, proj_a, ws_b)

      raw = "shares-list-instance-" <> Ecto.UUID.generate()

      {:ok, token} =
        Barkpark.Auth.create_token(
          raw,
          "shares-list-instance",
          @dataset,
          ~w(read admin),
          default_ws.id
        )

      {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, token.id, "admin", "api_token")

      conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)

      html = render_hook(view, "shares-open", %{})

      assert html =~ ws_b.slug,
             "instance declare authority was over-clamped out of its own inventory"
    end
  end

  # ─── THE TOKEN ARM (task-9e9b49d5787a90be) ──────────────────────────────────
  #
  # THE THIRD DOOR. The describes above prove the ACCOUNT arm is confined and
  # the LIST half is scoped. The WRITE half's FOREIGN arm was neither: when the
  # submitted scope's first segment did not match the mounted workspace,
  # `Shared.declarable_scope?/2` fell back to `instance_declare_authority?/1` —
  # a bare `Barkpark.Auth.has_permission?(token, "admin")`, a GLOBAL bit with no
  # membership lookup and no target-workspace resolution. Its HTTP twin resolves
  # the scope to a workspace id and demands `Tenancy.Auth.workspace_admin?/2`.
  # Same actor, same request: ALLOWED in the panel, 403 over HTTP.
  #
  # THE ACTOR SHAPE THE PREDICATE CHOICE TURNS ON. The token below is a genuine
  # seat admin of ws-A (a real `admin` membership row, so `Caps.admin?/1` passes
  # on its own seat and no denial here can be the panel's admin gate firing) and
  # holds a REAL but plain `member` row in ws-B. A stranger to B would be denied
  # under BOTH candidate predicates and would prove nothing.
  #
  # That shape is also why the predicate must be `workspace_admin?/2` and NEVER
  # `Tenancy.Auth.authorize/3`: `authorize/3`'s api_token arm ORs the token's
  # GLOBAL `permissions[]` with membership, so this actor PASSES
  # `authorize(tok, B, :admin)` and FAILS `workspace_admin?(tok, B)`. Both are
  # asserted in `token_preconditions!/3`, so swapping the handler's call for
  # `authorize/3` turns the leak tests green on a leaking handler.

  defp instance_admin_token!(conn, ws_a, ws_b, default_ws) do
    raw = "shares-scope-tenancy-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(
        raw,
        "shares scope tenancy",
        @dataset,
        ~w(read write admin),
        default_ws.id
      )

    {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, token.id, "admin", "api_token")
    {:ok, _} = Tenancy.Auth.create_membership(ws_b.id, token.id, "member", "api_token")

    token_preconditions!(token, ws_a, ws_b)
    {token, Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  defp token_preconditions!(token, ws_a, ws_b) do
    assert TenancyAuth.workspace_admin?(token, ws_a.id),
           "the actor must be a genuine seat admin of the MOUNTED workspace, or a denial " <>
             "below could come from Caps.admin?/1 and would prove nothing"

    assert TenancyAuth.membership_role(token, ws_b.id) == "member"
    assert TenancyAuth.authorize(token, ws_b.id, :admin) == :ok
    refute TenancyAuth.workspace_admin?(token, ws_b.id)

    # The global bit the OLD foreign arm rode. Asserting it is what makes the
    # leak tests non-vacuous: the reverted handler WOULD have allowed this.
    assert Auth.has_permission?(token, "admin")
  end

  # Mounts ws-A's Studio and OPENS the panel. Opening requires `Caps.admin?/1`,
  # so a socket that reaches "Network shares" has cleared the panel's own admin
  # gate.
  defp token_panel(conn, ws_a, proj_a, ws_b, default_ws) do
    {token, conn} = instance_admin_token!(conn, ws_a, ws_b, default_ws)
    {:ok, view, _html} = mount_on(conn, ws_a, proj_a)

    assert render_hook(view, "shares-open", %{}) =~ "Network shares"
    {token, view}
  end

  defp stored_share_count, do: Repo.aggregate(StoredShare, :count)

  describe "the TOKEN arm — the disclosure half" do
    test "LEAK CLOSED: a global-admin token seated in ws-A cannot declare over ws-B", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      default_ws: default_ws
    } do
      {_token, view} = token_panel(conn, ws_a, proj_a, ws_b, default_ws)

      refute Sharing.shared?(ws_b.slug, "default", @dataset, :docs)
      before_count = stored_share_count()

      render_hook(view, "shares-add", %{
        "scope" => "#{ws_b.slug}/default/#{@dataset}",
        "surfaces" => ["docs", "media"]
      })

      # THE STORE IS THE PROOF, not the flash. A "denial" that still wrote the
      # row would be the same cross-tenant disclosure in disguise.
      refute Sharing.shared?(ws_b.slug, "default", @dataset, :docs),
             "a global-admin token seated in #{ws_a.slug} declared a public share over #{ws_b.slug}"

      refute Sharing.shared?(ws_b.slug, "default", @dataset, :media)
      refute Sharing.shared?(ws_b.slug, "default", @dataset, :papers)
      assert stored_share_count() == before_count

      # ...and the panel says why, in the HTTP twin's own terms.
      assert render(view) =~ "not an admin of that scope&#39;s workspace"
    end

    test "a BARE ws-B slug is refused too (parse_scope defaults the missing segments)", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      default_ws: default_ws
    } do
      {_token, view} = token_panel(conn, ws_a, proj_a, ws_b, default_ws)
      before_count = stored_share_count()

      render_hook(view, "shares-add", %{"scope" => ws_b.slug, "surfaces" => ["docs"]})

      refute Sharing.shared?(ws_b.slug, "default", @dataset, :docs)
      assert stored_share_count() == before_count
    end

    test "a foreign workspace that EXISTS with a project that does not is still refused", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      default_ws: default_ws
    } do
      {_token, view} = token_panel(conn, ws_a, proj_a, ws_b, default_ws)
      before_count = stored_share_count()

      # The clamp resolves the WORKSPACE segment only — matching
      # `ShareController.delete/2`'s shape — so an unknown project under a real
      # foreign workspace must not become an escape hatch.
      render_hook(view, "shares-add", %{
        "scope" => "#{ws_b.slug}/no-such-project/#{@dataset}",
        "surfaces" => ["docs"]
      })

      refute Sharing.shared?(ws_b.slug, "no-such-project", @dataset, :docs)
      assert stored_share_count() == before_count
    end
  end

  describe "the TOKEN arm — the availability half" do
    setup %{ws_b: ws_b, proj_b: proj_b} do
      # ws-B's OWN live share, plus the edit token that rides it. This is the
      # asset `remove_share/3` destroys: it deletes the row AND hard-revokes
      # every ApiToken bound to the scope (`Auth.revoke_share_tokens/3`).
      # `create_share_token/5` REQUIRES an `:edit` share, so this fixture also
      # states the ceiling from the other side: `shares_add/2` hardcodes
      # `:read`, so the panel could never have forged this precondition itself.
      # ws-B's REAL project: `Auth.create_share_token/5` resolves the workspace
      # AND the project, so a ghost project slug would fail the fixture, not the
      # gate under test.
      scope_b = "#{ws_b.slug}/#{proj_b.slug}/#{@dataset}"
      {:ok, _} = Sharing.add_share("#{scope_b}:docs,media:edit")
      assert Sharing.access_for(ws_b.slug, proj_b.slug, @dataset) == :edit

      {:ok, {raw_b, token_b}} =
        Auth.create_share_token(ws_b.slug, proj_b.slug, @dataset, ["docs", "media"])

      assert is_nil(Repo.get(ApiToken, token_b.id).revoked_at)

      %{scope_b: scope_b, raw_b: raw_b, token_b: token_b}
    end

    test "LEAK CLOSED: ws-B's share stays live and its edit tokens stay unrevoked", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b,
      default_ws: default_ws,
      scope_b: scope_b,
      raw_b: raw_b,
      token_b: token_b
    } do
      {_token, view} = token_panel(conn, ws_a, proj_a, ws_b, default_ws)

      render_hook(view, "shares-remove", %{"scope" => scope_b})

      # Disclosure side: the share was NOT deleted.
      assert Sharing.shared?(ws_b.slug, proj_b.slug, @dataset, :docs),
             "a global-admin token seated in #{ws_a.slug} revoked #{ws_b.slug}'s share"

      assert Sharing.shared?(ws_b.slug, proj_b.slug, @dataset, :media)
      assert Sharing.access_for(ws_b.slug, proj_b.slug, @dataset) == :edit

      # Availability side, RELOADED FROM THE DB: B's live credential did not go
      # dark. The status/flash is not trusted.
      assert is_nil(Repo.get(ApiToken, token_b.id).revoked_at)
      assert {:ok, _} = Auth.verify_token(raw_b)

      assert render(view) =~ "not an admin of that scope&#39;s workspace"
    end

    test "a BARE ws-B slug cannot reach B's tokens either", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      default_ws: default_ws,
      token_b: token_b
    } do
      {_token, view} = token_panel(conn, ws_a, proj_a, ws_b, default_ws)

      render_hook(view, "shares-remove", %{"scope" => ws_b.slug})

      assert is_nil(Repo.get(ApiToken, token_b.id).revoked_at)
      assert render(view) =~ "not an admin of that scope&#39;s workspace"
    end
  end

  describe "the TOKEN arm — the legit path is not collateral damage" do
    # HONEST LIMIT: every assertion in this describe is PERMISSIVE, so it can
    # NEVER go red under a full reversion of the confinement — removing a clamp
    # cannot turn an allowed action into a denied one. Its mutation receipt is
    # against OVER-confinement (drop the mounted fast path AND raise the role
    # floor from ~w(owner admin) to `owner`), quoted in the commit body.
    test "a mounted-workspace admin still declares AND removes its OWN share, on the store", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      default_ws: default_ws
    } do
      {_token, view} = token_panel(conn, ws_a, proj_a, ws_b, default_ws)
      scope_a = "#{ws_a.slug}/#{proj_a.slug}/#{@dataset}"

      refute Sharing.shared?(ws_a.slug, proj_a.slug, @dataset, :docs)

      render_hook(view, "shares-add", %{"scope" => scope_a, "surfaces" => ["docs", "papers"]})

      assert Sharing.shared?(ws_a.slug, proj_a.slug, @dataset, :docs)
      assert Sharing.shared?(ws_a.slug, proj_a.slug, @dataset, :papers)
      assert Sharing.access_for(ws_a.slug, proj_a.slug, @dataset) == :read
      refute render(view) =~ "not an admin of that scope&#39;s workspace"

      render_hook(view, "shares-remove", %{"scope" => scope_a})

      refute Sharing.shared?(ws_a.slug, proj_a.slug, @dataset, :docs)
      refute Sharing.shared?(ws_a.slug, proj_a.slug, @dataset, :papers)
    end
  end

  # ─── TOTALITY: a denial, never a crash oracle ───────────────────────────────
  #
  # `Tenancy.Auth.workspace_admin?/2` raises `FunctionClauseError` on a nil id
  # and `Ecto.Query.CastError` on a non-UUID binary (including ""). The handler
  # never hands it a raw scope segment: `target_workspace_admits?/2` RESOLVES
  # the slug to a `%Tenancy.Workspace{}` first and only the DB row's own `id`
  # reaches the predicate, so the crash oracle is structurally unreachable —
  # the same shape the HTTP controllers buy with `Repo.uuid_or_nil/1`. These
  # tests prove it from the outside: the LiveView must stay alive and keep
  # serving the panel in every shape below.
  describe "the TOKEN arm — totality" do
    setup %{conn: conn, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, default_ws: default_ws} do
      {token, view} = token_panel(conn, ws_a, proj_a, ws_b, default_ws)
      %{token: token, view: view}
    end

    test "an empty or whitespace-only scope is a refusal, never a crash", %{view: view} do
      before_count = stored_share_count()

      for blank <- ["", "   "] do
        render_hook(view, "shares-add", %{"scope" => blank, "surfaces" => ["docs"]})

        html = render(view)
        assert html =~ "Scope is required."
        assert html =~ "Network shares"
      end

      assert stored_share_count() == before_count
    end

    test "a malformed scope is a refusal, never a crash", %{view: view} do
      before_count = stored_share_count()

      for bad <- ["*/default/production", "//production", "a/b/c/d/e", "ws:docs:read"] do
        render_hook(view, "shares-add", %{"scope" => bad, "surfaces" => ["docs"]})

        html = render(view)
        assert html =~ "Network shares", "the panel died on scope #{inspect(bad)}"
        assert html =~ "Invalid share" or html =~ "Scope is required."
      end

      assert stored_share_count() == before_count
    end

    test "shares-remove on an empty or malformed scope is a refusal, never a crash", %{
      view: view
    } do
      for bad <- ["", "   ", "*/default/production", "//production"] do
        render_hook(view, "shares-remove", %{"scope" => bad})

        html = render(view)
        assert html =~ "Network shares", "the panel died on scope #{inspect(bad)}"
        assert html =~ "Could not parse that scope."
      end
    end

    test "a scope naming a workspace that does not exist does not crash the panel", %{view: view} do
      ghost = "no-such-workspace-#{System.unique_integer([:positive])}"
      ghost_scope = "#{ghost}/default/#{@dataset}"

      render_hook(view, "shares-add", %{"scope" => ghost_scope, "surfaces" => ["docs"]})

      # THE ONE DECLARED DIVERGENCE FROM THE HTTP TWIN, PINNED HERE RATHER THAN
      # LEFT UNDESCRIBED.
      #
      # `ShareController.create/2` answers 422 for an unresolvable workspace
      # (THE GHOST SHARE, cef6ee8465 / #12701). This panel still ALLOWS it: an
      # unresolvable slug keeps the answer `instance_declare_authority?/1`
      # already gave, because closing it is a behaviour change beyond this row's
      # proof obligation ("a workspace-A admin … against workspace B", a
      # workspace that EXISTS) and it reds two `studio_live_shares_test.exs`
      # cases that declare and revoke `gyldendal/default/production` — a slug
      # with no workspace row — as the panel's own happy path.
      #
      # THE CEILING ON THAT DIVERGENCE, which is why it can wait: `shares_add/2`
      # hardcodes `:read`, so this surface cannot pre-plant the `:edit` share
      # `Auth.create_share_token/5` requires. The HTTP 422 exists to stop a
      # forged `:edit` ghost; there is no `:edit` to forge here.
      #
      # ASSERTED AS-IS SO A CHANGE IS LOUD: if the ghost arm is ever closed,
      # this line reds and whoever closes it must also move the two sibling
      # cases, rather than discovering the coupling in CI.
      assert Sharing.shared?(ghost, "default", @dataset, :docs)
      assert Sharing.access_for(ghost, "default", @dataset) == :read

      # What this test is FOR: no 500, no raised LiveView.
      assert render(view) =~ "Network shares"

      # The REMOVE half is at exact parity with `delete/2`, which also declines
      # to confine an unresolvable workspace — it is the only cleanup path for
      # ghost rows.
      render_hook(view, "shares-remove", %{"scope" => ghost_scope})
      refute Sharing.shared?(ghost, "default", @dataset, :docs)
      assert render(view) =~ "Network shares"
    end
  end
end
