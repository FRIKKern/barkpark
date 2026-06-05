defmodule BarkparkWeb.BulldocsIngestControllerTest do
  @moduledoc """
  Focused test for the paperflow paper-ingest endpoint (convergence MVP).

  Mirrors the request `paperflow/hooks/event-on-save.sh` POSTs:
  `Authorization: Bearer <ingest token>` + JSON `{source_doc, slug,
  event_type, body_html, goal_id?}`. Asserts a valid token upserts +
  broadcasts on the per-doc PubSub topic, and that a bad / missing token is
  rejected.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  import Ecto.Query, only: [from: 2]

  # Convenience accessors — papers are type-"paper" documents now; the block
  # list / HTML cache / provenance live in the document's `content` map.
  defp pc(doc, key), do: get_in(doc.content || %{}, [key])

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
      refute Content.get_paper("no-token-paper")
    end

    test "rejects with a wrong token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-the-real-token")
        |> put_req_header("content-type", "application/json")
        |> post(@path, body("bad-token-paper"))

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
      refute Content.get_paper("bad-token-paper")
    end
  end

  describe "valid ingest" do
    test "upserts the paper and broadcasts on the per-doc topic", %{conn: conn} do
      slug = "ingest-ok-paper"
      # Subscribe BEFORE the request so we observe the broadcast.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Content.paper_topic(slug, nil))

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
      paper = Content.get_paper(slug)
      assert pc(paper, "body_html") =~ slug
      assert pc(paper, "source_doc") == "plans/#{slug}.html"
      assert pc(paper, "goal_id") == "bd-test1"
      assert pc(paper, "event_type") == "plan-written"

      # Broadcast landed on the topic BulldocsLive subscribes to.
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

      paper = Content.get_paper(slug)
      assert pc(paper, "body_html") == "<p>v2 updated</p>"
      # Exactly one row for the slug — updated, not duplicated.
      count =
        Barkpark.Repo.one(
          from d in Barkpark.Content.Document,
            where: d.type == "paper" and d.doc_id == ^slug,
            select: count(d.id)
        )

      assert count == 1
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

  describe "block-ingest endpoint (POST /:slug/ops)" do
    defp ops_path(slug), do: "#{@path}/#{slug}/ops"

    defp auth_post(conn, slug, op) do
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")
      |> post(ops_path(slug), op)
    end

    defp append_op(id, text) do
      %{
        "op" => "append-block",
        "block" => %{
          "id" => id,
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => text}]
        }
      }
    end

    setup do
      slug = "ops-target-#{System.unique_integer([:positive])}"
      # A block-backed paper to apply ops against.
      {:ok, paper} =
        Content.upsert_paper(%{
          slug: slug,
          blocks: [
            %{"id" => "intro", "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Intro."}]}
          ]
        })

      {:ok, slug: slug, rev0: pc(paper, "rev")}
    end

    test "valid op + bearer applies, bumps rev, broadcasts a delta, returns the fragment",
         %{conn: conn, slug: slug, rev0: rev0} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Content.paper_topic(slug, nil))

      conn = auth_post(conn, slug, append_op("b-new", "Streamed in."))

      resp = json_response(conn, 200)
      assert resp["ok"] == true
      assert resp["slug"] == slug
      assert resp["op"] == "append-block"
      assert resp["block_id"] == "b-new"
      assert resp["rev"] == rev0 + 1
      assert resp["fragment_html"] =~ "Streamed in."

      # Persisted: block list grew, HTML cache refreshed.
      paper = Content.get_paper(slug)
      assert length(pc(paper, "blocks")) == 2
      assert pc(paper, "body_html") =~ "Streamed in."

      # Delta frame landed on the per-doc topic BulldocsLive subscribes to.
      assert_receive {:paper_block, %{op_kind: "append-block", block_id: "b-new", rev: rev}}
      assert rev == rev0 + 1
    end

    test "bad token → 401, no mutation", %{conn: conn, slug: slug} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-the-real-token")
        |> put_req_header("content-type", "application/json")
        |> post(ops_path(slug), append_op("b-x", "nope"))

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
      # Untouched — still just the seeded block.
      assert length(pc(Content.get_paper(slug), "blocks")) == 1
    end

    test "unknown slug → 404", %{conn: conn} do
      conn = auth_post(conn, "no-such-paper", append_op("b-x", "nope"))
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "malformed op (unknown discriminator) → 422", %{conn: conn, slug: slug} do
      conn = auth_post(conn, slug, %{"op" => "frobnicate", "block" => %{"id" => "z"}})
      assert json_response(conn, 422)["error"]["code"] == "malformed_op"
    end

    test "well-shaped op that fails to apply (block not found) → 422", %{conn: conn, slug: slug} do
      bad =
        %{
          "op" => "patch-block",
          "id" => "does-not-exist",
          "patch" => %{"content" => [%{"type" => "text", "value" => "x"}]}
        }

      conn = auth_post(conn, slug, bad)
      resp = json_response(conn, 422)
      assert resp["error"]["code"] == "block_not_found"
      assert resp["error"]["op"] == "patch-block"
    end
  end
end
