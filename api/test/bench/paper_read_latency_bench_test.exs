defmodule Barkpark.Bench.PaperReadLatencyBenchTest do
  @moduledoc """
  Opt-in measurement for pt-backlog-kill-the-body-html-cache. It is not part
  of the default lane: every test here is skipped unless its input file is
  named in the environment.

  Two checks, each fed REAL papers exported read-only from a live instance
  (never a hand-written fixture):

    * `PAPER_READ_SUBSET` — NDJSON of the HTML-only legacy papers (no blocks),
      one document per line as `bp doc get paper <id> -o json` prints it.
      Optional `PAPER_READ_SUBSET_SERVED` — NDJSON of `{id, kind, html}` from
      the live `/papers/:slug/source` route, compared byte for byte.
    * `PAPER_READ_BENCH` — colon-separated paths to single-paper JSON files
      (blocks papers). Prints median and p95 read latency for the cache read
      and the render-from-blocks read on the same stored row.

  Export (read-only) and run:

      bp doc get paper <id> --perspective published -o json > rep.json
      PAPER_READ_BENCH=/abs/rep.json PAPER_READ_SUBSET=/abs/legacy.ndjson \\
        PAPER_READ_SUBSET_SERVED=/abs/served.ndjson \\
        mix test test/bench/paper_read_latency_bench_test.exs
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo}
  alias Barkpark.Content.Labels
  alias Barkpark.PortableDoc.{HtmlSanitizer, Projection, Render}
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper, as: StudioPaper

  @subset System.get_env("PAPER_READ_SUBSET")
  @served System.get_env("PAPER_READ_SUBSET_SERVED")
  @bench System.get_env("PAPER_READ_BENCH")

  @iterations 200
  @warmup 20

  setup do
    dataset = "read-bench-#{System.unique_integer([:positive])}"
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    Barkpark.LabelFixtures.register_tags!(dataset)
    {:ok, dataset: dataset, ws: ws, proj: proj}
  end

  defp read_json_lines(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp unwrap(%{"result" => %{} = doc}), do: doc
  defp unwrap(doc), do: doc

  # Write the row through the normal upsert (so every other content key is what
  # the write path produces), then plant the exported content keys that matter
  # to the reader exactly as the live row stores them.
  defp store!(export, dataset, ws, proj, attrs) do
    slug = "bench-" <> export["_id"]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(
          Map.merge(
            %{
              "slug" => slug,
              "title" => export["title"] || slug,
              "dataset" => dataset,
              "workspace_id" => ws.id,
              "project_id" => proj.id
            },
            attrs
          )
        )
      )

    paper
  end

  describe "the real HTML-only subset" do
    @describetag skip: if(@subset, do: false, else: "set PAPER_READ_SUBSET to run")

    test "every legacy paper still reads through the new path", ctx do
      exports = @subset |> read_json_lines() |> Enum.map(&unwrap/1)

      served =
        if @served,
          do: @served |> read_json_lines() |> Map.new(&{&1["id"], &1}),
          else: %{}

      assert exports != []

      results =
        for export <- exports do
          body_html = export["body_html"]
          assert is_binary(body_html) and body_html != "", export["_id"]
          assert export["blocks"] in [nil, []], export["_id"]

          paper =
            store!(export, ctx.dataset, ctx.ws, ctx.proj, %{
              "body_html" => "<p>placeholder</p>",
              "style" => export["style"]
            })

          paper =
            paper
            |> Ecto.Changeset.change(content: Map.put(paper.content, "body_html", body_html))
            |> Repo.update!()

          stored = Content.get_paper(paper.doc_id, ctx.dataset, [])

          # The Studio write-capable arm reads body_html only when there is no
          # block list; this row must be on that arm.
          assert Projection.read_blocks(stored.content) == nil, export["_id"]

          assert {:ok, html} = Content.Papers.reader_html(stored, ctx.dataset, [])
          assert html == HtmlSanitizer.sanitize(body_html), export["_id"]
          assert StudioPaper.editor_body_html(stored.content["body_html"]) == html

          case served[export["_id"]] do
            %{"kind" => "html", "html" => live_html} ->
              assert html == live_html, "#{export["_id"]}: differs from the live /source bytes"
              {:ok, :matched_live}

            nil ->
              {:ok, :no_live_copy}
          end
        end

      counts = Enum.frequencies_by(results, &elem(&1, 1))

      IO.puts(
        "\n[real-subset] #{length(exports)} HTML-only papers read through " <>
          "Content.Papers.reader_html/3: #{inspect(counts)}"
      )
    end
  end

  describe "read latency on representative blocks papers" do
    @describetag skip: if(@bench, do: false, else: "set PAPER_READ_BENCH to run")

    test "cache read vs render from blocks", ctx do
      for path <- String.split(@bench, ":", trim: true) do
        export = path |> File.read!() |> Jason.decode!() |> unwrap()
        blocks = export["blocks"]
        assert is_list(blocks) and blocks != [], path

        paper =
          store!(export, ctx.dataset, ctx.ws, ctx.proj, %{
            "blocks" => blocks,
            "style" => export["style"]
          })

        stored = Content.get_paper(paper.doc_id, ctx.dataset, [])
        content = stored.content
        style = content["style"]
        opts = Labels.paper_render_opts(ctx.dataset, style, [])

        arms = [
          {"fetch row (Content.get_paper/3)",
           fn -> Content.get_paper(paper.doc_id, ctx.dataset, []) end},
          {"BEFORE scoped: Map.get body_html", fn -> Map.get(content, "body_html") end},
          {"BEFORE studio write-capable: sanitize(body_html)",
           fn -> StudioPaper.editor_body_html(Map.get(content, "body_html")) end},
          {"AFTER  studio write-capable: read_blocks check",
           fn -> is_list(Projection.read_blocks(content)) end},
          {"Render.render_blocks/2 alone", fn -> Render.render_blocks(blocks, opts) end},
          {"reader_source/3 (BulldocsLive, email, source; unchanged)",
           fn -> Content.Papers.reader_source(stored, ctx.dataset, []) end},
          {"AFTER  scoped / share / studio-denied: reader_html/3",
           fn -> Content.Papers.reader_html(stored, ctx.dataset, []) end}
        ]

        IO.puts(
          "\n[bench] #{export["_id"]}: #{length(blocks)} blocks, " <>
            "#{byte_size(content["body_html"] || "")} bytes body_html, style=#{inspect(style)}, " <>
            "#{@iterations} iterations after #{@warmup} warm-up"
        )

        for {label, fun} <- arms do
          for _ <- 1..@warmup, do: fun.()

          times =
            for _ <- 1..@iterations do
              {us, _} = :timer.tc(fun)
              us
            end
            |> Enum.sort()

          median = Enum.at(times, div(@iterations, 2))
          p95 = Enum.at(times, trunc(@iterations * 0.95) - 1)

          IO.puts(
            "  " <>
              String.pad_trailing(label, 58) <>
              " median #{pad(median)} us   p95 #{pad(p95)} us"
          )
        end

        # The render arm is honest only if it produces the bytes the cache holds.
        assert {:ok, html} = Content.Papers.reader_html(stored, ctx.dataset, [])
        assert html == content["body_html"]
      end
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(7)
end
