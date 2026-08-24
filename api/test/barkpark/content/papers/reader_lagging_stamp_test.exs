defmodule Barkpark.Content.Papers.ReaderLaggingStampTest do
  @moduledoc """
  A LAGGING render stamp classifies stale, not divergent.

  `Papers.cache_provenance/4` used to fail closed on any stamp it could not
  read as a non-empty binary: the `_ -> :divergent` catch-all sent the
  renderer's own honest pre-digest integer stamp (`@body_html_render_version`
  was 1..3 before commit f2404bcc70 made it a sha256 hex) and absent stamps
  straight to `:ambiguous_source` — HTTP 422 for every reader.

  Measured on guerrilla 2026-08-17 (recipe:
  `tooling/grip/ledger/pe-w2-guerrilla-live-writes-2026-08-17.md`): 119
  published papers carry the integer stamp 3 and 59 of them had been answering
  422 to every reader for ~4 weeks. The other 60 served only through the
  `rendered == html` byte-equality short-circuit, so any renderer change would
  have taken them dark as well; 42 null-stamped papers with HTML carried the
  same hazard.

  THE RULE PINNED HERE: only a stamp that IS the current renderer's digest
  claims "this renderer emitted these bytes from these blocks", so only that
  stamp can be contradicted by a byte mismatch. Divergence keeps the 422.
  Everything else — old digest, integer, empty string, nil, absent — is a
  lagging stamp: blocks are canonical, so re-render, serve, restamp.

  RED-BEFORE PROOF (recorded here because the merge carries this file):
  reverting the guard to its previous shape —

      case Map.get(content, "body_html_sv") do
        sv when is_binary(sv) and sv != "" ->
          if sv == Render.body_html_render_version(), do: :divergent, else: {:stale, rendered}
        _ -> :divergent
      end

  — reds this file 6 of 8 tests (`8 tests, 6 failures`), five of them on the
  same shape:

      match (=) failed
      code:  assert {:blocks, ^blocks} = Papers.reader_source(paper, @dataset, [])
      right: {:error, :ambiguous_source}

  and the sixth on `assert diverged == [Render.body_html_render_version()]` —
  pre-fix every stamp state fails closed, so `diverged` is all six of them.

  Exactly two stay green in both directions, and that is the point: the old-hex
  arm (already stale pre-fix, untouched by this slice) and the divergence test
  (`a current-digest stamp over HTML the blocks do not account for still
  422s`) — so the fix NARROWED the 422 rather than removing it.

  METHOD (charter D26): every assertion is on STATE — a return value or a
  reloaded row. A republish-based probe can never prove a cache path, because
  publish regenerates the cache and silently overwrites the fixture.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Labels, Papers}
  alias Barkpark.PortableDoc.Render
  alias Barkpark.Repo

  @dataset "production"

  # The renderer's own honest stamp before the digest existed: an INTEGER, and
  # the exact value 119 live papers carry.
  @legacy_integer_stamp 3

  defp blocks do
    [
      %{"id" => "p1", "type" => "paragraph", "text" => "Prose that must reach a reader."},
      %{"id" => "h1", "type" => "heading", "level" => 2, "text" => "A section"}
    ]
  end

  # A FAITHFUL emit of exactly these blocks by a renderer that is no longer
  # ours: a theme slot override moves every colour the walker emits while adding
  # and dropping nothing. That is the drift population — same blocks in,
  # different bytes out. The refute is load-bearing: a fixture that failed to
  # move the bytes would land on the `rendered == html` short-circuit and every
  # test below would pass without ever reaching the classifier.
  @alt_theme %{theme: %{text: "#ff0000", heading: "#ff0000"}}

  defp older_renderer_emit(blocks, opts \\ %{}) do
    html = Render.render_blocks(blocks, Map.merge(opts, @alt_theme))

    refute html == Render.render_blocks(blocks, opts),
           "the alternate theme must move the bytes for this to be a drift fixture"

    html
  end

  defp bare_paper(content) do
    %Document{
      doc_id: "lag-#{System.unique_integer([:positive])}",
      type: "paper",
      content: content
    }
  end

  defp drifted(stamp_entries) do
    blocks = blocks()

    content =
      Enum.into(stamp_entries, %{
        "blocks" => blocks,
        "body_html" => older_renderer_emit(blocks)
      })

    {blocks, bare_paper(content)}
  end

  describe "the integer stamp — the 59 dark papers" do
    test "an integer-3 stamp over drifted HTML serves blocks instead of 422ing" do
      {blocks, paper} = drifted(%{"body_html_sv" => @legacy_integer_stamp})

      source = Papers.reader_source(paper, @dataset, [])

      assert match?({:blocks, ^blocks}, source),
             "the renderer's own pre-digest integer stamp is lagging, not divergent; got: #{inspect(source)}"
    end

    test "the integer stamp is REPLACED by the current digest on read — proven from the reloaded row" do
      {ws, project} = ensure_default_scope!()
      blocks = blocks()
      stale = older_renderer_emit(blocks)

      {:ok, seed} =
        Content.create_document(
          "paper",
          %{"doc_id" => "lag-restamp-#{System.unique_integer([:positive])}", "title" => "P"},
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
            "body_html_sv" => @legacy_integer_stamp
          }
        })
        |> Repo.update()

      assert {:blocks, ^blocks} = Papers.reader_source(stored, @dataset, [])

      reloaded = Repo.get!(Document, stored.id)

      expected =
        Render.render_blocks(
          blocks,
          Labels.paper_render_opts(@dataset, nil, workspace_id: ws.id, project_id: project.id)
        )

      assert reloaded.content["body_html"] == expected
      refute reloaded.content["body_html"] == stale

      assert reloaded.content["body_html_sv"] == Render.body_html_render_version(),
             "the repair is self-healing: the next read must take the :coherent path"

      # The source of truth is untouched. A cache refresh that moved the blocks
      # would be the content loss this classification exists to avoid.
      assert reloaded.content["blocks"] == blocks
    end
  end

  describe "absent and empty stamps — the 42 null-stamped papers" do
    test "no body_html_sv key at all + drift serves blocks" do
      {blocks, paper} = drifted(%{})
      assert {:blocks, ^blocks} = Papers.reader_source(paper, @dataset, [])
    end

    test "an explicit nil stamp + drift serves blocks" do
      {blocks, paper} = drifted(%{"body_html_sv" => nil})
      assert {:blocks, ^blocks} = Papers.reader_source(paper, @dataset, [])
    end

    test "an empty-string stamp + drift serves blocks" do
      {blocks, paper} = drifted(%{"body_html_sv" => ""})
      assert {:blocks, ^blocks} = Papers.reader_source(paper, @dataset, [])
    end

    test "an old hex digest + drift still serves blocks (unchanged by this slice)" do
      {blocks, paper} = drifted(%{"body_html_sv" => String.duplicate("a", 64)})
      assert {:blocks, ^blocks} = Papers.reader_source(paper, @dataset, [])
    end
  end

  describe "divergence — the 422 narrows, it does not disappear" do
    test "a current-digest stamp over HTML the blocks do not account for still 422s" do
      blocks = blocks()

      paper =
        bare_paper(%{
          "blocks" => blocks,
          "body_html" => Render.render_blocks(blocks) <> "<p>Prose that exists in no block.</p>",
          "body_html_sv" => Render.body_html_render_version()
        })

      source = Papers.reader_source(paper, @dataset, [])

      assert match?({:error, :ambiguous_source}, source),
             "a stamp that claims THIS renderer, contradicted by the bytes, must fail closed; got: #{inspect(source)}"
    end

    test "the current digest is the ONLY stamp value that can 422" do
      blocks = blocks()
      html = Render.render_blocks(blocks) <> "<p>Prose that exists in no block.</p>"

      verdicts =
        for stamp <- [
              :absent,
              nil,
              "",
              @legacy_integer_stamp,
              String.duplicate("a", 64),
              Render.body_html_render_version()
            ] do
          content = %{"blocks" => blocks, "body_html" => html}

          content =
            if stamp == :absent, do: content, else: Map.put(content, "body_html_sv", stamp)

          {stamp, Papers.reader_source(bare_paper(content), @dataset, [])}
        end

      diverged = for {stamp, {:error, :ambiguous_source}} <- verdicts, do: stamp

      assert diverged == [Render.body_html_render_version()],
             "exactly one stamp state may fail closed, got: #{inspect(diverged)}"
    end
  end
end
