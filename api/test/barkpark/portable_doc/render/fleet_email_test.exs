defmodule Barkpark.PortableDoc.Render.FleetEmailTest do
  # Pure, in-process render — no DB, no Phoenix boot. Mirrors the data-viz email
  # test pattern (data_viz_test.exs): assert a real <table>, refute any `bp-`
  # class or `<svg>`, and pin the status hexes to StatusVocab.tones().
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Compose
  alias Barkpark.PortableDoc.Render.FleetEmail
  alias Barkpark.PortableDoc.Render.StatusVocab

  # Status-manifest light hexes — the ONE source these emitters must agree with.
  @done StatusVocab.tones()["ok"]["light"]
  @progress StatusVocab.tones()["info"]["light"]
  @blocked StatusVocab.tones()["warn"]["light"]
  # the thought-state hue (charter D9/D12) — researching's one new violet
  @violet StatusVocab.tones()["violet"]["light"]

  # Evergreen email skin (the default theme's captured hex).
  @ever_ground "#eaf1ee"
  @ever_border "#dde7e2"

  defp tasks_block do
    %{
      "type" => "tasks",
      "title" => "Wave 4",
      "snapshot" => [
        %{
          "status" => "in_progress",
          "title" => "Build the email variants",
          "priority" => 1,
          "criteria" => %{"met" => 1, "total" => 3},
          "worker" => "w1"
        },
        %{"status" => "ready", "title" => "Review", "phase" => "QA"},
        %{"status" => "done", "title" => "Ship", "phase" => "QA"},
        %{"status" => "blocked", "title" => "Deploy", "blocked_by" => "gate", "depth" => 1}
      ]
    }
  end

  defp detail_block do
    %{
      "type" => "task-detail",
      "task" => %{
        "title" => "The task",
        "status" => "in_progress",
        "priority" => 0,
        "kind" => "task",
        "worker" => "w1",
        "timeline" => [
          %{"status" => "open", "label" => "filed"},
          %{"status" => "done", "label" => "shipped"}
        ],
        "criteria" => [
          %{"text" => "does X", "met" => true, "evidence" => "gate green"},
          %{"text" => "does Y", "met" => false}
        ],
        "children" => [%{"status" => "done", "title" => "child a"}],
        "papers" => ["The Spec"],
        "labels" => ["epic", "email"],
        "blocks" => 2
      }
    }
  end

  defp board_block do
    %{
      "type" => "task-board",
      "snapshot" => [
        %{"status" => "in_progress", "title" => "A", "priority" => 1},
        %{"status" => "done", "title" => "B", "criteria" => %{"met" => 2, "total" => 2}}
      ]
    }
  end

  defp roadmap_block do
    %{
      "type" => "roadmap",
      "today" => 40,
      "scale" => ["Q1", "Q2"],
      "snapshot" => [
        %{
          "status" => "done",
          "title" => "Phase 1",
          "phase_row" => true,
          "left" => 0,
          "width" => 30
        },
        %{"status" => "in_progress", "title" => "Task B", "left" => 30, "width" => 40}
      ]
    }
  end

  # ── the email-safe shape: real tables, no classes, no SVG ─────────────────────

  test "every task-family emitter renders a real table with no bp- classes or SVG" do
    for html <- [
          FleetEmail.tasks_email_html(tasks_block()),
          FleetEmail.task_detail_email_html(detail_block()),
          FleetEmail.task_board_email_html(board_block()),
          FleetEmail.roadmap_email_html(roadmap_block())
        ] do
      assert html =~ "<table"
      refute html =~ ~s(class="bp-)
      refute html =~ "<svg"
    end
  end

  # ── status hues come from StatusVocab.tones(), not TokensGen ──────────────────

  test "task list colours the status glyphs from the status-manifest tones" do
    html = FleetEmail.tasks_email_html(tasks_block())

    assert html =~ "color:#{@progress}"
    assert html =~ "color:#{@done}"
    assert html =~ "color:#{@blocked}"
    # sanity: the manifest values are the lifecycle hexes, not the health greens
    assert @done == "#0d9488"
    assert @progress == "#2563eb"
    assert @blocked == "#d97706"
  end

  test "task board stripes the worked/done columns with their tone" do
    html = FleetEmail.task_board_email_html(board_block())

    # one <td> per NON-EMPTY column: only progress + done here
    assert html =~ "border-top:3px solid #{@progress}"
    assert html =~ "border-top:3px solid #{@done}"
    # the evergreen skin paints the column ground + card border
    assert html =~ "background:#{@ever_ground}"
    assert html =~ "border:1px solid #{@ever_border}"
  end

  # charter D9/D12 (tlv-s3): the two thought states are dim columns at the ladder
  # bottom — researching carries the violet hue, considering is dim (muted). Before
  # the manifest grew them, role_color's catch-all muted BOTH and the board dropped
  # the columns entirely; now researching reaches the violet hex + ◎, considering ◌.
  test "task board renders the thought columns — researching in violet, considering dim" do
    board = %{
      "type" => "task-board",
      "snapshot" => [
        %{"status" => "considering", "title" => "Weigh it"},
        %{"status" => "researching", "title" => "Dig in"}
      ]
    }

    html = FleetEmail.task_board_email_html(board)

    # researching's column stripe + glyph carry the violet manifest hex
    assert html =~ "border-top:3px solid #{@violet}"
    assert html =~ "color:#{@violet}"
    assert @violet == "#7c3aed"

    # both thought glyphs render (◌ considering, ◎ researching), not the open circle
    assert html =~ "◌"
    assert html =~ "◎"
  end

  test "roadmap bars carry the status tone and DROP the today marker (D5)" do
    html = FleetEmail.roadmap_email_html(roadmap_block())

    assert html =~ "background:#{@done}"
    assert html =~ "background:#{@progress}"

    # the today marker is the one honest degradation: the `today` key is ignored,
    # so output is byte-identical with and without it.
    without = FleetEmail.roadmap_email_html(Map.delete(roadmap_block(), "today"))
    assert html == without
  end

  test "task detail shows the criteria checklist glyphs and evidence" do
    html = FleetEmail.task_detail_email_html(detail_block())

    assert html =~ "Criteria · 1/2"
    assert html =~ "gate green"
    # met criterion → done tone, unmet → ready (ink); both are real cells
    assert html =~ "color:#{@done}"
    assert html =~ "<table"
  end

  # ── compose dispatch: :article stays classed, every other style goes inline ──

  test "compose_block(:article) keeps the classed Components emitters" do
    for {block, marker} <- [
          {tasks_block(), "bp-tasks"},
          {detail_block(), "bp-tdetail"},
          {board_block(), "bp-board"},
          {roadmap_block(), "bp-roadmap"}
        ] do
      %{"kind" => "_raw", "html" => html} = Compose.compose_block(block, :article)
      assert html =~ ~s(class="#{marker})
    end
  end

  test "compose_block(:email) takes the inline-styled FleetEmail variants" do
    for block <- [tasks_block(), detail_block(), board_block(), roadmap_block()] do
      %{"kind" => "_raw", "html" => html} = Compose.compose_block(block, :email)
      assert html =~ "<table"
      refute html =~ ~s(class="bp-)
      refute html =~ "<svg"
    end

    # task-list is the accepted alias of tasks — same email emitter.
    %{"kind" => "_raw", "html" => alias_html} =
      Compose.compose_block(Map.put(tasks_block(), "type", "task-list"), :email)

    assert alias_html =~ "<table"
    refute alias_html =~ ~s(class="bp-)
  end

  # ── the theme-aware /3 seam moves bytes (charter D2) ─────────────────────────

  test "compose_block/3 threads the theme through the skin" do
    # ember paper (#fdfcfb) is the ember card surface; evergreen would be #ffffff
    %{"kind" => "_raw", "html" => tasks_ember} =
      Compose.compose_block(tasks_block(), :email, :ember)

    assert tasks_ember =~ "background:#fdfcfb"

    # ember page-bg (#f4ece9) paints the board column ground
    %{"kind" => "_raw", "html" => board_ember} =
      Compose.compose_block(board_block(), :email, :ember)

    assert board_ember =~ "background:#f4ece9"
    # status tones are theme-invariant (manifest, not skin)
    assert board_ember =~ "border-top:3px solid #{@done}"
  end

  # ── empty / malformed inputs degrade honestly ────────────────────────────────

  test "empty snapshots render an honest empty note, never a crash" do
    assert FleetEmail.tasks_email_html(%{"type" => "tasks", "snapshot" => []}) =~ "No tasks yet."
    assert FleetEmail.task_board_email_html(%{"type" => "task-board"}) =~ "No tasks yet."
    assert FleetEmail.roadmap_email_html(%{"type" => "roadmap"}) =~ "No roadmap items."
    assert FleetEmail.task_detail_email_html(%{"type" => "task-detail"}) == ""
    assert FleetEmail.tasks_email_html(nil) =~ "No tasks yet."
  end

  test "author strings are escaped" do
    html =
      FleetEmail.tasks_email_html(%{
        "type" => "tasks",
        "title" => "<script>",
        "snapshot" => [%{"status" => "open", "title" => "<b>x</b>"}]
      })

    refute html =~ "<script>"
    refute html =~ "<b>x</b>"
    assert html =~ "&lt;b&gt;x&lt;/b&gt;"
  end
end
