defmodule BarkparkWeb.Studio.DeskUnknownDatasetTest do
  @moduledoc """
  task-f8383ce8dd2ef270 criterion 4: a dataset that does not exist, with a
  document pane in the URL, does not take the desk page down on a live mount
  or a live patch.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-nods-#{System.unique_integer([:positive])}"
    perms = ~w(read write admin)
    {:ok, _} = Barkpark.Auth.create_token(raw, "desk-nods", "production", perms, ws.id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     scope: "/w/#{ws.slug}/p/#{proj.slug}"}
  end

  # The Studio opens the project's own dataset and says so. The desk page
  # leaves for it, where it tried to patch itself there and died.
  defp studio(scope), do: "#{scope}/d/production/studio/post/post-01"

  @tag capture_log: true
  test "a live mount on a dataset that does not exist leaves for the Studio's", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, "#{scope}/d/nosuch/studio/_desk/post;post-01")
    {path, flash} = assert_redirect(view)
    assert path == studio(scope)
    assert flash["info"] =~ "nosuch"
  end

  test "a live patch to a dataset that does not exist leaves for the Studio's", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, "#{scope}/d/production/studio/_desk")
    render_async(view, 5_000)
    render_patch(view, "#{scope}/d/nosuch/studio/_desk/post;post-01")
    {path, _flash} = assert_redirect(view)
    assert path == studio(scope)
  end

  test "a dataset that exists opens its document in the desk, as before", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, "#{scope}/d/production/studio/_desk/post;post-01")
    assert render_async(view, 5_000) =~ "desk-panes"
    refute_redirected(view, studio(scope))
  end
end
