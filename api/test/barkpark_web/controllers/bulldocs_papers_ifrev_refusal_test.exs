defmodule BarkparkWeb.BulldocsPapersIfRevRefusalTest do
  @moduledoc """
  POST /v1/plugins/bulldocs/papers is an UNFENCED create-or-replace. It used to
  accept an `ifRev` / `if_rev` key in the body and silently drop it, answering
  the ordinary 200 `ok` receipt — byte-identical to a write that had no fence
  requested at all. A caller that assumed symmetry with the sibling
  `POST /papers/:slug/ops` (which honours `ifRev` and answers 412 on a stale
  rev) therefore got an unfenced write while believing it was fenced.

  These tests assert on the RESPONSE the caller sees and on the fact that
  NOTHING was written, so disarming the refusal reds them.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.LabelFixtures

  @token "barkpark-test-ingest-token"
  @path "/v1/plugins/bulldocs/papers"

  defp post_paper(conn, payload) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> post(@path, payload)
  end

  defp body(slug, extra) do
    LabelFixtures.paper_attrs(%{
      "slug" => slug,
      "body_html" => ~s(<article><h1>#{slug}</h1></article>)
    })
    |> Map.merge(extra)
  end

  describe "an ifRev key on the unfenced publish route" do
    test "camelCase ifRev is REFUSED 400 naming the ops route, and writes nothing", %{conn: conn} do
      slug = "ifrev-refusal-camel"

      conn = post_paper(conn, body(slug, %{"ifRev" => 999_999}))

      resp = json_response(conn, 400)
      assert resp["error"]["code"] == "malformed"
      assert resp["error"]["parameter"] == "ifRev"
      assert resp["error"]["fenced_route"] == "/v1/plugins/bulldocs/papers/:slug/ops"
      assert resp["error"]["message"] =~ "/v1/plugins/bulldocs/papers/:slug/ops"

      # The whole point: the write did NOT happen behind the 400.
      refute Content.get_paper(slug)
    end

    test "snake_case if_rev is refused the same way", %{conn: conn} do
      slug = "ifrev-refusal-snake"

      conn = post_paper(conn, body(slug, %{"if_rev" => 3}))

      resp = json_response(conn, 400)
      assert resp["error"]["code"] == "malformed"
      assert resp["error"]["parameter"] == "if_rev"
      refute Content.get_paper(slug)
    end

    test "a matching-looking ifRev is refused too — the route has no fence to match against",
         %{conn: conn} do
      slug = "ifrev-refusal-plausible"

      # First publish the paper so it has a real rev, then re-publish quoting
      # that rev. A caller doing this believes it holds a CAS. It does not.
      _ = post_paper(conn, body(slug, %{}))
      paper = Content.get_paper(slug)
      assert paper

      conn2 = post_paper(Phoenix.ConnTest.build_conn(), body(slug, %{"ifRev" => paper.rev}))
      assert json_response(conn2, 400)["error"]["parameter"] == "ifRev"
    end
  end

  describe "control — the refusal is narrow" do
    test "a body with no ifRev key publishes unchanged (200 ok)", %{conn: conn} do
      slug = "ifrev-control-clean"

      conn = post_paper(conn, body(slug, %{}))

      resp = json_response(conn, 200)
      assert resp["ok"] == true
      assert resp["slug"] == slug
      assert Content.get_paper(slug)
    end
  end
end
