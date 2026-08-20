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

  ## Per-module authz census

  ### ADMIN tier — flat global `admin` permission (`LiveAuth.:admin`), deny → /studio

  | Module              | Route                                                     | Deny target |
  |---------------------|-----------------------------------------------------------|-------------|
  | OrgAdminLive        | /studio/org-admin                                         | /studio     |
  | StyleguideLive      | /studio/styleguide                                        | /studio     |
  | SwatchLive          | /studio/styleguide/swatch                                 | /studio     |
  | TmuxLive            | /studio/tmux                                              | /studio     |
  | ChatLive            | /studio/chat                                              | /studio     |
  | PluginsLive         | /w/:ws/p/:proj/d/:ds/studio/_plugins                      | /studio     |
  | PluginSettingsLive  | /w/:ws/p/:proj/d/:ds/studio/_plugins/:plugin/settings     | /studio     |

  TmuxLive and ChatLive carry a SECOND runtime gate inside their own mount
  (`TmuxConsole.enabled?/0` needs a compiled PTY backend + the flag; ChatLive
  needs an enabled Claude/Codex runtime). The positive control enables that
  runtime via config so `{:ok, …}` genuinely holds and the authz pass is real,
  not masked by the runtime gate. Wrong-role for this tier is a `read`-only
  token (no `admin` permission).

  ### SCOPED-ADMIN tier — TARGET-workspace admin (`LiveAuth.:scoped_admin`), deny → /studio

  | Module         | Route                                | Deny target |
  |----------------|--------------------------------------|-------------|
  | SettingsLive   | /w/:ws/p/:proj/studio/settings       | /studio     |
  | ChatHostsLive  | /w/:ws/p/:proj/studio/chat-hosts     | /studio     |
  | ConnectorsLive | /w/:ws/p/:proj/studio/connectors     | /studio     |

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

  Zero mount-authz findings. Every privileged LiveView denies anon AND
  wrong-role at mount; every public LiveView is anon-mountable by design.

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
      assert_denied_to(live(anon(conn), "/studio/chat"), "/studio")
      assert_denied_to(live(as(conn, junior), "/studio/chat"), "/studio")

      # Positive control: enable a fake `claude` runtime (`cat` echo) so the
      # provider check in ChatLive.mount clears and an authorized admin mounts.
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

      assert {:ok, _view, _html} = live(as(conn, admin), "/studio/chat")
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
