defmodule BarkparkWeb.Studio.StudioLiveSharesEnvRowExplainedTest do
  @moduledoc """
  PDS wave 40 residue (`pds-w40-bl-shares-env-row-no-affordance`) — an
  env-sourced row in the Active shares list must EXPLAIN itself.

  `StudioComponents.Modals.shares_modal/1` renders the Remove button only for
  rows with `source == "stored"`, because `Sharing.remove_share/3` deletes
  stored rows and nothing else. A `BARKPARK_SHARES` row is therefore listed
  with no affordance — and, before this slice, no reason either. The only
  surface that named the baseline was the removal flash
  (`Handlers.Shares.still_shared_reason/3`), which an operator whose scope is
  env-ONLY can never reach: there is no sibling stored row to click.

  These tests drive the REAL panel through the REAL open event, and they assert
  in this order deliberately:

    1. the env row is actually RENDERED (positive control) — without it the
       absence of a Remove button below would be vacuous, satisfied just as
       well by a panel that listed nothing at all;
    2. the explanation is present and names BARKPARK_SHARES and the restart;
    3. no Remove button exists for that scope.

  The scope is a workspace this actor genuinely administers, because the read
  half of the panel is clamped by `Handlers.Shares.target_workspace_admits?/2`
  (`Shared.share_scope_visible?/2`): an invented slug would not be listed at
  all and every assertion here would be measuring the clamp, not the row.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Sharing}
  alias Barkpark.Sharing.Share
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.StudioComponents.Modals

  @dataset "production"
  @admin "shares-env-row-admin"

  setup %{conn: conn} do
    {:ok, admin_tok} =
      Auth.create_token(@admin, "shares env row admin", "production", ["read", "write", "admin"])

    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    {:ok, conn: conn, admin_tok: admin_tok}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  # A REAL workspace the @admin token administers — see the moduledoc.
  defp env_scope!(admin_tok) do
    n = System.unique_integer([:positive])
    ws = create_workspace!("shares-env-row-#{n}")
    proj = create_project!(ws, "shares-env-row-proj-#{n}")
    {:ok, _} = TenancyAuth.create_membership(ws.id, admin_tok.id, "admin", "api_token")
    assert TenancyAuth.workspace_admin?(admin_tok, ws.id)
    {ws.slug, proj.slug, "#{ws.slug}/#{proj.slug}/#{@dataset}"}
  end

  # Seed the STATIC env baseline the way runtime.exs does: a parsed Share list
  # under :shares_env, then refresh/0 to recompute the live :shares list.
  defp put_env_baseline(scope_entry) do
    Application.put_env(:barkpark, :shares_env, Sharing.parse(scope_entry))
    Sharing.refresh()
  end

  defp admin_view(conn) do
    conn
    |> init_test_session(%{"api_token" => @admin})
    |> live(scoped_studio("/d/#{@dataset}/studio"))
  end

  defp open_panel(view) do
    view |> element("button[phx-click=shares-open]") |> render_click()
  end

  describe "an env-only share explains itself in the Active shares list" do
    test "the row is listed, explains BARKPARK_SHARES, and offers no Remove button", %{
      conn: conn,
      admin_tok: admin_tok
    } do
      {ws, proj, scope} = env_scope!(admin_tok)
      put_env_baseline("#{scope}:papers:read")

      # The share is env-ONLY: no stored row exists, so no removal flash can
      # ever be the surface that explains it.
      assert %Share{} = Enum.find(Sharing.shares_env(), &(&1.workspace_slug == ws))
      assert Sharing.list_stored() == []
      assert Sharing.shared?(ws, proj, @dataset, :papers)

      {:ok, view, _html} = admin_view(conn)
      html = open_panel(view)

      # (1) POSITIVE CONTROL — the panel really rendered THIS env row. Without
      # this the refute below would pass on an empty list.
      assert html =~ scope
      assert has_element?(view, ".share-row .share-row-source", "env")

      # (2) The explanation is on the row, and it is the SAME sentence the
      # removal flash uses — one binary, read by both surfaces.
      assert has_element?(view, ".share-row .share-row-env-note")
      note = view |> element(".share-row .share-row-env-note") |> render()
      assert note =~ "BARKPARK_SHARES"
      assert note =~ "the Studio cannot remove"
      assert note =~ "restart to make it private"
      assert note =~ Modals.env_baseline_immutable()

      # (3) …and there is no affordance to remove it.
      refute has_element?(view, ~s(button.share-row-remove[phx-value-scope="#{scope}"]))
      refute has_element?(view, "button.share-row-remove")
    end

    test "a stored row keeps its Remove button and carries no env explanation", %{
      conn: conn,
      admin_tok: admin_tok
    } do
      # THE CONTROL IN THE OTHER DIRECTION: the note must be keyed on the row's
      # source, not rendered on every row. Without this a hunk that dropped the
      # `:if` would still pass the test above.
      {ws, proj, scope} = env_scope!(admin_tok)
      {:ok, _} = Sharing.add_share("#{scope}:papers:read")
      assert Sharing.shared?(ws, proj, @dataset, :papers)

      {:ok, view, _html} = admin_view(conn)
      html = open_panel(view)

      assert html =~ scope
      assert has_element?(view, ~s(button.share-row-remove[phx-value-scope="#{scope}"]))
      refute has_element?(view, ".share-row .share-row-env-note")
    end
  end
end
