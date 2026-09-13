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

  # ── the cancel lane (task-881952f8d8417f4b) ─────────────────────────────────
  #
  # THE FIFTH SURFACE. The row named four board surfaces; the derived set is five
  # — this email board holds its OWN `board_roles/0` and DROPPED cancelled rows
  # exactly as the article board did, with the same no-symptom failure: a fleet
  # digest mailed out with abandoned work simply absent, indistinguishable from an
  # epic that has none.
  #
  # FAIL-BEFORE (c1): with `board_roles/0` reverted to origin/main's
  # `~w(open ready progress blocked done considering researching)`, the "Abandoned
  # spike" assertion reds — the cell is not emitted at all.
  test "task board renders a cancelled row in its own cell, LAST, with the ✕ glyph" do
    board = %{
      "type" => "task-board",
      "snapshot" => [
        %{"status" => "ready", "title" => "Claim me"},
        %{"status" => "cancelled", "title" => "Abandoned spike"},
        %{"status" => "done", "title" => "Shipped"}
      ]
    }

    html = FleetEmail.task_board_email_html(board)

    # NEVER DROPPED: the row and its lane label reach the email.
    assert html =~ "Abandoned spike"
    assert html =~ "Cancelled"
    # The manifest's ✕, through the shared glyph seam.
    assert html =~ StatusVocab.glyph_for_role("cancel")
    assert StatusVocab.glyph_for_role("cancel") == "✕"

    # NEVER HOMED IN `open`: no open row in the snapshot, so an Open cell would
    # BE the misfile.
    refute html =~ ">Open<"

    # LAST: the cancelled cell follows the live ones.
    cancel_at = :binary.match(html, "Abandoned spike") |> elem(0)

    for live <- ["Claim me", "Shipped"] do
      assert :binary.match(html, live) |> elem(0) < cancel_at,
             "#{live} renders AFTER the cancelled cell — cancel must be LAST"
    end

    # DE-EMPHASISED: the terminal cell takes the muted stripe, not a live tone.
    refute html =~ "border-top:3px solid #{@violet}"
  end

  # c2 on this surface: the `open` cell holds ONLY claimable rows. Every manifest
  # rung has a cell of its own, so nothing falls back into the lane `bp task ready`
  # serves. Measured on the CELL COUNTS, which are what a fallback moves: one row
  # per rung in, so every non-empty cell must report exactly 1. Homing cancelled
  # rows in `open` makes Open read 2 and deletes the Cancelled cell, and this reds
  # on both.
  test "task board's open cell holds only claimable rows" do
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
      FleetEmail.task_board_email_html(%{
        "type" => "task-board",
        "snapshot" => Enum.map(statuses, fn s -> %{"status" => s, "title" => "row-" <> s} end)
      })

    for role <- StatusVocab.board_roles() do
      label = role |> StatusVocab.label_for_role() |> String.capitalize()

      assert html =~ ~s(>#{label}</b> 1),
             "the #{label} cell must hold exactly its OWN row; a count other than 1 means " <>
               "a row was misfiled into it (or its own row was dropped)"
    end

    # PRECONDITION/CONTROL: a count of 2 is what a misfile looks like, and nothing
    # in this render produces one.
    refute html =~ "</b> 2"
  end

  # c3 — the DERIVATION LOCK on this surface: the email board resolves its lane
  # order through the SAME StatusVocab.board_roles/0 the article board does, so the
  # two cannot diverge and neither can drop a rung. MUTATION: retype the list beside
  # the manifest and this reds naming the rung with no cell.
  test "every manifest rung is an email board cell, terminal cancel LAST" do
    html =
      FleetEmail.task_board_email_html(%{
        "type" => "task-board",
        "snapshot" =>
          Enum.map(StatusVocab.board_roles(), fn role ->
            status =
              StatusVocab.statuses() |> Enum.find_value(fn {st, r} -> if r == role, do: st end)

            %{"status" => status, "title" => "row-" <> role}
          end)
      })

    for role <- StatusVocab.roles() do
      assert html =~ "row-" <> role,
             "manifest rung #{inspect(role)} has NO email board cell — its rows are silently dropped"
    end

    # LAST: the terminal rung's cell trails every other rung's.
    cancel_at = :binary.match(html, "row-cancel") |> elem(0)

    for role <- StatusVocab.roles() -- ["cancel"] do
      assert :binary.match(html, "row-" <> role) |> elem(0) < cancel_at,
             "the #{role} cell renders AFTER the cancel cell — cancel must be LAST"
    end
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
