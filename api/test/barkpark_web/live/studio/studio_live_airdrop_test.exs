defmodule BarkparkWeb.Studio.StudioLiveAirdropTest do
  @moduledoc """
  The Share-access sheet (airdrop-grants capstone) — the grantor-facing Studio
  flow that MINTS + DELIVERS a scoped, time-boxed, account-bound grant.

  Proved NON-VACUOUSLY across the five ACs:

    1. reachable from a post-type surface (button) AND opens workspace-scoped
       (no type) from the workspace surface;
    2. duration chips compute `expires_at` (1d → ~24h out) + custom accepts a
       datetime;
    3. the capability picker offers ONLY what the grantor holds (a read-only
       grantor sees View, never Edit) — and mint's no-escalation REFUSES an
       unheld capability even on a forged submit, with NO grant written;
    4. a successful mint surfaces the `/grant/<token>` link EXACTLY ONCE and
       NEVER the persisted hash;
    5. delivery — a Swoosh email lands for the grantee, and an online grantee's
       user topic receives a MINIMAL toast broadcast.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Barkpark.{Access, Accounts, Auth, Content}
  alias Barkpark.TenancyFixtures

  @dataset "production"
  @admin_tok "airdrop-admin-tok"
  @reader_tok "airdrop-reader-tok"

  setup %{conn: conn} do
    {ws, _proj} = TenancyFixtures.ensure_default_scope!()

    # A public "post" type so the type-pane (post-type surface) renders.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    # Grantors: an admin (holds read+write) and a read-only member. create_token
    # makes each a member of the default workspace; the ApiToken capability gate
    # is the token's permissions array (a ["read"] token can never confer write).
    {:ok, _} =
      Auth.create_token(@admin_tok, "airdrop admin", @dataset, ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@reader_tok, "airdrop reader", @dataset, ["read"])

    {:ok, conn: conn, ws: ws}
  end

  defp view_for(conn, token) do
    conn
    |> init_test_session(%{"api_token" => token})
    |> live(scoped_studio("/d/#{@dataset}/studio"))
  end

  defp grantee_user do
    email = "grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    user
  end

  # ── AC1: reachable from both surfaces ───────────────────────────────────────

  describe "reachability + scope" do
    test "the post-type surface exposes the Share-access button and opens type-scoped",
         %{conn: conn} do
      # Post-type surface: navigate into the "post" type's document-list pane;
      # the Share-access button rides that type-pane header.
      {:ok, view, html} =
        conn
        |> init_test_session(%{"api_token" => @admin_tok})
        |> live(scoped_studio("/d/#{@dataset}/studio/post"))

      assert html =~ ~s(data-test-id="airdrop-open-type")

      # Opening from the post-type surface narrows scope with the type.
      view |> render_hook("airdrop-open", %{"type" => "post"})
      sheet = render(view)
      assert sheet =~ "Share access"
      assert sheet =~ "· post"
    end

    test "the workspace surface opens WITHOUT a type (workspace scope)", %{conn: conn} do
      {:ok, view, _html} = view_for(conn, @admin_tok)

      # The workspace-surface button emits `airdrop-open` with no type.
      view |> render_hook("airdrop-open", %{})
      sheet = render(view)
      assert sheet =~ "Share access"
      refute sheet =~ "· post"
    end
  end

  # ── AC3: capability picker gated to held caps ───────────────────────────────

  describe "capability gating (held-cap, not admin)" do
    test "an admin grantor sees View AND Edit", %{conn: conn} do
      {:ok, view, _} = view_for(conn, @admin_tok)
      view |> render_hook("airdrop-open", %{})
      sheet = render(view)
      assert sheet =~ ~s(value="read")
      assert sheet =~ ~s(value="write")
    end

    test "a read-only grantor sees View only — Edit is never offered", %{conn: conn} do
      {:ok, view, _} = view_for(conn, @reader_tok)
      view |> render_hook("airdrop-open", %{})
      sheet = render(view)
      assert sheet =~ ~s(value="read")
      refute sheet =~ ~s(value="write")
    end
  end

  # ── AC2 + AC4 + AC5 + AC-hygiene: mint, link once, email, no hash ───────────

  describe "mint + delivery" do
    test "mints, surfaces the /grant/<token> link ONCE, never the hash, sends email",
         %{conn: conn, ws: ws} do
      grantee = grantee_user()
      {:ok, view, _} = view_for(conn, @admin_tok)

      view |> render_hook("airdrop-open", %{})

      view
      |> render_hook("airdrop-create", %{
        "grantee_email" => grantee.email,
        "capabilities" => ["read"],
        "duration" => "1d"
      })

      html = render(view)

      # A grant was actually written, scoped to this workspace.
      [grant] = Access.list_grants_for_workspace(ws.id)
      assert grant.grantee_email == grantee.email
      assert grant.capabilities == ["read"]

      # AC2: 1d chip → expires ~24h out.
      secs = DateTime.diff(grant.expires_at, DateTime.utc_now())
      assert secs > 86_000 and secs < 86_500

      # AC4 + hygiene: the /grant/<token> link is surfaced EXACTLY ONCE, and the
      # persisted hash is NEVER rendered.
      assert html =~ ~s(data-test-id="airdrop-link")
      assert html =~ "/grant/"
      refute html =~ grant.link_token_hash

      # The raw token appears exactly once. Recover it from the DOM value attr.
      [_, token] = Regex.run(~r{/grant/([A-Za-z0-9_-]+)}, html)
      assert length(String.split(html, token)) == 2

      # AC5: the grantee got the claim email with the link. Grant delivery is now
      # offloaded to Barkpark.TaskSupervisor (GrantNotifier no longer blocks the
      # mint LiveView on SMTP), so wait for the background delivery with a timeout
      # rather than assert_email_sent's zero-timeout assert_received.
      assert_receive {:email, email}, 1_000
      assert {_, to_addr} = hd(email.to)
      assert to_addr == grantee.email
      assert email.text_body =~ "/grant/"
    end

    test "custom duration accepts a datetime", %{conn: conn, ws: ws} do
      grantee = grantee_user()
      {:ok, view, _} = view_for(conn, @admin_tok)
      view |> render_hook("airdrop-open", %{})

      future = DateTime.utc_now() |> DateTime.add(7200, :second)
      dt = Calendar.strftime(future, "%Y-%m-%dT%H:%M")

      view
      |> render_hook("airdrop-create", %{
        "grantee_email" => grantee.email,
        "capabilities" => ["read"],
        "duration" => "custom",
        "expires_at" => dt
      })

      [grant] = Access.list_grants_for_workspace(ws.id)
      secs = DateTime.diff(grant.expires_at, DateTime.utc_now())
      assert secs > 7_000 and secs < 7_300
    end

    test "an online grantee's user topic receives a minimal toast broadcast",
         %{conn: conn} do
      grantee = grantee_user()
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "user:#{grantee.id}")

      {:ok, view, _} = view_for(conn, @admin_tok)
      view |> render_hook("airdrop-open", %{})

      view
      |> render_hook("airdrop-create", %{
        "grantee_email" => grantee.email,
        "capabilities" => ["read"],
        "duration" => "1d"
      })

      # Minimal payload — no scope / capabilities / token leaks over the wire.
      assert_receive {:airdrop_granted}
    end
  end

  # ── AC3 security: no-escalation at the handler (non-admin member) ────────────

  describe "no-escalation" do
    test "a read-only grantor forging a write mint is REFUSED — no grant written",
         %{conn: conn, ws: ws} do
      grantee = grantee_user()
      {:ok, view, _} = view_for(conn, @reader_tok)
      view |> render_hook("airdrop-open", %{})

      # Forge a write capability the reader does not hold.
      view
      |> render_hook("airdrop-create", %{
        "grantee_email" => grantee.email,
        "capabilities" => ["write"],
        "duration" => "1d"
      })

      html = render(view)
      assert html =~ ~s(data-test-id="airdrop-error")
      assert html =~ "you hold" or html =~ "only share"

      # The security assertion: NO grant was minted.
      assert Access.list_grants_for_workspace(ws.id) == []
      refute_email_sent()
    end
  end

  # ── Recipient-email typeahead (pure UX; datalist is advisory) ───────────────

  describe "recipient typeahead (airdrop-suggest)" do
    test "suggests workspace-member emails matching the prefix; a non-member does not appear",
         %{conn: conn, ws: ws} do
      # A member of THIS workspace and a user who is NOT a member.
      {:ok, member} =
        Accounts.register_user(%{
          email: "teammate@example.com",
          password: "correct-horse-battery"
        })

      {:ok, _m} = Barkpark.Tenancy.Auth.create_membership(ws.id, member.id, "member", "user")

      {:ok, _outsider} =
        Accounts.register_user(%{
          email: "team-outsider@example.com",
          password: "correct-horse-battery"
        })

      {:ok, view, _} = view_for(conn, @admin_tok)
      view |> render_hook("airdrop-open", %{})

      html = view |> render_hook("airdrop-suggest", %{"grantee_email" => "team"})

      # The member surfaces as a <datalist> option; the non-member never does.
      assert html =~ ~s(id="airdrop-email-options")
      assert html =~ "teammate@example.com"
      refute html =~ "team-outsider@example.com"

      # Field stays free-text: still an email input (not a closed select).
      assert html =~ ~s(name="grantee_email")
    end
  end
end
