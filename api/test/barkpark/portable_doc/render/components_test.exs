defmodule Barkpark.PortableDoc.Render.ComponentsTest do
  # Pure snapshot-driven emitter — no DB, safe to run async.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Components
  alias Barkpark.PortableDoc.Render.{Compose, Walk}

  @article %{style: :article}

  defp render(block), do: block |> Compose.compose_block(:article) |> Walk.render_body(72, @article)

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
      html = Components.tasks_html(%{"snapshot" => [%{"title" => "a", "status" => "ready", "criteria" => %{"met" => 0, "total" => 0}}]})
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
    thin = Components.task_detail_html(%{"task" => %{"title" => "just a title", "status" => "open"}})
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
          "timeline" => [%{"status" => "open", "label" => "created"}, %{"status" => "done", "label" => "done"}],
          "criteria" => [%{"met" => true, "text" => "a", "evidence" => "papers.ex:766"}, %{"met" => false, "text" => "b"}],
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
    html = Components.task_detail_html(%{"task" => %{"title" => "<script>x</script>", "status" => "done", "worker" => "a<b"}})
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

  test "roadmap draws status-coloured bars, clamps geometry, today marker + scale" do
    html =
      Components.roadmap_html(%{
        "today" => 34,
        "scale" => ["Jul 01", "Jul 08"],
        "snapshot" => [
          %{"title" => "phase", "status" => "in_progress", "phase_row" => true, "left" => 0, "width" => 40},
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
    html = Components.roadmap_html(%{"snapshot" => [%{"title" => "<b>x</b>", "status" => "open"}]})
    refute html =~ "<b>x</b>"
    assert html =~ "&lt;b&gt;x&lt;/b&gt;"
    assert html =~ "left:0%"
  end
end
