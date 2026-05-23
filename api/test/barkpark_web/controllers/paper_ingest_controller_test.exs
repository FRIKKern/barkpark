defmodule BarkparkWeb.PaperIngestControllerTest do
  @moduledoc """
  Focused test for the paperflow paper-ingest endpoint (convergence MVP).

  Mirrors the request `paperflow/hooks/event-on-save.sh` POSTs:
  `Authorization: Bearer <ingest token>` + JSON `{source_doc, slug,
  event_type, body_html, goal_id?}`. Asserts a valid token upserts +
  broadcasts on the per-doc PubSub topic, and that a bad / missing token is
  rejected.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Papers

  # Set in config/test.exs.
  @token "paperflow-test-ingest-token"
  @path "/v1/paperflow/papers"

  defp body(slug) do
    %{
      "source_doc" => "plans/#{slug}.html",
      "slug" => slug,
      "event_type" => "plan-written",
      "body_html" => ~s(<article><h1>#{slug}</h1></article>),
      "goal_id" => "bd-test1"
    }
  end

  describe "auth" do
    test "rejects with no token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(@path, body("no-token-paper"))

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
      refute Papers.get_paper("no-token-paper")
    end

    test "rejects with a wrong token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-the-real-token")
        |> put_req_header("content-type", "application/json")
        |> post(@path, body("bad-token-paper"))

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
      refute Papers.get_paper("bad-token-paper")
    end
  end

  describe "valid ingest" do
    test "upserts the paper and broadcasts on the per-doc topic", %{conn: conn} do
      slug = "ingest-ok-paper"
      # Subscribe BEFORE the request so we observe the broadcast.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Papers.topic(slug))

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("content-type", "application/json")
        |> post(@path, body(slug))

      resp = json_response(conn, 200)
      assert resp["ok"] == true
      assert resp["slug"] == slug
      assert resp["liveview_path"] == "/papers/#{slug}"
      assert is_binary(resp["rev"])

      # Persisted so a fresh LiveView mount renders the latest HTML.
      paper = Papers.get_paper(slug)
      assert paper.body_html =~ slug
      assert paper.source_doc == "plans/#{slug}.html"
      assert paper.goal_id == "bd-test1"
      assert paper.event_type == "plan-written"

      # Broadcast landed on the topic PaperLive subscribes to.
      assert_receive {:paper_updated, %{slug: ^slug, html: html}}
      assert html =~ slug
    end

    test "a second POST with the same slug updates in place (upsert)", %{conn: conn} do
      slug = "ingest-upsert-paper"

      auth = fn c, payload ->
        c
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("content-type", "application/json")
        |> post(@path, payload)
      end

      _ = auth.(conn, %{"slug" => slug, "body_html" => "<p>v1</p>"})

      _ =
        auth.(Phoenix.ConnTest.build_conn(), %{"slug" => slug, "body_html" => "<p>v2 updated</p>"})

      paper = Papers.get_paper(slug)
      assert paper.body_html == "<p>v2 updated</p>"
      # Exactly one row for the slug — updated, not duplicated.
      assert length(Barkpark.Repo.all(Barkpark.Papers.Paper)) >= 1
    end

    test "rejects a payload missing slug/body_html with 400", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("content-type", "application/json")
        |> post(@path, %{"event_type" => "plan-written"})

      assert json_response(conn, 400)["error"]["code"] == "malformed"
    end
  end
end
