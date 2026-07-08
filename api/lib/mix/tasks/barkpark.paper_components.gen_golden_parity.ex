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

  NOT COVERED (known divergences — FILED, not fixed; this harness must never imply
  parity it does not hold):

    * task-board `open`-task DROP — the Elixir 4-column omit-empty View drops
      `open` tasks the web 5-column view keeps. A ⊆-projection structurally cannot
      catch an omission, so the `task-board` input here OMITS `open`; owned by
      **bug-taskboard-drops-open-tasks** (which carries the open-inclusive
      cross-surface test that DOES catch it — a real data-loss bug found day one).
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

  # ── the canonical component inputs ───────────────────────────────────────────
  #
  # task-board: a snapshot whose statuses land in the four board columns the
  # emitter draws (ready · progress · blocked · done); two `ready` rows pin the
  # per-column ordering, `open`/`cancelled` are deliberately avoided so the SAME
  # projection is realizable on all three surfaces (the emitter drops `open`, the
  # web keeps an extra empty `open` column + a cancelled tally — both are supersets
  # of this projection, which is the shared truth).
  @task_board_input %{
    "type" => "task-board",
    "snapshot" => [
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

  # The board's column order + labels — mirrors the PRIVATE column list in
  # `Components.task_board_html/1`. The freshness test renders the real emitter and
  # asserts every column here is realized, so a column-order/label edit there reds.
  @board_columns [
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
  def types, do: ["task-board", "status-legend"]

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
end
