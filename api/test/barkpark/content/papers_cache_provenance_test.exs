defmodule Barkpark.Content.PapersCacheProvenanceTest do
  @moduledoc """
  `reader_source/3` classifies a body_html byte mismatch instead of calling all
  of them ambiguous.

  The byte-compare in `conflicting_html_cache?` was doing double duty: it could
  not tell DRIFT (the cache was rendered from THESE blocks by an older
  renderer — harmless, blocks are canonical) from DIVERGENCE (the stored HTML
  carries content the blocks do not — genuinely ambiguous). The 422 was built
  for divergence and fired on drift. These tests pin all four populations.

  METHOD (charter D26): a republish-based mutation can never prove a cache
  path — publish regenerates the cache and silently overwrites the probe, so
  the page stays 200 and looks like a refutation. Every assertion below is on
  STATE: a return value, or a reloaded row.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Labels, Papers}
  alias Barkpark.PortableDoc.Render
  alias Barkpark.Repo

  @dataset "production"

  defp blocks do
    [
      %{"id" => "p1", "type" => "paragraph", "text" => "Canonical prose."},
      %{"id" => "h1", "type" => "heading", "level" => 2, "text" => "A section"}
    ]
  end

  defp render(blocks, opts \\ %{}), do: Render.render_blocks(blocks, opts)

  # A FAITHFUL emit of exactly these blocks by a renderer that is not ours: a
  # theme slot override moves every colour the walker emits (render.ex :theme)
  # while adding and dropping NOTHING. That is precisely the drift population —
  # same blocks in, different bytes out — and it is why this is not simply a
  # hand-mangled string, which would be indistinguishable from divergence.
  #
  # The refute is not decoration. A fixture that failed to move the bytes would
  # land on the :coherent path and every drift test below would pass without
  # ever exercising the classifier — and it caught exactly that on the first
  # run (`theme: :midnight` leaves paragraph/heading bytes untouched).
  @alt_theme %{theme: %{text: "#ff0000", heading: "#ff0000"}}

  defp older_renderer_emit(blocks, opts \\ %{}) do
    html = render(blocks, Map.merge(opts, @alt_theme))

    refute html == render(blocks, opts),
           "the alternate theme must move the bytes for this to be a drift fixture"

    html
  end

  defp bare_paper(content) do
    %Document{
      doc_id: "prov-#{System.unique_integer([:positive])}",
      type: "paper",
      content: content
    }
  end

  describe "drift" do
    test "a lagging stamp over a faithful older-renderer emit serves blocks, no 422" do
      blocks = blocks()

      paper =
        bare_paper(%{
          "blocks" => blocks,
          "body_html" => older_renderer_emit(blocks),
          # A real digest shape that is not the current one.
          "body_html_sv" => String.duplicate("a", 64)
        })

      assert {:blocks, ^blocks} = Papers.reader_source(paper, @dataset, [])
    end

    test "the refreshed cache is PERSISTED — proven by reloading the row" do
      {ws, project} = ensure_default_scope!()
      blocks = blocks()
      stale = older_renderer_emit(blocks)

      {:ok, seed} =
        Content.create_document(
          "paper",
          %{"doc_id" => "prov-persist-#{System.unique_integer([:positive])}", "title" => "P"},
          @dataset,
          workspace_id: ws.id,
          project_id: project.id
        )

      {:ok, stored} =
        seed
        |> Document.changeset(%{
          "content" => %{
            "blocks" => blocks,
            "body_html" => stale,
            "body_html_sv" => String.duplicate("a", 64)
          }
        })
        |> Repo.update()

      assert {:blocks, ^blocks} = Papers.reader_source(stored, @dataset, [])

      reloaded = Repo.get!(Document, stored.id)

      expected =
        render(
          blocks,
          Labels.paper_render_opts(@dataset, nil, workspace_id: ws.id, project_id: project.id)
        )

      assert reloaded.content["body_html"] == expected,
             "the reader must rewrite the derived cache it just proved stale"

      refute reloaded.content["body_html"] == stale

      assert reloaded.content["body_html_sv"] == Render.body_html_render_version(),
             "the refreshed cache must carry the stamp of the renderer that produced it"

      # The blocks are untouched. A cache refresh must never move the source of
      # truth — that would be the content-loss failure this whole slice exists
      # to avoid.
      assert reloaded.content["blocks"] == blocks
    end
  end

  describe "divergence — the original safety property, preserved exactly" do
    test "current stamp + HTML carrying content the blocks lack still 422s" do
      blocks = blocks()

      paper =
        bare_paper(%{
          "blocks" => blocks,
          "body_html" => render(blocks) <> "<p>Prose that exists in no block.</p>",
          "body_html_sv" => Render.body_html_render_version()
        })

      assert {:error, :ambiguous_source} = Papers.reader_source(paper, @dataset, [])
    end
  end

  describe "legacy" do
    # Superseded by pe-w2-reader-stamp-guard: an absent stamp claims nothing
    # about the CURRENT renderer, so a byte mismatch cannot contradict it. The
    # old fail-closed reading took 59 live papers dark for ~4 weeks. Full
    # classification pinned in
    # test/barkpark/content/papers/reader_lagging_stamp_test.exs.
    test "a paper with both fields and no stamp is lagging, not divergent" do
      blocks = blocks()

      paper =
        bare_paper(%{
          "blocks" => blocks,
          "body_html" => older_renderer_emit(blocks)
        })

      assert {:blocks, ^blocks} = Papers.reader_source(paper, @dataset, [])
    end
  end

  describe "external referent drift (charter D9)" do
    setup do
      {ws, project} = ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]
      {:ok, ws: ws, project: project, scope: scope}
    end

    test "renaming a REFERENCED document does not 422 an untouched paper, and the reader emits the CURRENT title",
         %{scope: scope} do
      referent_id = "prov-referent-#{System.unique_integer([:positive])}"

      {:ok, _referent} =
        Content.create_document(
          "post",
          %{"doc_id" => referent_id, "title" => "Original Title"},
          @dataset,
          scope
        )

      blocks = [
        %{
          "id" => "ref1",
          "type" => "field-reference",
          "name" => "related",
          "refType" => "post",
          "value" => referent_id
        }
      ]

      opts = Labels.paper_render_opts(@dataset, nil, scope)
      body_html = render(blocks, opts)
      assert body_html =~ "Original Title", "fixture must bake the live-resolved title in"

      paper =
        bare_paper(%{
          "blocks" => blocks,
          "body_html" => body_html,
          "body_html_sv" => Render.body_html_render_version()
        })

      # Baseline: byte-exact cache, current stamp — coherent.
      assert {:blocks, ^blocks} = Papers.reader_source(paper, @dataset, [])

      # Rename ONLY the referent. The paper's blocks, body_html, stamp and the
      # renderer are all untouched, yet a fresh render now differs.
      {:ok, _} =
        Content.upsert_document(
          "post",
          %{"doc_id" => referent_id, "title" => "Renamed Title"},
          @dataset,
          scope
        )

      refute render(blocks, opts) == body_html,
             "the rename must move the render, or this test proves nothing"

      source = Papers.reader_source(paper, @dataset, [])

      assert match?({:blocks, ^blocks}, source),
             "external referent drift is not divergence and must not 422; got: #{inspect(source)}"

      # NOT a frozen label (charter D10): the served blocks re-resolve live, so
      # the consumer emits the CURRENT title. A frozen label would make the
      # stamp match while serving the stale title — a silent wrong value, which
      # is strictly worse than the loud false 422 it replaces.
      {:blocks, served} = Papers.reader_source(paper, @dataset, [])
      emitted = render(served, opts)
      assert emitted =~ "Renamed Title"
      refute emitted =~ "Original Title"
    end

    test "a codelist relabel behaves the same", %{scope: scope} do
      blocks = [
        %{
          "id" => "cl1",
          "type" => "codelist",
          "name" => "status",
          "codelistId" => "prov-status",
          "value" => "draft"
        }
      ]

      opts = Labels.paper_render_opts(@dataset, nil, scope)

      # The cache as it stood when the code "draft" still carried the label
      # "Provisional" — a faithful emit of THESE blocks under the label that was
      # live at write time. Relabelling the code is the codelist twin of
      # renaming a referent: same blocks, same renderer, different bytes.
      stale_label_opts = Map.put(opts, :codelist_resolver, fn _p, _id, _code -> "Provisional" end)
      body_html = render(blocks, stale_label_opts)

      assert body_html =~ "Provisional"

      refute body_html == render(blocks, opts),
             "the relabel must move the bytes for this to be a referent-drift fixture"

      paper =
        bare_paper(%{
          "blocks" => blocks,
          "body_html" => body_html,
          # CURRENT stamp — so this lands in the divergence branch and hard-422s
          # unless the resolver exemption catches it first.
          "body_html_sv" => Render.body_html_render_version()
        })

      assert {:blocks, ^blocks} = Papers.reader_source(paper, @dataset, [])
    end

    test "the exemption is SHAPE-scoped: an empty-value reference does not exempt a paper" do
      # A field-reference with no value invokes no resolver (Render's guard
      # requires a non-empty binary), so nothing external can explain a byte
      # gap and the safety property must still apply.
      blocks = [%{"id" => "ref0", "type" => "field-reference", "name" => "rel", "value" => ""}]

      paper =
        bare_paper(%{
          "blocks" => blocks,
          "body_html" => render(blocks) <> "<p>Unaccounted prose.</p>",
          "body_html_sv" => Render.body_html_render_version()
        })

      assert {:error, :ambiguous_source} = Papers.reader_source(paper, @dataset, [])
    end
  end

  describe "proven able to fail" do
    test "provenance is CONSULTED: the four sv states no longer collapse to one verdict" do
      blocks = blocks()
      html = older_renderer_emit(blocks)

      base = %{"blocks" => blocks, "body_html" => html}

      verdicts =
        for sv <- [:absent, nil, "old", :current] do
          content =
            case sv do
              :absent -> base
              :current -> Map.put(base, "body_html_sv", Render.body_html_render_version())
              other -> Map.put(base, "body_html_sv", other)
            end

          {sv, Papers.reader_source(bare_paper(content), @dataset, [])}
        end

      distinct = verdicts |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

      # THIS is the assertion that fails before the fix: pre-fix, the byte
      # mismatch alone decided, so all four sv states returned the identical
      # {:error, :ambiguous_source} and `distinct` had length 1.
      assert length(distinct) > 1,
             "provenance is not consulted — every sv state produced #{inspect(hd(distinct))}"

      # And the specific verdicts, so a future change cannot satisfy the above
      # by scrambling them. Since pe-w2-reader-stamp-guard only the CURRENT
      # digest can fail closed: absent and nil stamps claim nothing about this
      # renderer, so they are lagging (serve blocks, restamp).
      assert {:absent, {:blocks, ^blocks}} = Enum.at(verdicts, 0)
      assert {nil, {:blocks, ^blocks}} = Enum.at(verdicts, 1)
      assert {"old", {:blocks, ^blocks}} = Enum.at(verdicts, 2)
      assert {:current, {:error, :ambiguous_source}} = Enum.at(verdicts, 3)
    end
  end
end
