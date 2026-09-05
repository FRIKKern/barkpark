defmodule BarkparkWeb.BulldocsProposalsTest do
  @moduledoc """
  The AI-proposes loop (lvw-t4) — `POST /v1/plugins/bulldocs/papers/:slug/proposals`.

  The three keep-sacred invariants under test, adversarially (distrust
  vacuous green):

    1. A proposal NEVER mutates the published revision — asserted by
       byte-comparing the published row's content + mutation rev before/after.
    2. Every proposal carries provenance — the `proposal-source` edge exists,
       hangs off the DRAFT row's PK (not the published row, where the
       projector would wipe it), and points at the source doc; an
       unresolvable source rolls the WHOLE write back (no draft row).
    3. Approval is the EXISTING draft→publish gate — `publish_document/4`
       lands the proposed block on the published row with the provenance
       sidecar intact, and the Bulldocs extractor re-emits the edge from it.
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Edge}
  alias Barkpark.Repo

  # Set in config/test.exs.
  @token "barkpark-test-ingest-token"
  @dataset "production"

  defp propose_path(slug), do: "/v1/plugins/bulldocs/papers/#{slug}/proposals"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  # A published paper to propose into, plus a published source doc (another
  # paper) for provenance. Returns {slug, source_slug}.
  defp seed!(slug, source_slug) do
    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "blocks" => [
            %{
              "id" => "intro",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Canonical prose."}]
            }
          ]
        })
      )

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => source_slug,
          "blocks" => [
            %{
              "id" => "v",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "12 weeks"}]
            }
          ]
        })
      )

    # These papers were born PUBLISHED via the upsert_paper bypass (D13 — the
    # wall's fifth mount is deferred to ae-upsert-paper-wall) and carry no
    # labels; the explicit draft->publish gate under test rides the exemption
    # ledger exactly like prod's pre-wall corpus.
    Barkpark.LabelFixtures.exempt!([slug, source_slug], @dataset)

    {slug, source_slug}
  end

  defp valueref_block(id, target) do
    %{
      "id" => id,
      "type" => "paragraph",
      "content" => [
        %{"type" => "text", "value" => "Launch delay is "},
        %{
          "type" => "valueref",
          "target" => target,
          "field" => "launch_delay",
          "fallback" => "12 weeks",
          "children" => [%{"type" => "text", "value" => "12 weeks"}]
        }
      ]
    }
  end

  defp proposal_body(block, source_slug) do
    %{
      "ops" => [%{"op" => "append-block", "block" => block}],
      "source" => %{"doc_id" => source_slug, "agent" => "agent-x", "note" => "derived from kpi"}
    }
  end

  defp get_doc!(doc_id) do
    Repo.one!(from d in Document, where: d.doc_id == ^doc_id and d.dataset == ^@dataset)
  end

  defp edges_from(pk) do
    Repo.all(from e in Edge, where: e.from_id == ^pk)
  end

  describe "auth" do
    test "rejects without the ingest token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(propose_path("nope"), %{"ops" => [], "source" => %{}})

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end
  end

  describe "the proposal write" do
    test "lands on the drafts. twin and NEVER mutates the published revision", %{conn: conn} do
      {slug, source} = seed!("lvw-t4-paper", "lvw-t4-kpi")
      pub_before = get_doc!(slug)

      conn =
        authed(conn)
        |> post(propose_path(slug), proposal_body(valueref_block("prop-1", source), source))

      resp = json_response(conn, 200)

      assert resp["ok"] == true
      assert resp["draft_id"] == "drafts.#{slug}"
      assert resp["applied_block_ids"] == ["prop-1"]
      assert resp["skipped_block_ids"] == []

      assert resp["provenance"] == %{
               "from" => "drafts.#{slug}",
               "to" => source,
               "kind" => "proposal-source"
             }

      assert resp["approve_via"]["mutate"]["publish"] == %{"id" => slug, "type" => "paper"}

      # THE invariant: the published row is byte-identical — content AND
      # mutation-spine rev untouched.
      pub_after = get_doc!(slug)
      assert pub_after.content == pub_before.content
      assert pub_after.rev == pub_before.rev
      refute Enum.any?(pub_after.content["blocks"], &(&1["id"] == "prop-1"))

      # The draft carries the suggestion + the provenance sidecar.
      draft = get_doc!("drafts.#{slug}")
      assert draft.status == "draft"
      assert Enum.any?(draft.content["blocks"], &(&1["id"] == "prop-1"))

      assert %{"source" => ^source, "agent" => "agent-x", "note" => "derived from kpi"} =
               draft.content["proposals"]["prop-1"]

      # The draft still contains the original prose (proposals only insert).
      assert Enum.any?(draft.content["blocks"], &(&1["id"] == "intro"))
    end

    test "writes the provenance edge from the DRAFT row's PK to the source doc", %{conn: conn} do
      {slug, source} = seed!("lvw-t4-edge-paper", "lvw-t4-edge-kpi")

      authed(conn)
      |> post(propose_path(slug), proposal_body(valueref_block("prop-1", source), source))

      draft = get_doc!("drafts.#{slug}")
      pub = get_doc!(slug)
      source_doc = get_doc!(source)

      assert [edge] = edges_from(draft.id)
      assert edge.to_id == source_doc.id
      assert edge.kind == "proposal-source"
      assert edge.plugin_source == "bulldocs-proposal:agent-x"

      # Pinned to the draft, NOT the published row (the projector rebuilds the
      # published row's outbound edges and would wipe a manual edge there).
      assert Enum.filter(edges_from(pub.id), &(&1.kind == "proposal-source")) == []
    end

    test "is idempotent on block id: replay skips, no duplicate block, one edge", %{conn: conn} do
      {slug, source} = seed!("lvw-t4-idem-paper", "lvw-t4-idem-kpi")
      body = proposal_body(valueref_block("prop-1", source), source)

      resp1 = authed(conn) |> post(propose_path(slug), body) |> json_response(200)
      resp2 = authed(build_conn()) |> post(propose_path(slug), body) |> json_response(200)

      assert resp1["applied_block_ids"] == ["prop-1"]
      assert resp2["applied_block_ids"] == []
      assert resp2["skipped_block_ids"] == ["prop-1"]
      # No spurious rev bump on the replay.
      assert resp2["rev"] == resp1["rev"]

      draft = get_doc!("drafts.#{slug}")
      assert Enum.count(draft.content["blocks"], &(&1["id"] == "prop-1")) == 1
      assert [_one_edge] = edges_from(draft.id)
    end
  end

  describe "fail-closed validation" do
    test "rejects mutating op kinds — overwriting prose is structurally impossible", %{conn: conn} do
      {slug, source} = seed!("lvw-t4-mut-paper", "lvw-t4-mut-kpi")

      body = %{
        "ops" => [%{"op" => "patch-block", "id" => "intro", "patch" => %{"content" => []}}],
        "source" => %{"doc_id" => source, "agent" => "agent-x"}
      }

      resp = authed(conn) |> post(propose_path(slug), body) |> json_response(422)
      assert resp["error"]["code"] == "invalid_proposal"
      # Nothing written — not even the draft seed.
      assert Repo.all(from d in Document, where: d.doc_id == ^"drafts.#{slug}") == []
    end

    test "rejects an id-less proposed block (no idempotency key)", %{conn: conn} do
      {slug, source} = seed!("lvw-t4-noid-paper", "lvw-t4-noid-kpi")

      body = %{
        "ops" => [%{"op" => "append-block", "block" => %{"type" => "paragraph", "content" => []}}],
        "source" => %{"doc_id" => source, "agent" => "agent-x"}
      }

      assert authed(conn)
             |> post(propose_path(slug), body)
             |> json_response(422)
             |> get_in(["error", "code"]) ==
               "invalid_proposal"
    end

    test "rejects a proposal without source (provenance is mandatory)", %{conn: conn} do
      {slug, _source} = seed!("lvw-t4-nosrc-paper", "lvw-t4-nosrc-kpi")

      body = %{"ops" => [%{"op" => "append-block", "block" => valueref_block("prop-1", "x")}]}

      assert authed(conn)
             |> post(propose_path(slug), body)
             |> json_response(422)
             |> get_in(["error", "code"]) ==
               "missing_source"
    end

    test "an unresolvable source rolls the WHOLE write back — no draft, no edge", %{conn: conn} do
      {slug, _source} = seed!("lvw-t4-badsrc-paper", "lvw-t4-badsrc-kpi")

      body = proposal_body(valueref_block("prop-1", "ghost"), "no-such-doc-anywhere")
      resp = authed(conn) |> post(propose_path(slug), body) |> json_response(422)

      assert resp["error"]["code"] == "source_not_found"
      # Fail closed: the transaction rolled back the draft seed too.
      assert Repo.all(from d in Document, where: d.doc_id == ^"drafts.#{slug}") == []
    end

    test "404s on an unknown paper slug", %{conn: conn} do
      body = proposal_body(valueref_block("prop-1", "x"), "x")
      assert authed(conn) |> post(propose_path("no-such-paper"), body) |> json_response(404)
    end

    test "a proposal breaking the constraint vocabulary rolls the WHOLE write back (pdd-t20)",
         %{conn: conn} do
      # A doctrine paper carrying its one featured (title @0 + featured @1) is
      # constraint-VALID, so the op-layer backstop is live on its drafts twin — an
      # insert-only proposal appending a SECOND featured breaks max-1. Under D11 the
      # featured is no longer auto-seeded, so it is supplied explicitly.
      slug = "lvw-t4-constraint-paper"

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => slug,
            "blocks" => [
              %{
                "id" => "tpl-title",
                "type" => "heading",
                "level" => 1,
                "role" => "title",
                "locked" => true,
                "text" => "T"
              },
              %{
                "id" => "tpl-featured",
                "type" => "image",
                "role" => "featured",
                "locked" => true
              },
              # A real body block: skeleton-only papers are refused by the
              # hollow-body quality gate (p-quality-gate); this test targets the
              # constraint vocabulary, not the hollow gate.
              %{
                "id" => "body-p",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Body."}]
              }
            ]
          })
        )

      {_, source} = seed!("lvw-t4-constraint-helper", "lvw-t4-constraint-kpi")

      body =
        proposal_body(
          %{"id" => "prop-feat", "type" => "image", "role" => "featured"},
          source
        )

      resp = authed(conn) |> post(propose_path(slug), body) |> json_response(422)
      assert resp["error"]["code"] == "constraint"
      assert resp["error"]["message"] =~ "at most 1 \"featured\" block"

      # Fail closed: the transaction rolled back the draft seed too.
      assert Repo.all(from d in Document, where: d.doc_id == ^"drafts.#{slug}") == []
    end
  end

  describe "approval — the EXISTING draft→publish gate" do
    test "publish lands the proposal on the published row, provenance sidecar intact", %{
      conn: conn
    } do
      {slug, source} = seed!("lvw-t4-gate-paper", "lvw-t4-gate-kpi")

      authed(conn)
      |> post(propose_path(slug), proposal_body(valueref_block("prop-1", source), source))

      assert {:ok, published} = Content.publish_document(slug, "paper", @dataset)

      # The proposed block + the original prose are BOTH on the published row.
      ids = Enum.map(published.content["blocks"], & &1["id"])
      assert "prop-1" in ids
      assert "intro" in ids
      # Provenance rode the publish copy.
      assert published.content["proposals"]["prop-1"]["source"] == source
      # The draft is consumed by the gate.
      assert Repo.all(from d in Document, where: d.doc_id == ^"drafts.#{slug}") == []
    end

    test "the extractor re-emits the provenance edge from the published sidecar", %{conn: conn} do
      {slug, source} = seed!("lvw-t4-extract-paper", "lvw-t4-extract-kpi")

      authed(conn)
      |> post(propose_path(slug), proposal_body(valueref_block("prop-1", source), source))

      assert {:ok, published} = Content.publish_document(slug, "paper", @dataset)

      edges = Barkpark.Plugins.Bulldocs.extract_edges(published, %{})

      assert %{from_id: ^slug, to_id: ^source, kind: "proposal-source", plugin_source: "bulldocs"} =
               Enum.find(edges, &(&1.kind == "proposal-source"))

      # The proposed valueref ALSO projects its own valueref edge (post-#714).
      assert Enum.any?(edges, &(&1.kind == "valueref" and &1.to_id == source))
    end

    test "rejection is the existing discardDraft — published prose untouched throughout", %{
      conn: conn
    } do
      {slug, source} = seed!("lvw-t4-reject-paper", "lvw-t4-reject-kpi")
      pub_before = get_doc!(slug)

      authed(conn)
      |> post(propose_path(slug), proposal_body(valueref_block("prop-1", source), source))

      assert {:ok, _} = Content.discard_draft(slug, "paper", @dataset)

      pub_after = get_doc!(slug)
      assert pub_after.content == pub_before.content
      assert Repo.all(from d in Document, where: d.doc_id == ^"drafts.#{slug}") == []
      # The cascade took the draft's provenance edge with it.
      assert Repo.all(from e in Edge, where: e.kind == "proposal-source") == []
    end
  end
end
