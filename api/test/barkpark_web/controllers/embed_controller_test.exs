defmodule BarkparkWeb.EmbedControllerTest do
  # GET /v1/embed/canvas names the paper canvas files under their content hash
  # (task-c57dd84f98c1296c); those URLs cache as immutable, the plain ones stay no-cache.
  use BarkparkWeb.ConnCase, async: true

  @immutable ["public, max-age=31536000, immutable"]

  test "names the canvas bundle and stylesheets under their hash, anonymously", %{conn: conn} do
    conn = get(conn, "/v1/embed/canvas")
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
    body = json_response(conn, 200)

    assert body["script"] =~ ~r|\A/assets/v/[A-Za-z0-9_-]{16}/bp-paper-editor\.bundle\.js\z|

    assert Enum.map(body["styles"], &Path.basename/1) ==
             ["bp-paper-editor.css", "bp-paper-editor-shell.css", "bp-paper-surface.css"]

    for path <- [body["script"] | body["styles"]] do
      assert path =~ ~r|\A/assets/v/[A-Za-z0-9_-]{16}/|
      served = get(build_conn(), path)
      assert served.status == 200, path
      assert get_resp_header(served, "cache-control") == @immutable, path
    end
  end

  test "names only same-origin asset paths: no host, no token, no other key", %{conn: conn} do
    body =
      conn
      |> put_req_header("authorization", "Bearer some-token")
      |> get("/v1/embed/canvas")
      |> json_response(200)

    assert Map.keys(body) |> Enum.sort() == ["script", "styles"]

    for path <- [body["script"] | body["styles"]] do
      assert is_binary(path)
      assert String.starts_with?(path, "/assets/"), path
      refute path =~ "://", path
      refute path =~ ~r/token|bearer|@/i, path
    end
  end

  test "the plain bundle URL keeps working with no-cache" do
    conn = get(build_conn(), "/assets/bp-paper-editor.bundle.js")
    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
  end
end
