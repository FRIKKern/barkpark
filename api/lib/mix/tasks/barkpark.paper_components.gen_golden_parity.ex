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

  NOT COVERED (known divergences — FILED, not fixed; this harness must never imply
  parity it does not hold):

    * status/label PROSE differs (Elixir "in progress"/"cancelled" vs Go
      "progress"/"cancel"). The projection shares role + glyph, NOT meaning text;
      owned by **au-w5-status-prose-parity**. Board column LABELS are likewise
      "two copies agree" (this task's `@board_columns` + `components.ex`, tied by
      the realization tests), NOT a single manifest source — folded into
      **au-w5-status-prose-parity**.

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

  # card: the slots-native singular card. title/body are the SHARED subset every
  # surface realizes (tone accent + media/action + slot ORDER diverge across
  # Elixir/Go — see au-w5-card-slot-parity; NOT projected here).
  @card_input %{
    "type" => "card",
    "slots" => %{
      "title" => [%{"type" => "heading", "text" => "Card title"}],
      "body" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Card body text."}]}
      ]
    }
  }

  # pipeline: a horizontal flow of labelled nodes. kind/title/detail are the
  # SHARED per-node fields (the `source` accent is Elixir-class vs Go-provenance-
  # line — NOT projected).
  @pipeline_input %{
    "type" => "pipeline",
    "nodes" => [
      %{"kind" => "source", "title" => "Ingest", "detail" => "reads the queue", "source" => true},
      %{"kind" => "emit", "title" => "Transform", "detail" => "maps the rows"},
      %{"kind" => "gate", "title" => "Publish", "detail" => "writes the board"}
    ]
  }

  # stage: ONE pipeline node (the singular widget). kind/title/detail flat scalars.
  @stage_input %{
    "type" => "stage",
    "kind" => "gate",
    "title" => "Review",
    "detail" => "checks the criteria"
  }

  # task-detail: the "open a task and SEE it" card. The projected sections are the
  # SHARED ⊆ (meta · criteria · labels) every surface renders in this order; the
  # `timeline` section is Elixir-only (Go's taskDetailRenderer omits it — see
  # au-w5-task-detail-timeline-parity) so the input carries NO timeline.
  @task_detail_input %{
    "type" => "task-detail",
    "task" => %{
      "title" => "Wire the harness",
      "status" => "in_progress",
      "priority" => "1",
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
      %{"title" => "Foundation", "status" => "done", "phase_row" => true, "left" => 0, "width" => 40},
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
      [%{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Left column body."}]}],
      [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Right column body."}]}
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

  # The board's column order + labels — mirrors the PRIVATE column list in
  # `Components.task_board_html/1`. The freshness test renders the real emitter and
  # asserts every column here is realized, so a column-order/label edit there reds.
  @board_columns [
    {"open", "Open"},
    {"ready", "Ready"},
    {"progress", "In progress"},
    {"blocked", "Blocked"},
    {"done", "Done"}
  ]

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
      "terminal"
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
      @board_columns
      |> Enum.map(fn {role, label} -> {role, label, Map.get(by_role, role, [])} end)
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
          "spinner" => StatusVocab.spinner?(role)
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
    %{"container_role" => "note", "label" => row["label"], "lead" => row["lead"], "text" => row["text"]}
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

  # card: the SHARED subset — title + flattened plain-text body (via the same slot
  # accessors `card_html/1` reads). tone/media/action + slot ORDER are surface-
  # divergent and deliberately NOT projected (au-w5-card-slot-parity).
  defp card_projection(block) do
    %{
      "container_role" => "card",
      "title" => Slots.card_title_text(block),
      "body" => Slots.card_body_text(block)
    }
  end

  # pipeline: per-node kind · title · detail (the SHARED text fields every surface
  # draws; the `source` accent is surface-divergent, not projected).
  defp pipeline_projection(%{"nodes" => nodes}) when is_list(nodes) do
    ns =
      Enum.map(nodes, fn n ->
        %{
          "kind" => n |> Map.get("kind") |> to_string(),
          "title" => n |> Map.get("title") |> to_string(),
          "detail" => n |> Map.get("detail") |> to_string()
        }
      end)

    %{"container_role" => "pipeline", "nodes" => ns}
  end

  # stage: ONE pnode's kind · title · detail, read through the same slot accessor
  # `stage_html/1` uses (scalar-only stage → the plain scalar).
  defp stage_projection(block) do
    %{
      "container_role" => "stage",
      "kind" => Slots.stage_field_text(block, "kind"),
      "title" => Slots.stage_field_text(block, "title"),
      "detail" => Slots.stage_field_text(block, "detail")
    }
  end

  # task-detail: title + the ORDERED present-section spine (the SHARED ⊆ every
  # surface renders) + the criteria rollup. Section presence mirrors the emitter's
  # conditional sections; `timeline` is Elixir-only so it is neither in the input
  # nor the projection (au-w5-task-detail-timeline-parity).
  defp task_detail_projection(%{"task" => t}) when is_map(t) do
    crit = t |> Map.get("criteria") |> as_list()

    sections =
      [
        {"meta", true},
        {"criteria", crit != []},
        {"labels", (t |> Map.get("labels") |> as_list()) != []}
      ]
      |> Enum.filter(fn {_role, present?} -> present? end)
      |> Enum.map(fn {role, _} -> role end)

    met = Enum.count(crit, fn c -> Map.get(c, "met") == true end)

    %{
      "container_role" => "task-detail",
      "title" => t |> Map.get("title") |> to_string(),
      "sections" => sections,
      "criteria" => %{"met" => met, "total" => length(crit)}
    }
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

  defp as_list(l) when is_list(l), do: l
  defp as_list(_), do: []
end
