defmodule BarkparkWeb.LiveViewMountAuthzCensusTest do
  @moduledoc """
  arpss-lv-mount-authz-census — the executable mount-authz capstone for the
  LiveView security wave (epic `api-read-path-security-sweep`, wave 6).

  This is a CERTIFICATION guard, not a re-derivation: the four-hook mount stack
  (`LiveAuth.:admin`, `LiveAuth.:scoped_admin`, `LiveAuth.:fetch_api_token` +
  `LiveScope.:resolve`, and the plugin public buckets) is already merged. The
  test pins it so a future edit that drops a gate reddens CI. Each privileged
  independently-routed LiveView is asserted to DENY an anonymous socket AND a
  wrong-role authenticated socket at mount, with a POSITIVE control per module
  so the deny is never a blanket redirect. The 5 public LiveViews are asserted
  anonymous-mountable by design (documented why), so the guard never falsely
  demands auth on a public surface.

  ## Authz census, keyed on `{module, live_session}`

  The key is the PAIR, never the module alone. `ChatLive` is routed in TWO
  live_sessions whose `on_mount` chains differ (`:admin_studio` and
  `:scoped_admin_studio`), so a module-keyed row describes one door and stays
  silent about the other. It was keyed on the module until
  `pds-w42-bl-chatlive-routed-clauses-ungated`, and the missing
  `{ChatLive, :scoped_admin_studio}` row is why this census read green through a
  live cross-tenant delete on the flat route.

  ### ADMIN tier — flat global `admin` permission (`LiveAuth.:admin`), deny → /studio

  | Module              | live_session            | Route                                                     | Deny target |
  |---------------------|-------------------------|-----------------------------------------------------------|-------------|
  | OrgAdminLive        | :admin_studio           | /studio/org-admin                                         | /studio     |
  | StyleguideLive      | :admin_studio           | /studio/styleguide                                        | /studio     |
  | SwatchLive          | :admin_swatch           | /studio/styleguide/swatch                                 | /studio     |
  | TmuxLive            | :admin_studio           | /studio/tmux                                              | /studio     |
  | ChatLive            | :admin_studio           | /studio/chat                                              | /studio     |
  | PluginsLive         | :scoped_plugin_admin    | /w/:ws/p/:proj/d/:ds/studio/_plugins                      | /studio     |
  | PluginSettingsLive  | :scoped_plugin_admin    | /w/:ws/p/:proj/d/:ds/studio/_plugins/:plugin/settings     | /studio     |

  TmuxLive and ChatLive carry a SECOND runtime gate inside their own mount
  (`TmuxConsole.enabled?/0` needs a compiled PTY backend + the flag; ChatLive
  needs an enabled Claude/Codex runtime). The positive control enables that
  runtime via config so `{:ok, …}` genuinely holds and the authz pass is real,
  not masked by the runtime gate. Wrong-role for this tier is a `read`-only
  token (no `admin` permission).

  ### SCOPED-ADMIN tier — TARGET-workspace admin (`LiveAuth.:scoped_admin`), deny → /studio

  | Module         | live_session          | Route                                | Deny target |
  |----------------|-----------------------|--------------------------------------|-------------|
  | SettingsLive   | :scoped_admin_studio  | /w/:ws/p/:proj/studio/settings       | /studio     |
  | ChatHostsLive  | :scoped_admin_studio  | /w/:ws/p/:proj/studio/chat-hosts     | /studio     |
  | ConnectorsLive | :scoped_admin_studio  | /w/:ws/p/:proj/studio/connectors     | /studio     |
  | ChatLive       | :scoped_admin_studio  | /w/:ws/p/:proj/studio/chat           | /studio     |

  `ChatLive` appears in BOTH tiers — that is the point of keying on the pair.
  Its flat row rides a global-permission gate; its scoped row rides the
  target-workspace gate. The two rows disagree about the same module, and both
  are true.

  Wrong-role for this tier is the W24 escalation shape: a token holding the
  flat global `admin` permission but only a `member` (not owner/admin) role in
  the TARGET workspace — denied by `Tenancy.Auth.workspace_admin?/2`. The
  positive control holds an owner/admin membership in the target workspace.

  ### READ-level studio — token + membership read gate
  (`LiveAuth.:fetch_api_token` + `LiveScope.:resolve`), deny → /login

  | Module        | Route                                   | Deny target |
  |---------------|-----------------------------------------|-------------|
  | StudioLive    | /w/:ws/p/:proj/d/:ds/studio             | /login      |
  | MediaLive     | /w/:ws/p/:proj/d/:ds/studio/media       | /login      |
  | ApiTesterLive | /w/:ws/p/:proj/d/:ds/studio/api-tester  | /login      |

  These read desks require the `:public_demo_studio` flag OFF (production
  posture — the flag is ON by default in test.exs, which would let an anon
  mount the seeded Default demo). The census flips it OFF and targets a
  NON-default workspace, so the `:shared_studio_browser` conn pipeline halts
  the DEAD render with a 403 before the LiveScope on_mount hook is reached
  (the seeded Default + flag-on path is the only one that 302s to /login).
  The deny assertion therefore accepts EITHER a forbidden status OR a /login
  redirect — never a 200 mount. Wrong-role for this tier is a valid token that
  is a member of a DIFFERENT workspace, not the target (the cross-tenant seam).
  The positive control is a member (read) token of the target workspace, which
  clears both the conn pipeline and the on_mount gate to `{:ok, …}`.

  ### PUBLIC tier — anonymous-mountable BY DESIGN (no authz on_mount hook)

  | Module           | Route              | Why intentionally public |
  |------------------|--------------------|--------------------------|
  | FinderLive       | /finder            | The cross-content search surface — a public read tool; `:finder` live_session carries NO auth on_mount. |
  | QuizHostLive     | /quiz/host/:pin    | Hyperquiz presenter — `:public_root`, no auth; `mount` calls `Quiz.ensure_room/1` and a host joins by PIN. |
  | QuizPlayLive     | /quiz/play/:pin    | Hyperquiz player — `:public_root`, no auth; anyone with the room PIN plays. |
  | SheetsReaderLive | /sheets/:slug      | Published-only read-only grid — the `/papers/:slug` public-reader precedent; anonymous read of a PUBLISHED sheet. |
  | BulldocsLive     | /papers/:slug      | Published-only paper reader — `:public_root`, anonymous read of a PUBLISHED paper; the canonical public surface. |

  The public assertions prove the ABSENCE of an authz gate: an anonymous mount
  reaches `{:ok, …}` (never an auth redirect to /login or /studio). For sheets
  and papers a real published doc is created so the mount is a clean render
  rather than a 404. A finding here would be a MISSING gate, not a leak — the
  census records zero such findings: every public surface is public by design.

  ## Findings

  Zero mount-authz findings. Every privileged `{module, live_session}` pair
  denies anon AND wrong-role at mount; every public LiveView is anon-mountable
  by design.

  One recorded LIMIT, from `pds-w42-bl-chatlive-routed-clauses-ungated`: a
  clean mount census is not a clean authorization census. `{ChatLive,
  :admin_studio}` denies anon and denies a `read`-only token, and still admitted
  a workspace-bound admin token that then drove four lifecycle clauses at
  `:global` scope into another workspace's rows. A mount gate bounds WHO gets a
  socket, never WHICH ROWS the clauses on that socket may touch. Clause-level
  scope is guarded separately, in
  `test/barkpark_web/live/studio/pds_w42_chatlive_flat_lifecycle_global_test.exs`.

  async: false — flips `:public_demo_studio` and runtime-gate config globally.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures, only: [ensure_default_scope!: 0]

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # A non-nil backend so `TmuxConsole.enabled?/0` clears its backend check. The
  # module is never invoked at mount (mount only checks `enabled?/0`), so a bare
  # stub is enough for a real `{:ok, …}` positive control.
  defmodule FakePtyStub do
    def spawn(_file, _args, _opts), do: {:ok, %{}}
  end

  defp anon(conn), do: Plug.Test.init_test_session(conn, %{})
  defp as(conn, raw), do: Plug.Test.init_test_session(conn, %{"api_token" => raw})

  defp token!(label, perms) do
    raw = "#{label}-#{System.unique_integer([:positive])}"
    {:ok, tok} = Auth.create_token(raw, label, "production", perms)
    {raw, tok}
  end

  # A principal class this census could not express until
  # `pds-w42-bl-chatlive-routed-clauses-ungated`: an admin token BOUND to a
  # workspace. Every wrong-role principal above is keyed on permission-ABSENCE
  # (a `read`-only token) or on membership role; none of them varies the token's
  # TENANCY. `LiveAuth.on_mount(:admin)` reads only `permissions` and never the
  # binding, so a bound admin token mounts every flat admin surface — which is
  # correct at the mount, and was NOT correct at ChatLive's lifecycle clauses,
  # where a hard-coded `:global` scope let it reach another workspace's rows.
  defp bound_token!(label, perms, workspace_id) do
    raw = "#{label}-#{System.unique_integer([:positive])}"
    {:ok, tok} = Auth.create_token(raw, label, "production", perms, workspace_id)
    {raw, tok}
  end

  # ChatLive.mount/3 bounces a runtime-less instance to "/studio" — the SAME
  # target an authz denial redirects to. So the runtime must be enabled BEFORE
  # any ChatLive deny assertion: otherwise a principal whose gate was REMOVED
  # would reach mount/3, be bounced for the missing runtime, and satisfy
  # `assert_denied_to(…, "/studio")` for entirely the wrong reason. With the
  # runtime on, a gate removal shows up as `{:ok, …}` and the assertion fails,
  # which is the only way these rows are worth anything.
  defp enable_chat_runtime! do
    prev_chat = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)

    on_exit(fn ->
      if prev_chat,
        do: Application.put_env(:barkpark, :claude_chat, prev_chat),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)
  end

  # A privileged mount must NOT be {:ok} for anon/wrong-role — it redirects.
  defp assert_denied_to(result, expected) do
    assert {:error, {:redirect, %{to: to}}} = result
    assert to =~ expected, "expected mount deny to #{expected}, got redirect to #{to}"
  end

  # Read-level studio rides the `:shared_studio_browser` conn pipeline, which
  # gates the DEAD render before the LiveScope on_mount hook ever runs: on a
  # non-default workspace an unauthorized actor is HALTED at the HTTP layer with
  # a 403 (never a 200 that `live/2` could connect), and only the seeded Default
  # + flag-on demo path 302s to /login. Assert the dead render is denied either
  # way — a forbidden status OR a /login redirect — never a 200 mount.
  defp assert_dead_render_denied(conn, path) do
    resp = get(conn, path)

    cond do
      resp.status in [401, 403] ->
        assert true

      resp.status in [302, 303] ->
        assert redirected_to(resp) =~ "/login",
               "expected a /login redirect, got #{redirected_to(resp)}"

      true ->
        flunk("expected a mount deny (403 or /login redirect), got status #{resp.status}")
    end
  end

  # ── ADMIN tier — flat global `admin` gate ────────────────────────────────

  describe "ADMIN tier — flat LiveAuth.:admin, deny → /studio" do
    setup %{conn: conn} do
      ensure_default_scope!()
      {admin_raw, _} = token!("census-admin", ["read", "write", "admin"])
      {junior_raw, _} = token!("census-junior", ["read"])
      {:ok, conn: conn, admin_raw: admin_raw, junior_raw: junior_raw}
    end

    test "OrgAdminLive denies anon + wrong-role, admin mounts", ctx do
      %{conn: conn, admin_raw: admin, junior_raw: junior} = ctx
      assert_denied_to(live(anon(conn), "/studio/org-admin"), "/studio")
      assert_denied_to(live(as(conn, junior), "/studio/org-admin"), "/studio")
      assert {:ok, _view, _html} = live(as(conn, admin), "/studio/org-admin")
    end

    test "StyleguideLive denies anon + wrong-role, admin mounts", ctx do
      %{conn: conn, admin_raw: admin, junior_raw: junior} = ctx
      assert_denied_to(live(anon(conn), "/studio/styleguide"), "/studio")
      assert_denied_to(live(as(conn, junior), "/studio/styleguide"), "/studio")
      assert {:ok, _view, _html} = live(as(conn, admin), "/studio/styleguide")
    end

    test "SwatchLive denies anon + wrong-role, admin mounts", ctx do
      %{conn: conn, admin_raw: admin, junior_raw: junior} = ctx
      assert_denied_to(live(anon(conn), "/studio/styleguide/swatch"), "/studio")
      assert_denied_to(live(as(conn, junior), "/studio/styleguide/swatch"), "/studio")
      assert {:ok, _view, _html} = live(as(conn, admin), "/studio/styleguide/swatch")
    end

    test "PluginsLive denies anon + wrong-role, admin mounts", ctx do
      %{conn: conn, admin_raw: admin, junior_raw: junior} = ctx
      path = "/w/default/p/default/d/production/studio/_plugins"
      assert_denied_to(live(anon(conn), path), "/studio")
      assert_denied_to(live(as(conn, junior), path), "/studio")
      assert {:ok, _view, _html} = live(as(conn, admin), path)
    end

    test "PluginSettingsLive denies anon + wrong-role, admin mounts", ctx do
      %{conn: conn, admin_raw: admin, junior_raw: junior} = ctx
      path = "/w/default/p/default/d/production/studio/_plugins/onixedit/settings"
      assert_denied_to(live(anon(conn), path), "/studio")
      assert_denied_to(live(as(conn, junior), path), "/studio")
      assert {:ok, _view, _html} = live(as(conn, admin), path)
    end

    test "TmuxLive denies anon + wrong-role; admin mounts with the runtime gate on", ctx do
      %{conn: conn, admin_raw: admin, junior_raw: junior} = ctx
      # Deny path first — the authz halt runs BEFORE the runtime gate.
      assert_denied_to(live(anon(conn), "/studio/tmux"), "/studio")
      assert_denied_to(live(as(conn, junior), "/studio/tmux"), "/studio")

      # Positive control: enable the console runtime so an authorized admin
      # reaches {:ok} (proving the authz gate passed, not the runtime gate).
      prev_tmux = Application.get_env(:barkpark, :tmux_console)
      prev_demo = Application.get_env(:barkpark, :public_demo_studio)

      on_exit(fn ->
        if prev_tmux,
          do: Application.put_env(:barkpark, :tmux_console, prev_tmux),
          else: Application.delete_env(:barkpark, :tmux_console)

        Application.put_env(:barkpark, :public_demo_studio, prev_demo)
      end)

      Application.put_env(:barkpark, :tmux_console,
        enabled: true,
        backend: FakePtyStub,
        session: "census-test"
      )

      Application.put_env(:barkpark, :public_demo_studio, false)

      assert {:ok, _view, _html} = live(as(conn, admin), "/studio/tmux")
    end

    test "ChatLive denies anon + wrong-role; admin mounts with a runtime enabled", ctx do
      %{conn: conn, admin_raw: admin, junior_raw: junior} = ctx

      # BEFORE the denials, not after — see `enable_chat_runtime!/0`. A
      # runtime-less mount redirects to the same "/studio" an authz denial does,
      # so the denials below are only meaningful with the runtime already on.
      enable_chat_runtime!()

      assert_denied_to(live(anon(conn), "/studio/chat"), "/studio")
      assert_denied_to(live(as(conn, junior), "/studio/chat"), "/studio")

      assert {:ok, _view, _html} = live(as(conn, admin), "/studio/chat")
    end

    # The class the module-keyed census could not express. This asserts the
    # TRUTH, which is a mount SUCCESS: `on_mount(:admin)` is a global-permission
    # gate and a workspace-bound admin token clears it. Recorded here so the
    # census stops implying the flat route filters by tenancy — it does not, and
    # the confinement for this module lives at the CLAUSES
    # (`ChatLive.principal_chat_scope/1`, guarded by
    # pds_w42_chatlive_flat_lifecycle_global_test.exs).
    test "ChatLive flat: an admin token BOUND to another workspace still mounts", ctx do
      %{conn: conn} = ctx

      {:ok, other} =
        Tenancy.create_workspace(%{
          slug: "census-bound-#{System.unique_integer([:positive])}",
          name: "Census Bound WS"
        })

      {:ok, _proj} = Tenancy.create_project(other, %{slug: "default", name: "Default"})
      {bound_raw, _} = bound_token!("census-bound-admin", ["read", "write", "admin"], other.id)

      enable_chat_runtime!()

      assert {:ok, _view, _html} = live(as(conn, bound_raw), "/studio/chat"),
             "the flat admin gate is expected to admit a workspace-bound admin token — " <>
               "if this now denies, the flat gate gained a tenancy check and the " <>
               "clause-level scope guard should be re-examined, not silently kept"
    end
  end

  # ── SCOPED-ADMIN tier — TARGET-workspace admin gate ──────────────────────

  describe "SCOPED-ADMIN tier — LiveAuth.:scoped_admin, deny → /studio" do
    setup %{conn: conn} do
      ensure_default_scope!()

      {:ok, ws} =
        Tenancy.create_workspace(%{
          slug: "census-scoped-#{System.unique_integer([:positive])}",
          name: "Census Scoped WS"
        })

      {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

      # Owner-admin of THIS workspace — the legit operator (positive control).
      {owner_raw, owner} = token!("census-owner", ["read", "write", "admin"])
      {:ok, _} = TenancyAuth.create_membership(ws.id, owner.id, "owner")

      # W24 escalation shape: flat global admin perm, but MEMBER-only here.
      {member_raw, member} = token!("census-member", ["read", "write", "admin"])
      {:ok, _} = TenancyAuth.create_membership(ws.id, member.id)

      {:ok, conn: conn, ws: ws, owner_raw: owner_raw, member_raw: member_raw}
    end

    test "SettingsLive denies anon + member-only, owner mounts", ctx do
      %{conn: conn, ws: ws, owner_raw: owner, member_raw: member} = ctx
      path = "/w/#{ws.slug}/p/default/studio/settings"
      assert_denied_to(live(anon(conn), path), "/studio")
      assert_denied_to(live(as(conn, member), path), "/studio")
      assert {:ok, _view, _html} = live(as(conn, owner), path)
    end

    test "ChatHostsLive denies anon + member-only, owner mounts", ctx do
      %{conn: conn, ws: ws, owner_raw: owner, member_raw: member} = ctx
      path = "/w/#{ws.slug}/p/default/studio/chat-hosts"
      assert_denied_to(live(anon(conn), path), "/studio")
      assert_denied_to(live(as(conn, member), path), "/studio")
      assert {:ok, _view, _html} = live(as(conn, owner), path)
    end

    test "ConnectorsLive denies anon + member-only, owner mounts", ctx do
      %{conn: conn, ws: ws, owner_raw: owner, member_raw: member} = ctx
      path = "/w/#{ws.slug}/p/default/studio/connectors"
      assert_denied_to(live(anon(conn), path), "/studio")
      assert_denied_to(live(as(conn, member), path), "/studio")
      assert {:ok, _view, _html} = live(as(conn, owner), path)
    end

    # The row a module-keyed census cannot hold: ChatLive's SECOND live_session.
    # `{ChatLive, :admin_studio}` is covered in the ADMIN tier above and rides a
    # global-permission gate; this pair rides the target-workspace gate. Both
    # rows are true of the same module, which is why the key is the pair.
    test "ChatLive scoped denies anon + member-only + a ws-bound-elsewhere admin, owner mounts",
         ctx do
      %{conn: conn, ws: ws, owner_raw: owner, member_raw: member} = ctx
      path = "/w/#{ws.slug}/p/default/studio/chat"

      # An admin token bound to a DIFFERENT workspace — the exact principal that
      # sails through the flat route. The scoped gate resolves the target from
      # the URL and denies it. That asymmetry between ChatLive's two rows is the
      # finding the module-keyed census could not represent.
      {:ok, elsewhere} =
        Tenancy.create_workspace(%{
          slug: "census-elsewhere-#{System.unique_integer([:positive])}",
          name: "Census Elsewhere WS"
        })

      {bound_raw, _} =
        bound_token!("census-elsewhere-admin", ["read", "write", "admin"], elsewhere.id)

      # Runtime BEFORE the denials — see `enable_chat_runtime!/0`. Without it,
      # removing the `:scoped_admin` gate would let each principal fall through
      # to mount/3, bounce on the missing runtime to "/studio", and satisfy all
      # three denials anyway. The gate would be gone and this row still green.
      enable_chat_runtime!()

      assert_denied_to(live(anon(conn), path), "/studio")
      assert_denied_to(live(as(conn, member), path), "/studio")
      assert_denied_to(live(as(conn, bound_raw), path), "/studio")

      assert {:ok, _view, _html} = live(as(conn, owner), path)
    end
  end

  # ── READ-level studio — token + membership read gate ─────────────────────

  describe "READ-level studio — LiveScope.:resolve, deny → /login (public-demo OFF)" do
    setup %{conn: conn} do
      ensure_default_scope!()

      prev_demo = Application.get_env(:barkpark, :public_demo_studio)
      on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev_demo) end)
      # Production posture — anon must fail closed instead of mounting the demo.
      Application.put_env(:barkpark, :public_demo_studio, false)

      {:ok, target} =
        Tenancy.create_workspace(%{
          slug: "census-read-#{System.unique_integer([:positive])}",
          name: "Census Read WS"
        })

      {:ok, proj} = Tenancy.create_project(target, %{slug: "default", name: "Default"})
      {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: "production", name: "Production"})

      # A DIFFERENT workspace whose member is authenticated but NOT a member of
      # the target — the cross-tenant wrong-role.
      {:ok, other} =
        Tenancy.create_workspace(%{
          slug: "census-other-#{System.unique_integer([:positive])}",
          name: "Census Other WS"
        })

      {:ok, _} = Tenancy.create_project(other, %{slug: "default", name: "Default"})

      {member_raw, member} = token!("census-read-member", ["read"])
      {:ok, _} = TenancyAuth.create_membership(target.id, member.id, "member")

      {outsider_raw, outsider} = token!("census-read-outsider", ["read"])
      {:ok, _} = TenancyAuth.create_membership(other.id, outsider.id, "member")

      base = "/w/#{target.slug}/p/default/d/production/studio"
      {:ok, conn: conn, base: base, member_raw: member_raw, outsider_raw: outsider_raw}
    end

    test "StudioLive denies anon + cross-tenant, member mounts", ctx do
      %{conn: conn, base: base, member_raw: member, outsider_raw: outsider} = ctx
      assert_dead_render_denied(anon(conn), base)
      assert_dead_render_denied(as(conn, outsider), base)
      assert {:ok, _view, _html} = live(as(conn, member), base)
    end

    test "MediaLive denies anon + cross-tenant, member mounts", ctx do
      %{conn: conn, base: base, member_raw: member, outsider_raw: outsider} = ctx
      path = base <> "/media"
      assert_dead_render_denied(anon(conn), path)
      assert_dead_render_denied(as(conn, outsider), path)
      assert {:ok, _view, _html} = live(as(conn, member), path)
    end

    test "ApiTesterLive denies anon + cross-tenant, member mounts", ctx do
      %{conn: conn, base: base, member_raw: member, outsider_raw: outsider} = ctx
      path = base <> "/api-tester"
      assert_dead_render_denied(anon(conn), path)
      assert_dead_render_denied(as(conn, outsider), path)
      assert {:ok, _view, _html} = live(as(conn, member), path)
    end
  end

  # ── PUBLIC tier — anonymous-mountable BY DESIGN ──────────────────────────

  describe "PUBLIC tier — no authz on_mount hook (anon reaches the LV)" do
    setup %{conn: conn} do
      ensure_default_scope!()
      {:ok, conn: conn}
    end

    test "FinderLive mounts anonymously — public search surface", %{conn: conn} do
      assert {:ok, _view, _html} = live(anon(conn), "/finder")
    end

    test "QuizHostLive mounts anonymously by PIN — public presenter", %{conn: conn} do
      assert {:ok, _view, _html} = live(anon(conn), "/quiz/host/9100001")
    end

    test "QuizPlayLive mounts anonymously by PIN — public player", %{conn: conn} do
      assert {:ok, _view, _html} = live(anon(conn), "/quiz/play/9100002")
    end

    test "SheetsReaderLive mounts anonymously for a PUBLISHED sheet", %{conn: conn} do
      slug = "census-sheet-#{System.unique_integer([:positive])}"

      {:ok, _draft} =
        Content.create_document(
          "sheet",
          %{
            "doc_id" => slug,
            "content" => %{
              "tabs" => [%{"name" => "Data", "cells" => %{"A1" => %{"v" => "hi"}}}]
            }
          },
          "production"
        )

      {:ok, _pub} = Content.publish_document(slug, "sheet", "production")

      assert {:ok, _view, _html} = live(anon(conn), "/sheets/#{slug}")
    end

    test "BulldocsLive mounts anonymously for a PUBLISHED paper", %{conn: conn} do
      slug = "census-paper-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            body_html: ~s(<section id="census-block"><h1>Census Paper</h1></section>),
            event_type: "plan-written"
          })
        )

      assert {:ok, _view, _html} = live(anon(conn), "/papers/#{slug}")
    end
  end
end
