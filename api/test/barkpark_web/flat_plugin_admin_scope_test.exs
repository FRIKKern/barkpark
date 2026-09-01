defmodule BarkparkWeb.FlatPluginAdminScopeTest do
  @moduledoc """
  The FLAT `/studio/tickets` mount must bind to a workspace the operator is
  actually AUTHORIZED in — never the seeded Default by default.

  `Barkpark.Plugins.Tickets.InboxLive` is mounted twice. The scoped route
  `/w/:ws/p/:proj/studio/tickets` rides `:scoped_plugin_admin`, which carries
  `{PluginScopeSession, :scope}` — it bridges `:scoped_browser`'s resolved
  workspace across the HTTP→WebSocket boundary, so `StudioChrome`'s
  Default-pinning fallback no-ops on its truthy-assign guard. That surface is
  fine and is NOT what this file covers.

  The FLAT route `/studio/tickets` rides `:plugin_admin`, whose on_mount list is
  `[LiveAuth :admin, LiveAuth :require_org_mfa, StudioChrome :default]` — no
  workspace producer at all. `LiveAuth :admin` gates on the workspace-BLIND
  `admin` permission and assigns only `:api_token`, so
  `StudioChrome.default_scope_fallback/1` was the only producer.

  TWO POPULATIONS REACH IT, and this file now covers both.

  1. task-e656670726427b96 — a WORKSPACE-BOUND admin (its
     `api_tokens.workspace_id` names workspace B). The fallback pinned Default
     and overrode B. Fixed by `StudioChrome.derive_scope_from_principal/1`,
     which binds the principal's own workspace BEFORE the fallback runs.

  2. task-e9386e19bd7bb376 — an INSTANCE-WIDE token: `workspace_id` nil AND no
     `workspace_memberships` row anywhere. The fallback pinned Default for it
     too, and the earlier row deliberately PINNED that as an acceptable "flat
     posture". This file retracts that: `Tenancy.Auth.authorize/3` is
     `member?(token, ws) and permits?(token, action)` with no global bypass, so
     that principal is authorized in NO workspace, Default included. See the
     third describe block, which SUPERSEDES the one it replaces.

  All four ticket-key arms read the `:current_workspace` assign
  (`inbox_live.ex` `workspace/1` / `workspace_id/1`), so neither defect is
  merely a read disclosure — the operator MINTS a live credential into the
  wrong tenant and can rotate, pause and unpause that tenant's existing keys.
  `Keys.scope_workspace/2` is fail-closed and correct in both cases; it is
  handed the wrong workspace and faithfully confines the operator to it. The
  bug is UPSTREAM of that fence, both times.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.AccountsFixtures, only: [register_user: 1]

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Plugins.Tickets.Keys
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @flat_path "/studio/tickets"
  @dataset "production"

  setup %{conn: conn} do
    default_ws = ensure_default!()

    {:ok, ws_b} =
      Tenancy.create_workspace(%{
        slug: "flat-tickets-b-#{System.unique_integer([:positive])}",
        name: "Flat Tickets B"
      })

    {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    # A workspace-BOUND admin: holds the global `admin` permission (so the flat
    # `LiveAuth :admin` gate passes) and `api_tokens.workspace_id` points at B.
    raw = "flat-tickets-admin-#{System.unique_integer([:positive])}"

    {:ok, _token} =
      Auth.create_token(
        raw,
        "flat tickets ws-b admin",
        @dataset,
        ["read", "write", "admin"],
        ws_b.id
      )

    # One ticket key in each tenant, so an empty listing can never pass
    # vacuously — the ws-B row MUST render and the Default row MUST NOT.
    {:ok, %{key: default_key}} =
      Keys.mint(%{name: "DEFAULT-TENANT-KEY", workspace_id: default_ws.id, dataset: @dataset})

    {:ok, %{key: b_key}} =
      Keys.mint(%{name: "WSB-OWN-KEY", workspace_id: ws_b.id, dataset: @dataset})

    %{
      conn: init_test_session(conn, %{"api_token" => raw}),
      default_ws: default_ws,
      ws_b: ws_b,
      default_key: default_key,
      b_key: b_key
    }
  end

  describe "flat /studio/tickets binds to the operator's own workspace" do
    test "the key list shows B's keys and NEVER Default's", %{conn: conn} do
      {:ok, view, _html} = live(conn, @flat_path)

      html = render_click(view, "open_keys", %{})

      # Non-vacuous: the operator's OWN key must be present...
      assert html =~ "WSB-OWN-KEY",
             "the ws-B admin should see their own workspace's ticket key"

      # ...and the other tenant's must not.
      refute html =~ "DEFAULT-TENANT-KEY",
             "flat /studio/tickets leaked the Default workspace's ticket keys to a ws-B admin"
    end

    test "a mint lands in B, not Default", %{conn: conn, ws_b: ws_b, default_ws: default_ws} do
      {:ok, view, _html} = live(conn, @flat_path)

      render_click(view, "open_keys", %{})
      render_click(view, "mint_key", %{"name" => "MINTED-BY-WSB-ADMIN"})

      minted = Repo.get_by(ApiToken, name: "MINTED-BY-WSB-ADMIN")

      # Bound as a boolean so assert/2 can actually surface the message — a
      # `assert %ApiToken{} = minted, "..."` match-assert silently discards it.
      refute is_nil(minted), "the mint should have created a ticket key"

      assert minted.workspace_id == ws_b.id,
             "a ws-B admin minted a live ticket credential into workspace " <>
               "#{inspect(minted.workspace_id)} instead of their own #{inspect(ws_b.id)}"

      refute minted.workspace_id == default_ws.id
      refute "MINTED-BY-WSB-ADMIN" in Enum.map(Keys.list(default_ws), & &1.name)
      assert "MINTED-BY-WSB-ADMIN" in Enum.map(Keys.list(ws_b), & &1.name)
    end

    test "a rotate cannot reach Default's key", %{conn: conn, default_key: default_key} do
      {:ok, view, _html} = live(conn, @flat_path)

      render_click(view, "open_keys", %{})
      render_click(view, "rotate_key", %{"id" => default_key.id})

      after_rotate = Repo.get!(ApiToken, default_key.id)

      assert after_rotate.token_hash == default_key.token_hash,
             "a ws-B admin rotated the Default workspace's ticket key from the flat mount"
    end

    test "a pause cannot reach Default's key", %{conn: conn, default_key: default_key} do
      {:ok, view, _html} = live(conn, @flat_path)

      render_click(view, "open_keys", %{})
      render_click(view, "pause_key", %{"id" => default_key.id})

      after_pause = Repo.get!(ApiToken, default_key.id)

      assert is_nil(after_pause.paused_at),
             "a ws-B admin paused the Default workspace's ticket key from the flat mount"
    end

    # PAIRED POSITIVE CONTROL for the two negatives above. Without it, a green
    # "Default's key is untouched" is three worlds in one: a correct scope
    # refusal, an unrelated error, or a dead handler that mutates nothing
    # anywhere. This proves the SAME socket drives a real rotate/pause through
    # to completion — so the Default no-op is the fence refusing, not the arm
    # being inert.
    test "the same socket DOES rotate and pause B's own key", %{conn: conn, b_key: b_key} do
      {:ok, view, _html} = live(conn, @flat_path)

      render_click(view, "open_keys", %{})
      render_click(view, "rotate_key", %{"id" => b_key.id})

      rotated = Repo.get!(ApiToken, b_key.id)

      refute rotated.token_hash == b_key.token_hash,
             "the rotate arm did not reach the operator's OWN key — the negatives above " <>
               "would then be green for the wrong reason"

      render_click(view, "pause_key", %{"id" => b_key.id})
      assert %ApiToken{paused_at: %DateTime{}} = Repo.get!(ApiToken, b_key.id)
    end
  end

  describe "the instance-wide operator (NO membership anywhere) is not scoped into Default" do
    # POPULATION 2, RE-ADJUDICATED — task-e9386e19bd7bb376.
    #
    # THIS DESCRIBE BLOCK SUPERSEDES ONE THIS FILE USED TO CARRY, WHOLESALE.
    # The deleted block was titled "the instance-wide operator (no workspace of
    # its own) keeps Default" and asserted the exact OPPOSITE of what follows:
    # that this principal mounts, "sees Default's keys, and mints into Default".
    # It is deleted rather than weakened, because the behaviour it pinned is now
    # classified as the defect, not the posture.
    #
    # WHY THE OLD PIN WAS WRONG. The old block argued Default was this
    # principal's "documented flat posture", by analogy with the HTTP sibling
    # `DeriveWorkspaceFromToken`'s nil-token carve-out. That analogy does not
    # survive `Tenancy.Auth.authorize/3`, which is literally
    # `member?(token, workspace_id) and permits?(token, action)` with NO
    # global-permission bypass: this token is authorized in NO workspace, the
    # seeded Default INCLUDED. Preserving Default for it is not a posture — it
    # hands it a tenant it cannot be authorized in, and `InboxLive` then reads
    # Default's key roster and MINTS a live credential into Default. The
    # carve-out preserves a WORKSPACE; it never established AUTHORITY in it.
    #
    # RED-BEFORE: on the unfixed tree the three behavioural tests below FAIL —
    # the operator sees DEFAULT-TENANT-KEY, the mint lands in Default, and the
    # rotate of Default's key succeeds. They go GREEN on the authority check
    # inside `StudioChrome.default_scope_fallback/1`.
    setup %{conn: conn} do
      # Inserted raw, NOT via `Auth.create_token/5`: that helper defaults a nil
      # workspace_id to the Default workspace AND writes a membership row, which
      # would manufacture the very authority this population is defined by NOT
      # having. Asserted below so the fixture can never drift into the positive
      # control by accident.
      raw = "flat-tickets-instance-#{System.unique_integer([:positive])}"

      {:ok, token} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token(raw),
          label: "instance-wide operator",
          dataset: @dataset,
          permissions: ["read", "write", "admin"]
        })
        |> Repo.insert()

      %{conn: init_test_session(conn, %{"api_token" => raw}), instance_token: token}
    end

    # ASSERT THE SUBJECT EXISTS. Every behavioural test below is a refutation,
    # and a refutation is vacuous if the fixture is not the population it names
    # — a token that quietly acquired a Default membership would make all three
    # pass while proving nothing.
    test "fixture check: the principal really is authorized in NO workspace", %{
      instance_token: token,
      default_ws: default_ws,
      ws_b: ws_b
    } do
      assert is_nil(token.workspace_id)
      assert TenancyAuth.membership(token, default_ws.id) == nil
      assert TenancyAuth.membership(token, ws_b.id) == nil

      assert TenancyAuth.authorize(token, default_ws.id, :read) == {:error, :forbidden},
             "the fixture token is authorized in Default — it is the POSITIVE-control " <>
               "population, and every refutation below would be vacuous"
    end

    test "mounts, and the key list is EMPTY rather than Default's roster", %{conn: conn} do
      # The mount must still succeed: this row narrows the scope, it does not
      # lock the host operator out of the flat surfaces (OrgAdmin, Styleguide
      # and tmux ride the same `default_scope_fallback/1`).
      assert {:ok, view, _html} = live(conn, @flat_path)

      html = render_click(view, "open_keys", %{})

      # NON-VACUOUS #1: the panel actually rendered and the fetch SUCCEEDED.
      # Without these three, "no DEFAULT-TENANT-KEY in the HTML" is also what a
      # crashed panel or a failed query looks like.
      assert html =~ ~s(data-test-id="key-table")
      assert html =~ ~s(data-test-id="keys-empty")
      refute html =~ ~s(data-test-id="keys-unavailable")

      # NON-VACUOUS #2: both tenants hold a key (the outer setup mints one
      # each), so an empty roster is a scope refusal, not an empty database.
      refute html =~ "DEFAULT-TENANT-KEY",
             "a token authorized in NO workspace read the Default workspace's ticket keys"

      refute html =~ "WSB-OWN-KEY"
    end

    test "a mint does NOT land in Default", %{conn: conn, default_ws: default_ws} do
      {:ok, view, _html} = live(conn, @flat_path)

      render_click(view, "open_keys", %{})
      render_click(view, "mint_key", %{"name" => "MINTED-BY-INSTANCE-OP"})

      minted = Repo.get_by(ApiToken, name: "MINTED-BY-INSTANCE-OP")

      # The mint arm still RUNS — which is what makes the workspace assertion
      # below meaningful rather than "nothing happened at all".
      refute is_nil(minted), "the mint arm did not run at all"

      refute minted.workspace_id == default_ws.id,
             "a token authorized in NO workspace minted a live ticket credential into Default"

      # It lands on the un-bound path instead: member-less and kind-fenced, so
      # inert on every normal route (`Keys.mint/1`'s documented nil case).
      assert is_nil(minted.workspace_id)

      refute "MINTED-BY-INSTANCE-OP" in Enum.map(Keys.list(default_ws), & &1.name)
    end

    test "a rotate cannot reach Default's key", %{conn: conn, default_key: default_key} do
      {:ok, view, _html} = live(conn, @flat_path)

      render_click(view, "open_keys", %{})
      render_click(view, "rotate_key", %{"id" => default_key.id})

      after_rotate = Repo.get!(ApiToken, default_key.id)

      assert after_rotate.token_hash == default_key.token_hash,
             "a token authorized in NO workspace rotated the Default workspace's ticket key"
    end
  end

  describe "POSITIVE CONTROL — a token that HOLDS a Default membership keeps Default" do
    # The first half of acceptance 3 on task-e9386e19bd7bb376. Without it, the
    # refusals above are equally consistent with a fallback that pins NOBODY —
    # which would break the legitimate instance-admin path the row's DESIGN
    # CONSTRAINT protects. Same surface, same events; one difference in the
    # fixture: this principal is a member of Default.
    setup %{conn: conn, default_ws: default_ws} do
      raw = "flat-tickets-default-member-#{System.unique_integer([:positive])}"

      # `workspace_id` deliberately left nil, so `derive_scope_from_principal/1`
      # does NOT bind it — the Default assign must come from the FALLBACK, which
      # is the code under test — but WITH a real Default membership row.
      {:ok, token} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token(raw),
          label: "default member operator",
          dataset: @dataset,
          permissions: ["read", "write", "admin"]
        })
        |> Repo.insert()

      {:ok, _membership} = TenancyAuth.create_membership(default_ws.id, token.id, "admin")

      %{conn: init_test_session(conn, %{"api_token" => raw}), member_token: token}
    end

    test "fixture check: this principal IS authorized in Default", %{
      member_token: token,
      default_ws: default_ws
    } do
      assert is_nil(token.workspace_id)
      assert TenancyAuth.authorize(token, default_ws.id, :read) == :ok
    end

    test "still sees Default's keys and still mints into Default", %{
      conn: conn,
      default_ws: default_ws
    } do
      {:ok, view, _html} = live(conn, @flat_path)

      html = render_click(view, "open_keys", %{})
      assert html =~ "DEFAULT-TENANT-KEY"

      render_click(view, "mint_key", %{"name" => "MINTED-BY-DEFAULT-MEMBER"})
      minted = Repo.get_by(ApiToken, name: "MINTED-BY-DEFAULT-MEMBER")

      assert %ApiToken{} = minted
      assert minted.workspace_id == default_ws.id
    end
  end

  describe "POSITIVE CONTROL — the ACCOUNT-session arm keeps Default" do
    # The second legitimate population named by the row's DESIGN CONSTRAINT.
    # `LiveAuth.authorize_user/3` will not `{:cont, …}` unless
    # `Tenancy.Auth.authorize(user, default_ws_id, :admin) == :ok`, so this
    # principal holds a real Default membership and clears the `:read` bar the
    # fallback now applies — a fortiori. Proved, not assumed: if the new check
    # asked the wrong question, or asked it of the wrong assign (this arm
    # carries `:current_user` and NO `:api_token`), this test reds.
    setup %{conn: conn, default_ws: default_ws} do
      user = register_user("flat-tickets-acct-#{System.unique_integer([:positive])}@example.test")
      {:ok, _} = TenancyAuth.create_membership(default_ws.id, user.id, "admin", "user")
      {:ok, session_raw} = Accounts.create_user_session_token(user)

      # `init_test_session/2` MERGES — without clearing it, the OUTER setup's
      # api_token survives, `LiveAuth.authorize/4` finds a token candidate
      # first, and this "account session" is quietly the token arm again.
      %{conn: init_test_session(conn, %{"api_token" => nil, "user_session" => session_raw})}
    end

    test "mounts and still sees Default's keys", %{conn: conn} do
      assert {:ok, view, _html} = live(conn, @flat_path)

      html = render_click(view, "open_keys", %{})
      assert html =~ "DEFAULT-TENANT-KEY"
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defp ensure_default! do
    ws =
      case Tenancy.get_default_workspace() do
        nil ->
          {:ok, ws} = Tenancy.create_workspace(%{slug: "default", name: "Default"})
          ws

        ws ->
          ws
      end

    case Tenancy.get_default_project() do
      nil -> {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
      _proj -> :ok
    end

    ws
  end
end
