defmodule Mix.Tasks.Barkpark.PortableDoc.GenPdParity do
  @moduledoc """
  Generate the canonical **cross-surface PortableDoc render-parity golden** — one
  frozen fixture per IN-SCOPE block type — and write each byte-identically to the
  two mirror trees. This is the golden the canonical JS `PortableDoc` renderer
  (`@barkpark/react`) is proven against block-by-block (render-path unification
  Wave 1).

      MIX_ENV=test mix barkpark.portable_doc.gen_pd_parity

  Modeled on `Mix.Tasks.Barkpark.PaperComponents.GenGoldenParity` as a SIBLING
  (pure `build/1` → byte-equal N-mirror write → freshness lock), NOT an extension:
  that task freezes a HAND-DERIVED structural projection for 13 component types;
  this one freezes the REAL `:article` HTML emission for the 64 blog-grammar types
  plus a parser-derived DOM-shape the JS Layer-2 comparator reads.

  ## The 64 in-scope types (charter D7)

  `compose.ex` dispatches 63 distinct block types (incl. the 3 interactive chat
  cards from #3514 — chat-approval/chat-question/chat-plan — and gauge-list from
  #3670). The 15 schema-field/embed types
  (`field-{string,slug,text,boolean,select,datetime,color,reference,image,number}`,
  `composite`, `arrayOf`, `codelist`, `localizedText`, `embed`) are OUT — they have
  zero web-fork seed, are schema-editor renderers not blog grammar, and are never
  named in the wish. The remaining in-scope types ARE the kitchen-sink array. BOTH members of
  the 3 alias pairs are present so the harness exercises alias dispatch:
  `questionnaire`/`form`, `stat-grid`/`stats`, `task-list`/`tasks`. `quiz` (a
  LiveView plugin, no Pd-tree block) and `onix` (separate XML) are NOT compose.ex
  clauses and never appear.

  The `scripts/pd-parity-completeness.sh` guard greps compose.ex's `"type" => "X"`
  clause heads + `t in [...]` guard members, subtracts the excluded set, and FAILS
  if any in-scope type lacks a golden fixture — the anti-drift lock. It MUST run
  under `bash` (its shebang), never zsh (which word-splits vacuously → false green).

  ## What a fixture carries (charter D9/D10 — SHAPE-equal, not byte-equal)

    * `type`         — the block type slug.
    * `input`        — the authored block map fed to the renderer.
    * `expectedHtml` — the FROZEN `:article` HTML string, straight out of the real
      Elixir emitter (`Render.render_block(input, style: :article)`, doctype:false
      so it is the bare fragment — no stylesheet wrapper).
    * `shape`        — a node-for-node DOM-shape projection of `expectedHtml`:
      each element is `{tag, sorted class-SET, sorted data-* map, children}`, each
      text node is `{text}`. Whitespace-only text nodes are dropped (the exact
      inter-tag whitespace that differs between Elixir HEEx and JS SSR — the
      normalization D10 mandates). This is the Layer-2 comparator's target: Elixir
      HEEx and JS SSR never match byte-for-byte, so parity is asserted on this
      shape, not the raw bytes.

  `build/1` is pure over the module's `@inputs` + the real render path, so the
  freshness test regenerates it in-memory and asserts `committed == build/1`. The
  HTML parse uses `LazyHTML` (already a `:test` dependency via Phoenix.LiveViewTest;
  its `to_tree/2` yields the Floki-shaped `{tag, attrs, children}` tuple tree) — so
  the generator + its freshness lock run in the TEST env where LazyHTML is loaded.

  ## Mirrors (byte-identical — the same JSON string is written to both)

    * `api/test/support/fixtures/pd-parity/<type>.golden.json`
    * `js/packages/react/tests/fixtures/pd-golden/<type>.golden.json`

  Do NOT hand-edit a mirror — re-run this task. The Elixir freshness + mirror-identity
  lock lives in `test/barkpark/portable_doc/render/pd_golden_parity_test.exs`.
  """

  # LazyHTML is a :test-only dep (mix.exs) — the runtime guard at run/1 already
  # errors cleanly outside the test env. Silence the prod-compile undefined-module
  # warning so the warnings-as-errors Prod compile gate stays green.
  @compile {:no_warn_undefined, LazyHTML}
  @shortdoc "Regenerate the cross-surface PortableDoc render-parity golden (two mirrors)"

  use Mix.Task

  alias Barkpark.PortableDoc.Render

  # ── the 64 in-scope authored inputs ───────────────────────────────────────────
  #
  # ONE realistic block per in-scope type. Every string is whitespace-clean so the
  # emitter's trims are no-ops and the frozen bytes are stable. Alias members share
  # a field shape but carry their own `"type"` so the alias-dispatch path is real.
  @inputs %{
    # scaffy:add-block-type Tabs MARK:parity-input-tabs
    "tabs" => %{
      "type" => "tabs",
      "tabs" => [
        %{
          "label" => "macOS",
          "blocks" => [
            %{
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "brew install barkpark"}]
            }
          ]
        },
        %{
          "label" => "Linux",
          "blocks" => [
            %{
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "curl -fsSL install.sh | sh"}]
            }
          ]
        }
      ]
    },
    # scaffy:add-block-type CodeTabs MARK:parity-input-code-tabs
    "code-tabs" => %{
      "type" => "code-tabs",
      "syncKey" => "lang",
      "tabs" => [
        %{"label" => "JS", "language" => "js", "value" => "console.log(1)"},
        %{"label" => "Go", "language" => "go", "value" => "fmt.Println(1)"}
      ]
    },
    # scaffy:add-block-type ApiEndpoint MARK:parity-input-api-endpoint
    "api-endpoint" => %{
      "type" => "api-endpoint",
      "method" => "POST",
      "path" => "/v1/data/mutate",
      "params" => [
        %{"name" => "dataset", "in" => "path", "type" => "string", "required" => true}
      ]
    },
    # scaffy:add-block-type Video MARK:parity-input-video
    "video" => %{
      "type" => "video",
      "src" => "https://ex.com/demo.mp4",
      "poster" => "https://ex.com/demo-poster.jpg",
      "captions" => [%{"lang" => "en", "src" => "https://ex.com/en.vtt"}]
    },
    # scaffy:add-block-type CriteriaProgress MARK:parity-input-criteria-progress
    "criteria-progress" => %{
      "type" => "criteria-progress",
      "rows" => [
        %{"label" => "Survey every corpus chapter", "met" => 2, "total" => 5},
        %{"label" => "File child tasks", "met" => 5, "total" => 5}
      ]
    },
    # scaffy:add-block-type Equation MARK:parity-input-equation
    "equation" => %{"type" => "equation", "tex" => "E = mc^2", "display" => true},
    # scaffy:add-block-type BarChart MARK:parity-input-bar-chart
    "bar-chart" => %{
      "type" => "bar-chart",
      "bars" => [
        %{"label" => "paragraph", "value" => 40},
        %{"label" => "heading", "value" => 25},
        %{"label" => "list", "value" => 10}
      ],
      "values" => true
    },
    # scaffy:add-block-type Expandable MARK:parity-input-expandable
    "expandable" => %{
      "type" => "expandable",
      "summary" => "Show the full trace",
      "open" => false,
      "blocks" => [
        %{
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Hidden detail."}]
        }
      ]
    },
    # scaffy:add-block-type Footnote MARK:parity-input-footnote
    "footnote" => %{
      "type" => "footnote",
      "notes" => [
        %{"id" => "fn1", "text" => "The board updates live."},
        %{"id" => "fn2", "text" => "You always feel progress."}
      ]
    },
    # scaffy:add-block-type Steps MARK:parity-input-steps
    "steps" => %{
      "type" => "steps",
      "steps" => [
        %{
          "title" => "Claim the task",
          "blocks" => [
            %{
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Run bp task next."}]
            }
          ]
        },
        %{"title" => "Stamp evidence"}
      ]
    },
    # scaffy:add-block-type Toc MARK:parity-input-toc
    "toc" => %{
      "type" => "toc",
      "items" => [
        %{"text" => "Getting started", "level" => 2, "anchor" => "getting-started"},
        %{"text" => "Installation", "level" => 3, "anchor" => "installation"},
        %{"text" => "Advanced usage", "level" => 2, "anchor" => "advanced-usage"}
      ],
      "depth" => 2,
      "numbered" => true
    },
    # scaffy:add-block-type Blockquote MARK:parity-input-blockquote
    # Grown (pbw-w1): a semantic attributed quotation — `content` inline array +
    # `cite`. Exercises the PdBlockquote article path (`<blockquote><p>…</p><cite>`)
    # that the JS `blockquote` emitter is proven shape-equal to.
    "blockquote" => %{
      "type" => "blockquote",
      "content" => [
        %{"type" => "text", "value" => "The best way to predict the future is to invent it."}
      ],
      "cite" => "Alan Kay"
    },
    # scaffy:add-block-type Filetree MARK:parity-input-filetree
    # W7 grow (D78): verbatim box-glyph tree lines exercising ALL THREE
    # annotation markers (● / ○ / ✕) plus the optional legend row.
    "filetree" => %{
      "type" => "filetree",
      "text" =>
        "api/lib/barkpark/portable_doc/render/\n" <>
          "├── components.ex ● diff_html/1 + filetree_html/1\n" <>
          "├── compose.ex ○ grew the diff + filetree clauses\n" <>
          "└── starter_stub.ex ✕ removed",
      "legend" => "● created · ○ injected · ✕ removed"
    },
    # scaffy:add-block-type Diff MARK:parity-input-diff
    # W7 grow (D75/D77): a small REAL unified diff — git file headers (dropped
    # from counting; the `+++` transition emits the bold path sub-header), one
    # verbatim `@@` hunk header, context + removed + added rows, and the
    # optional file/lang metadata leading the tally row.
    "diff" => %{
      "type" => "diff",
      "file" => "lib/render/compose.ex",
      "lang" => "elixir",
      "diff" =>
        "diff --git a/lib/render/compose.ex b/lib/render/compose.ex\n" <>
          "index 3f9c2d1..8a41b7e 100644\n" <>
          "--- a/lib/render/compose.ex\n" <>
          "+++ b/lib/render/compose.ex\n" <>
          "@@ -1,4 +1,5 @@\n" <>
          " defmodule Render.Compose do\n" <>
          "-  def compose(block), do: starter(block)\n" <>
          "+  def compose(block), do: grown(block)\n" <>
          "+  defp grown(block), do: block\n" <>
          " end"
    },
    # ── prose / typographic roles ──────────────────────────────────────────────
    "heading" => %{"type" => "heading", "level" => 2, "text" => "The render path"},
    "eyebrow" => %{"type" => "eyebrow", "text" => "Dispatches"},
    "byline" => %{"type" => "byline", "items" => ["Jane Rae", "2026-07-16"]},
    "ingress" => %{
      "type" => "ingress",
      "content" => [%{"type" => "text", "value" => "A lead paragraph that opens the article."}]
    },
    "paragraph" => %{
      "type" => "paragraph",
      "content" => [
        %{"type" => "text", "value" => "A body paragraph with "},
        # Marks are MAPS keyed by "type" (Inline.apply_mark/3) — NOT bare strings.
        # A string mark hits the unknown-mark passthrough and emits no <span>, so
        # this fixture would silently NOT exercise D4 inline marks.
        %{"type" => "text", "value" => "bold emphasis", "marks" => [%{"type" => "bold"}]},
        %{"type" => "text", "value" => " inside it."}
      ]
    },
    "pullquote" => %{
      "type" => "pullquote",
      "content" => [%{"type" => "text", "value" => "The best interface is no interface."}]
    },
    "list" => %{
      "type" => "list",
      "ordered" => false,
      "items" => [
        [%{"type" => "text", "value" => "First point"}],
        [%{"type" => "text", "value" => "Second point"}]
      ]
    },
    "callout" => %{
      "type" => "callout",
      "tone" => "warn",
      "title" => "Heads up",
      "content" => [%{"type" => "text", "value" => "This is a warning callout body."}]
    },
    "action" => %{
      "type" => "action",
      "label" => "Read the docs",
      "href" => "https://example.com/docs",
      "priority" => "primary"
    },
    "divider" => %{"type" => "divider"},

    # ── figures / media / code ─────────────────────────────────────────────────
    "diagram" => %{
      "type" => "diagram",
      "source" => "graph TD; A[Ingest] --> B[Render] --> C[Publish]",
      "caption" => "The three-stage pipeline"
    },
    "asciicast" => %{
      "type" => "asciicast",
      "src" => "https://example.com/casts/demo.cast",
      "caption" => "A terminal walkthrough",
      # `poster` is the OPTIONAL resting frame (data-cast-poster). It rides the
      # fixture so the Elixir ⇄ TS twins are proven byte-identical WITH the
      # attribute — the unset leg (no attribute at all) is covered by the
      # figures_test / PortableDoc.test unit pairs.
      "poster" => "npt:0:12"
    },
    "figure" => %{
      "type" => "figure",
      "caption" => "Figure with a captioned child",
      "child" => %{
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "The figure body."}]
      }
    },
    "code" => %{"type" => "code", "value" => "def hello do\n  :world\nend"},
    "image" => %{
      "type" => "image",
      "src" => "https://cdn.example.com/cover.png",
      "alt" => "Cover art",
      "width" => 640,
      "height" => 360
    },

    # ── tables / sheet ─────────────────────────────────────────────────────────
    "table" => %{
      "type" => "table",
      "head" => [
        [%{"type" => "text", "value" => "Surface"}],
        [%{"type" => "text", "value" => "Renderer"}]
      ],
      "rows" => [
        [
          [%{"type" => "text", "value" => "Phoenix"}],
          [%{"type" => "text", "value" => "Elixir"}]
        ],
        [
          [%{"type" => "text", "value" => "Next"}],
          [%{"type" => "text", "value" => "React"}]
        ]
      ]
    },
    "sheet" => %{
      "type" => "sheet",
      "ref" => "budget-2026",
      "snapshot" => %{
        "head" => ["Item", "Cost"],
        "rows" => [["Hosting", "42"], ["Domains", "18"]],
        "col_widths" => [12, 8]
      }
    },

    # ── forms (alias pair: questionnaire + form) ───────────────────────────────
    "form" => %{
      "type" => "form",
      "kind" => "grill",
      "questions" => [
        %{"id" => "q1", "type" => "yesno", "prompt" => "Ship it?"},
        %{
          "id" => "q2",
          "type" => "single",
          "prompt" => "Pick a surface",
          "options" => ["Next", "Astro", "Phoenix"]
        },
        %{
          "id" => "q3",
          "type" => "multi",
          "prompt" => "Which renderers to keep",
          "options" => ["Elixir", "Go", "JS"]
        },
        %{
          "id" => "q4",
          "type" => "scale",
          "prompt" => "Confidence",
          "scale" => %{"min" => 1, "max" => 5}
        },
        %{"id" => "q5", "type" => "text", "prompt" => "Anything else?"}
      ]
    },
    "questionnaire" => %{
      "type" => "questionnaire",
      "questions" => [
        %{"id" => "q1", "type" => "yesno", "prompt" => "Ready to review?"},
        %{"id" => "q2", "type" => "text", "prompt" => "Notes"}
      ]
    },

    # ── chat family ────────────────────────────────────────────────────────────
    "chat-tool-diff" => %{
      "type" => "chat-tool-diff",
      "input" => %{
        "file_path" => "lib/foo.ex",
        "old_string" => "def hello do\n  :old\nend",
        "new_string" => "def hello do\n  :new\nend"
      }
    },
    "chat-todo" => %{
      "type" => "chat-todo",
      "todos" => [
        %{"content" => "Author the array", "status" => "completed"},
        %{
          "content" => "Wire the generator",
          "status" => "in_progress",
          "active_form" => "Wiring the generator"
        },
        %{"content" => "Prove parity", "status" => "pending"}
      ]
    },
    "chat-thinking" => %{"type" => "chat-thinking", "tokens" => 1200},
    # The three INTERACTIVE chat cards (charter D35) — the read-only VISUAL only
    # (the answer path stays on the message envelope). `approval_status: "pending"`
    # exercises the pending title branch + the "pending" status label; the summary /
    # question-with-options / preview are non-empty so the body/chip branches render.
    "chat-approval" => %{
      "type" => "chat-approval",
      "tool_name" => "Bash",
      "summary" => "rm -rf api/_build/prod",
      "approval_status" => "pending"
    },
    "chat-question" => %{
      "type" => "chat-question",
      "questions" => [
        %{"question" => "Which renderer is canonical?", "options" => ["Elixir", "Go", "JS"]}
      ],
      "approval_status" => "pending"
    },
    "chat-plan" => %{
      "type" => "chat-plan",
      "title" => "Unify the renderers",
      "preview" => "Collapse five renderers to three, prove parity per block.",
      "approval_status" => "pending"
    },

    # ── data-viz slate (alias pair: stat-grid + stats) ─────────────────────────
    "stat" => %{
      "type" => "stat",
      "value" => "71",
      "denom" => "118",
      "unit" => "blokker",
      "label" => "Blocks covered",
      "body" => "Hver blokk består sine egne mekaniske porter.",
      "max" => 118,
      "spark" => [3, 5, 8, 13, 21],
      "source" => "commit:591fdcd53"
    },
    "stats" => %{
      "type" => "stats",
      "sourceDefault" => "paper:scaffy-benchmark",
      "items" => [
        %{"value" => "42", "label" => "In-scope types"},
        %{"value" => "3", "label" => "Renderers", "source" => "task:jdf-bl-historiene"}
      ]
    },
    "stat-grid" => %{
      "type" => "stat-grid",
      "items" => [
        %{"value" => "5", "label" => "Renderers today"},
        %{"value" => "3", "label" => "Renderers target"}
      ]
    },
    "heatmap" => %{
      "type" => "heatmap",
      "cells" => [
        [0.1, 0.4, 0.9],
        [0.6, 0.2, 0.5]
      ]
    },
    "chart" => %{
      "type" => "chart",
      "kind" => "line",
      "caption" => "Coverage over time",
      "series" => [
        %{"label" => "Covered", "points" => [10, 20, 35, 42]}
      ],
      "axes" => %{"xLabels" => ["W1", "W2", "W3", "W4"]}
    },
    # route (sport track): a small fixed loop — encoded polyline is DATA, so the
    # golden freezes the projection + marker geometry alongside the meta row.
    "route" => %{
      "type" => "route",
      "sport" => "sykling",
      "distance" => "4.2 km",
      "elevation" => "61 m",
      "duration" => "12m",
      "caption" => "Testrunden",
      "polyline" => "}ujlJgxgcAyPqOgO~JsLc[wF{aAdJ{[hSeE~MzTbInh@aB~e@"
    },
    # duel + lineage (jdf-bl-historiene-renderer-reconciliation): the jarl figure
    # family, with THE KILDE LAW exercised — per-row/node `source` refs plus a
    # `sourceDefault` fallback, deduped into the «kilde» stamp.
    "duel" => %{
      "type" => "duel",
      "legendA" => "Med katalogen",
      "legendB" => "Bare hendene",
      "sourceDefault" => "commit:591fdcd53",
      "rows" => [
        %{
          "label" => "add-error-shape",
          "delta" => "−30 %",
          "valueA" => "1 478",
          "valueB" => "2 121"
        },
        %{
          "label" => "add-oban-worker",
          "delta" => "−34,8 %",
          "valueA" => "1 788",
          "valueB" => "2 743",
          "source" => "task:jdf-bl-historiene"
        }
      ]
    },
    "lineage" => %{
      "type" => "lineage",
      "sourceDefault" => "paper:scaffy-benchmark",
      "nodes" => [
        %{
          "overline" => "jan–sep 2025",
          "title" => "nextgen-go-cli",
          "value" => "335",
          "unit" => "commits",
          "body" => "Et kveldsprosjekt med én forfatter."
        },
        %{
          "overline" => "2026",
          "title" => "Navnebyttet: Scaffy",
          "body" => "Idéen ble født på nytt."
        },
        %{
          "overline" => "i dag",
          "title" => "Kommandoer som innhold",
          "value" => "22",
          "unit" => "kommandoer",
          "source" => "https://jarl.no/prosjekter/scaffy"
        }
      ]
    },
    # gauge-list share mode (#3670): `rows` present without `snapshot` → share. The
    # values 2/1/1 over a summed denom of 4 give exactly-representable props
    # (0.5/0.25/0.25 → widths 50/25/25%), so the frozen bytes are float-stable and
    # the JS `fmt` twin agrees byte-for-byte.
    "gauge-list" => %{
      "type" => "gauge-list",
      "title" => "Coverage by surface",
      "rows" => [
        %{"label" => "Elixir", "value" => 2, "note" => "source of truth"},
        %{"label" => "Go", "value" => 1},
        %{"label" => "JS", "value" => 1}
      ]
    },

    # ── task-tracking / composition family ─────────────────────────────────────
    "notes" => %{
      "type" => "notes",
      "items" => [
        %{"label" => "Upgrade", "lead" => "Instant", "text" => "The board updates live."},
        %{"label" => "Why", "lead" => "Trust", "text" => "You always feel progress."}
      ]
    },
    "note" => %{
      "type" => "note",
      "label" => "Note",
      "lead" => "Run-in",
      "text" => "A single annotated row."
    },
    "cards" => %{
      "type" => "cards",
      "items" => [
        %{"title" => "Rule one", "text" => "The first rule body.", "tone" => "info"},
        %{"title" => "Rule two", "text" => "The second rule body.", "tone" => "warn"}
      ]
    },
    "card" => %{
      "type" => "card",
      "tone" => "info",
      "slots" => %{
        "title" => [%{"type" => "heading", "text" => "Card title"}],
        "body" => [
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Card body text."}]
          }
        ],
        "action" => [
          %{
            "type" => "action",
            "label" => "Open the board",
            "href" => "https://example.com/board"
          }
        ]
      }
    },
    "pipeline" => %{
      "type" => "pipeline",
      "nodes" => [
        %{
          "kind" => "source",
          "title" => "Ingest",
          "detail" => "reads the queue",
          "source" => true
        },
        %{
          "kind" => "emit",
          "title" => "Transform",
          "detail" => "maps the rows",
          "source" => "queue.ex:42"
        },
        %{"kind" => "gate", "title" => "Publish", "detail" => "writes the board"}
      ]
    },
    "stage" => %{
      "type" => "stage",
      "kind" => "gate",
      "title" => "Review",
      "detail" => "checks the criteria",
      "source" => true
    },
    "task-detail" => %{
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
          %{"text" => "JS realizes the golden", "met" => false}
        ],
        "labels" => ["parity", "w1"]
      }
    },
    "task-board" => %{
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
        }
      ]
    },
    "roadmap" => %{
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
    },

    # ── task-list alias pair (tasks + task-list) ───────────────────────────────
    "tasks" => %{
      "type" => "tasks",
      "snapshot" => [
        %{"title" => "Author the array", "status" => "done"},
        %{"title" => "Wire the generator", "status" => "in_progress", "priority" => "0"},
        %{"title" => "Prove parity", "status" => "ready"}
      ]
    },
    "task-list" => %{
      "type" => "task-list",
      "snapshot" => [
        %{"title" => "Seed the renderer", "status" => "ready"},
        %{"title" => "Close the gaps", "status" => "open"}
      ]
    },

    # ── containers ─────────────────────────────────────────────────────────────
    "columns" => %{
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
    },
    "terminal" => %{
      "type" => "terminal",
      "title" => "bp tasks",
      "live" => true,
      "footer" => "q to quit",
      "children" => [
        %{
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Inside the frame."}]
        }
      ]
    },
    "paper-links" => %{
      "type" => "paper-links",
      "title" => "Continue reading",
      "description" => "Papers with useful context for this change.",
      "refs" => [
        %{
          "slug" => "paper-authoring-excellence",
          "title" => "Paper authoring excellence",
          "description" => "A practical guide to publishing clear, useful Papers.",
          "reason" => "See the principles behind this example."
        }
      ]
    },
    "section" => %{
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
        }
      ]
    },
    "status-legend" => %{"type" => "status-legend"}
  }

  # The 15 schema-field/embed types cut by charter D7 — the ONE lever a later wave
  # edits to pull the field-* set back into scope. Kept here as the executable
  # counterpart of the bash guard's `excluded` list (asserted equal in the test).
  @excluded ~w(
    field-string field-slug field-text field-boolean field-select field-datetime
    field-color field-reference field-image field-number composite arrayOf codelist localizedText embed
  )

  # The 3 alias pairs — BOTH members are in-scope so alias dispatch is exercised.
  @alias_pairs [{"questionnaire", "form"}, {"stat-grid", "stats"}, {"task-list", "tasks"}]

  @comment "Generated by `MIX_ENV=test mix barkpark.portable_doc.gen_pd_parity` — DO NOT hand-edit. " <>
             "Cross-surface PortableDoc render-parity golden: the frozen :article HTML of the real " <>
             "Elixir emitter + a node-for-node DOM-shape projection (tag/class-set/data-*/text). The " <>
             "canonical JS PortableDoc renderer (@barkpark/react) is proven shape-equal to this per type."

  # gen_pd_parity.ex lives at api/lib/mix/tasks/ → ../../../ = api/.
  @api_dir Path.expand("../../../test/support/fixtures/pd-parity", __DIR__)
  @js_dir Path.expand("../../../../js/packages/react/tests/fixtures/pd-golden", __DIR__)

  @doc "The two mirror DIRECTORIES the fixtures are written into (also read by the freshness test)."
  def mirror_dirs, do: [@api_dir, @js_dir]

  @doc "The excluded (out-of-scope) type set — charter D7's 14 schema-field/embed types."
  def excluded, do: @excluded

  @doc "The 3 alias pairs whose BOTH members are in-scope."
  def alias_pairs, do: @alias_pairs

  @doc "The 64 in-scope block type slugs, sorted (each emits `<slug>.golden.json`)."
  def types, do: @inputs |> Map.keys() |> Enum.sort()

  @doc "The authored input block for a type slug."
  def input(type), do: Map.fetch!(@inputs, type)

  @doc "Fixture filename for a type slug."
  def filename(type), do: "#{type}.golden.json"

  @impl Mix.Task
  def run(_args) do
    unless Code.ensure_loaded?(LazyHTML) do
      Mix.raise(
        "LazyHTML is not loaded — run this generator under the test env: " <>
          "`MIX_ENV=test mix barkpark.portable_doc.gen_pd_parity`."
      )
    end

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
      "gen_pd_parity: #{length(types())} type(s) × #{length(mirror_dirs())} mirror(s) written — " <>
        "re-run the parity test + `bash scripts/pd-parity-completeness.sh`."
    )
  end

  @doc """
  Build ONE fixture map for a block type: render the authored input through the
  REAL Elixir `:article` emitter, freeze the HTML, and project its DOM shape.

  Pure over `@inputs` + the render path (no app boot, no Repo). Requires `LazyHTML`
  (test env). `build(type) == Jason.decode!(committed)` — the freshness lock.
  """
  def build(type) do
    input = input(type)
    html = Render.render_block(input, %{style: :article})

    %{
      "_comment" => @comment,
      "type" => type,
      "input" => input,
      "expectedHtml" => html,
      "shape" => shape(html)
    }
  end

  @doc """
  Project an HTML fragment to a node-for-node DOM shape (charter D10): each element
  is `%{tag, classes (sorted set), data (sorted data-* map), children}`, each text
  node is `%{text}`. Whitespace-only text and comments are dropped — the exact
  inter-tag whitespace + Elixir-side comments that never survive a JS SSR render.
  """
  def shape(html) when is_binary(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.to_tree(sort_attributes: true, skip_whitespace_nodes: true)
    |> Enum.flat_map(&project_node/1)
  end

  # Element node → the projected map.
  defp project_node({tag, attrs, children}) when is_binary(tag) do
    [
      %{
        "tag" => tag,
        "classes" => classes(attrs),
        "data" => data_attrs(attrs),
        "children" => Enum.flat_map(children, &project_node/1)
      }
    ]
  end

  # Text node → a `{text}` leaf (whitespace-only already dropped by the parser).
  defp project_node(text) when is_binary(text), do: [%{"text" => text}]

  # Comments / anything else the parser can emit → nothing (never in JS SSR output).
  defp project_node(_), do: []

  # The class attribute split into a SORTED set (order-invariant; JS emits the
  # same classes, possibly in a different source order).
  defp classes(attrs) do
    case List.keyfind(attrs, "class", 0) do
      {"class", value} -> value |> String.split(~r/\s+/, trim: true) |> Enum.sort()
      _ -> []
    end
  end

  # The `data-*` attributes as a SORTED map (structural payload; JS emits the
  # same data-* keys). Non-data attributes (href/src/style/colspan/…) live in the
  # frozen `expectedHtml`, not this normalized shape (D10).
  defp data_attrs(attrs) do
    attrs
    |> Enum.filter(fn {name, _} -> String.starts_with?(name, "data-") end)
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Map.new()
  end
end
