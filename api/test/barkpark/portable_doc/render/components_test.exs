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

  test "an unresolved task-detail renders the bp-tdetail--empty placeholder, not nothing" do
    for block <- [
          %{"task" => %{"title" => ""}},
          %{"task" => %{"title" => "   "}},
          %{"type" => "task-detail", "query" => %{"parent_id" => "nope"}},
          %{"task" => %{}}
        ] do
      html = Components.task_detail_html(block)

      assert html =~ ~s(class="bp-tdetail bp-tdetail--empty"),
             "an unresolved task-detail must keep its place with a placeholder, got: #{inspect(html)}"

      assert html =~ "No matching tasks."
      refute html == ""
      refute html =~ "bp-tdetail__title"
    end
  end

  test "a non-map task-detail argument is not a block and still yields empty string" do
    assert Components.task_detail_html("x") == ""
    assert Components.task_detail_html(nil) == ""
    assert Components.task_detail_html([]) == ""
  end

  test "a resolved task-detail is untouched by the empty state" do
    html = Components.task_detail_html(%{"task" => %{"title" => "real", "status" => "ready"}})
    refute html =~ "bp-tdetail--empty"
    refute html =~ "No matching tasks."
    assert html =~ ~s(<div class="bp-tdetail"><div class="bp-tdetail__title">real</div>)
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
  alias Barkpark.PortableDoc.Render.StatusVocab

  # ── the cancel lane (task-881952f8d8417f4b) ─────────────────────────────────
  #
  # THE RULING: a cancelled row renders in its OWN lane, LAST and de-emphasised,
  # carrying the manifest's ✕ — never dropped, never homed in `open`.
  #
  # WHAT THIS SURFACE DID BEFORE: it DROPPED the row. `board_roles/0` was a
  # hand-typed seven-role list with `cancel` subtracted, and `task_board_html/1`
  # collects columns by iterating that list ALONE — so an abandoned row left the
  # board with no symptom at all. A reader could not tell "this epic has no
  # cancelled work" from "this surface does not render cancelled work", and the
  # second reading was the true one.
  #
  # FAIL-BEFORE (c1): with `board_roles/0` reverted to origin/main's
  # `~w(open ready progress blocked done considering researching)`, the first
  # assertion below reds — `Assertion with =~ failed ... "bp-board__col--cancel"`.
  test "task-board renders a cancelled row in its OWN cancel column, last, with the ✕ glyph" do
    html =
      Components.task_board_html(%{
        "snapshot" => [
          %{"title" => "Claim me", "status" => "ready"},
          %{"title" => "Abandoned spike", "status" => "cancelled"},
          %{"title" => "Shipped", "status" => "done"}
        ]
      })

    # NEVER DROPPED: the row reaches the board, in a lane of its own.
    assert html =~ "bp-board__col--cancel"
    assert html =~ ~s(<span class="bp-board__label">Cancelled</span>)
    assert html =~ "Abandoned spike"

    # The manifest's ✕, through the shared glyph seam — not a hand-typed mark.
    assert html =~ ~s(<span class="bp-g bp-g--cancel">✕</span>)
    assert StatusVocab.glyph_for_role("cancel") == "✕"

    # NEVER HOMED IN `open`: the snapshot carries no open row, so an `open`
    # column appearing at all would BE the misfile.
    refute html =~ "bp-board__col--open"

    # LAST: the cancel column follows every live column in the emitted HTML.
    cancel_at = :binary.match(html, "bp-board__col--cancel") |> elem(0)

    for live <- ["bp-board__col--ready", "bp-board__col--done"] do
      live_at = :binary.match(html, live) |> elem(0)

      assert live_at < cancel_at,
             "#{live} renders AFTER the cancel column — cancel must be LAST"
    end
  end

  # c2, stated as a RULE rather than as a list: the `open` column holds ONLY rows
  # whose own resolved role is `open`. Every manifest rung now has a column of its
  # own, so nothing can fall back into the lane `bp task ready` serves.
  #
  # MUTATION: home cancelled rows in `open` (drop `cancel` from the lane order and
  # add an `open` fallback in `task_board_html/1`) and this reds on "Abandoned
  # spike" appearing inside the open column's card list.
  test "task-board's open column holds only claimable rows — no terminal or thought state falls into it" do
    statuses = [
      "open",
      "ready",
      "in_progress",
      "blocked",
      "done",
      "cancelled",
      "considering",
      "researching"
    ]

    html =
      Components.task_board_html(%{
        "snapshot" => Enum.map(statuses, fn s -> %{"title" => "row-" <> s, "status" => s} end)
      })

    # Slice the open column out: from its class to the start of the next column.
    [_, after_open] =
      String.split(html, ~s(<div class="bp-board__col bp-board__col--open">), parts: 2)

    open_col = after_open |> String.split(~s(<div class="bp-board__col), parts: 2) |> hd()

    # PRECONDITION: the slice really is the open column. Without this the loop
    # below could pass on an empty string and measure nothing.
    assert open_col =~ "row-open"

    for s <- statuses -- ["open"] do
      refute open_col =~ "row-" <> s,
             "a #{s} row landed in the CLAIMABLE open column — `bp task ready` serves that lane"
    end
  end

  # c3 — the DERIVATION LOCK. The lane order is computed from
  # design/status-manifest.json roles[] (via StatusVocab.board_roles/0), so a rung
  # added to the manifest becomes a column automatically and can never ship another
  # silent drop. The expectation here is COMPUTED, never retyped: written as a
  # literal it would be a second copy of the list and could not catch its own bug.
  #
  # MUTATION (c3): replace `defp board_roles, do: StatusVocab.board_roles()` with
  # the retyped literal `~w(open ready progress blocked done considering
  # researching)` and this reds — `manifest rung "cancel" has NO board column`.
  test "every manifest rung is a board column, terminal cancel LAST — derived, not retyped" do
    lanes = StatusVocab.board_roles()

    for rung <- StatusVocab.roles() do
      assert rung in lanes,
             "manifest rung #{inspect(rung)} has NO board column, so its rows are silently " <>
               "dropped; the lane order must be DERIVED from the manifest, not retyped beside it"
    end

    assert length(lanes) == length(StatusVocab.roles())
    assert List.last(lanes) == "cancel"
    assert lanes == Enum.reject(StatusVocab.roles(), &(&1 == "cancel")) ++ ["cancel"]

    # And the emitter really uses it: every rung resolves to a column of its own.
    html =
      Components.task_board_html(%{
        "snapshot" =>
          Enum.map(lanes, fn r -> %{"title" => "row-" <> r, "status" => board_status(r)} end)
      })

    for rung <- lanes, do: assert(html =~ "bp-board__col--" <> rung)
  end

  # The manifest's statuses map, inverted to ONE stored status per role — so the
  # test above drives the emitter through its real `role_of` seam instead of
  # assuming a role name is also a status name (`progress` is not; `in_progress` is).
  defp board_status(role) do
    StatusVocab.statuses()
    |> Enum.find_value(fn {status, r} -> if r == role, do: status end)
  end

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

defmodule Barkpark.PortableDoc.Render.ComponentsRoadmapV2Test do
  @moduledoc """
  Roadmap v2 render lock. The geometry contract is Go's
  (`internal/pdrender/taskblocks.go` — `roadmapSpan`/`roadmapLeftWidth`/
  `roadmapTodayCell`, glyph precedence `today > milestone > note > fill`), so
  this suite reads the SAME fixture the Go suite reads —
  `internal/pdrender/testdata/sample_m22.json`, loaded by
  `internal/pdrender/render_m22_test.go:19` — rather than a second copy that can
  drift. One file, two suites.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Components

  # The ONE shared v2 fixture. If this path ever moves, BOTH suites must move
  # with it — which is the point.
  @go_fixture Path.expand(
                "../../../../../internal/pdrender/testdata/sample_m22.json",
                __DIR__
              )

  defp v2_block do
    assert File.exists?(@go_fixture),
           "the shared Go v2 fixture is missing: #{@go_fixture}"

    @go_fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("blocks")
    |> Enum.find(&(&1["type"] == "roadmap"))
  end

  test "the shared Go fixture really carries the v2 shape (precondition)" do
    block = v2_block()

    assert block["start"] == "2026-01-01"
    assert block["end"] == "2026-06-30"
    assert block["today"] == "2026-03-20"

    titles = Enum.map(block["snapshot"], & &1["title"])
    assert "Discovery" in titles
    assert "Kickoff" in titles
    assert "Legacy plan" in titles

    kickoff = Enum.find(block["snapshot"], &(&1["title"] == "Kickoff"))
    assert kickoff["milestone"] == true

    build = Enum.find(block["snapshot"], &(&1["title"] == "Build"))
    assert build["note"] == true

    legacy = Enum.find(block["snapshot"], &(&1["title"] == "Legacy plan"))
    assert legacy["left"] == 5
    assert legacy["width"] == 30
    refute Map.has_key?(legacy, "start")
  end

  # c1 feature 1 — date rails.
  test "a v2 row with ISO start/end DERIVES its geometry off the block span" do
    html = Components.roadmap_html(v2_block())

    # Discovery = 2026-01-01..2026-02-15 inside 2026-01-01..2026-06-30 (180 days).
    # left = 0/180 = 0%; width = 45/180 = 25%.
    assert html =~ ~s(<span class="bp-rm__bar bp-rm__bar--done" style="left:0.0%;width:25.0%">)

    # Launch = 2026-05-01..2026-06-30 → left = 120/180, width = 180/180 - left.
    launch_left = 120 / 180 * 100
    launch_width = 100 - launch_left

    assert html =~
             ~s(style="left:#{launch_left}%;width:#{launch_width}%")

    # The proof this is DERIVED and not the old fallback. MEASURED: running
    # origin/main@a333e4b5's `roadmap_html/1` on this exact fixture emitted
    # `style="left:0%;width:100%"` for EVERY dated lane (a dateless row reads
    # left=0 and `clampf_width(nil, 0)` = 100 — a full-width bar).
    refute html =~ ~s(style="left:0%;width:100%")
  end

  # c1 feature 1b — a dateless row inside a spanned block keeps its literal pct.
  test "a row WITHOUT dates falls back to its literal pct even under a span" do
    html = Components.roadmap_html(v2_block())

    # "Legacy plan" carries left:5 width:30 and no dates — unchanged by the span.
    assert html =~ ~s(style="left:5%;width:30%")
  end

  # c1 feature 2 — ISO today.
  test "an ISO `today` derives its pct off the span; a number stays a pct" do
    html = Components.roadmap_html(v2_block())

    # 2026-03-20 is day 78 of the 180-day span.
    iso_pct = 78 / 180 * 100
    assert html =~ ~s(<span class="bp-rm__today" style="left:#{iso_pct}%"></span>)

    # A numeric today is the v1 path and is untouched.
    numeric =
      Components.roadmap_html(%{
        "today" => 34,
        "snapshot" => [%{"title" => "a", "status" => "open", "left" => 0, "width" => 10}]
      })

    assert numeric =~ ~s(<span class="bp-rm__today" style="left:34%"></span>)

    # An ISO today with NO block span draws nothing (Go returns cell -1).
    spanless =
      Components.roadmap_html(%{
        "today" => "2026-03-20",
        "snapshot" => [%{"title" => "a", "status" => "open", "left" => 0, "width" => 10}]
      })

    refute spanless =~ "bp-rm__today"
  end

  # c1 feature 3 — milestone marker at the bar's END edge.
  test "milestone:true draws a marker at the bar's end edge" do
    html = Components.roadmap_html(v2_block())

    # Kickoff = 2026-01-08..2026-01-08 → left = width-floor start, a zero-length
    # bar clamped to the 1% floor, so its marker sits at left + width.
    assert html =~ ~s(<span class="bp-rm__ms" style=")

    only =
      Components.roadmap_html(%{
        "snapshot" => [
          %{"title" => "m", "status" => "done", "left" => 20, "width" => 30, "milestone" => true}
        ]
      })

    assert only =~ ~s(<span class="bp-rm__ms" style="left:50%"></span>)
  end

  # c1 feature 4 — note marker at the bar's START edge.
  test "note:true draws a marker at the bar's start edge" do
    only =
      Components.roadmap_html(%{
        "snapshot" => [
          %{"title" => "n", "status" => "ready", "left" => 20, "width" => 30, "note" => true}
        ]
      })

    assert only =~ ~s(<span class="bp-rm__note" style="left:20%"></span>)
  end

  # c1 feature 5 — precedence, realized as PAINT order inside the track.
  test "markers emit in Go's precedence order: bar, note, milestone, today" do
    html =
      Components.roadmap_html(%{
        "today" => 50,
        "snapshot" => [
          %{
            "title" => "all",
            "status" => "done",
            "left" => 20,
            "width" => 30,
            "note" => true,
            "milestone" => true
          }
        ]
      })

    bar = :binary.match(html, ~s(class="bp-rm__bar)) |> elem(0)
    note = :binary.match(html, ~s(class="bp-rm__note)) |> elem(0)
    ms = :binary.match(html, ~s(class="bp-rm__ms)) |> elem(0)
    today = :binary.match(html, ~s(class="bp-rm__today)) |> elem(0)

    assert bar < note,
           "fill must emit before note — Go: clsNote > clsFill"

    assert note < ms,
           "note must emit before milestone — Go: clsMilestone > clsNote"

    assert ms < today,
           "milestone must emit before today — Go: clsToday > clsMilestone"
  end

  # c2 — precomputed-geometry rows stay BYTE-IDENTICAL.
  #
  # Both strings below were captured by RUNNING `Components.roadmap_html/1` on
  # origin/main@a333e4b588f1716e9e200cf9967f27f5d3224898, BEFORE the v2 change,
  # and pasted here verbatim. They are not a re-derivation of the new code.
  test "a v1 precomputed-geometry block renders byte-identical to pre-v2" do
    input =
      "test/support/fixtures/roadmap.golden.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("input")

    assert Components.roadmap_html(input) ==
             ~s(<div class="bp-roadmap"><div class="bp-rm__scale"><span>Q1</span><span>Q2</span><span>Q3</span></div><div class="bp-rm__lanes"><div class="bp-rm__lane bp-rm__lane--phase"><span class="bp-rm__lbl">Foundation</span><div class="bp-rm__track"><span class="bp-rm__bar bp-rm__bar--done" style="left:0%;width:40%"></span></div></div><div class="bp-rm__lane"><span class="bp-rm__lbl">Ship the board</span><div class="bp-rm__track"><span class="bp-rm__bar bp-rm__bar--progress" style="left:40%;width:35%"></span></div></div></div></div>)
  end

  test "a v1 numeric-today + width-clamp block renders byte-identical to pre-v2" do
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

    assert html ==
             ~s(<div class="bp-roadmap"><div class="bp-rm__scale"><span>Jul 01</span><span>Jul 08</span></div><div class="bp-rm__lanes"><div class="bp-rm__lane bp-rm__lane--phase"><span class="bp-rm__lbl">phase</span><div class="bp-rm__track"><span class="bp-rm__bar bp-rm__bar--progress" style="left:0%;width:40%"></span><span class="bp-rm__today" style="left:34%"></span></div></div><div class="bp-rm__lane"><span class="bp-rm__lbl">over</span><div class="bp-rm__track"><span class="bp-rm__bar bp-rm__bar--blocked" style="left:90%;width:10%"></span><span class="bp-rm__today" style="left:34%"></span></div></div></div></div>)
  end

  # A malformed span must not activate the v2 path at all.
  test "a malformed or inverted block span leaves every lane on the pct path" do
    for {s, e} <- [{"2026-06-30", "2026-01-01"}, {"not-a-date", "2026-06-30"}, {"2026-01-01", ""}] do
      html =
        Components.roadmap_html(%{
          "start" => s,
          "end" => e,
          "snapshot" => [
            %{"title" => "x", "status" => "open", "start" => "2026-02-01", "end" => "2026-03-01"}
          ]
        })

      assert html =~ ~s(style="left:0%;width:100%"),
             "span #{inspect({s, e})} must NOT derive geometry"
    end
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
