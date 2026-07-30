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
  SUPERSET difference this ⊆-projection deliberately does not police. COVERED since
  au-w5-status-prose-parity: the status LABEL prose is ONE manifest source, the
  legend projection asserts the canonical label TEXT ("in progress"/"cancelled")
  and this leg RENDER-asserts it; board LABELS are the fold (derived
  `board_label/1`, not two hardcoded copies). Legend MEANING stays an Elixir/TUI
  superset (web renders name-only). The harness never implies parity it does not
  hold.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.CardsEmail
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

      # GRADUATED (au-w5-status-prose-parity): the canonical LABEL text is realized,
      # not just the role+glyph — a wrong label render reds this leg.
      assert html =~ ~s|<span class="bp-legend__n">#{row["label"]}</span>|,
             "legend label #{inspect(row["label"])} for #{role} missing"

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
  # `_raw` HTML node rather than a `Components.*` emitter. Pinned to `:article`:
  # these tests assert the CLASSED projection, and since the fleet email variants
  # (gp-w4c) the containers are style-branched — `compose_block/1`'s `:email`
  # default would take the inline-styled table variant instead.
  defp raw_html(input), do: Compose.compose_block(input, :article)["html"]

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

  # The authored render marker for one card slot, DERIVED from the fixture input
  # (never hand-typed): the media slot's image alt attr, the title heading text, the
  # body paragraph's plain text, the action label. Used to assert each PROJECTED
  # slot realizes IN the projection's slot ORDER.
  defp card_slot_marker(input, "media"),
    do: ~s|alt="#{input["slots"]["media"] |> List.first() |> Map.get("alt")}"|

  defp card_slot_marker(input, "title"),
    do: input["slots"]["title"] |> List.first() |> Map.get("text")

  defp card_slot_marker(input, "body"),
    do:
      input["slots"]["body"]
      |> List.first()
      |> Map.get("content")
      |> List.first()
      |> Map.get("value")

  defp card_slot_marker(input, "action"),
    do: input["slots"]["action"] |> List.first() |> Map.get("label")

  test "card: the emitter realizes the MODEL-B projection (ordered slots · tone · image fast-path · action)" do
    fx = decode!(@api_dir, "card")
    input = fx["input"]
    html = Components.card_html(input)
    ex = fx["expected"]

    assert String.starts_with?(html, ~s|<div class="bp-card|), "card container role not realized"

    # The projection's PRESENT slots realize IN ORDER — a reorder or a dropped slot
    # in `card_html/2` reds the ordered-spine check (the non-vacuous graduation proof).
    assert ex["slots"] == ["media", "title", "body", "action"],
           "projection floor: card must exercise all four model-B slots"

    assert_ordered(html, Enum.map(ex["slots"], &card_slot_marker(input, &1)))

    # tone accent tints the card (info → bp-card--info) — dropping it reds this leg.
    if ex["tone"] != "",
      do: assert(html =~ ~s|bp-card--#{ex["tone"]}|, "tone accent #{ex["tone"]} missing")

    # media fast-path: the image media child renders as a real <img> element.
    if ex["media_fastpath"], do: assert(html =~ "<img", "media image fast-path (<img>) missing")

    # the action slot renders as the button element (its label already ordered above).
    assert html =~ ~s|class="bp-button"|, "action button chrome missing"

    # ── EMAIL realization leg (cd-7-card-surface-parity) ─────────────────────
    # The SAME decoded fixture also drives the inline-styled email twin
    # (`CardsEmail.card_email_html/1`), which recurses the SAME model-B slots
    # through the SHARED `Compose.render_children(:email)` seam. This closes the
    # third parity deliverable: email slot CONTENT now joins the golden gate.
    # Email HTML is inline-styled + classless — assert the DERIVED plain-text
    # slot markers in projection ORDER (NOT the `bp-card__*` View classes, which
    # the email variant strips).
    email = CardsEmail.card_email_html(input)

    assert_ordered(email, Enum.map(ex["slots"], &card_slot_marker(input, &1)))

    # media fast-path: the image media child renders as a real <img> in email too.
    if ex["media_fastpath"],
      do: assert(email =~ "<img", "email media image fast-path (<img>) missing")
  end

  test "pipeline: the emitter realizes the projection (container · kind/title/detail · source_role per node)" do
    fx = decode!(@api_dir, "pipeline")
    html = Components.pipeline_html(fx["input"])
    assert html =~ ~s|<div class="bp-pipe">|

    # the fixture MUST exercise both coercion branches or the source graduation is
    # vacuous — pin that an origin node AND a provenance node are present.
    roles = fx["expected"]["nodes"] |> Enum.map(& &1["source_role"])
    assert "origin" in roles, "fixture lost its source:true (origin) node"
    assert "provenance" in roles, "fixture lost its source:\"text\" (provenance) node"

    for node <- fx["expected"]["nodes"] do
      assert html =~ ~s|<div class="bp-pnode__k">#{node["kind"]}</div>|, "kind #{node["kind"]}"
      assert html =~ ~s|<div class="bp-pnode__t">#{node["title"]}</div>|, "title #{node["title"]}"

      assert html =~ ~s|<div class="bp-pnode__d">#{node["detail"]}</div>|,
             "detail #{node["detail"]}"

      # source_role realizes: origin → the accent-bordered pnode; provenance → the
      # provenance line carrying the text (a render tamper reds this leg).
      case node["source_role"] do
        "origin" ->
          assert html =~ ~s|<div class="bp-pnode bp-pnode--src">|,
                 "origin accent for #{node["title"]}"

        "provenance" ->
          assert html =~ ~s|<div class="bp-pnode__src">#{node["source_text"]}</div>|,
                 "provenance line #{node["source_text"]}"

        _ ->
          :ok
      end
    end
  end

  test "stage: the emitter realizes the projection (one pnode · kind/title/detail · source_role)" do
    fx = decode!(@api_dir, "stage")
    html = Components.stage_html(fx["input"])
    ex = fx["expected"]
    assert String.starts_with?(html, ~s|<div class="bp-pnode|)
    assert html =~ ~s|<div class="bp-pnode__k">#{ex["kind"]}</div>|
    assert html =~ ~s|<div class="bp-pnode__t">#{ex["title"]}</div>|
    assert html =~ ~s|<div class="bp-pnode__d">#{ex["detail"]}</div>|

    case ex["source_role"] do
      "origin" -> assert html =~ ~s|<div class="bp-pnode bp-pnode--src">|, "stage origin accent"
      "provenance" -> assert html =~ ~s|<div class="bp-pnode__src">#{ex["source_text"]}</div>|
      _ -> :ok
    end
  end

  test "task-detail: the emitter realizes the projection (title · ordered sections · timeline · criteria)" do
    fx = decode!(@api_dir, "task-detail")
    html = Components.task_detail_html(fx["input"])
    ex = fx["expected"]

    assert html =~ ~s|<div class="bp-tdetail__title">#{ex["title"]}</div>|

    crit = ex["criteria"]
    assert html =~ ~s|Criteria · #{crit["met"]}/#{crit["total"]}|, "criteria rollup"

    # The projected sections realize as their marker classes, IN the projected order.
    marker = %{
      "meta" => ~s|class="bp-tdetail__meta"|,
      "timeline" => ~s|class="bp-tdetail__timeline"|,
      "criteria" => ~s|class="bp-tdetail__crit"|,
      "labels" => ~s|class="bp-tdetail__labels"|
    }

    assert_ordered(html, Enum.map(ex["sections"], &Map.fetch!(marker, &1)))

    # Timeline is now COVERED (au-w5-task-detail-timeline-parity): one glyph+label
    # cell per ordered segment, each keyed to its derived glyph-role.
    timeline = ex["timeline"]
    assert timeline != [], "projection floor: task-detail fixture carries no timeline"

    assert occurrences(html, ~s|class="bp-tl__seg"|) == length(timeline),
           "rendered timeline cell count diverged from the projection"

    for seg <- timeline do
      assert html =~ ~s|bp-g--#{seg["glyph_role"]}|,
             "timeline glyph-role #{seg["glyph_role"]} missing"

      assert html =~ ~s|<span>#{seg["label"]}</span>|, "timeline label #{seg["label"]} missing"
    end
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

  # ── section (cd-12-section-golden-layout-leg): the grid layout realizes ───────
  #
  # A grid `section` composes to a `_raw` HTML node (like columns/terminal — the
  # SAME `raw_html/1` :article seam, NOT a `Components.section_html` — no such
  # emitter exists; `Compose.compose_block(section, :article)` owns the grid path).
  # The projection ECHOES the AUTHORED span/order (D-W3-2); on :article the article
  # cell wrapper renders them UNCLAMPED, so at span<=tracks (D-W3-3) authored ==
  # rendered — a `grid-column:span N` / `order:K` per cell that carried it. A drop
  # of the grid class, a mis-emitted track count, or a dropped span/order style reds
  # this leg. Child prose realizes in AUTHORED source order (CSS `order:` reorders
  # the VISUAL flow, not the DOM — so the article HTML stays authored-ordered).
  test "section: the composer realizes the grid layout (grid class · tracks/gap vars · per-cell span/order · ordered prose)" do
    fx = decode!(@api_dir, "section")
    html = raw_html(fx["input"])
    ex = fx["expected"]

    assert ex["mode"] == "grid", "projection floor: section fixture must be a grid section"
    assert html =~ ~s|class="bp-section__grid"|, "grid container class not realized"

    # Structural grid vars — the track count + the gap TOKEN var (never a px, D2).
    assert html =~ ~s|--bp-tracks:#{ex["tracks"]}|, "track count var not realized"
    assert html =~ ~s|--bp-grid-gap:|, "gap var not realized"

    cells = ex["cells"]
    assert length(cells) >= 2, "projection floor: fewer than 2 cells — coverage lost"

    # Exactly the projection's cells — no smeared/dropped cell (geometry guard).
    assert occurrences(html, ~s|class="bp-section__cell"|) == length(cells),
           "rendered cell count diverged from the projection"

    # Per-cell placement realizes UNCLAMPED on :article (authored == rendered at
    # span<=tracks). A cell carrying NEITHER key stays a bare wrapper (byte-stable).
    for cell <- cells do
      if cell["span"],
        do: assert(html =~ ~s|grid-column:span #{cell["span"]}|, "span #{cell["span"]}")

      if cell["order"], do: assert(html =~ ~s|order:#{cell["order"]}|, "order #{cell["order"]}")
    end

    # Non-vacuous: the fixture MUST exercise both a span cell AND an order cell.
    assert Enum.any?(cells, & &1["span"]), "fixture lost its span cell"
    assert Enum.any?(cells, & &1["order"]), "fixture lost its order cell"

    # Ordered child prose — each card's title, in AUTHORED source order (the DOM
    # order the article grid preserves; a reorder or drop reds the ordered-spine).
    prose =
      fx["input"]["blocks"]
      |> Enum.map(fn b -> b["slots"]["title"] |> List.first() |> Map.get("text") end)

    assert_ordered(html, prose)
  end
end
