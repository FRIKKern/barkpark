defmodule BarkparkWeb.Studio.MintDoubleSubmitTest do
  @moduledoc """
  wbqs-api-double-submit-guards: `OrgAdminLive`'s "Mint SCIM token" button had
  no `phx-disable-with` and its handler called `Scim.mint_token/2`
  unconditionally, so a double-click silently minted TWO live tokens while the
  UI only ever showed the LAST plaintext.

  `Barkpark.Scim.mint_token/2` has NO server-side debounce — confirmed by
  reading `lib/barkpark/scim.ex`: every call unconditionally builds a fresh
  plaintext and `Repo.insert`s a new `Scim.Token` row. The guard against a
  double-submit lives entirely in the LiveView socket (`org_admin_live.ex`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Repo, Tenancy}
  alias Barkpark.Scim.Token
  import Ecto.Query

  @admin_token "mint-double-submit-admin-token"

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "test admin", "production", ["read", "write", "admin"])

    {:ok, conn: conn}
  end

  defp org_with_ws(slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: "WS"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {org, ws}
  end

  defp admin_conn(conn), do: init_test_session(conn, %{"api_token" => @admin_token})

  defp token_count(org_id) do
    Repo.aggregate(from(t in Token, where: t.organization_id == ^org_id), :count)
  end

  defp extract_token(html) do
    Regex.run(~r/scim_[A-Za-z0-9_-]+/, html) |> hd()
  end

  test "a double-submit on Mint SCIM token mints exactly one token", %{conn: conn} do
    {org, _ws} = org_with_ws("dblmint")

    {:ok, view, _html} = live(admin_conn(conn), "/studio/org-admin")

    html1 = view |> element(~s([data-mint-scim="dblmint"])) |> render_click()
    assert html1 =~ "shown again"
    minted_token = extract_token(html1)
    assert token_count(org.id) == 1

    # the double-submit: a second "mint_scim" event for the SAME org, fired
    # directly at the LiveView the way the client's own JS would in the
    # instant before `phx-disable-with` visually disables the button — this
    # bypasses `element/2`'s disabled-attribute check (which now correctly
    # refuses to click a disabled button) so we exercise the SERVER-SIDE
    # guard itself, not just its client-side reinforcement.
    html2 = render_click(view, "mint_scim", %{"org" => org.id})

    assert token_count(org.id) == 1
    # still showing the ORIGINAL plaintext, not a fresh second one
    assert extract_token(html2) == minted_token
    # the button now reflects the guarded state
    assert html2 =~ ~s(data-mint-scim="dblmint")
    assert html2 =~ "disabled"
  end

  test "minting for a DIFFERENT org is unaffected by another org's guard", %{conn: conn} do
    {org_a, _} = org_with_ws("dbl-a")
    {org_b, _} = org_with_ws("dbl-b")

    {:ok, view, _html} = live(admin_conn(conn), "/studio/org-admin")

    view |> element(~s([data-mint-scim="dbl-a"])) |> render_click()
    view |> element(~s([data-mint-scim="dbl-b"])) |> render_click()

    assert token_count(org_a.id) == 1
    assert token_count(org_b.id) == 1
  end
end
