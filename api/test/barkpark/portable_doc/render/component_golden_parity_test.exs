defmodule Barkpark.PortableDoc.Render.ComponentGoldenParityTest do
  @moduledoc """
  Elixir source-of-truth leg of the cross-surface **paper-component golden parity**
  spine: `Render.Components` (the View emitter) -> one committed structural-projection
  fixture per block type -> {api View tests, internal/pdrender TUI, web reader}.

  A `Components` emitter change or a `design/status-manifest.json` glyph/role edit
  that ships WITHOUT regenerating the fixtures would let the surfaces realize a
  stale projection with every gate otherwise green. This suite reds instead:

    * FRESHNESS — the committed api mirror equals a fresh `build/1`, and the three
      mirrors decode term-identical (no drift between surface copies).
    * REALIZATION — the REAL emitter HTML *realizes* the fixture's `expected`
      structural projection (container role, per-column class/label/count/card,
      per-row glyph-role) — the Elixir half of "each surface realizes the shared
      contract". Loops are fixture-driven, so a regen needs no edits here.

  Regenerate with `mix barkpark.paper_components.gen_golden_parity` whenever this reds.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Components
  alias Barkpark.PortableDoc.Render.StatusVocab
  alias Mix.Tasks.Barkpark.PaperComponents.GenGoldenParity

  @api_dir Path.expand("../../../support/fixtures", __DIR__)
  @web_dir Path.expand("../../../../../web/__tests__/fixtures", __DIR__)
  @go_dir Path.expand("../../../../../internal/pdrender/testdata", __DIR__)

  defp decode!(dir, type),
    do: dir |> Path.join(GenGoldenParity.filename(type)) |> File.read!() |> Jason.decode!()

  defp occurrences(haystack, needle),
    do: haystack |> String.split(needle) |> length() |> Kernel.-(1)

  # ── freshness ────────────────────────────────────────────────────────────────

  for type <- ["task-board", "status-legend"] do
    @type_slug type

    test "#{type}: committed api mirror equals a fresh build/1" do
      assert decode!(@api_dir, @type_slug) == GenGoldenParity.build(@type_slug),
             "#{@type_slug}.golden.json is stale — " <>
               "run `mix barkpark.paper_components.gen_golden_parity` and re-verify all three surfaces."
    end

    test "#{type}: the three mirrors decode term-identical" do
      api = decode!(@api_dir, @type_slug)
      assert api == decode!(@web_dir, @type_slug), "web mirror drifted from api mirror"
      assert api == decode!(@go_dir, @type_slug), "internal/pdrender mirror drifted from api mirror"
    end
  end

  # ── realization: the real emitter HTML realizes the projection ───────────────

  test "task-board: the View emitter realizes the projection (columns · labels · counts · cards · glyph-role)" do
    fx = decode!(@api_dir, "task-board")
    html = Components.task_board_html(fx["input"])
    projection = fx["expected"]

    assert String.starts_with?(html, ~s|<div class="bp-board">|),
           "board container role not realized"

    columns = projection["columns"]
    assert length(columns) >= 3, "projection floor: fewer than 3 columns — regen dropped coverage"

    # Exactly the projection's columns — no smeared/dropped lane (geometry guard).
    assert occurrences(html, ~s|class="bp-board__col |) == length(columns),
           "rendered column count diverged from the projection"

    for col <- columns do
      role = col["role"]
      assert html =~ ~s|bp-board__col--#{role}|, "column #{role} lane missing"
      assert html =~ ~s|<span class="bp-board__label">#{col["label"]}</span>|, "label #{col["label"]} missing"
      assert html =~ ~s|<span class="bp-board__count">#{col["count"]}</span>|, "count for #{role} missing"
      assert html =~ ~s|bp-g--#{col["glyph_role"]}|, "glyph-role #{col["glyph_role"]} missing"

      for card <- col["cards"] do
        assert html =~ ~s|<span class="bp-bcard__t">#{card["title"]}</span>|,
               "card title #{inspect(card["title"])} missing from lane #{role}"
      end
    end
  end

  test "status-legend: the View emitter realizes the projection (6 rungs · per-row glyph-role · spinner)" do
    fx = decode!(@api_dir, "status-legend")
    html = Components.status_legend_html(fx["input"])
    rows = fx["expected"]["rows"]

    assert String.starts_with?(html, ~s|<div class="bp-legend">|),
           "legend container role not realized"

    # One rung per projection row, in the shared manifest order — no more, no less.
    assert occurrences(html, ~s|class="bp-legend__r"|) == length(rows)
    assert length(rows) == length(StatusVocab.roles())

    for row <- rows do
      role = row["role"]
      assert html =~ ~s|bp-g--#{role}|, "glyph-role #{role} missing"

      if row["spinner"] do
        # A spinner role is an empty glyph span the CSS animates — no static char.
        assert html =~ ~s|<span class="bp-g bp-g--#{role}" aria-label="in progress"></span>|,
               "spinner rung #{role} not realized as an animated empty glyph"
      else
        assert html =~ ~s|<span class="bp-g bp-g--#{role}">#{row["glyph"]}</span>|,
               "static glyph #{inspect(row["glyph"])} for #{role} missing"
      end
    end
  end
end
