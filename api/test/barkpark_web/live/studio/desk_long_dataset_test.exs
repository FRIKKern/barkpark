defmodule BarkparkWeb.Studio.DeskLongDatasetTest do
  @moduledoc """
  task-f8383ce8dd2ef270 criterion 5: a very long dataset segment names no
  dataset. It is a 404, where the desk page raised Regex.CompileError.
  """
  use BarkparkWeb.ConnCase, async: true

  setup %{conn: conn} do
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-long-#{System.unique_integer([:positive])}"
    perms = ~w(read write admin)
    {:ok, _} = Barkpark.Auth.create_token(raw, "desk-long", "production", perms, ws.id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     scope: "/w/#{ws.slug}/p/#{proj.slug}"}
  end

  test "a very long dataset segment is a 404", %{conn: conn, scope: scope} do
    long = String.duplicate("a", 100_000)
    assert_error_sent(404, fn -> get(conn, "#{scope}/d/#{long}/studio/_desk") end)

    assert_error_sent(404, fn ->
      get(conn, "#{scope}/d/#{String.duplicate("a", 256)}/studio/_desk")
    end)

    # The longest name there can be is read as any dataset is.
    assert html_response(get(conn, "#{scope}/d/#{String.duplicate("a", 255)}/studio/_desk"), 200)
    assert html_response(get(conn, "#{scope}/d/production/studio/_desk"), 200)
  end
end
