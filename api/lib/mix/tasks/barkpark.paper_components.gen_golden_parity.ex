defmodule Mix.Tasks.Barkpark.PaperComponents.GenGoldenParity do
  @moduledoc """
  Generate the cross-surface **paper-component golden parity fixtures** and write
  each byte-identically to all three mirror trees. One canonical JSON PER in-scope
  PortableDoc component block type — the executable **structural contract** that the
  Elixir View emitter (`PortableDoc.Render.Components`), the Go TUI renderer
  (`internal/pdrender`) and the web reader (`web/components/portable-doc.tsx`) must
  all realize.

      mix barkpark.paper_components.gen_golden_parity

  ## What a fixture carries (DECISION-1 = a shared STRUCTURAL projection, not
  literal-HTML nor text-normalized diff — the TUI emits ANSI, the surfaces share
  no prose):

    * `input`    — the authored block JSON fed to every surface's renderer.
    * `expected` — the STRUCTURAL PROJECTION: an element-tree of node roles /
      column labels / row {title} / glyph-role / nesting. Derived from the SHARED
      status vocabulary (`Render.StatusVocab`, itself compiled from
      `design/status-manifest.json`) plus the emitter's own column order, so a
      manifest glyph/role edit can't leave the projection stale.

  Each surface asserts its NATIVE output *realizes* this projection (View HTML
  role/class/glyph assertions; stripped-ANSI substring/geometry; web model
  bucketing) — never a byte diff.

  ## In-scope types (STEP S1 — the harness proof; the other ~11 web cases are S2)

    * `task-board`    — data-driven kanban; columns bucket the snapshot by role.
    * `status-legend` — static 6-rung white ladder (no input data).

  ## Coverage (honest scope — subset-parity, projection ⊆ native)

  COVERED: for every column/row PRESENT in the shared projection, all three
  surfaces agree on label + count + ordered card titles + glyph-role. Each surface
  asserts this at native strictness — the View at exact HTML span, web at exact
  equality, the TUI at an exact `glyph Label␣␣count` delimited-field match (a
  superstring rename fails on every leg).

  COVERED since **bug-taskboard-drops-open-tasks**: the `task-board` input now
  INCLUDES an `open` row and the Elixir View + Go pdrender both grew an `open`
  column, so a populated `open` bucket realizes on every surface (the day-one
  data-loss drop is fixed, not just filed). Empty-column policy (web keep-empty vs
  View/TUI omit-empty) stays a SUPERSET difference this ⊆-projection does not police.

  COVERED since **au-w5-card-slot-parity** (GRADUATED — all three surfaces render
  MODEL B: Elixir View + web reader #1529, Go pdrender #1535): the `card` fixture
  exercises all four slots and `card_projection/1` projects the full model-B shape —
  the ORDERED PRESENT slots (`media, title, body, action`, the emitter's fixed
  render order, derived by filtering `@card_slot_order` through `Slots.slot_elements`),
  the `tone` accent (info|ok|warn|danger, normalized via the shared `card_tone/1`
  allowlist), and a `media_fastpath` marker (an image media child ⇒ `<img>` / 🖼-box).
  Each surface's realization leg asserts the authored slot text renders IN that order,
  the tone class/tint (Elixir + web — the Go border tint is a stripped colour, owned
  by the coloured legs like the roadmap lane bar), and the image element. A card-slot
  render tamper (drop/reorder a slot, drop the tone, drop the image) reds the tampered
  surface's leg — the non-vacuous proof of graduation.

  COVERED since **au-w5-status-prose-parity**: the status LABEL prose is now a
  single manifest source (`design/status-manifest.json` `roles[].label` via
  `StatusVocab.label_for_role/1`). The legend projection asserts the canonical
  label TEXT (progress→"in progress", cancel→"cancelled") and every surface
  RENDERS it (Elixir/web/TUI legs), so the old "shares role+glyph NOT meaning"
  carve-out is closed. Board column LABELS are likewise ONE source now — the
  fold: `@board_roles` + a derived `board_label/1` (canonical label,
  sentence-cased), NOT a second hardcoded copy. (Legend MEANING is still an
  Elixir/TUI superset the web reader does not render — name-only web parity.)

  NOT COVERED (known divergences — FILED, not fixed; this harness must never imply
  parity it does not hold):

    * card/roadmap/pipeline surface-local COLOUR (tone border, lane bar, source
      accent) stays expressed as style, not the shared projection text — asserted
      by the coloured legs (Elixir/web), not the TUI.

  COVERED since **au-w5-pipeline-source-parity** (GRADUATED): a pipeline/stage node's
  `source` is projected as its coercion RESULT — `source_role` ("origin" |
  "provenance" | null) + `source_text`. The RATIFIED model: boolean `true` → an
  ORIGIN signal, a non-empty string → a provenance LINE rendering the text,
  false/absent → nothing (false is the SAME as absent → null). Each surface realizes
  the role in its NATIVE idiom (accent border on Elixir + web, ◆ ORIGIN eyebrow on
  the Go TUI, provenance line everywhere) — a semantic-parity graduation like
  tone/glyph, no pixel identity required. The pipeline fixture exercises all three
  branches (true · "queue.ex:42" · absent); the stage fixture covers origin. Only the
  surface-local COLOUR of the accent stays a documented non-structural carve-out. A
  source-render tamper reds the tampered surface's realization leg (non-vacuous).

  ## Mirrors (byte-identical — the same JSON string is written to all three)

    * `api/test/support/fixtures/<type>.golden.json`
    * `web/__tests__/fixtures/<type>.golden.json`
    * `internal/pdrender/testdata/<type>.golden.json`

  Do NOT hand-edit any mirror — re-run this task and re-verify all three surfaces.
  The Elixir freshness lock lives in
  `test/barkpark/portable_doc/render/component_golden_parity_test.exs` (asserts the
  committed api mirror equals `build/1`, the three mirrors decode term-identical,
  and the real emitter HTML realizes the projection). The Go leg is
  `internal/pdrender/component_golden_test.go`; the web leg is
  `web/__tests__/component-golden-parity.test.ts`.

  `build/1` is pure (only `StatusVocab` + the module's own `@*_input`) so the
  freshness test can regenerate in-memory without `Mix.Task`.
  """
  @shortdoc "Regenerate the cross-surface paper-component golden-parity fixtures (three mirrors)"

  use Mix.Task

  alias Barkpark.PortableDoc.Render.StatusVocab
  alias Barkpark.PortableDoc.Slots

  # ── the canonical component inputs ───────────────────────────────────────────
  #
  # task-board: a snapshot whose statuses land in the five board columns every
  # emitter now draws (open · ready · progress · blocked · done); two `ready` rows
  # pin the per-column ordering and a leading `open` row COVERS the open-inclusive
  # parity that bug-taskboard-drops-open-tasks fixed — the Elixir View + Go
  # pdrender both grew an `open` column so a populated `open` bucket is no longer
  # dropped, matching the web reader's white-ladder set. `cancelled` is still
  # avoided (the board folds it to a tally, never a column). Empty-column policy
  # (web keep-empty vs View/TUI omit-empty) is a SUPERSET difference this
  # ⊆-projection deliberately does not police.
  @task_board_input %{
    "type" => "task-board",
    "snapshot" => [
      %{"title" => "Backlog groom", "status" => "open"},
      %{"title" => "Wire the harness", "status" => "ready", "priority" => "1"},
      %{"title" => "Render the board", "status" => "in_progress", "priority" => "0"},
      %{"title" => "Await review", "status" => "blocked"},
      %{
        "title" => "Ship the legend",
        "status" => "done",
        "criteria" => %{"met" => 2, "total" => 2}
      },
      %{"title" => "Second ready row", "status" => "ready"}
    ]
  }

  # status-legend takes NO data — it renders the fixed white ladder. The input is
  # just the block shape every surface receives.
  @status_legend_input %{"type" => "status-legend"}

  # ── S2 inputs (the task-tracking / composition component family) ─────────────
  #
  # Every string is whitespace-clean so the emitters' trim (Elixir/Go) is a no-op
  # and the projection's derived text is byte-stable across surfaces.

  # notes: annotated definition rows. All items non-empty so the ⊆-projection is
  # realizable — Go's noteRenderer DROPS an all-empty row, Elixir keeps it, so an
  # empty item would break the shared row count (kept out of scope, like open).
  @notes_input %{
    "type" => "notes",
    "items" => [
      %{"label" => "Upgrade", "lead" => "Instant", "text" => "The board updates live."},
      %{"label" => "Why", "lead" => "Trust", "text" => "You always feel progress."}
    ]
  }

  # note: ONE annotated row (the singular widget). Flat fields → the same three
  # plain strings the slot accessors read.
  @note_input %{
    "type" => "note",
    "label" => "Note",
    "lead" => "Run-in",
    "text" => "A single annotated row."
  }

  # cards: a tone-tinted rule-card grid. tone ∈ info|ok|warn|danger (the shared
  # allowlist) — an off-list tone drops to "" (no accent), same on every surface.
  @cards_input %{
    "type" => "cards",
    "items" => [
      %{"title" => "Rule one", "text" => "The first rule body.", "tone" => "info"},
      %{"title" => "Rule two", "text" => "The second rule body.", "tone" => "warn"}
    ]
  }

  # card: the slots-native singular card, MODEL B (au-w5-card-slot-parity GRADUATED).
  # All FOUR slots are exercised so the full model-B projection realizes on every
  # surface: a `media` image (fast-paths to <img> / 🖼 box), a `title` heading, a
  # `body` paragraph, an `action` link button — recursed in the emitter's fixed
  # render order (media·title·body·action). A `tone` accent (info) tints the card.
  @card_input %{
    "type" => "card",
    "tone" => "info",
    "slots" => %{
      "media" => [
        %{
          "type" => "image",
          "src" => "https://cdn.example.com/cover.png",
          "alt" => "Cover art",
          "width" => 320,
          "height" => 180
        }
      ],
      "title" => [%{"type" => "heading", "text" => "Card title"}],
      "body" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Card body text."}]}
      ],
      "action" => [
        %{"type" => "action", "label" => "Open the board", "href" => "https://example.com/board"}
      ]
    }
  }

  # The card's FIXED render order (mirrors the PRIVATE slot order in
  # `Components.card_html/2`, components.ex:355-358). The projection derives the
  # PRESENT slots by filtering this order to the slots the card actually carries
  # (read through `Slots.slot_elements`, the SAME accessor the emitter recurses),
  # so the ordered slot list is a STRUCTURAL render contract — a reorder in the
  # emitter reds the realization legs, exactly like `@board_columns` and the
  # task-detail section spine (two copies that AGREE, tied by the realization
  # tests). Not a manifest token — the slot vocabulary is structural, not glyph.
  @card_slot_order ["media", "title", "body", "action"]

  # pipeline: a horizontal flow of labelled nodes. kind/title/detail are the SHARED
  # per-node text fields; `source` is now COVERED via its coercion RESULT
  # (source_role/source_text — au-w5-pipeline-source-parity). The three nodes
  # exercise ALL THREE coercion branches: node 1 `source: true` → origin (accent),
  # node 2 `source: "queue.ex:42"` → provenance (line), node 3 absent → null.
  @pipeline_input %{
    "type" => "pipeline",
    "nodes" => [
      %{"kind" => "source", "title" => "Ingest", "detail" => "reads the queue", "source" => true},
      %{
        "kind" => "emit",
        "title" => "Transform",
        "detail" => "maps the rows",
        "source" => "queue.ex:42"
      },
      %{"kind" => "gate", "title" => "Publish", "detail" => "writes the board"}
    ]
  }

  # stage: ONE pipeline node (the singular widget). kind/title/detail flat scalars;
  # `source: true` exercises the ORIGIN coercion branch (the accent), COVERED by the
  # projected source_role. (The pipeline fixture above covers provenance + absent.)
  @stage_input %{
    "type" => "stage",
    "kind" => "gate",
    "title" => "Review",
    "detail" => "checks the criteria",
    "source" => true
  }

  # task-detail: the "open a task and SEE it" card. The projected sections are the
  # SHARED ⊆ (meta · timeline · criteria · labels) every surface renders in this
  # order. The `timeline` section is now COVERED on all three surfaces (Elixir
  # detail_timeline/1, Go detailTimeline #1509, web renderBlock) — so the input
  # carries a lifecycle timeline whose glyph+label cells realize on every surface
  # (au-w5-task-detail-timeline-parity). Labels are whitespace-clean so the derived
  # projection text is byte-stable.
  @task_detail_input %{
    "type" => "task-detail",
    "task" => %{
      "title" => "Wire the harness",
      "status" => "in_progress",
      "priority" => "1",
      "timeline" => [
        %{"status" => "open", "label" => "Filed"},
        %{"status" => "in_progress", "label" => "Building"},
        %{"status" => "done", "label" => "Shipped"}
      ],
      "criteria" => [
        %{"text" => "Gen emits fixtures", "met" => true},
        %{"text" => "Web realizes the projection", "met" => false}
      ],
      "labels" => ["parity", "w5"]
    }
  }

  # roadmap: author-positioned phase/task bars. Lane title + role + phase flag are
  # SHARED; the left/width bar geometry is surface-local (CSS % vs ASCII cells) so
  # only the structural lane list + scale axis are projected.
  @roadmap_input %{
    "type" => "roadmap",
    "snapshot" => [
      %{
        "title" => "Foundation",
        "status" => "done",
        "phase_row" => true,
        "left" => 0,
        "width" => 40
      },
      %{"title" => "Ship the board", "status" => "in_progress", "left" => 40, "width" => 35}
    ],
    "scale" => ["Q1", "Q2", "Q3"]
  }

  # columns: a recursive container — a LIST of columns, each a list of child
  # blocks. The projection expresses the NESTING (per-column ordered child types);
  # the child leaf renders are locked by their own cases.
  @columns_input %{
    "type" => "columns",
    "columns" => [
      [
        %{
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Left column body."}]
        }
      ],
      [
        %{
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Right column body."}]
        }
      ]
    ]
  }

  # terminal: a recursive container — traffic-light chrome (title · live · footer)
  # wrapping child blocks. The projection carries the chrome scalars + the ordered
  # child types (the nesting).
  @terminal_input %{
    "type" => "terminal",
    "title" => "bp tasks",
    "live" => true,
    "footer" => "q to quit",
    "children" => [
      %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Inside the frame."}]}
    ]
  }

  # section: a grid-section-of-cards — the composition-doctrine ladder's Section
  # tier over a structured grid layout (D1 Elements-only-slots does NOT apply; a
  # section holds Widget/Element children, here `card` widgets). The layout is
  # `{mode:grid, tracks:2, gap:md}`; the three card children exercise the per-cell
  # placement contract: cell 0 plain, cell 1 `span:2` (== tracks, the D-W3-3 floor:
  # ALL spans <= tracks), cell 2 `order:-1` (a CSS-order hoist). Each card carries a
  # distinct title so the ordered-prose realization legs are non-vacuous. The
  # projection ECHOES the AUTHORED span/order (not the RENDERED, clamped value —
  # D-W3-2) so the surfaces can each realize placement in their native idiom.
  @section_input %{
    "type" => "section",
    "layout" => %{"mode" => "grid", "tracks" => 2, "gap" => "md"},
    "blocks" => [
      %{
        "type" => "card",
        "slots" => %{"title" => [%{"type" => "heading", "text" => "Alpha cell"}]}
      },
      %{
        "type" => "card",
        "span" => 2,
        "slots" => %{"title" => [%{"type" => "heading", "text" => "Beta cell"}]}
      },
      %{
        "type" => "card",
        "order" => -1,
        "slots" => %{"title" => [%{"type" => "heading", "text" => "Gamma cell"}]}
      }
    ]
  }

  # The board's column ROLES, in white-ladder order — mirrors the PRIVATE column
  # list in `Components.task_board_html/1`. Labels are DERIVED (canonical manifest
  # label, sentence-cased), never a second hardcoded copy — the fold. The freshness
  # test renders the real emitter and asserts every derived column label is realized.
  @board_roles ~w(open ready progress blocked done)

  @comment "Generated by `mix barkpark.paper_components.gen_golden_parity` — DO NOT hand-edit. " <>
             "Cross-surface paper-component structural-parity lock (api View tests + internal/pdrender + web reader). " <>
             "`expected` is a STRUCTURAL projection (node roles / column labels / row titles / glyph-role / nesting) " <>
             "derived from design/status-manifest.json via Render.StatusVocab — each surface asserts its native output realizes it."

  # render/ mix task dir -> ../../../ = api/ ; the three mirror trees hang off there.
  @api_dir Path.expand("../../../test/support/fixtures", __DIR__)
  @web_dir Path.expand("../../../../web/__tests__/fixtures", __DIR__)
  @go_dir Path.expand("../../../../internal/pdrender/testdata", __DIR__)

  @doc "The three mirror DIRECTORIES the fixtures are written into (also read by the freshness test)."
  def mirror_dirs, do: [@api_dir, @web_dir, @go_dir]

  @doc "The in-scope block type slugs (each emits `<slug>.golden.json`)."
  def types,
    do: [
      "task-board",
      "status-legend",
      "notes",
      "note",
      "cards",
      "card",
      "pipeline",
      "stage",
      "task-detail",
      "roadmap",
      "columns",
      "terminal",
      "section"
    ]

  @impl Mix.Task
  def run(_args) do
    for type <- types() do
      json = Jason.encode!(build(type), pretty: true) <> "\n"

      for dir <- mirror_dirs() do
        File.mkdir_p!(dir)
        path = Path.join(dir, filename(type))
        File.write!(path, json)
        Mix.shell().info("wrote #{path}")
      end
    end

    Mix.shell().info(
      "gen_golden_parity: #{length(types())} type(s) × 3 mirror(s) written — re-verify all three surfaces."
    )
  end

  @doc "Fixture filename for a type slug."
  def filename(type), do: "#{type}.golden.json"

  @doc """
  Build ONE fixture data map for a block type (pure — `StatusVocab` + the module's
  own inputs; no app boot). Every term is JSON-safe (string keys, lists) so a Jason
  encode -> decode round-trip is the identity and `build/1 == Jason.decode!(committed)`.
  """
  def build("task-board") do
    %{
      "_comment" => @comment,
      "type" => "task-board",
      "input" => @task_board_input,
      "expected" => task_board_projection(@task_board_input)
    }
  end

  def build("status-legend") do
    %{
      "_comment" => @comment,
      "type" => "status-legend",
      "input" => @status_legend_input,
      "expected" => status_legend_projection()
    }
  end

  def build("notes") do
    fixture("notes", @notes_input, notes_projection(@notes_input))
  end

  def build("note") do
    fixture("note", @note_input, note_projection(@note_input))
  end

  def build("cards") do
    fixture("cards", @cards_input, cards_projection(@cards_input))
  end

  def build("card") do
    fixture("card", @card_input, card_projection(@card_input))
  end

  def build("pipeline") do
    fixture("pipeline", @pipeline_input, pipeline_projection(@pipeline_input))
  end

  def build("stage") do
    fixture("stage", @stage_input, stage_projection(@stage_input))
  end

  def build("task-detail") do
    fixture("task-detail", @task_detail_input, task_detail_projection(@task_detail_input))
  end

  def build("roadmap") do
    fixture("roadmap", @roadmap_input, roadmap_projection(@roadmap_input))
  end

  def build("columns") do
    fixture("columns", @columns_input, columns_projection(@columns_input))
  end

  def build("terminal") do
    fixture("terminal", @terminal_input, terminal_projection(@terminal_input))
  end

  def build("section") do
    fixture("section", @section_input, section_projection(@section_input))
  end

  defp fixture(type, input, expected) do
    %{"_comment" => @comment, "type" => type, "input" => input, "expected" => expected}
  end

  # ── projections (derived from the input + shared vocabulary, never hand-typed) ─

  # Group the snapshot rows by their ladder role into the emitter's fixed column
  # order, dropping empty columns (exactly what `task_board_html/1` does). Each
  # column carries its label, glyph-role, count and the ordered card titles.
  defp task_board_projection(%{"snapshot" => rows}) when is_list(rows) do
    by_role =
      Enum.group_by(rows, fn r -> r |> Map.get("status") |> StatusVocab.role_for_status() end)

    columns =
      @board_roles
      |> Enum.map(fn role -> {role, board_label(role), Map.get(by_role, role, [])} end)
      |> Enum.reject(fn {_role, _label, rs} -> rs == [] end)
      |> Enum.map(fn {role, label, rs} ->
        %{
          "role" => role,
          "label" => label,
          "glyph_role" => role,
          "count" => length(rs),
          "cards" => Enum.map(rs, fn r -> %{"title" => r |> Map.get("title") |> to_string()} end)
        }
      end)

    %{"container_role" => "board", "columns" => columns}
  end

  # A board column header label: the canonical lowercase manifest label
  # sentence-cased (the fold — mirrors `Components.board_label/1`).
  defp board_label(role), do: role |> StatusVocab.label_for_role() |> String.capitalize()

  # The static white ladder: one row per role in the manifest's order, each pinned
  # to its glyph-role, glyph char and spinner flag — ALL straight out of
  # StatusVocab (so a manifest edit re-derives here at build time).
  defp status_legend_projection do
    rows =
      Enum.map(StatusVocab.roles(), fn role ->
        %{
          "role" => role,
          "glyph_role" => role,
          "glyph" => StatusVocab.glyph_for_role(role),
          "spinner" => StatusVocab.spinner?(role),
          "label" => StatusVocab.label_for_role(role)
        }
      end)

    %{"container_role" => "legend", "rows" => rows}
  end

  # ── S2 projections ───────────────────────────────────────────────────────────
  #
  # Each derives the SHARED structural projection from the input via the SAME pure
  # read-path the emitter uses (Slots.note_* / card_* / stage_field_text;
  # StatusVocab.role_for_status) — so a manifest/slot-contract edit re-derives here
  # at build time and the per-surface realization tests catch any drift.

  # notes / note: label · lead · plain-text body, read through the note slot
  # accessors (a bare flat item reads the flat field). Trimmed lead mirrors the
  # emitter (`note_item_html` trims lead before the <b> wrap).
  defp note_row(item) do
    %{
      "label" => Slots.note_label_text(item),
      "lead" => item |> Slots.note_lead_text() |> String.trim(),
      "text" => Slots.note_body_text(item)
    }
  end

  defp notes_projection(%{"items" => items}) when is_list(items) do
    %{"container_role" => "notes", "rows" => Enum.map(items, &note_row/1)}
  end

  defp note_projection(item) do
    row = note_row(item)

    %{
      "container_role" => "note",
      "label" => row["label"],
      "lead" => row["lead"],
      "text" => row["text"]
    }
  end

  # cards: title · text · tone, tone normalized against the SHARED card allowlist
  # (info|ok|warn|danger; off-list → "") exactly as `cards_html/1`.
  defp card_tone(tone) when tone in ~w(info ok warn danger), do: tone
  defp card_tone(_), do: ""

  defp cards_projection(%{"items" => items}) when is_list(items) do
    cards =
      Enum.map(items, fn it ->
        %{
          "title" => it |> Map.get("title") |> to_string(),
          "text" => it |> Map.get("text") |> to_string(),
          "tone" => it |> Map.get("tone") |> to_string() |> card_tone()
        }
      end)

    %{"container_role" => "cards", "cards" => cards}
  end

  # card: the MODEL-B projection (au-w5-card-slot-parity GRADUATED — all three
  # surfaces now render model B: Elixir+web #1529, Go #1535). The card's slots hold
  # arbitrary element children recursed in the emitter's fixed order (media·title·
  # body·action) with a legacy `tone` accent and an image-media fast-path. The
  # projection carries:
  #
  #   * `slots` — `@card_slot_order` FILTERED to the slots PRESENT (non-empty) in
  #     this card, read through the SAME `Slots.slot_elements/2` accessor the emitter
  #     recurses (so a slot the emitter would draw is projected, and the ORDER is the
  #     structural render contract — a reorder reds the realization legs, like the
  #     board column order + the task-detail spine).
  #   * `tone` — normalized through the SHARED card allowlist (`card_tone/1`,
  #     info|ok|warn|danger→itself, off-list→"") EXACTLY as `card_html/1` and
  #     `cards_html/1` — derived from the input, never hand-typed.
  #   * `media_fastpath` — true iff the media slot's lone element is (or normalizes
  #     to) an image element (the `<img>` / 🖼-box fast-path every surface takes).
  #
  # The title/body TEXT is no longer projected — the ORDERED slot list already
  # asserts they render (in place), and the per-surface realization legs assert the
  # authored slot text appears in that order. This is the DOCUMENTED graduation
  # target (see the moduledoc), now activated.
  defp card_projection(block) do
    present = Enum.filter(@card_slot_order, fn name -> Slots.slot_elements(block, name) != [] end)

    %{
      "container_role" => "card",
      "slots" => present,
      "tone" => block |> Map.get("tone") |> to_string() |> card_tone(),
      "media_fastpath" => card_media_fastpath?(block)
    }
  end

  # media_fastpath: does the card's media slot fast-path to an image? True iff its
  # lone element is a typed `image` element OR a typeless `{src,...}` map (which the
  # emitters normalize to `type:"image"` — `normalize_media_element` in
  # components.ex, `coerceMediaImages` in composeblocks.go). Read through the SAME
  # `Slots.slot_elements` accessor, so it tracks whatever the emitter would recurse.
  defp card_media_fastpath?(block) do
    case Slots.slot_elements(block, "media") do
      [first | _] when is_map(first) ->
        Map.get(first, "type") == "image" or
          (not Map.has_key?(first, "type") and Map.has_key?(first, "src"))

      _ ->
        false
    end
  end

  # pipeline: per-node kind · title · detail + the `source` coercion RESULT
  # (source_role/source_text — COVERED since au-w5-pipeline-source-parity). The
  # projection carries the SEMANTIC result, not the raw field: boolean `true` →
  # "origin", a non-empty string → "provenance" (+ source_text), false/absent → null.
  # Each surface realizes the role in its native idiom (accent border on Elixir/web,
  # ◆ ORIGIN eyebrow on the Go TUI) — no pixel identity, like tone/glyph parity.
  defp pipeline_projection(%{"nodes" => nodes}) when is_list(nodes) do
    ns =
      Enum.map(nodes, fn n ->
        {role, text} = source_coercion(Map.get(n, "source"))

        %{
          "kind" => n |> Map.get("kind") |> to_string(),
          "title" => n |> Map.get("title") |> to_string(),
          "detail" => n |> Map.get("detail") |> to_string(),
          "source_role" => role,
          "source_text" => text
        }
      end)

    %{"container_role" => "pipeline", "nodes" => ns}
  end

  # stage: ONE pnode's kind · title · detail, read through the same slot accessor
  # `stage_html/1` uses (scalar-only stage → the plain scalar), plus the `source`
  # coercion RESULT (source_role/source_text).
  defp stage_projection(block) do
    {role, text} = source_coercion(Map.get(block, "source"))

    %{
      "container_role" => "stage",
      "kind" => Slots.stage_field_text(block, "kind"),
      "title" => Slots.stage_field_text(block, "title"),
      "detail" => Slots.stage_field_text(block, "detail"),
      "source_role" => role,
      "source_text" => text
    }
  end

  # The RATIFIED `source` coercion, projected as the SEMANTIC result (mirrors
  # `Components.pnode_source/1`, the Go type-switch, and the web `pnodeSource`):
  # boolean `true` → {"origin", ""}; non-empty string → {"provenance", text};
  # `false`/absent/"" → {nil, ""} (nil ⇒ JSON null — false is SAME as absent).
  defp source_coercion(true), do: {"origin", ""}
  defp source_coercion(s) when is_binary(s) and s != "", do: {"provenance", s}
  defp source_coercion(_), do: {nil, ""}

  # task-detail: title + the ORDERED present-section spine (the SHARED ⊆ every
  # surface renders) + the ordered timeline entries + the criteria rollup. Section
  # presence mirrors the emitter's conditional sections; `timeline` is now COVERED
  # on all three surfaces (au-w5-task-detail-timeline-parity) — present iff the
  # task carries timeline segments, drawn AFTER meta and BEFORE criteria (the
  # emitter's `detail_timeline` slot in `task_detail_html/1`). Each entry's role is
  # derived through the SAME `StatusVocab.role_for_status` the emitter's `role_of`
  # uses (so a manifest edit re-derives here); `glyph_role` == role, exactly what
  # `glyph_html(role)` keys off.
  defp task_detail_projection(%{"task" => t}) when is_map(t) do
    crit = t |> Map.get("criteria") |> as_list()
    timeline = t |> Map.get("timeline") |> as_list()

    sections =
      [
        {"meta", true},
        {"timeline", timeline != []},
        {"criteria", crit != []},
        {"labels", t |> Map.get("labels") |> as_list() != []}
      ]
      |> Enum.filter(fn {_role, present?} -> present? end)
      |> Enum.map(fn {role, _} -> role end)

    met = Enum.count(crit, fn c -> Map.get(c, "met") == true end)

    %{
      "container_role" => "task-detail",
      "title" => t |> Map.get("title") |> to_string(),
      "sections" => sections,
      "timeline" => Enum.map(timeline, &timeline_entry/1),
      "criteria" => %{"met" => met, "total" => length(crit)}
    }
  end

  # One timeline cell: its ladder role (derived, never hand-typed) doubling as the
  # glyph-role, plus the plain label text every surface prints.
  defp timeline_entry(seg) do
    role = seg |> Map.get("status") |> StatusVocab.role_for_status()
    %{"role" => role, "glyph_role" => role, "label" => seg |> Map.get("label") |> to_string()}
  end

  # roadmap: the structural lane list (title · ladder-role · phase flag) + the
  # optional scale axis. Bar geometry (left/width) is surface-local, not projected.
  defp roadmap_projection(%{"snapshot" => rows} = block) when is_list(rows) do
    lanes =
      Enum.map(rows, fn r ->
        %{
          "title" => r |> Map.get("title") |> to_string(),
          "role" => r |> Map.get("status") |> StatusVocab.role_for_status(),
          "phase" => Map.get(r, "phase_row") == true
        }
      end)

    scale = block |> Map.get("scale") |> as_list() |> Enum.map(&to_string/1)
    %{"container_role" => "roadmap", "lanes" => lanes, "scale" => scale}
  end

  # columns: the nesting — a list of columns, each the ordered child block TYPES.
  defp columns_projection(%{"columns" => cols}) when is_list(cols) do
    %{"container_role" => "columns", "columns" => Enum.map(cols, &child_types/1)}
  end

  # terminal: the chrome scalars (title · live · footer) + the ordered child types.
  defp terminal_projection(block) do
    children = Map.get(block, "children") || Map.get(block, "blocks") || []

    %{
      "container_role" => "terminal",
      "title" => block |> Map.get("title") |> to_string(),
      "live" => Map.get(block, "live") in [true, "true", "live"],
      "footer" => block |> Map.get("footer") |> to_string(),
      "children" => child_types(children)
    }
  end

  defp child_types(list) when is_list(list),
    do: Enum.map(list, fn c -> c |> Map.get("type") |> to_string() end)

  defp child_types(_), do: []

  # section (grid): the AUTHORED-ECHO layout projection — the container role, the
  # grid mode, the resolved track count + gap TOKEN, and one cell per child echoing
  # its AUTHORED span/order (NOT the rendered/clamped value — D-W3-2) + child type.
  # Every scalar is read through the SAME coercions the emitter uses (mirrors the
  # PRIVATE `Compose.grid_layout/1`, `grid_tracks/1`, `span_int/1`, `order_int/1` +
  # the `gap_token_var/1` vocabulary), so a coercion drift in the render seam reds
  # the realization legs, not this pure projection. `breakpoints` are EXCLUDED — a
  # section's adaptive collapse is surface-local (the Go TUI's width floor), not a
  # shared structural fact. span/order absent → null (JSON), the present-only
  # contract the `.bp-section__cell` wrapper honors byte-for-byte.
  defp section_projection(block) do
    layout = grid_layout(block) || %{}

    %{
      "container_role" => "section",
      "mode" => layout |> Map.get("mode") |> to_string(),
      "tracks" => grid_tracks(Map.get(layout, "tracks")),
      "gap" => gap_token(Map.get(layout, "gap")),
      "cells" => section_cells(block)
    }
  end

  defp section_cells(block) do
    block
    |> Map.get("blocks", [])
    |> List.wrap()
    |> Enum.map(fn child ->
      %{
        "span" => span_int(Map.get(child, "span")),
        "order" => order_int(Map.get(child, "order")),
        "type" => child |> Map.get("type") |> to_string()
      }
    end)
  end

  # The ONE grid predicate (mirrors `Compose.grid_layout/1`): the layout iff its
  # mode is exactly "grid", else nil → the stack path (no grid projection).
  defp grid_layout(%{"layout" => %{"mode" => "grid"} = layout}), do: layout
  defp grid_layout(_), do: nil

  # tracks → a positive int column count (mirrors `Compose.grid_tracks/1`): int or
  # stringy-int, anything else → 2 (the CSS `repeat(var(--bp-tracks,2),…)` default).
  defp grid_tracks(n) when is_integer(n) and n > 0, do: n

  defp grid_tracks(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> i
      _ -> 2
    end
  end

  defp grid_tracks(_), do: 2

  # span → a positive int (mirrors `Compose.span_int/1`): the WHOLE string must
  # parse (a trailing `;background:url(x)` fails), 0/neg/non-int → nil (JSON null).
  defp span_int(n) when is_integer(n) and n > 0, do: n

  defp span_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> i
      _ -> nil
    end
  end

  defp span_int(_), do: nil

  # order → ANY int (0/negative are legal CSS `order`; mirrors `Compose.order_int/1`):
  # int or whole-string int, else nil (JSON null).
  defp order_int(n) when is_integer(n), do: n

  defp order_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp order_int(_), do: nil

  # gap TOKEN name (none|sm|md|lg; absent/unknown → md) — the token half of the
  # emitter's `Compose.gap_token_var/1` (which maps the SAME vocabulary to a CSS
  # `--bp-space-*` var). The projection carries the token, never a px literal (D2).
  defp gap_token(g) when g in ~w(none sm md lg), do: g
  defp gap_token(_), do: "md"

  defp as_list(l) when is_list(l), do: l
  defp as_list(_), do: []
end
