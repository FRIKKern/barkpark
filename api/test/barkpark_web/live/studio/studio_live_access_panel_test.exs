defmodule BarkparkWeb.Studio.StudioLiveAccessPanelTest do
  @moduledoc """
  The Access panel (airdrop-grants slice 3 UI) — the honest read/revoke sibling
  of the airdrop mint sheet. Proved NON-VACUOUSLY across the ACs:

    1. the panel opens with two honest sections (Your access / Active grants in
       this workspace) and reads the existing `:access_grants` assign — no new
       query path;
    2. a workspace MEMBER sees the workspace grants and revoking one DROPS the
       row from the re-listed panel (the active predicate excludes it), while a
       real `Access.revoke/2` stamped `revoked_at`;
    3. DENY-side: a read-only member who is neither grantor nor admin is REFUSED
       (`Access.revoke/2` server-authorizes grantor-or-admin) — the grant stays
       ACTIVE and an inline error is shown;
    4. a grantee (non-member) sees ONLY their own access — the workspace section
       is hidden — each row carrying live countdown data (`data-expires-at`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Access, Accounts, Auth}
  alias Barkpark.Access.Grant
  alias Barkpark.Repo
  alias Barkpark.TenancyFixtures

  @dataset "production"
  @admin "access-admin-tok"
  @member "access-member-tok"
  @reader "access-reader-tok"

  setup %{conn: conn} do
    {ws, _proj} = TenancyFixtures.ensure_default_scope!()

    # An admin member (read+write+admin) and a read-only member. create_token
    # auto-memberships each on the Default workspace, so both are authorized to
    # READ the workspace (the workspace section's gate). Only the admin's
    # permissions satisfy the :admin action Access.revoke re-checks.
    {:ok, _} = Auth.create_token(@admin, "access admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(@member, "access member", @dataset, ["read", "write"])
    {:ok, _} = Auth.create_token(@reader, "access reader", @dataset, ["read"])

    {:ok, conn: conn, ws: ws}
  end

  defp token_view(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{"api_token" => token})
    |> live(scoped_studio("/d/#{@dataset}/studio"))
  end

  defp grantee_user do
    email = "access-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    user
  end

  # Insert an ACTIVE workspace grant directly. grantor_id is a random principal
  # id (no FK), so a read-only member is neither the grantor nor an admin — the
  # exact deny shape. Overrides bind it to a grantee user / tune the expiry.
  defp insert_grant!(ws, email, overrides \\ %{}) do
    attrs =
      %{
        grantor_id: Ecto.UUID.generate(),
        grantee_email: email,
        workspace_id: ws.id,
        capabilities: ["read"],
        link_token_hash: "hash-" <> Ecto.UUID.generate(),
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }
      |> Map.merge(overrides)

    {:ok, grant} = %Grant{} |> Grant.changeset(attrs) |> Repo.insert()
    grant
  end

  # ── AC1 + AC2: member sees workspace grants; admin revoke drops the row ──────

  describe "workspace section (member-gated) + revoke" do
    test "an admin member sees the workspace grants section with a Revoke affordance",
         %{conn: conn, ws: ws} do
      _grant = insert_grant!(ws, "recipient@example.com")

      {:ok, view, _html} = token_view(conn, @admin)

      view |> render_hook("access-open", %{})
      html = render(view)

      assert html =~ ~s(data-test-id="access-panel")
      assert html =~ ~s(data-test-id="access-workspace")
      assert html =~ "recipient@example.com"
      assert html =~ ~s(data-test-id="access-revoke")
      # The live countdown chip carries the client-hook target.
      assert html =~ ~s(data-test-id="access-countdown")
      assert html =~ "data-expires-at"
    end

    test "an admin revokes a grant — Access.revoke stamps revoked_at and the row DROPS",
         %{conn: conn, ws: ws} do
      grant = insert_grant!(ws, "revoke-me@example.com")

      {:ok, view, _html} = token_view(conn, @admin)
      view |> render_hook("access-open", %{})
      assert render(view) =~ "revoke-me@example.com"

      view |> render_hook("access-revoke", %{"id" => grant.id})
      html = render(view)

      # NON-VACUOUS: the grant was actually revoked in the DB (active predicate
      # now excludes it) AND the row is gone from the re-listed panel.
      assert Repo.get(Grant, grant.id).revoked_at != nil
      assert Access.list_grants_for_workspace(ws.id) == []
      refute html =~ "revoke-me@example.com"
    end
  end

  # ── AC3: DENY-side — a non-authorized revoke is refused, grant stays active ──

  describe "revoke deny-side (server-authorized, grantor-or-admin)" do
    test "a write member (not grantor, not admin) is REFUSED by the handler — inline error, grant ACTIVE",
         %{conn: conn, ws: ws} do
      grant = insert_grant!(ws, "protected@example.com")

      # A write-capable, non-admin member PASSES the Caps :write gate (so it
      # reaches the handler) but is neither the grantor nor a workspace admin —
      # so Access.revoke/2's server-side authorization REFUSES it.
      {:ok, view, _html} = token_view(conn, @member)
      view |> render_hook("access-open", %{})
      assert render(view) =~ "protected@example.com"

      view |> render_hook("access-revoke", %{"id" => grant.id})
      html = render(view)

      # The security assertion: NO revoke happened, the grant is still active, an
      # inline error is surfaced, and the row is still shown (live-active view).
      assert Repo.get(Grant, grant.id).revoked_at == nil
      assert [_still_active] = Access.list_grants_for_workspace(ws.id)
      assert html =~ ~s(data-test-id="access-error")
      assert html =~ "grantor or a workspace admin"
      assert html =~ "protected@example.com"
    end

    test "a read-only member is denied ONE LAYER EARLIER by the Caps :write gate — grant ACTIVE",
         %{conn: conn, ws: ws} do
      grant = insert_grant!(ws, "protected@example.com")

      # A read-only member lacks write, so the load-bearing Caps deny-gate HALTS
      # `access-revoke` (a :write event) before the handler ever runs. Defense in
      # depth: even if it slipped through, Access.revoke would still refuse it.
      {:ok, view, _html} = token_view(conn, @reader)
      view |> render_hook("access-open", %{})
      view |> render_hook("access-revoke", %{"id" => grant.id})

      # NON-VACUOUS: nothing was revoked.
      assert Repo.get(Grant, grant.id).revoked_at == nil
      assert [_still_active] = Access.list_grants_for_workspace(ws.id)
    end
  end

  # ── AC4: grantee sees ONLY their own access (workspace section hidden) ───────

  describe "grantee 'Your access' section" do
    test "a non-member grantee sees their own grant with countdown, and NO workspace section",
         %{conn: conn, ws: ws} do
      user = grantee_user()

      # Bind an active, claimed grant to this user (the shape :access_grants loads).
      _grant =
        insert_grant!(ws, user.email, %{
          grantee_user_id: user.id,
          claimed_at: DateTime.utc_now(),
          capabilities: ["read", "write"],
          expires_at: DateTime.add(DateTime.utc_now(), 1800, :second)
        })

      {:ok, raw} = Accounts.create_user_session_token(user)

      {:ok, view, _html} =
        conn
        |> Plug.Test.init_test_session(%{"user_session" => raw})
        |> live(scoped_studio("/d/#{@dataset}/studio"))

      view |> render_hook("access-open", %{})
      html = render(view)

      # Your access shows the grant with live countdown data.
      assert html =~ ~s(data-test-id="access-your")
      assert html =~ ~s(data-test-id="access-your-row")
      assert html =~ ~s(data-test-id="access-countdown")
      assert html =~ "data-expires-at"
      # Capabilities render as human chips.
      assert html =~ "View" and html =~ "Edit"

      # The non-member grantee does NOT get the workspace section.
      refute html =~ ~s(data-test-id="access-workspace")
    end

    test "an authenticated caller with no grants sees an honest empty state",
         %{conn: conn} do
      user = grantee_user()
      {:ok, raw} = Accounts.create_user_session_token(user)

      {:ok, view, _html} =
        conn
        |> Plug.Test.init_test_session(%{"user_session" => raw})
        |> live(scoped_studio("/d/#{@dataset}/studio"))

      view |> render_hook("access-open", %{})
      html = render(view)

      assert html =~ ~s(data-test-id="access-your-empty")
    end
  end
end
