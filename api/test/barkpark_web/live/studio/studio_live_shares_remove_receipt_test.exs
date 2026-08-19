defmodule BarkparkWeb.Studio.StudioLiveSharesRemoveReceiptTest do
  @moduledoc """
  PDS wave 40 — the "Stopped sharing X" receipt must read the STORE back, not
  echo the request.

  `Barkpark.Sharing.remove_share/3` deletes STORED rows only and returns
  `{:ok, count}` with no error arm. The Studio's shares-remove handler used to
  discard that count and flash a sentence built entirely from the
  request-parsed slugs, so THREE different worlds produced one byte-identical
  success receipt: a real removal, a no-op on a scope that was never shared,
  and — the one that costs an operator — a removal that left the scope PUBLIC
  because a `BARKPARK_SHARES` env-baseline share also covers it.

  That last case is why surfacing the count would not have been enough: at
  `count == 1` the delete really did remove a row and the scope is STILL
  readable. The only honest receipt is a post-read of `Sharing.shared?/4`.

  These tests drive the REAL rendered Remove button (the one
  `StudioComponents.Modals.shares_modal/1` renders for `source == "stored"`
  rows), not a forged event payload, and assert the flash and `shared?/4`
  AGREE.

  The event is DOUBLE admin-gated (`Caps.@admin_events` deny-gate + the
  handler's own `Caps.admin?/1` re-check) — but that is ONE opinion asked twice,
  not two: both gates call the SAME forked `Caps` predicate, and there is no
  second opinion anywhere on the admin path.

  The original claim here — that the misled party is "a workspace admin/operator,
  never a plain member" — was FALSE on the tree this correction was written
  against. An api_token holding a plain `"member"` membership row plus global
  `admin` permissions passed BOTH gates, because the token arm of both `Caps`
  admin answers read only the token's global `permissions[]`. That shape is
  proven MOUNTABLE — with a `"member"` row read back from the store — in
  `BarkparkWeb.Studio.CapsMountReachabilityTest` ("shape B"), and it remains
  mountable.

  arpss-w10's sibling slice (`arpss-w10-caps-admin-parity-table`) then moved both
  `Caps` admin answers onto workspace-scoped SEAT authority
  (`role_permits?(membership_role, ws_id, :admin)`), which closes that specific
  shape at the admin gate: the `member`-row global-admin token still mounts, but
  no longer clears either admin gate. What survives is the STRUCTURAL point, and
  it is the reason this paragraph stays: the two gates are one oracle asked
  twice, so whoever the forked predicate admits is exactly whoever this receipt
  can mislead — there is no independent check to catch a future drift in it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Sharing}
  alias Barkpark.Sharing.Share

  @dataset "production"
  @admin "shares-receipt-admin"

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin, "shares receipt admin", "production", ["read", "write", "admin"])

    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    {:ok, conn: conn}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp admin_view(conn) do
    conn
    |> init_test_session(%{"api_token" => @admin})
    |> live(scoped_studio("/d/#{@dataset}/studio"))
  end

  # Seed the STATIC env baseline the way runtime.exs does: a parsed Share list
  # under :shares_env, then refresh/0 to recompute the live :shares list.
  defp put_env_baseline(scope_entry) do
    Application.put_env(:barkpark, :shares_env, Sharing.parse(scope_entry))
    Sharing.refresh()
  end

  defp open_panel(view) do
    view |> element("button[phx-click=shares-open]") |> render_click()
    view
  end

  defp remove_button(view, scope) do
    element(view, ~s(button.share-row-remove[phx-value-scope="#{scope}"]))
  end

  describe "the removal receipt agrees with the store" do
    test "a scope shared via BOTH the env baseline and a stored row is reported as STILL shared",
         %{conn: conn} do
      scope = "dualws/default/production"
      put_env_baseline("#{scope}:papers:read")
      {:ok, _} = Sharing.add_share("#{scope}:papers:read")

      # Both halves are live, and the scope really is publicly readable.
      assert %Share{} = Enum.find(Sharing.shares_env(), &(&1.workspace_slug == "dualws"))
      assert Sharing.shared?("dualws", "default", "production", :papers)

      {:ok, view, _html} = admin_view(conn)
      open_panel(view)

      # The REAL rendered Remove button — it only exists on the `stored` row.
      html = view |> remove_button(scope) |> render_click()

      # The store is the authority, and the receipt says what it says.
      assert Sharing.shared?("dualws", "default", "production", :papers),
             "the env baseline survives remove_share/3 — the scope is still public"

      assert html =~ "is STILL shared"
      assert html =~ "BARKPARK_SHARES"
      refute html =~ "Stopped sharing #{scope}"

      # ...and the stored half really was deleted, so this is not a failure to act.
      assert Sharing.list_stored() == []
    end

    test "a purely stored share is removed and reported as no longer shared", %{conn: conn} do
      scope = "storedws/default/production"
      {:ok, _} = Sharing.add_share("#{scope}:papers:read")
      assert Sharing.shared?("storedws", "default", "production", :papers)

      {:ok, view, _html} = admin_view(conn)
      open_panel(view)

      html = view |> remove_button(scope) |> render_click()

      refute Sharing.shared?("storedws", "default", "production", :papers)
      assert html =~ "Stopped sharing #{scope}"
      assert html =~ "no longer shared"
      refute html =~ "is STILL shared"
    end

    test "removing a scope that was never shared does not claim a removal", %{conn: conn} do
      {:ok, view, _html} = admin_view(conn)
      open_panel(view)

      # No stored row exists, so no Remove button is rendered for it — the
      # absent-scope path is only reachable by pushing the event, which is
      # exactly the shape that used to flash success.
      refute has_element?(view, ~s(button.share-row-remove))

      html = render_hook(view, "shares-remove", %{"scope" => "ghost/default/production"})

      refute Sharing.shared?("ghost", "default", "production", :papers)
      assert html =~ "ghost/default/production was not shared"
      refute html =~ "Stopped sharing ghost/default/production"
    end

    test "an unparseable scope still reports a parse error and mutates nothing", %{conn: conn} do
      {:ok, _} = Sharing.add_share("keepws/default/production:papers:read")

      {:ok, view, _html} = admin_view(conn)
      open_panel(view)

      html = render_hook(view, "shares-remove", %{"scope" => "*/default/production"})

      assert html =~ "Could not parse that scope."
      assert Sharing.shared?("keepws", "default", "production", :papers)
    end
  end
end
