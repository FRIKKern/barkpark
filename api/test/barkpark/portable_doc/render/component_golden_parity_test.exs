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

  COVERAGE (honest scope — subset-parity, projection ⊆ native): for every
  column/row PRESENT in the projection, all three surfaces agree on label + count
  + ordered card titles + glyph-role (this leg checks the View HTML at exact
  span). COVERED since bug-taskboard-drops-open-tasks: the task-board fixture now
  INCLUDES an `open` row and the View + Go pdrender both grew an `open` column, so
  a populated `open` bucket realizes on every surface (the drop is fixed, not just
  filed). Empty-column policy (web keep-empty vs View/TUI omit-empty) stays a
  SUPERSET difference this ⊆-projection deliberately does not police. NOT COVERED,
  FILED not fixed: status/label PROSE ("in progress" vs
  "progress"); the projection shares role + glyph, not meaning text; owned by
  au-w5-status-prose-parity (which also owns the "board labels are two copies that
  agree, not one manifest source" gap). The harness never implies parity it does
  not hold.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Components
  alias Barkpark.PortableDoc.Render.Compose
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

  for type <- GenGoldenParity.types() do
    @type_slug type

    test "#{type}: committed api mirror equals a fresh build/1" do
      assert decode!(@api_dir, @type_slug) == GenGoldenParity.build(@type_slug),
             "#{@type_slug}.golden.json is stale — " <>
               "run `mix barkpark.paper_components.gen_golden_parity` and re-verify all three surfaces."
    end

    test "#{type}: the three mirrors decode term-identical" do
      api = decode!(@api_dir, @type_slug)
      assert api == decode!(@web_dir, @type_slug), "web mirror drifted from api mirror"

      assert api == decode!(@go_dir, @type_slug),
             "internal/pdrender mirror drifted from api mirror"
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

      assert html =~ ~s|<span class="bp-board__label">#{col["label"]}</span>|,
             "label #{col["label"]} missing"

      assert html =~ ~s|<span class="bp-board__count">#{col["count"]}</span>|,
             "count for #{role} missing"

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

  # ── S2 realization: the View emitter/composer realizes each projection ───────

  # `raw_html/1` renders the container types (columns/terminal) that compose to a
  # `_raw` HTML node rather than a `Components.*` emitter.
  defp raw_html(input), do: Compose.compose_block(input)["html"]

  # Assert the substrings appear in `html` in the given order (an ordered-spine check).
  defp assert_ordered(html, needles) do
    Enum.reduce(needles, 0, fn needle, from ->
      idx = :binary.match(html, needle)

      assert idx != :nomatch and elem(idx, 0) >= from,
             "expected #{inspect(needle)} at or after offset #{from} (ordered-spine)"

      elem(idx, 0)
    end)
  end

  test "notes: the emitter realizes the projection (container · per-row label/lead/text)" do
    fx = decode!(@api_dir, "notes")
    html = Components.notes_html(fx["input"])
    assert String.starts_with?(html, ~s|<div class="bp-notes">|)

    for row <- fx["expected"]["rows"] do
      assert html =~ ~s|<span class="bp-note__k">#{row["label"]}</span>|, "label #{row["label"]}"
      assert html =~ ~s|<b>#{row["lead"]}</b>|, "lead #{row["lead"]}"
      assert html =~ row["text"], "text #{row["text"]}"
    end
  end

  test "note: the emitter realizes the projection (single row · label/lead/text)" do
    fx = decode!(@api_dir, "note")
    html = Components.note_item_html(fx["input"])
    ex = fx["expected"]
    assert String.starts_with?(html, ~s|<div class="bp-note">|)
    assert html =~ ~s|<span class="bp-note__k">#{ex["label"]}</span>|
    assert html =~ ~s|<b>#{ex["lead"]}</b>|
    assert html =~ ex["text"]
  end

  test "cards: the emitter realizes the projection (container · title/text/tone per card)" do
    fx = decode!(@api_dir, "cards")
    html = Components.cards_html(fx["input"])
    assert String.starts_with?(html, ~s|<div class="bp-cards">|)

    for card <- fx["expected"]["cards"] do
      assert html =~ ~s|<div class="bp-card__t">#{card["title"]}</div>|, "title #{card["title"]}"
      assert html =~ ~s|<div class="bp-card__d">#{card["text"]}</div>|, "text #{card["text"]}"

      if card["tone"] != "",
        do: assert(html =~ ~s|bp-card--#{card["tone"]}|, "tone #{card["tone"]}")
    end
  end

  test "card: the emitter realizes the projection (title + flattened body)" do
    fx = decode!(@api_dir, "card")
    html = Components.card_html(fx["input"])
    ex = fx["expected"]
    assert String.starts_with?(html, ~s|<div class="bp-card|)
    assert html =~ ~s|<div class="bp-card__t">#{ex["title"]}</div>|
    assert html =~ ~s|<div class="bp-card__d">#{ex["body"]}</div>|
  end

  test "pipeline: the emitter realizes the projection (container · kind/title/detail per node)" do
    fx = decode!(@api_dir, "pipeline")
    html = Components.pipeline_html(fx["input"])
    assert html =~ ~s|<div class="bp-pipe">|

    for node <- fx["expected"]["nodes"] do
      assert html =~ ~s|<div class="bp-pnode__k">#{node["kind"]}</div>|, "kind #{node["kind"]}"
      assert html =~ ~s|<div class="bp-pnode__t">#{node["title"]}</div>|, "title #{node["title"]}"
      assert html =~ ~s|<div class="bp-pnode__d">#{node["detail"]}</div>|, "detail #{node["detail"]}"
    end
  end

  test "stage: the emitter realizes the projection (one pnode · kind/title/detail)" do
    fx = decode!(@api_dir, "stage")
    html = Components.stage_html(fx["input"])
    ex = fx["expected"]
    assert String.starts_with?(html, ~s|<div class="bp-pnode|)
    assert html =~ ~s|<div class="bp-pnode__k">#{ex["kind"]}</div>|
    assert html =~ ~s|<div class="bp-pnode__t">#{ex["title"]}</div>|
    assert html =~ ~s|<div class="bp-pnode__d">#{ex["detail"]}</div>|
  end

  test "task-detail: the emitter realizes the projection (title · ordered sections · criteria)" do
    fx = decode!(@api_dir, "task-detail")
    html = Components.task_detail_html(fx["input"])
    ex = fx["expected"]

    assert html =~ ~s|<div class="bp-tdetail__title">#{ex["title"]}</div>|

    crit = ex["criteria"]
    assert html =~ ~s|Criteria · #{crit["met"]}/#{crit["total"]}|, "criteria rollup"

    # The projected sections realize as their marker classes, IN the projected order.
    marker = %{
      "meta" => ~s|class="bp-tdetail__meta"|,
      "criteria" => ~s|class="bp-tdetail__crit"|,
      "labels" => ~s|class="bp-tdetail__labels"|
    }

    assert_ordered(html, Enum.map(ex["sections"], &Map.fetch!(marker, &1)))
  end

  test "roadmap: the emitter realizes the projection (scale axis · per-lane title/role/phase)" do
    fx = decode!(@api_dir, "roadmap")
    html = Components.roadmap_html(fx["input"])
    ex = fx["expected"]

    for cell <- ex["scale"], do: assert(html =~ ~s|<span>#{cell}</span>|, "scale #{cell}")

    for lane <- ex["lanes"] do
      assert html =~ ~s|<span class="bp-rm__lbl">#{lane["title"]}</span>|, "lane #{lane["title"]}"
      assert html =~ ~s|bp-rm__bar--#{lane["role"]}|, "role #{lane["role"]}"
      if lane["phase"], do: assert(html =~ ~s|bp-rm__lane--phase|, "phase lane")
    end
  end

  test "columns: the composer realizes the projection (one .bp-cols__c per column · nested children)" do
    fx = decode!(@api_dir, "columns")
    html = raw_html(fx["input"])
    cols = fx["expected"]["columns"]

    assert String.starts_with?(html, ~s|<div class="bp-cols"|)
    assert occurrences(html, ~s|class="bp-cols__c"|) == length(cols),
           "column count diverged from the projection"

    # Each column's child prose survives the nesting (input carries distinct text).
    assert html =~ "Left column body."
    assert html =~ "Right column body."
  end

  test "terminal: the composer realizes the projection (title · live · footer · nested child)" do
    fx = decode!(@api_dir, "terminal")
    html = raw_html(fx["input"])
    ex = fx["expected"]

    assert String.starts_with?(html, ~s|<div class="bp-term">|)
    assert html =~ ~s|<span class="bp-term__title">#{ex["title"]}</span>|
    if ex["live"], do: assert(html =~ ~s|<span class="bp-term__live">live</span>|)
    assert html =~ ~s|<div class="bp-term__foot">#{ex["footer"]}</div>|
    assert html =~ "Inside the frame."
  end
end
