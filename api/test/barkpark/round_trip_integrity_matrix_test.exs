defmodule Barkpark.RoundTripIntegrityMatrixTest do
  @moduledoc """
  THE ROUND-TRIP INTEGRITY MATRIX (Run-4 Lane B).

  The save-path matrix pins "an edit of one field moves no other field". This
  pins the next level up: a document that is MOVED, COPIED or RESTORED arrives
  byte-identical (`===`) to what was stored.

      corpus  = every field-type x stored-shape cell (`Barkpark.FieldShapeCorpus`)
                + every PortableDoc block type (the golden 65, one paper)
      paths   = envelope export -> createOrReplace into a fresh dataset (`bp export`)
                workspace bundle export -> import into a new dataset id
                query envelope -> createOrReplace in another project (`bp migrate`)
                sync: mutation event -> SSE -> Applier into another workspace
                BPML pull -> push of an unedited paper (must derive ZERO ops)
                revision restore of the first revision
                duplicate document (clone)

  The baseline is the document AS STORED after its first write — a transfer
  must preserve what is in the store, not re-run normalisation on it. A failure
  lists every failing cell (field name, or block type) rather than the first.

  Markdown import -> export -> import is not a path: there is no PortableDoc ->
  markdown exporter (formats are json and bpml), so it cannot round-trip.
  """
  # Every test runs twice: on a legacy field document, and on one whose block
  # list a Beta edit materialised (the projection branch of every writer).
  use BarkparkWeb.ConnCase,
    async: false,
    parameterize: [%{variant: :legacy}, %{variant: :blocks}]

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.{DraftId, MutationEvent}
  alias Barkpark.FieldShapeCorpus
  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.Repo
  alias Barkpark.Sync.{Applier, SSE}
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.WorkspaceBundle

  import Ecto.Query, only: [from: 2]

  @ds "rt"
  @type_name "rtfields"
  @golden_dir Path.expand("../support/fixtures/pd-parity", __DIR__)

  # ── corpus ────────────────────────────────────────────────────────────────

  defp golden_blocks do
    @golden_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".golden.json"))
    |> Enum.sort()
    |> Enum.map(fn file ->
      type = String.replace_suffix(file, ".golden.json", "")

      input =
        @golden_dir |> Path.join(file) |> File.read!() |> Jason.decode!() |> Map.fetch!("input")

      Map.put_new(input, "id", "g-" <> type)
    end)
  end

  defp schema!(scope, dataset) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Round trip",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "probe", "type" => "string"}
            | FieldShapeCorpus.schema_fields()
          ]
        },
        dataset,
        scope
      )
  end

  defp tenancy!(dataset) do
    ws = create_workspace!()
    proj = create_project!(ws)
    {:ok, _} = Tenancy.create_dataset(proj, %{slug: dataset, name: dataset})
    scope = [workspace_id: ws.id, project_id: proj.id]
    schema!(scope, dataset)
    %{ws: ws, proj: proj, scope: scope}
  end

  setup %{variant: variant} do
    {default_ws, default_proj} = ensure_default_scope!()
    src = tenancy!(@ds)
    doc_id = "rt-#{System.unique_integer([:positive])}"

    {:ok, fields_doc} =
      Content.create_document(
        @type_name,
        %{
          "doc_id" => doc_id,
          "title" => "Round trip",
          "content" => Map.put(FieldShapeCorpus.content(), "probe", "p")
        },
        @ds,
        src.scope ++ [source: :api]
      )

    fields_doc =
      if variant == :blocks do
        {blocks, _} = Content.resolve_blocks_for_edit(fields_doc, @type_name, @ds)
        probe = Enum.find(blocks, &(&1["fieldName"] == "probe"))
        op = %{"op" => "patch-block", "id" => probe["id"], "patch" => %{"value" => "p"}}

        {:ok, _} =
          Content.apply_document_block_op(fields_doc.doc_id, @type_name, op, @ds, src.scope)

        {:ok, d} = Content.get_document(fields_doc.doc_id, @type_name, @ds, src.scope)
        true = is_list(d.content["blocks"])
        d
      else
        fields_doc
      end

    slug = "rt-paper-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Round trip paper",
          "blocks" => golden_blocks()
        })
      )

    paper = Content.get_paper(slug)

    %{
      src: src,
      default: %{
        ws: default_ws,
        proj: default_proj,
        scope: [workspace_id: default_ws.id, project_id: default_proj.id]
      },
      fields_doc: fields_doc,
      paper: paper
    }
  end

  # ── comparison ────────────────────────────────────────────────────────────

  defp field_failures(base, got) do
    names = Enum.map(FieldShapeCorpus.cells(), &elem(&1, 0)) ++ ["blocks"]

    for name <- names,
        Map.fetch(base, name) !== Map.fetch(got || %{}, name) do
      {name, Map.get(base, name, :absent), Map.get(got || %{}, name, :absent)}
    end
  end

  defp block_failures(base_blocks, got_blocks) do
    got_by_id = Map.new(got_blocks || [], &{&1["id"], &1})

    changed =
      for block <- base_blocks, got_by_id[block["id"]] !== block do
        {block["type"], block, got_by_id[block["id"]]}
      end

    order =
      if Enum.map(base_blocks, & &1["id"]) == Enum.map(got_blocks || [], & &1["id"]),
        do: [],
        else: [
          {"<block order>", Enum.map(base_blocks, & &1["id"]),
           Enum.map(got_blocks || [], & &1["id"])}
        ]

    changed ++ order
  end

  defp assert_none!(path, failures) do
    case failures do
      [] ->
        :ok

      fails ->
        lines =
          Enum.map_join(fails, "\n", fn {cell, want, got} ->
            "  #{cell}:\n    stored #{inspect(want, limit: 12)}\n    → #{inspect(got, limit: 12)}"
          end)

        flunk("#{path}: #{length(fails)} cell(s) did not survive:\n#{lines}")
    end
  end

  defp fields_of(doc), do: doc.content || %{}
  defp blocks_of(doc), do: (doc.content || %{})["blocks"] || []

  defp get!(doc_id, type, dataset, scope) do
    {:ok, doc} = Content.get_document(doc_id, type, dataset, scope)
    doc
  end

  defp export_envelopes!(dataset, scope, type) do
    {:ok, envs} =
      Repo.transaction(fn ->
        dataset
        |> Content.Export.export_stream(
          scope ++ [type: type, caller_context: :internal, perspective: :raw]
        )
        |> Enum.to_list()
      end)

    envs
  end

  defp create_or_replace!(env, dataset, scope) do
    assert {:ok, _} = Content.apply_mutations([%{"createOrReplace" => env}], dataset, scope)
  end

  # ── 1. envelope export -> createOrReplace (`bp export`, then a re-import) ──

  describe "envelope export -> createOrReplace into a fresh dataset" do
    test "the field corpus", %{src: src, fields_doc: doc} do
      [env] = export_envelopes!(@ds, src.scope, @type_name)
      dst = tenancy!("rt-copy")
      create_or_replace!(env, "rt-copy", dst.scope)

      got = get!(doc.doc_id, @type_name, "rt-copy", dst.scope)
      assert_none!("export_fields", field_failures(fields_of(doc), fields_of(got)))
    end

    test "the golden-65 paper", %{default: default, paper: paper} do
      env =
        export_envelopes!("production", default.scope, "paper")
        |> Enum.find(&(&1["_id"] == paper.doc_id))

      dst = tenancy!("rt-copy")
      create_or_replace!(env, "rt-copy", dst.scope)

      got = get!(DraftId.draft_id(paper.doc_id), "paper", "rt-copy", dst.scope)
      assert_none!("export_paper", block_failures(blocks_of(paper), blocks_of(got)))
    end
  end

  # ── 1b. workspace bundle export -> import into a new dataset id ──────────

  describe "workspace bundle export -> import into a new dataset" do
    test "the field corpus", %{src: src, fields_doc: doc} do
      {:ok, bundle} = WorkspaceBundle.export(src.ws.id, dataset: @ds)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      {:ok, stats} =
        WorkspaceBundle.import_bundle(bundle,
          into_dataset: [workspace_id: ws_b.id, project_id: proj_b.id, slug: "rt-bundle"]
        )

      got =
        Repo.one!(
          from d in Content.Document,
            where: d.dataset_id == ^stats.remap.dataset_id and d.doc_id == ^doc.doc_id
        )

      assert_none!("bundle_fields", field_failures(fields_of(doc), fields_of(got)))
    end
  end

  # ── 2. query envelope -> createOrReplace in another project (`bp migrate`) ──

  defp query_envelopes!(conn, tenancy, dataset, type) do
    raw = "rt-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(raw, "rt", dataset, ["read", "write", "admin"], tenancy.ws.id)

    body =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> get(
        "/w/#{tenancy.ws.slug}/p/#{tenancy.proj.slug}/v1/data/query/#{dataset}/#{type}?perspective=raw&limit=1000"
      )
      |> json_response(200)

    body["result"]["documents"] || body["documents"] || body["result"]
  end

  describe "query envelope -> createOrReplace in another project (bp migrate)" do
    test "the field corpus", %{conn: conn, src: src, fields_doc: doc} do
      [env] = query_envelopes!(conn, src, @ds, @type_name)
      dst = tenancy!(@ds)
      create_or_replace!(env, @ds, dst.scope)

      got = get!(doc.doc_id, @type_name, @ds, dst.scope)
      assert_none!("migrate_fields", field_failures(fields_of(doc), fields_of(got)))
    end

    test "the golden-65 paper", %{conn: conn, default: default, paper: paper} do
      env =
        conn
        |> query_envelopes!(default, "production", "paper")
        |> Enum.find(&(&1["_id"] == paper.doc_id))

      assert env, "the query did not return the paper"
      dst = tenancy!("production")
      create_or_replace!(env, "production", dst.scope)

      got = get!(DraftId.draft_id(paper.doc_id), "paper", "production", dst.scope)
      assert_none!("migrate_paper", block_failures(blocks_of(paper), blocks_of(got)))
    end
  end

  # ── 3. sync: mutation event -> SSE -> Applier into another workspace ──────

  defp sync_into!(doc, dataset) do
    row =
      Repo.one!(
        from e in MutationEvent,
          where: e.doc_id == ^doc.doc_id and e.dataset == ^dataset,
          order_by: [desc: e.id],
          limit: 1
      )

    {[event], ""} = SSE.parse_frames(BarkparkWeb.ListenController.format_event(row, dataset))
    dst = tenancy!(dataset)

    ctx = %{
      source: "rt-#{System.unique_integer([:positive])}",
      dataset: dataset,
      scope: dst.scope
    }

    assert {:ok, :applied} = Applier.apply_event(event, ctx)
    dst
  end

  describe "sync: mutation event -> Applier into another workspace" do
    test "the field corpus", %{fields_doc: doc} do
      dst = sync_into!(doc, @ds)
      got = get!(DraftId.draft_id(doc.doc_id), @type_name, @ds, dst.scope)
      assert_none!("sync_fields", field_failures(fields_of(doc), fields_of(got)))
    end

    # The Bulldocs ingest / block-op doors write NO `mutation_events` row (only a
    # revision + a PubSub frame), so a paper written there never reaches the
    # listen stream sync pulls from — an owner decision filed separately, not a
    # cell this file can turn green. What IS pinned: a paper written through the
    # generic door (which does emit) crosses the Applier with every block intact.
    test "the golden-65 paper (through the generic write door)", %{
      default: default,
      paper: paper
    } do
      env =
        export_envelopes!("production", default.scope, "paper")
        |> Enum.find(&(&1["_id"] == paper.doc_id))

      create_or_replace!(env, "production", default.scope)
      emitted = get!(DraftId.draft_id(paper.doc_id), "paper", "production", default.scope)
      dst = sync_into!(emitted, "production")

      got =
        case Content.get_document(paper.doc_id, "paper", "production", dst.scope) do
          {:ok, d} -> d
          _ -> get!(DraftId.draft_id(paper.doc_id), "paper", "production", dst.scope)
        end

      assert_none!("sync_paper", block_failures(blocks_of(paper), blocks_of(got)))
    end
  end

  # ── 4. BPML pull -> push of an unedited paper ─────────────────────────────

  # One paper PER block type (behind an anchor paragraph, so no single-block
  # paper is hollow): a block outside the BPML kernel vocabulary is REFUSED at
  # pull (422 `bpml_unprintable`) — an honest refusal, not a cell failure — and
  # every printable block must come back with ZERO derived ops, and the push of
  # the unedited pull must apply nothing.
  describe "BPML pull -> push with no edits" do
    test "every printable block type derives zero ops; the push applies nothing", %{conn: conn} do
      results =
        for block <- golden_blocks() do
          slug = "rt-bpml-#{System.unique_integer([:positive])}"

          anchor = %{
            "id" => "anchor",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Anchor."}]
          }

          {:ok, _} =
            Content.upsert_paper(
              Barkpark.LabelFixtures.paper_attrs(%{
                "slug" => slug,
                "title" => "BPML " <> block["type"],
                "blocks" => [anchor, block]
              })
            )

          {block["type"], bpml_round_trip(conn, slug)}
        end

      Process.put(:rt_bpml_unprintable, for({t, :unprintable} <- results, do: t))

      fails = for {type, {:fail, want, got}} <- results, do: {type, want, got}
      assert_none!("bpml_round_trip", fails)
    end
  end

  describe "BPML print -> parse keeps what an EDITED push writes back" do
    # Zero ops on an unedited push is the Diff's job; this is the grammar's:
    # once an author edits one of these blocks, the replace-block carries the
    # PARSED block, so every stored key must survive print -> parse.
    test "lineage unit/value/sourceDefault, stats source/sourceDefault, expandable open" do
      blocks = [
        %{
          "id" => "l1",
          "type" => "lineage",
          "sourceDefault" => "paper:x",
          "nodes" => [
            %{"title" => "A", "overline" => "2025", "unit" => "commits", "value" => "335"}
          ]
        },
        %{
          "id" => "s1",
          "type" => "stats",
          "sourceDefault" => "paper:x",
          "items" => [%{"label" => "L", "value" => "3", "source" => "task:t"}]
        },
        %{
          "id" => "g1",
          "type" => "stat-grid",
          "sourceDefault" => "paper:x",
          "items" => [%{"label" => "L", "value" => "3", "source" => "task:t"}]
        },
        %{
          "id" => "e1",
          "type" => "expandable",
          "summary" => "More",
          "open" => true,
          "blocks" => [
            %{
              "id" => "e1-0",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "x"}]
            }
          ]
        }
      ]

      assert {:ok, parsed} = Bpml.parse_blocks(Bpml.print_blocks(blocks))
      assert parsed == blocks
    end
  end

  defp bpml_round_trip(conn, slug) do
    stored = blocks_of(Content.get_paper(slug))
    pulled = get(conn, "/papers/#{slug}/source", %{"format" => "bpml"})

    case pulled.status do
      422 ->
        :unprintable

      200 ->
        bpml = response(pulled, 200)
        [rev] = get_resp_header(pulled, "x-paper-rev")
        {:ok, parsed} = Bpml.parse_paper(bpml)
        {:ok, _minted, ops} = Bpml.Diff.derive(stored, parsed["blocks"])

        pushed =
          scoped_conn()
          |> put_req_header("authorization", "Bearer barkpark-test-ingest-token")
          |> put_req_header("content-type", "application/json")
          |> post("/v1/plugins/bulldocs/papers/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})

        push_body = Jason.decode!(pushed.resp_body)

        cond do
          ops != [] ->
            {:fail, stored, {:derived_ops, ops}}

          pushed.status != 200 or push_body["unchanged"] != true ->
            {:fail, stored, {:push, pushed.status, push_body}}

          true ->
            :ok
        end
    end
  end

  # ── 6. revision restore of the first revision ─────────────────────────────

  describe "revision restore" do
    # The revision restored is the one captured for the CURRENT stored state
    # (the newest), and the restored document must equal it — cells and, on a
    # block-bearing doc, the block list.
    test "the field corpus: an edit, then restoring the prior revision gives it back", %{
      src: src,
      fields_doc: doc
    } do
      [first | _] = Content.list_revisions(doc.doc_id, @type_name, @ds, src.scope)
      assert first.content["probe"] == "p"

      {:ok, _} =
        Content.apply_mutations(
          [%{"patch" => %{"id" => doc.doc_id, "type" => @type_name, "set" => %{"probe" => "q"}}}],
          @ds,
          src.scope
        )

      {:ok, restored} = Content.restore_revision(first.id, @type_name, @ds, src.scope)
      assert restored.content["probe"] == "p"
      assert_none!("restore_fields", field_failures(fields_of(doc), fields_of(restored)))
    end

    test "the golden-65 paper", %{default: default, paper: paper} do
      [first | _] =
        Content.list_revisions(paper.doc_id, "paper", "production", default.scope)
        |> Enum.reverse()

      {:ok, restored} = Content.restore_revision(first.id, "paper", "production", default.scope)
      assert_none!("restore_paper", block_failures(blocks_of(paper), blocks_of(restored)))
    end
  end

  # ── 7. duplicate document ─────────────────────────────────────────────────

  describe "duplicate document (clone)" do
    test "the field corpus", %{src: src, fields_doc: doc} do
      {:ok, copy} = Content.clone_document(doc, @type_name, @ds, src.scope)
      refute copy.doc_id == doc.doc_id

      # The one intended change (task-970a40d1a252e649): the block bound to
      # the title field carries the copy's title, or the copy's next block
      # write would project the source title back. Every other cell survives.
      expected =
        case fields_of(doc) do
          %{"blocks" => blocks} = fields when is_list(blocks) ->
            Map.put(
              fields,
              "blocks",
              Enum.map(blocks, fn
                %{"fieldName" => "title"} = b -> Map.put(b, "value", copy.title)
                b -> b
              end)
            )

          fields ->
            fields
        end

      if is_list(fields_of(doc)["blocks"]) do
        assert %{"value" => "Round trip (copy)"} =
                 Enum.find(fields_of(copy)["blocks"], &(&1["fieldName"] == "title"))
      end

      assert_none!("clone_fields", field_failures(expected, fields_of(copy)))
    end

    test "the golden-65 paper", %{default: default, paper: paper} do
      {:ok, copy} = Content.clone_document(paper, "paper", "production", default.scope)
      refute copy.doc_id == paper.doc_id
      assert_none!("clone_paper", block_failures(blocks_of(paper), blocks_of(copy)))
    end
  end
end
