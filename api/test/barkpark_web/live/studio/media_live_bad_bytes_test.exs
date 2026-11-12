defmodule BarkparkWeb.Studio.MediaLiveBadBytesTest do
  @moduledoc """
  task-f8383ce8dd2ef270 criterion 2: a dataset segment the database refuses as
  text (not UTF-8, or a NUL) on the Studio media page names no dataset. It is
  a 404 for everyone, where the page's first read raised Postgrex 22021.
  """
  use BarkparkWeb.ConnCase, async: true

  defp token(conn, perms) do
    raw = "media-bad-bytes-#{System.unique_integer([:positive])}"
    ws = Barkpark.TenancyFixtures.default_workspace_id!()
    {:ok, _} = Barkpark.Auth.create_token(raw, "media-bad-bytes", "production", perms, ws)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  test "a dataset that is not text is a 404 on the media page", %{conn: conn} do
    callers = [
      nobody: conn,
      reader: token(conn, ~w(read)),
      admin: token(conn, ~w(read write admin))
    ]

    for {who, conn} <- callers, bad <- ~w(production%FF production%00 %00 %C3%28) do
      assert_error_sent(404, fn -> get(conn, scoped_studio("/d/#{bad}/studio/media")) end)
      assert who in [:nobody, :reader, :admin]
    end

    assert html_response(get(callers[:admin], scoped_studio("/d/production/studio/media")), 200)
  end
end
