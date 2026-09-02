defmodule Barkpark.PortableDoc.Render.ComponentsTest do
  # Pure snapshot-driven emitter — no DB, safe to run async.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Components
  alias Barkpark.PortableDoc.Render.{Compose, Walk}

  @article %{style: :article}

  defp render(block),
    do: block |> Compose.compose_block(:article) |> Walk.render_body(72, @article)

  describe "tasks_html/1 — the shared status vocabulary" do
    test "maps each lifecycle status to its glyph + role class" do
      html =
        Components.tasks_html(%{
          "snapshot" => [
            %{"title" => "a", "status" => "open"},
            %{"title" => "b", "status" => "ready"},
            %{"title" => "c", "status" => "in_progress"},
            %{"title" => "d", "status" => "blocked"},
            %{"title" => "e", "status" => "done"},
            %{"title" => "f", "status" => "cancelled"}
          ]
        })

      assert html =~ ~s(bp-trow--open)
      assert html =~ ~s(<span class="bp-g bp-g--open">○</span>)
      assert html =~ ~s(<span class="bp-g bp-g--ready">○</span>)
      # in_progress carries no text glyph — the CSS ::before spins the Braille frames
      assert html =~ ~s(bp-g--progress)
      refute html =~ ~s(bp-g--progress">)
      assert html =~ ~s(<span class="bp-g bp-g--blocked">!</span>)
      assert html =~ ~s(<span class="bp-g bp-g--done">✓</span>)
      assert html =~ ~s(<span class="bp-g bp-g--cancel">✕</span>)
    end

    test "closed folds to the done role" do
      html = Components.tasks_html(%{"snapshot" => [%{"title" => "x", "status" => "closed"}]})
      assert html =~ ~s(bp-trow--done)
    end
  end

  describe "tasks_html/1 — structure" do
    test "groups by phase with a done/total rollup" do
      html =
        Components.tasks_html(%{
          "snapshot" => [
            %{"title" => "a", "status" => "done", "phase" => "W1"},
            %{"title" => "b", "status" => "ready", "phase" => "W1"},
            %{"title" => "c", "status" => "open", "phase" => "W2"}
          ]
        })

      assert html =~ ~s(<span class="bp-phase__nm">W1</span>)
      assert html =~ ~s(<span class="bp-phase__n">1/2</span>)
      assert html =~ ~s(<span class="bp-phase__nm">W2</span>)
      assert html =~ ~s(<span class="bp-phase__n">0/1</span>)
    end

    test "momentum header reads in-flight / ready / done / percent" do
      html =
        Components.tasks_html(%{
          "snapshot" => [
            %{"title" => "a", "status" => "in_progress"},
            %{"title" => "b", "status" => "ready"},
            %{"title" => "c", "status" => "done"},
            %{"title" => "d", "status" => "done"}
          ]
        })

      assert html =~ ~s(<b>1</b> in flight)
      assert html =~ ~s(<b>1</b> ready)
      assert html =~ ~s(<b>2</b> done)
      assert html =~ ~s(bp-momentum__pct">50%)
      assert html =~ ~s(style="width:50%")
    end

    test "nests children by depth with a guide arrow" do
      html =
        Components.tasks_html(%{
          "snapshot" => [
            %{"title" => "parent", "status" => "ready"},
            %{"title" => "child", "status" => "done", "depth" => 1}
          ]
        })

      assert html =~ ~s(padding-left:32px)
      assert html =~ ~s(<span class="bp-trow__arr">↳</span>)
    end

    test "renders priority, criteria, worker and blocker cells" do
      html =
        render(%{
          "type" => "tasks",
          "snapshot" => [
            %{
              "title" => "t",
              "status" => "blocked",
              "priority" => "1",
              "criteria" => %{"met" => 2, "total" => 3},
              "worker" => "opus",
              "blocked_by" => "resolver"
            }
          ]
        })

      assert html =~ ~s(<span class="bp-trow__p" data-p="1">P1</span>)
      assert html =~ ~s(<span class="bp-trow__cn">2/3</span>)
      assert html =~ ~s(<span class="bp-trow__w">opus</span>)
      assert html =~ ~s(<span class="bp-trow__blk">! resolver</span>)
    end
  end

  describe "tasks_html/1 — honest edge states" do
    test "empty snapshot renders an honest empty state, not a crash" do
      assert Components.tasks_html(%{"snapshot" => []}) =~ "bp-tasks--empty"
      assert Components.tasks_html(%{"snapshot" => nil}) =~ "bp-tasks--empty"
    end

    test "a non-map block yields the empty string" do
      assert Components.tasks_html("nope") == ""
      assert Components.tasks_html(nil) == ""
    end

    test "criteria only render when total > 0" do
      html =
        Components.tasks_html(%{
          "snapshot" => [
            %{"title" => "a", "status" => "ready", "criteria" => %{"met" => 0, "total" => 0}}
          ]
        })

      refute html =~ "bp-trow__cn"
    end
  end

  describe "tasks_html/1 — hostile input is inert" do
    test "escapes every author string; no script or attribute breakout" do
      html =
        render(%{
          "type" => "tasks",
          "snapshot" => [
            %{
              "title" => "<script>alert(1)</script>",
              "status" => "done",
              "worker" => ~s|"><img src=x onerror=alert(1)>|,
              "blocked_by" => ~s|a"b<c|,
              "priority" => "9;}</style>"
            }
          ]
        })

      refute html =~ "<script>"
      refute html =~ "<img"
      refute html =~ ~s(</style>)
      assert html =~ "&lt;script&gt;"
      # priority is reduced to its digits — no CSS breakout survives
      assert html =~ ~s(data-p="9">P9)
    end
  end
end

defmodule Barkpark.PortableDoc.Render.ComponentsDetailTest do
  use ExUnit.Case, async: true
  alias Barkpark.PortableDoc.Render.Components

  test "renders conditional sections; a thin task stays thin" do
    thin =
      Components.task_detail_html(%{"task" => %{"title" => "just a title", "status" => "open"}})

    assert thin =~ "just a title"
    refute thin =~ "bp-tdetail__timeline"
    refute thin =~ "Criteria"
    refute thin =~ "Dependencies"
  end

  test "meta line, timeline, criteria-with-evidence, deps-in-words, rails" do
    html =
      Components.task_detail_html(%{
        "task" => %{
          "title" => "resolver",
          "status" => "in_progress",
          "priority" => "1",
          "kind" => "task",
          "worker" => "o3",
          "created" => "2d ago",
          "timeline" => [
            %{"status" => "open", "label" => "created"},
            %{"status" => "done", "label" => "done"}
          ],
          "criteria" => [
            %{"met" => true, "text" => "a", "evidence" => "papers.ex:766"},
            %{"met" => false, "text" => "b"}
          ],
          "blocks" => 2,
          "blocked_by" => 0,
          "children" => [%{"title" => "c1", "status" => "done"}],
          "papers" => ["charter"]
        }
      })

    assert html =~ ~s(in_progress · P1 · task · o3)
    assert html =~ ~s(bp-tdetail__timeline)
    assert html =~ ~s(Criteria · 1/2)
    assert html =~ ~s(↳ papers.ex:766)
    assert html =~ ~s(blocks 2 tasks)
    assert html =~ ~s(Children · 1/1 done)
    assert html =~ ~s(▸ charter)
  end

  test "empty title or non-map yields empty string" do
    assert Components.task_detail_html(%{"task" => %{"title" => ""}}) == ""
    assert Components.task_detail_html("x") == ""
  end

  test "escapes hostile author strings" do
    html =
      Components.task_detail_html(%{
        "task" => %{"title" => "<script>x</script>", "status" => "done", "worker" => "a<b"}
      })

    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
  end

  test "child rail truncates honestly at 20" do
    kids = for i <- 1..25, do: %{"title" => "k#{i}", "status" => "open"}
    html = Components.task_detail_html(%{"task" => %{"title" => "big", "children" => kids}})
    assert html =~ "… and 5 more"
  end
end

defmodule Barkpark.PortableDoc.Render.ComponentsBoardRoadmapTest do
  use ExUnit.Case, async: true
  alias Barkpark.PortableDoc.Render.Components

  test "task-board groups into columns by lifecycle, omits empty ones" do
    html =
      Components.task_board_html(%{
        "snapshot" => [
          %{"title" => "a", "status" => "ready", "priority" => "1"},
          %{"title" => "b", "status" => "done", "criteria" => %{"met" => 2, "total" => 2}}
        ]
      })

    assert html =~ "bp-board__col--ready"
    assert html =~ "bp-board__col--done"
    refute html =~ "bp-board__col--blocked"
    assert html =~ ~s(<span class="bp-board__count">1</span>)
    assert html =~ "2/2"
  end

  test "task-board empty + non-map" do
    assert Components.task_board_html(%{"snapshot" => []}) =~ "bp-tasks--empty"
    assert Components.task_board_html(nil) == ""
  end

  # bug-taskboard-drops-open-tasks: the 4-column omit-empty board had NO `open`
  # column, so `open` tasks were silently dropped (data loss — the reader could
  # not see open work the web 5-column reader kept). FAIL-BEFORE / PASS-AFTER:
  # this asserts a populated `open` bucket renders as its own column + card.
  test "task-board renders open tasks in an Open column (no silent drop)" do
    html =
      Components.task_board_html(%{
        "snapshot" => [
          %{"title" => "Backlog groom", "status" => "open"},
          %{"title" => "Wire the harness", "status" => "ready"}
        ]
      })

    assert html =~ "bp-board__col--open"
    assert html =~ ~s(<span class="bp-board__label">Open</span>)
    assert html =~ "Backlog groom"
    # the open card still carries the shared white-ladder glyph
    assert html =~ ~s(<span class="bp-g bp-g--open">)
  end

  # charter D10b/D11 (tlv-s3): before the manifest grew the thought states,
  # TaskResolver passed raw lifecycle_status through verbatim and StatusVocab fell
  # back to the DEFAULT role `open` — so a `considering`/`researching` board row
  # rendered as the bright OPEN circle (the worst direction for "open means ready").
  # FAIL-BEFORE / PASS-AFTER: each thought state now maps to its OWN role, glyph
  # (◌ / ◎) and dim column at the ladder bottom (D12), never the open circle.
  test "task-board renders considering/researching as their own thought glyph + column, not the open circle" do
    html =
      Components.task_board_html(%{
        "snapshot" => [
          %{"title" => "Weigh the slice", "status" => "considering"},
          %{"title" => "Investigate the seam", "status" => "researching"}
        ]
      })

    # own dim/violet columns at the ladder bottom (D12)
    assert html =~ "bp-board__col--considering"
    assert html =~ "bp-board__col--researching"
    assert html =~ ~s(<span class="bp-board__label">Considering</span>)
    assert html =~ ~s(<span class="bp-board__label">Researching</span>)

    # each thought card carries its OWN glyph-role span (◌ dotted / ◎ bullseye),
    # NOT the bright open circle it used to fail into.
    assert html =~ ~s(<span class="bp-g bp-g--considering">◌</span>)
    assert html =~ ~s(<span class="bp-g bp-g--researching">◎</span>)
    refute html =~ ~s(<span class="bp-g bp-g--open">)
    refute html =~ "bp-board__col--open"
  end

  test "roadmap draws status-coloured bars, clamps geometry, today marker + scale" do
    html =
      Components.roadmap_html(%{
        "today" => 34,
        "scale" => ["Jul 01", "Jul 08"],
        "snapshot" => [
          %{
            "title" => "phase",
            "status" => "in_progress",
            "phase_row" => true,
            "left" => 0,
            "width" => 40
          },
          %{"title" => "over", "status" => "blocked", "left" => 90, "width" => 999}
        ]
      })

    assert html =~ "bp-rm__bar--progress"
    assert html =~ "bp-rm__bar--blocked"
    assert html =~ "bp-rm__today"
    assert html =~ "Jul 08"
    # width clamps so left+width never exceeds 100
    assert html =~ "left:90%;width:10%"
  end

  test "roadmap escapes titles + handles missing geometry" do
    html =
      Components.roadmap_html(%{"snapshot" => [%{"title" => "<b>x</b>", "status" => "open"}]})

    refute html =~ "<b>x</b>"
    assert html =~ "&lt;b&gt;x&lt;/b&gt;"
    assert html =~ "left:0%"
  end
end

defmodule Barkpark.PortableDoc.Render.ComponentsLegendTest do
  use ExUnit.Case, async: true
  alias Barkpark.PortableDoc.Render.Components

  test "status-legend renders all six states with glyph + canonical label + meaning" do
    html = Components.status_legend_html(%{})
    for role <- ~w(open ready progress blocked done cancel), do: assert(html =~ "bp-g--#{role}")
    # Canonical manifest label (au-w5-status-prose-parity) — the folded ONE source,
    # a plain space (no hardcoded &nbsp;), from StatusVocab.label_for_role/1.
    assert html =~ ~s(<span class="bp-legend__n">in progress</span>)
    assert html =~ ~s(<span class="bp-legend__n">cancelled</span>)
    assert html =~ "being worked right now"
    assert html =~ "something is required first"
  end
end

defmodule Barkpark.PortableDoc.Render.PageBlocksTest do
  # notes (pure) + terminal/columns (container blocks that compose children).
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.{Components, Compose, Walk}

  defp render(block),
    do: block |> Compose.compose_block(:article) |> Walk.render_body(72, %{style: :article})

  describe "notes" do
    test "renders label chip + optional bold lead + text" do
      html =
        Components.notes_html(%{
          "items" => [
            %{"label" => "alive", "lead" => "Momentum up top:", "text" => "always feel progress."}
          ]
        })

      assert html =~ ~s(<span class="bp-note__k">alive</span>)
      assert html =~ "<b>Momentum up top:</b>"
      assert html =~ "always feel progress."
    end

    test "empty + non-map + hostile input" do
      assert Components.notes_html(%{"items" => []}) == ""
      assert Components.notes_html("x") == ""

      html =
        Components.notes_html(%{
          "items" => [%{"label" => "<b>x</b>", "text" => "<script>alert(1)</script>"}]
        })

      refute html =~ "<script>"
      refute html =~ "<b>x</b>"
      assert html =~ "&lt;script&gt;"
    end

    # REGRESSION (the notes_html refactor byte-guard): pin the EXACT bytes of a
    # multi-item grid — the lead trailing-space, `<b>…</b> ` only when nonempty, the
    # trim-then-escape(lead) order — so the parity gate's `notes` rows stay green after
    # notes_html was refactored to Enum.map(&note_item_html/1).
    test "notes_html emits BYTE-EXACT grid HTML (multi-item, lead present + absent)" do
      html =
        Components.notes_html(%{
          "items" => [
            %{"label" => "a<b>", "lead" => " Lead & co ", "text" => "body <x>"},
            %{"label" => "two", "text" => "no lead"}
          ]
        })

      assert html ==
               ~s(<div class="bp-notes">) <>
                 ~s(<div class="bp-note"><span class="bp-note__k">a&lt;b&gt;</span>) <>
                 ~s(<div class="bp-note__d"><b>Lead &amp; co</b> body &lt;x&gt;</div></div>) <>
                 ~s(<div class="bp-note"><span class="bp-note__k">two</span>) <>
                 ~s(<div class="bp-note__d">no lead</div></div>) <>
                 ~s(</div>)
    end
  end

  # ── the notes-grid split: the singular `note` WIDGET ────────────────────────────
  describe "note widget — byte-align to a legacy notes row" do
    # A note in the flat wire form.
    defp note(extra \\ %{}) do
      Map.merge(
        %{"type" => "note", "label" => "alive", "lead" => "Kept", "text" => "the body"},
        extra
      )
    end

    test "note_item_html/1 == the inner row of a single-item notes grid (grid MINUS wrapper)" do
      item = %{"label" => "alive", "lead" => "Kept", "text" => "the body"}
      row = Components.note_item_html(item)

      # The lone-item grid is exactly the wrapper + this row.
      assert Components.notes_html(%{"items" => [item]}) ==
               ~s(<div class="bp-notes">) <> row <> ~s(</div>)

      # And the row itself carries NO grid wrapper (a lone note is one row).
      refute row =~ "bp-notes"
      assert row =~ ~s(<span class="bp-note__k">alive</span>)
      assert row =~ ~s(<b>Kept</b> the body)
    end

    test "compose_block(note, :article) `_raw` html == note_item_html == the notes row (lead PRESENT)" do
      composed = Compose.compose_block(note(), :article)
      assert composed == %{"kind" => "_raw", "html" => Components.note_item_html(note())}

      # Byte-identical to a single-item notes grid MINUS the `bp-notes` wrapper.
      grid =
        Components.notes_html(%{
          "items" => [%{"label" => "alive", "lead" => "Kept", "text" => "the body"}]
        })

      assert composed["html"] ==
               String.replace_prefix(grid, ~s(<div class="bp-notes">), "")
               |> String.replace_suffix("</div>", "")
    end

    test "compose_block(note, :article) byte-aligns for a lead-ABSENT note (no <b> run)" do
      n = %{"type" => "note", "label" => "solo", "text" => "just a line"}
      composed = Compose.compose_block(n, :article)

      assert composed["html"] ==
               ~s(<div class="bp-note"><span class="bp-note__k">solo</span>) <>
                 ~s(<div class="bp-note__d">just a line</div></div>)

      refute composed["html"] =~ "<b>"
    end

    test "a MATERIALIZED note composes byte-identically to its flat twin (the byte-align claim)" do
      flat = note()

      slotted = %{
        "type" => "note",
        "slots" => %{
          "label" => [
            %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "alive"}]}
          ],
          "lead" => [
            %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Kept"}]}
          ],
          "body" => [
            %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "the body"}]}
          ]
        }
      }

      assert Compose.compose_block(slotted, :article) == Compose.compose_block(flat, :article)
    end

    test "note render goes through walk `_raw` verbatim (reader passes it through)" do
      assert render(note()) =~ ~s(<div class="bp-note">)
    end
  end

  describe "terminal chrome" do
    test "renders title, live dot, keybind footer, and wraps child blocks" do
      html =
        render(%{
          "type" => "terminal",
          "title" => "bp tasks — guerrilla",
          "live" => true,
          "footer" => "j/k move · c claim",
          "children" => [
            %{
              "type" => "task-list",
              "snapshot" => [%{"title" => "resolver", "status" => "ready"}]
            }
          ]
        })

      assert html =~ ~s(<span class="bp-term__title">bp tasks — guerrilla</span>)
      assert html =~ "bp-term__live"
      assert html =~ ~s(<div class="bp-term__foot">j/k move · c claim</div>)
      # the nested task-list actually rendered inside the frame
      assert html =~ "bp-term__body"
      assert html =~ "bp-tasks"
      assert html =~ "resolver"
    end

    test "no live / no footer omits them; title escaped" do
      html = render(%{"type" => "terminal", "title" => "<x>", "children" => []})
      refute html =~ "bp-term__live"
      refute html =~ "bp-term__foot"
      assert html =~ "&lt;x&gt;"
    end

    # editable-terminal: the canvas node-view (terminal-node.js) mirrors these EXACT
    # bytes to inherit paper-surface.css paint. Lock the full compose string so a future
    # compose edit that silently drifts the shape reds here (guards the coarse-patch
    # round-trip the node-view depends on).
    test "compose_block emits the EXACT terminal chrome bytes (title+footer+live)" do
      assert Compose.compose_block(
               %{
                 "type" => "terminal",
                 "title" => "build",
                 "footer" => "^C to quit",
                 "live" => true,
                 "children" => []
               },
               :article
             ) == %{
               "kind" => "_raw",
               "html" =>
                 ~s|<div class="bp-term"><div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title">build</span><span class="bp-term__live">live</span></div><div class="bp-term__body"></div><div class="bp-term__foot">^C to quit</div></div>|
             }
    end

    test "compose_block: absent live + footer emit NOTHING (exact empty-chrome bytes)" do
      assert Compose.compose_block(%{"type" => "terminal", "children" => []}, :article) == %{
               "kind" => "_raw",
               "html" =>
                 ~s|<div class="bp-term"><div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title"></span></div><div class="bp-term__body"></div></div>|
             }
    end
  end

  describe "columns" do
    test "lays out N columns, each rendering its child blocks" do
      html =
        render(%{
          "type" => "columns",
          "columns" => [
            [%{"type" => "heading", "level" => 2, "text" => "Left"}],
            [
              %{"type" => "status-legend"},
              %{"type" => "notes", "items" => [%{"label" => "k", "text" => "v"}]}
            ]
          ]
        })

      assert html =~ ~s(style="--bp-cols:2")
      assert html =~ "Left"
      assert html =~ "bp-legend"
      assert html =~ "bp-note__k"
      # two column wrappers
      assert length(String.split(html, ~s(class="bp-cols__c"))) == 3
    end
  end

  test "the whole page: columns > terminal > task-list, + legend + notes composes" do
    page = %{
      "type" => "columns",
      "columns" => [
        [
          %{
            "type" => "terminal",
            "title" => "board",
            "live" => true,
            "footer" => "c claim",
            "children" => [
              %{
                "type" => "task-list",
                "snapshot" => [
                  %{"title" => "a", "status" => "done", "phase" => "W1"},
                  %{"title" => "b", "status" => "blocked", "phase" => "W1", "blocked_by" => "a"}
                ]
              }
            ]
          }
        ],
        [
          %{"type" => "heading", "level" => 2, "text" => "What upgraded"},
          %{"type" => "status-legend"},
          %{"type" => "notes", "items" => [%{"label" => "alive", "text" => "momentum"}]}
        ]
      ]
    }

    html = page |> Compose.compose_block(:article) |> Walk.render_body(72, %{style: :article})

    for m <-
          ~w(bp-cols bp-term bp-term__live bp-term__foot bp-tasks bp-momentum bp-g--blocked bp-legend bp-note__k) do
      assert html =~ m, "page missing #{m}"
    end

    assert html =~ "What upgraded"
  end
end

defmodule Barkpark.PortableDoc.Render.CardsPipelineTest do
  use ExUnit.Case, async: true
  alias Barkpark.PortableDoc.Render.Components

  test "cards render titled tone-accented cards; empty/non-map safe; escaped" do
    html =
      Components.cards_html(%{
        "items" => [
          %{"title" => "Gate", "text" => "hard stop", "tone" => "danger"},
          %{"title" => "x", "text" => "y", "tone" => "bogus"}
        ]
      })

    assert html =~ ~s(<div class="bp-card bp-card--danger">)
    assert html =~ ~s(<div class="bp-card__t">Gate</div>)
    refute html =~ "bp-card--bogus"
    assert Components.cards_html(%{"items" => []}) == ""
    assert Components.cards_html("x") == ""

    assert Components.cards_html(%{
             "items" => [%{"title" => "<b>", "text" => "<script>x</script>"}]
           }) =~ "&lt;script&gt;"

    refute Components.cards_html(%{
             "items" => [%{"title" => "<b>", "text" => "<script>x</script>"}]
           }) =~ "<script>"
  end

  test "pipeline renders nodes joined by arrows, source-accented, scroll-wrapped; escaped" do
    html =
      Components.pipeline_html(%{
        "nodes" => [
          %{"kind" => "source", "title" => "manifest", "source" => true},
          %{"kind" => "gate", "title" => "drift check"}
        ]
      })

    assert html =~ "bp-pipe-scroll"
    assert html =~ ~s(<div class="bp-pnode bp-pnode--src">)
    assert html =~ ~s(<span class="bp-pipe__arr">→</span>)
    assert html =~ "drift check"
    assert Components.pipeline_html(%{"nodes" => []}) == ""
    assert Components.pipeline_html(nil) == ""
    assert Components.pipeline_html(%{"nodes" => [%{"title" => "<x>"}]}) =~ "&lt;x&gt;"
  end

  # ── source coercion regression (au-w5-pipeline-source-parity) ────────────────
  # The old `truthy/1` CONFLATED boolean true and a non-empty string — both flipped
  # the accent and the string TEXT was swallowed, never rendered. These pin the
  # ratified three-way coercion; #1 reds if reverted to `truthy(get(n,"source"))`.
  test "pipeline source:\"text\" string RENDERS the provenance text (was swallowed by truthy)" do
    html =
      Components.pipeline_html(%{
        "nodes" => [%{"title" => "Ingest", "source" => "queue.ex:42"}]
      })

    # the TEXT renders in the provenance line …
    assert html =~ ~s(<div class="bp-pnode__src">queue.ex:42</div>)
    # … and a string does NOT flip the boolean-only origin accent.
    refute html =~ "bp-pnode--src"
  end

  test "pipeline source:true → origin accent, NO provenance line, no literal \"true\"" do
    html = Components.pipeline_html(%{"nodes" => [%{"title" => "Ingest", "source" => true}]})
    assert html =~ ~s(<div class="bp-pnode bp-pnode--src">)
    refute html =~ "bp-pnode__src"
    refute html =~ "true"
  end

  test "pipeline source:false / absent → NOTHING (no accent, no provenance line)" do
    for src <- [%{"title" => "Ingest", "source" => false}, %{"title" => "Ingest"}] do
      html = Components.pipeline_html(%{"nodes" => [src]})
      refute html =~ "bp-pnode--src"
      refute html =~ "bp-pnode__src"
      refute html =~ "false"
    end
  end

  test "stage source coercion mirrors the pipeline node (string→provenance, true→accent)" do
    prov = Components.stage_html(%{"title" => "Ingest", "source" => "queue.ex:42"})
    assert prov =~ ~s(<div class="bp-pnode__src">queue.ex:42</div>)
    refute prov =~ "bp-pnode--src"

    origin = Components.stage_html(%{"title" => "Ingest", "source" => true})
    assert origin =~ ~s(<div class="bp-pnode bp-pnode--src">)
    refute origin =~ "bp-pnode__src"

    none = Components.stage_html(%{"title" => "Ingest", "source" => false})
    refute none =~ "bp-pnode--src"
    refute none =~ "bp-pnode__src"
  end
end

defmodule Barkpark.PortableDoc.Render.ChatCardStatusTest do
  # Pure emitter — no DB, safe to run async.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Components

  # ── chat card status: the fold + the narrow-viewport clamp ──────────────────
  #
  # A chat card's status word used to take ARBITRARY author text into a span
  # carrying an INLINE `white-space: nowrap` — inline, so no paper-surface.css
  # rule could ever clamp it. Measured on origin/main, headless Chromium, the
  # reader's real container geometry, 390px viewport, ONE 44-character
  # approval_status: chat-approval 433px, chat-plan 450px, chat-question 466px
  # of document scrollWidth against a 390px innerWidth. Both halves are closed
  # here: the three html emitters fold the status through
  # `chat_approval_status/1` (pending | allowed | denied | canceled, fail-open
  # to pending) and the header span carries a wrap guard instead of the nowrap.
  describe "chat card approval_status is folded before it is rendered" do
    # 44 characters — the exact length the filed measurement used.
    @arbitrary_status "awaiting-operator-decision-2026-08-24T11:23Z"

    setup do
      assert String.length(@arbitrary_status) == 44
      :ok
    end

    test "chat_approval_html/1 never lets an arbitrary status reach the output" do
      html =
        Components.chat_approval_html(%{
          "type" => "chat-approval",
          "tool_name" => "Bash",
          "summary" => "Bash — command: rm -rf build",
          "approval_status" => @arbitrary_status
        })

      refute html =~ @arbitrary_status
      assert html =~ ">pending</span>"
      # and the fold reaches the TITLE branch too — an unrecognized status is
      # still "awaiting you", so the card keeps asking.
      assert html =~ "Allow Bash?"
    end

    test "chat_question_html/1 never lets an arbitrary status reach the output" do
      html =
        Components.chat_question_html(%{
          "type" => "chat-question",
          "questions" => [%{"question" => "Which database?", "options" => ["Postgres"]}],
          "approval_status" => @arbitrary_status
        })

      refute html =~ @arbitrary_status
      assert html =~ ">pending</span>"
    end

    test "chat_plan_html/1 never lets an arbitrary status reach the output" do
      html =
        Components.chat_plan_html(%{
          "type" => "chat-plan",
          "title" => "Ship the parser",
          "preview" => "Refactor the tokenizer, then add tests.",
          "approval_status" => @arbitrary_status
        })

      refute html =~ @arbitrary_status
      assert html =~ ">pending</span>"
    end

    test "the KNOWN vocabulary survives the fold — the cards still read terminal state" do
      for {status, label} <- [
            {"pending", "pending"},
            {"allowed", "✓ allowed"},
            {"denied", "⊘ denied"},
            {"canceled", "— canceled"}
          ] do
        for html <- [
              Components.chat_approval_html(%{
                "tool_name" => "Bash",
                "summary" => "s",
                "approval_status" => status
              }),
              Components.chat_question_html(%{"questions" => [], "approval_status" => status}),
              Components.chat_plan_html(%{
                "title" => "t",
                "preview" => "p",
                "approval_status" => status
              })
            ] do
          assert html =~ label, "status #{inspect(status)} lost its label"
        end
      end
    end

    test "the header carries NO inline white-space:nowrap — the declaration CSS cannot beat" do
      for html <- [
            Components.chat_approval_html(%{
              "tool_name" => "Bash",
              "summary" => "s",
              "approval_status" => "pending"
            }),
            Components.chat_question_html(%{"questions" => [], "approval_status" => "pending"}),
            Components.chat_plan_html(%{
              "title" => "t",
              "preview" => "p",
              "approval_status" => "pending"
            })
          ] do
        refute html =~ "nowrap"
        # the guard a shrink-to-fit flex item actually needs: only `anywhere`
        # reduces the intrinsic width the box is sized from, and `min-width: 0`
        # lets the item shrink below its content size at all.
        assert html =~ "min-width: 0; overflow-wrap: anywhere;"
      end
    end
  end
end
