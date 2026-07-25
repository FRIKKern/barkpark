defmodule BarkparkWeb.BulldocsSessionsControllerTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  @token "barkpark-test-ingest-token"
  @path "/v1/plugins/bulldocs/sessions"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp body(slug, extra \\ %{}) do
    Map.merge(%{"slug" => slug, "title" => "S", "status" => "open"}, extra)
    |> Jason.encode!()
  end

  test "rejects with no token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(@path, body("s-no-token"))

    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
  end

  test "upserts a metadata-only session", %{conn: conn} do
    resp = conn |> authed() |> post(@path, body("session-2026-07-25-a"))
    assert json_response(resp, 200)["ok"] == true
    assert Content.get_blocks_doc("session-2026-07-25-a", "session", "production")
  end

  test "upserts with blocks and reads back via GET", %{conn: conn} do
    blocks = [%{"id" => "b1", "type" => "paragraph", "content" => ["synth"]}]
    resp = conn |> authed() |> post(@path, body("session-2026-07-25-b", %{"blocks" => blocks}))
    assert json_response(resp, 200)["ok"] == true

    show = conn |> authed() |> get(@path <> "/session-2026-07-25-b")
    payload = json_response(show, 200)
    assert payload["slug"] == "session-2026-07-25-b"
    assert payload["status"] == "open"
    assert [%{"type" => "paragraph"} | _] = payload["blocks"]
  end

  test "GET unknown slug is 404", %{conn: conn} do
    resp = conn |> authed() |> get(@path <> "/session-nope")
    assert json_response(resp, 404)
  end

  test "applies a block op to a session", %{conn: conn} do
    conn
    |> authed()
    |> post(
      @path,
      body(
        "session-2026-07-25-c",
        %{
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "v1"}]
            }
          ]
        }
      )
    )

    op = %{
      "op" => "replace-block",
      "id" => "b1",
      "block" => %{
        "id" => "b1",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "v2"}]
      }
    }

    resp = conn |> authed() |> post(@path <> "/session-2026-07-25-c/ops", Jason.encode!(op))
    assert json_response(resp, 200)["ok"] == true
  end
end
