defmodule Barkpark.PortableDoc.Render.TableTypedColsTest do
  # Pure, in-process render — no DB, no Phoenix boot.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  # ── the table `cols` contract on :article ───────────────────────────────────
  #
  # A table block may carry an optional `cols` spec — an index-aligned array of
  # {type} maps tagging each column text | num | delta | spark. The contract is
  # NOT invented here: internal/pdrender/richblocks.go (tableRenderer) already
  # renders it in the TUI. This suite pins the WEB projection of the same value
  # and holds it to the Go precedence:
  #
  #   num    right-aligns, body UNCHANGED (alignment is the only difference)
  #   delta  direction glyph FIRST (▲ / ▼ / -) then the magnitude, right-aligned
  #   spark  the series becomes the ONE sparkline primitive (DataViz.spark_svg/2)
  #   text   / unknown / out-of-range ⇒ the legacy body
  #   cols ABSENT ⇒ byte-identical to a table with no spec (the golden below)
  #
  # The glyphs and the right-aligned type set are read from ONE shared fixture,
  # `test/support/fixtures/table-col-types.json`, so the constant lives in a file
  # rather than in this suite's own source. Honest scope: the Go suite does NOT
  # read that fixture yet (richblocks.go still hardcodes the literals) — the file
  # names both readers so the drift is visible.

  @fixture Path.expand("../../../support/fixtures/table-col-types.json", __DIR__)
  @external_resource @fixture

  @golden_path Path.expand("table_untyped_golden.txt", __DIR__)
  @external_resource @golden_path

  defp contract, do: @fixture |> File.read!() |> Jason.decode!()

  defp article(block), do: Render.render_block(block, %{style: :article, doctype: false})
  defp email(block), do: Render.render_block(block, %{style: :email, doctype: false})

  defp cols(types), do: Enum.map(types, &%{"type" => &1})

  describe "num columns" do
    test "a num column right-aligns the body cell AND its header, body text unchanged" do
      html =
        article(%{
          "type" => "table",
          "head" => ["Label", "Count"],
          "cols" => cols(["text", "num"]),
          "rows" => [["Errors", "1204"]]
        })

      # the num column (index 1) right-aligns; the text column (index 0) does not
      assert html =~ ~s(<th class="bp-table__th">)
      assert html =~ ~s(<th class="bp-table__th bp-table__th--num">)
      assert html =~ ~s(<td class="bp-table__td"><span>Errors</span></td>)
      assert html =~ ~s(<td class="bp-table__td bp-table__td--num"><span>1204</span></td>)

      # "num right-aligns via style only": the cell BODY is the legacy body.
      refute html =~ "▲"
      refute html =~ "<svg"
    end

    test "the right-aligned type set matches the shared fixture" do
      assert contract()["right_aligned"] == ["num", "delta"]

      for type <- contract()["right_aligned"] do
        html =
          article(%{"type" => "table", "cols" => cols([type]), "rows" => [["1"]]})

        assert html =~ ~s(class="bp-table__td bp-table__td--num"),
               "#{type} column must right-align"
      end
    end
  end

  describe "delta columns" do
    test "the sign becomes a leading glyph and the magnitude loses its sign" do
      glyphs = contract()["delta_glyphs"]

      html =
        article(%{
          "type" => "table",
          "cols" => cols(["text", "delta"]),
          "rows" => [["up", 4.2], ["down", -4.2], ["flat", 0]]
        })

      assert html =~
               ~s(<td class="bp-table__td bp-table__td--num"><span>#{glyphs["up"]} 4.2</span></td>)

      assert html =~
               ~s(<td class="bp-table__td bp-table__td--num"><span>#{glyphs["down"]} 4.2</span></td>)

      assert html =~
               ~s(<td class="bp-table__td bp-table__td--num"><span>#{glyphs["flat"]} 0</span></td>)

      # the glyph carries the direction with ZERO colour — never colour-only
      refute html =~ "color:"
    end

    test "a delta cell that does not coerce to a number keeps the legacy body" do
      html =
        article(%{"type" => "table", "cols" => cols(["delta"]), "rows" => [["n/a"]]})

      assert html =~ ~s(<td class="bp-table__td bp-table__td--num"><span>n/a</span></td>)
      refute html =~ "▲"
      refute html =~ "▼"
    end
  end

  describe "spark columns" do
    test "a numeric series renders as an inline sparkline SVG, not literal spans" do
      html =
        article(%{
          "type" => "table",
          "cols" => cols(["text", "spark"]),
          "rows" => [["latency", [1, 2, 3, 4]]]
        })

      assert html =~ ~s(<td class="bp-table__td bp-table__td--spark"><svg class="bp-table__spark")
      assert html =~ ~s(<polyline points="0,24 40,16.7 80,9.3 120,2"/>)

      # the failure this replaces: four numbers dumped as four literal spans
      refute html =~ ~s(<span>1</span>)
      refute html =~ ~s(<span>4</span>)
    end

    test "a spark cell with no coercible numbers falls back to the legacy body" do
      html =
        article(%{"type" => "table", "cols" => cols(["spark"]), "rows" => [["not a series"]]})

      assert html =~
               ~s(<td class="bp-table__td bp-table__td--spark"><span>not a series</span></td>)

      refute html =~ "<svg"
    end

    test "the table sparkline reuses the stat primitive — same geometry, own class" do
      series = [1, 2, 3, 4]

      table =
        article(%{"type" => "table", "cols" => cols(["spark"]), "rows" => [[series]]})

      stat = article(%{"type" => "stat", "value" => "1", "spark" => series})

      [points] = Regex.run(~r|<polyline points="([^"]+)"/>|, table, capture: :all_but_first)
      assert stat =~ ~s(<polyline points="#{points}"/>)
      assert stat =~ ~s(<svg class="bp-stat__spark")
    end
  end

  describe "no `cols` spec ⇒ byte-identical" do
    test "the untyped table corpus renders byte-identical to the pre-change golden" do
      golden = File.read!(@golden_path)

      assert render_untyped_corpus() == golden, """
      An untyped table's render moved. `cols` ABSENT must stay byte-identical to
      the pre-typed-columns engine — the golden was captured from origin/main
      BEFORE this slice. Regenerate only with a justification in review.
      """
    end

    test "a head-only unknown column type degrades to text (no class, no glyph)" do
      typed =
        article(%{
          "type" => "table",
          "cols" => cols(["wat"]),
          "rows" => [["x"]]
        })

      assert typed =~ ~s(<td class="bp-table__td"><span>x</span></td>)
    end

    test "a column index past the end of `cols` stays text" do
      html =
        article(%{"type" => "table", "cols" => cols(["num"]), "rows" => [["1", "2"]]})

      assert html =~ ~s(<td class="bp-table__td bp-table__td--num"><span>1</span></td>)
      assert html =~ ~s(<td class="bp-table__td"><span>2</span></td>)
    end
  end

  describe ":email is untouched by the spec" do
    test "a cols-bearing table renders in :email exactly as the same table without cols" do
      rows = [["up", 4.2], ["series", [1, 2, 3, 4]]]

      typed =
        email(%{
          "type" => "table",
          "cols" => cols(["text", "delta"]),
          "rows" => rows
        })

      untyped = email(%{"type" => "table", "rows" => rows})

      assert typed == untyped
      refute typed =~ "▲"
      refute typed =~ "<svg"
    end
  end

  # The same four untyped table shapes captured on origin/main, in both styles.
  defp render_untyped_corpus do
    blocks = [
      %{
        "type" => "table",
        "head" => ["Metric", "Value"],
        "rows" => [["Uptime", "99.9%"], ["Errors", "3"]]
      },
      %{"type" => "table", "rows" => [["a", "b"], ["c", "d"]]},
      %{
        "type" => "table",
        "columns" => [%{"key" => "k", "label" => "K"}, %{"key" => "v", "label" => "V"}],
        "rows" => [%{"k" => "x", "v" => "1"}]
      },
      %{"type" => "table", "rows" => [%{"header" => true, "cells" => ["H1", "H2"]}, ["r1", "r2"]]}
    ]

    blocks
    |> Enum.with_index()
    |> Enum.map_join("", fn {b, i} ->
      "### block #{i} :article\n" <>
        article(b) <>
        "\n### block #{i} :email\n" <> email(b) <> "\n"
    end)
  end
end
