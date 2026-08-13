defmodule BarkparkWeb.BulldocsBpmlApiTest do
  @moduledoc """
  BPML over the wire (masterplan W1/W2): publish a paper AS BPML, read it
  back via `GET /papers/:slug/source?format=bpml`, patch it with a BPML op
  fragment — and get teaching errors, not generic 4xx, for every wrong shape.
  The full-circle test at the end is the API-level isomorphism proof:
  BPML in → blocks stored → BPML out → same blocks.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.LabelFixtures
  alias Barkpark.PortableDoc.Bpml

  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  defp pc(doc, key), do: get_in(doc.content || %{}, [key])

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp bpml_doc(slug) do
    """
    <paper slug="#{slug}" title="Rollout">
      <eyebrow>OPS · LIVE</eyebrow>
      <h1>Rollout</h1>
      <section id="s1" title="Detail">
        <p id="p1">Canary at <b>5%</b> — see <a href="/papers/plan">the plan</a>.</p>
      </section>
    </paper>
    """
  end

  describe "publish via bpml" do
    test "a BPML document ingests through the same pipeline as blocks", %{conn: conn} do
      slug = "bpml-publish-paper"
      body = LabelFixtures.paper_attrs(%{"bpml" => bpml_doc(slug)})

      conn = authed(conn) |> post(@ingest_path, body)
      assert %{"ok" => true, "slug" => ^slug} = json_response(conn, 200)

      paper = Content.get_paper(slug)
      assert [eyebrow, heading, section] = pc(paper, "blocks")
      assert eyebrow["type"] == "eyebrow"
      # the write chokepoint mints ids for id-less blocks — BPML need not carry them
      assert heading["id"] != nil

      assert Map.take(heading, ["type", "level", "text"]) ==
               %{"type" => "heading", "level" => 1, "text" => "Rollout"}

      assert section["id"] == "s1"
      assert [%{"id" => "p1", "type" => "paragraph", "content" => content}] = section["blocks"]
      assert %{"type" => "text", "marks" => ["strong"], "value" => "5%"} in content
    end

    test "a broken BPML document returns collected teaching errors", %{conn: conn} do
      bpml = """
      <paper slug="bpml-bad-paper" title="Bad">
        <div>nope</div>
        <p class="lead">styled</p>
      </paper>
      """

      conn = authed(conn) |> post(@ingest_path, %{"bpml" => bpml})
      assert %{"error" => %{"code" => "bpml", "errors" => errors}} = json_response(conn, 422)
      assert [div_err, class_err] = errors
      assert div_err["code"] == "unknown-tag"
      assert div_err["hint"] =~ "<section"
      assert div_err["line"] == 2
      assert class_err["code"] == "no-styling"
      refute Content.get_paper("bpml-bad-paper")
    end
  end

  describe "GET source?format=bpml" do
    test "returns the readable view with the rev anchored in a header", %{conn: conn} do
      slug = "bpml-read-paper"
      body = LabelFixtures.paper_attrs(%{"bpml" => bpml_doc(slug)})
      assert authed(build_conn()) |> post(@ingest_path, body) |> json_response(200)

      conn = get(conn, "/papers/#{slug}/source", %{"format" => "bpml"})
      assert response_content_type(conn, :bpml) =~ "text/bpml"
      assert [rev] = get_resp_header(conn, "x-paper-rev")
      assert rev != ""

      bpml = response(conn, 200)
      assert bpml =~ ~s(<paper slug="#{slug}" title="Rollout">)
      assert bpml =~ "<b>5%</b>"
    end

    test "an unknown format teaches the format family", %{conn: conn} do
      conn = get(conn, "/papers/whatever/source", %{"format" => "yaml"})
      assert %{"error" => err} = json_response(conn, 400)
      assert err["code"] == "unknown_format"
      assert err["hint"] =~ "bpml"
    end
  end

  describe "ops with BPML fragments" do
    test "an op may spell its block as BPML", %{conn: conn} do
      slug = "bpml-ops-paper"
      body = LabelFixtures.paper_attrs(%{"bpml" => bpml_doc(slug)})
      assert authed(build_conn()) |> post(@ingest_path, body) |> json_response(200)

      ops = %{
        "ops" => [
          %{
            "op" => "append-block",
            "bpml" => ~s(<callout id="c-new" tone="success" title="Done">Shipped.</callout>)
          }
        ]
      }

      conn = authed(conn) |> post("#{@ingest_path}/#{slug}/ops", ops)
      assert %{"ok" => true, "op_count" => 1} = json_response(conn, 200)

      paper = Content.get_paper("drafts." <> slug) || Content.get_paper(slug)
      appended = paper |> pc("blocks") |> List.last()
      assert appended["id"] == "c-new"
      assert appended["tone"] == "success"
      assert appended["content"] == [%{"type" => "text", "value" => "Shipped."}]
    end

    test "a fragment with two blocks teaches one-op-one-block", %{conn: conn} do
      slug = "bpml-ops-arity-paper"
      body = LabelFixtures.paper_attrs(%{"bpml" => bpml_doc(slug)})
      assert authed(build_conn()) |> post(@ingest_path, body) |> json_response(200)

      ops = %{"ops" => [%{"op" => "append-block", "bpml" => "<p>one</p>\n<p>two</p>"}]}

      conn = authed(conn) |> post("#{@ingest_path}/#{slug}/ops", ops)
      assert %{"error" => %{"code" => "bpml", "errors" => [e]}} = json_response(conn, 422)
      assert e["code"] == "bpml-fragment-arity"
      assert e["hint"] =~ "one op per block"
    end

    test "a broken fragment carries its op index", %{conn: conn} do
      slug = "bpml-ops-broken-paper"
      body = LabelFixtures.paper_attrs(%{"bpml" => bpml_doc(slug)})
      assert authed(build_conn()) |> post(@ingest_path, body) |> json_response(200)

      ops = %{
        "ops" => [
          %{"op" => "append-block", "block" => %{"id" => "x1", "type" => "divider"}},
          %{"op" => "append-block", "bpml" => "<div>nope</div>"}
        ]
      }

      conn = authed(conn) |> post("#{@ingest_path}/#{slug}/ops", ops)
      assert %{"error" => %{"errors" => [e]}} = json_response(conn, 422)
      assert e["op_index"] == 1
      assert e["hint"] =~ "<section"
    end
  end

  describe "POST papers/validate (validate-all dry-run)" do
    test "a compliant BPML paper validates clean and persists NOTHING", %{conn: conn} do
      slug = "bpml-validate-clean"
      attrs = LabelFixtures.paper_attrs(%{})

      bpml = """
      <paper slug="#{slug}" title="Clean">
        <meta>
          <description>#{attrs["description"]}</description>
      #{Enum.map_join(attrs["tags"], "\n", fn t -> ~s(    <tag tag="#{t["tag"]}" strength="#{t["strength"]}">#{t["rationale"]}</tag>) end)}
        </meta>
        <h1>Clean</h1>
        <p>A real paragraph of content, long enough to be honest.</p>
      </paper>
      """

      conn = authed(conn) |> post("#{@ingest_path}/validate", %{"bpml" => bpml})
      assert %{"valid" => true, "violations" => []} = json_response(conn, 200)
      refute Content.get_paper(slug)
    end

    test "every violation arrives in ONE reply — wall + structure together", %{conn: conn} do
      # unregistered tag + hollow body (title only): two different gates
      bpml = """
      <paper slug="bpml-validate-bad" title="Bad">
        <meta>
          <description>A perfectly reasonable description of this paper.</description>
          <tag tag="never-registered-tag" strength="50">not in the registry</tag>
        </meta>
        <h1>Bad</h1>
      </paper>
      """

      conn = authed(conn) |> post("#{@ingest_path}/validate", %{"bpml" => bpml})
      assert %{"valid" => false, "violations" => violations} = json_response(conn, 200)
      codes = Enum.map(violations, & &1["code"])
      assert "unknown_tag" in codes
      assert "hollow_paper" in codes
      refute Content.get_paper("bpml-validate-bad")
    end

    test "a BPML parse failure returns the teaching errors as violations", %{conn: conn} do
      conn =
        authed(conn)
        |> post("#{@ingest_path}/validate", %{
          "bpml" => "<paper slug=\"x\" title=\"X\"><div>no</div></paper>"
        })

      assert %{"valid" => false, "violations" => [v]} = json_response(conn, 200)
      assert v["code"] == "bpml-unknown-tag"
      assert v["hint"] =~ "<section"
    end
  end

  describe "full circle" do
    test "BPML in → blocks stored → BPML out → identical blocks", %{conn: conn} do
      slug = "bpml-circle-paper"
      body = LabelFixtures.paper_attrs(%{"bpml" => bpml_doc(slug)})
      assert authed(build_conn()) |> post(@ingest_path, body) |> json_response(200)

      stored = Content.get_paper(slug) |> pc("blocks")

      out = get(conn, "/papers/#{slug}/source", %{"format" => "bpml"}) |> response(200)
      assert {:ok, %{"blocks" => reparsed}} = Bpml.parse_paper(out)
      assert reparsed == stored
    end
  end
end
