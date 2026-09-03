defmodule BarkparkWeb.BulldocsBpmlApiTest do
  @moduledoc """
  BPML over the wire (masterplan W1/W2): publish a paper AS BPML, read it
  back via `GET /papers/:slug/source?format=bpml`, patch it with a BPML op
  fragment — and get teaching errors, not generic 4xx, for every wrong shape.
  The full-circle test at the end is the API-level isomorphism proof:
  BPML in → blocks stored → BPML out → same blocks.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures
  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.Repo

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

  describe "POST papers/:slug/sync (working-copy push)" do
    defp pull!(conn, slug) do
      conn = get(conn, "/papers/#{slug}/source", %{"format" => "bpml"})
      [rev] = get_resp_header(conn, "x-paper-rev")
      {response(conn, 200), rev}
    end

    test "the full cycle: pull, edit the file, push, converge on canonical", %{conn: conn} do
      slug = "bpml-sync-paper"
      body = LabelFixtures.paper_attrs(%{"bpml" => bpml_doc(slug)})
      assert authed(build_conn()) |> post(@ingest_path, body) |> json_response(200)

      {bpml, rev} = pull!(build_conn(), slug)
      edited = String.replace(bpml, "Canary at ", "Canary holding at ")
      assert edited != bpml

      conn =
        authed(conn)
        |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => edited, "baseRev" => rev})

      assert %{"ok" => true, "op_count" => 1, "rev" => new_rev, "bpml" => canonical} =
               json_response(conn, 200)

      assert new_rev != rev
      assert canonical =~ "Canary holding at "

      # the working copy converges: pulling again returns exactly the canonical
      {pulled, pulled_rev} = pull!(build_conn(), slug)
      assert pulled == canonical
      assert pulled_rev == to_string(new_rev)
    end

    test "a stale baseRev is a 412 that teaches pull-first", %{conn: conn} do
      slug = "bpml-sync-stale"
      body = LabelFixtures.paper_attrs(%{"bpml" => bpml_doc(slug)})
      assert authed(build_conn()) |> post(@ingest_path, body) |> json_response(200)

      {bpml, _rev} = pull!(build_conn(), slug)

      conn =
        authed(conn)
        |> post("#{@ingest_path}/#{slug}/sync", %{
          "bpml" => bpml <> "<p>late edit</p>\n",
          "baseRev" => "not-the-rev"
        })

      assert %{"error" => err} = json_response(conn, 412)
      assert err["code"] == "precondition_failed"
      assert err["hint"] =~ "pull"
    end

    test "an unchanged push applies nothing", %{conn: conn} do
      slug = "bpml-sync-unchanged"
      body = LabelFixtures.paper_attrs(%{"bpml" => bpml_doc(slug)})
      assert authed(build_conn()) |> post(@ingest_path, body) |> json_response(200)

      {bpml, rev} = pull!(build_conn(), slug)

      conn =
        authed(conn) |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})

      assert %{"ok" => true, "unchanged" => true, "op_count" => 0} = json_response(conn, 200)
    end

    test "a broken edit returns teaching errors, nothing applied", %{conn: conn} do
      slug = "bpml-sync-broken"
      body = LabelFixtures.paper_attrs(%{"bpml" => bpml_doc(slug)})
      assert authed(build_conn()) |> post(@ingest_path, body) |> json_response(200)

      {bpml, rev} = pull!(build_conn(), slug)
      broken = String.replace(bpml, "<h1", "<div") |> String.replace("</h1>", "</div>")

      conn =
        authed(conn)
        |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => broken, "baseRev" => rev})

      assert %{"error" => %{"code" => "bpml", "errors" => [e | _]}} = json_response(conn, 422)
      assert e["hint"] =~ "<section"

      {after_bpml, after_rev} = pull!(build_conn(), slug)
      assert after_bpml == bpml
      assert after_rev == rev
    end

    # Create-on-push (pe-w6 / charter D41): an absent slug is no longer a 404 —
    # sync CREATES it through the full publish wall. What this pins instead:
    # the two honest refusals of that arm — a path/document identity mismatch,
    # and a wall refusal that names every violation and writes NOTHING (the
    # deep create tests live in bulldocs_ingest_controller_test.exs).
    test "an unknown slug whose document names a DIFFERENT slug refuses the identity mismatch",
         %{conn: conn} do
      conn =
        authed(conn)
        |> post("#{@ingest_path}/nope-never/sync", %{
          "bpml" => "<paper slug=\"x\" title=\"X\"></paper>",
          "baseRev" => "1"
        })

      assert %{"error" => err} = json_response(conn, 422)
      assert err["code"] == "slug_mismatch"
      refute Content.get_paper("nope-never")
      refute Content.get_paper("x")
    end

    test "an unknown slug with a wall-failing document is a create refusal that writes nothing",
         %{conn: conn} do
      conn =
        authed(conn)
        |> post("#{@ingest_path}/nope-never/sync", %{
          "bpml" => "<paper slug=\"nope-never\" title=\"X\"><h1>X</h1></paper>",
          "baseRev" => "1"
        })

      assert %{"error" => err} = json_response(conn, 422)
      assert err["code"] == "create_wall"
      assert is_list(err["errors"]) and err["errors"] != []
      refute Content.get_paper("nope-never")
    end
  end

  # ── fail-honest: the printer's typed refusal at both doors ──────────────────
  #
  # The 2026-08-17 full-corpus census (776 published papers,
  # tooling/grip/ledger/bpml-full-corpus-census-2026-08-17.md) found 141 papers
  # answering a RAW HTTP 500 on the pull, because the printer crashed with an
  # unrescued FunctionClauseError on every unprintable shape except an unknown
  # block type. The same papers made the sync path DESTRUCTIVE: a kernel-only
  # BPML document cannot describe a non-kernel block, and the differ faithfully
  # deleted every one of them behind a 200.
  describe "unprintable papers fail honestly" do
    # Legacy rows carry shapes the write chokepoint no longer mints, so the
    # fixture writes them the way history did: publish a clean paper, then put
    # the historical blocks on the row.
    defp with_blocks!(slug, blocks) do
      {:ok, paper} =
        Content.upsert_paper(
          LabelFixtures.paper_attrs(%{
            slug: slug,
            blocks: [
              %{
                "id" => "p1",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "A real paragraph of content."}]
              }
            ]
          })
        )

      content = paper.content |> Map.put("blocks", blocks) |> Map.delete("body_html")

      paper
      |> Ecto.Changeset.change(content: content)
      |> Repo.update!()

      Content.get_paper(slug)
    end

    test "a persisted inline node outside the kernel is a labelled 422, not a 500", %{conn: conn} do
      slug = "bpml-unprintable-inline-#{System.unique_integer([:positive])}"

      with_blocks!(slug, [
        %{
          "id" => "p1",
          "type" => "paragraph",
          "content" => [
            %{"type" => "text", "value" => "run "},
            %{"type" => "valueref", "ref" => "stats.total"}
          ]
        }
      ])

      assert %{"error" => err} =
               conn
               |> get("/papers/#{slug}/source", %{"format" => "bpml"})
               |> json_response(422)

      assert err["code"] == "bpml_unprintable"
      assert err["message"] =~ ~s(inline node type "valueref")
      assert err["message"] =~ "kind: inline"
      assert err["hint"] =~ "format=json"

      # the block truth is still readable — the refusal is about the VIEW
      assert %{"source" => %{"kind" => "blocks"}} =
               build_conn() |> get("/papers/#{slug}/source") |> json_response(200)
    end

    test "a table head cell with no printable text refuses instead of silently losing the cell",
         %{conn: conn} do
      slug = "bpml-unprintable-head-#{System.unique_integer([:positive])}"

      with_blocks!(slug, [
        %{
          "id" => "t1",
          "type" => "table",
          # A cell with NO readable body. (A `%{"content" => inline_nodes}` cell
          # is spellable and now PRINTS — refusing what the kernel can spell is
          # a narrower loss, not honesty.)
          "head" => [%{"tone" => "warn"}],
          "rows" => [[[%{"type" => "text", "value" => "a"}]]]
        }
      ])

      assert %{"error" => err} =
               conn
               |> get("/papers/#{slug}/source", %{"format" => "bpml"})
               |> json_response(422)

      assert err["code"] == "bpml_unprintable"
      assert err["message"] =~ "kind: head_cell"
    end

    test "sync REFUSES an unprintable paper up front — the non-kernel block survives",
         %{conn: conn} do
      slug = "bpml-sync-destructive-#{System.unique_integer([:positive])}"

      blocks = [
        %{
          "id" => "p1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Kept."}]
        },
        %{"id" => "i1", "type" => "image"}
      ]

      paper = with_blocks!(slug, blocks)
      rev = to_string(get_in(paper.content, ["rev"]))

      # exactly what a client could send: the kernel-only spelling of this paper
      kernel_only = """
      <paper slug="#{slug}" title="#{paper.title}">
        <p id="p1">Kept and edited.</p>
      </paper>
      """

      conn =
        authed(conn)
        |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => kernel_only, "baseRev" => rev})

      assert %{"error" => err} = json_response(conn, 422)
      assert err["code"] == "bpml_unprintable"
      assert err["message"] =~ ~s(block type "image")
      assert err["hint"] =~ "block ops"

      # THE POINT: nothing was derived and nothing was applied — before the
      # guard this returned 200 and deleted the divider.
      after_paper = Content.get_paper(slug)
      assert pc(after_paper, "blocks") == blocks
      assert to_string(get_in(after_paper.content, ["rev"])) == rev
    end

    test "the canonical echo degrades to bpml:nil and keeps the rev anchor" do
      slug = "bpml-echo-degrade-#{System.unique_integer([:positive])}"

      paper =
        with_blocks!(slug, [
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "valueref", "ref" => "stats.total"}]
          }
        ])

      # A write that LANDED must not be reported as a failure: a 500 strands the
      # client's rev anchor and a 422 lies about what happened.
      assert {nil, refusal} = BarkparkWeb.BulldocsIngestController.canonical_echo(paper)
      assert refusal =~ "kind: inline"

      payload =
        BarkparkWeb.BulldocsIngestController.maybe_mark_echo(
          %{ok: true, slug: slug, rev: "7", op_count: 2, bpml: nil},
          refusal
        )

      assert payload.ok == true
      assert payload.rev == "7"
      assert payload.bpml == nil
      assert payload.bpml_unprintable == refusal
      assert payload.hint =~ "anchor"
    end

    test "a printable paper's echo is unchanged — the rescue is narrow" do
      slug = "bpml-echo-clean-#{System.unique_integer([:positive])}"

      paper =
        with_blocks!(slug, [%{"id" => "h1", "type" => "heading", "level" => 1, "text" => "H"}])

      assert {bpml, nil} = BarkparkWeb.BulldocsIngestController.canonical_echo(paper)
      assert bpml =~ "<h1 id=\"h1\">H</h1>"

      payload = %{ok: true, bpml: bpml}
      assert BarkparkWeb.BulldocsIngestController.maybe_mark_echo(payload, nil) == payload
    end
  end

  # ── wave-6: byline map-item items no longer answer a RAW 500 ────────────────
  #
  # The wave-5/6 papers themselves stored byline items as maps
  # (%{"value" => binary}); the printer's byline clause ran `esc(to_string(map))`
  # → Protocol.UndefinedError → escaped the rescue as a raw HTTP 500
  # (tooling/grip/ledger/pe-w6-byline-map-item-500-class-2026-08-17.md). The
  # clause now coerces the map to its string; a non-binary item refuses 422.
  describe "byline map-item items fail honestly (wave-6)" do
    test "a byline whose items are maps prints (200), not a raw 500", %{conn: conn} do
      slug = "bpml-byline-map-#{System.unique_integer([:positive])}"

      with_blocks!(slug, [
        %{
          "id" => "by",
          "type" => "byline",
          "items" => [%{"value" => "Epic task-4792 · wave 6"}, "A plain author"]
        }
      ])

      body = conn |> get("/papers/#{slug}/source", %{"format" => "bpml"}) |> response(200)
      assert body =~ "<item>Epic task-4792 · wave 6</item>"
      assert body =~ "<item>A plain author</item>"
    end

    test "a byline with a non-binary item is a labelled 422, not a 500", %{conn: conn} do
      slug = "bpml-byline-bad-#{System.unique_integer([:positive])}"

      with_blocks!(slug, [
        %{
          "id" => "p1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "A real paragraph."}]
        },
        %{"id" => "by", "type" => "byline", "items" => [%{"unexpected" => "shape"}]}
      ])

      assert %{"error" => err} =
               conn
               |> get("/papers/#{slug}/source", %{"format" => "bpml"})
               |> json_response(422)

      assert err["code"] == "bpml_unprintable"
    end
  end

  # ── wave-6: the notes grid round-trips over the wire ────────────────────────
  describe "notes grid over the wire (wave-6)" do
    test "a dict-item notes grid reads back as BPML and re-parses to the same blocks",
         %{conn: conn} do
      slug = "bpml-notes-grid-#{System.unique_integer([:positive])}"

      blocks = [
        %{
          "id" => "n1",
          "type" => "notes",
          "items" => [
            %{"label" => "First", "lead" => "one", "text" => "The opening remark."},
            %{"label" => "Second", "text" => "A follow-up."}
          ]
        }
      ]

      with_blocks!(slug, blocks)

      out = conn |> get("/papers/#{slug}/source", %{"format" => "bpml"}) |> response(200)
      assert out =~ ~s(<note label="First" lead="one">The opening remark.</note>)
      assert {:ok, %{"blocks" => reparsed}} = Bpml.parse_paper(out)
      assert reparsed == blocks
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
