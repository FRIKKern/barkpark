defmodule BarkparkWeb.Studio.ChatTurnFilesChangedTest do
  @moduledoc """
  THE PER-TURN FILES-CHANGED AGGREGATE (task-eb3a6938ecc8576c).

  U1 (task-8f904a88b9bc3d59) folds a settled turn under one header. This suite
  owns what that header SAYS about the turn's effect on the tree: one entry per
  mutated PATH, in first-touch order, carrying the turn's TOTAL +/- for it.

  Two halves:

    * the DERIVATION — `ChatToolRenderer.files_changed/1`, which walks the SAME
      `classify/1` shape dispatch and the SAME `Barkpark.Papers.TextDiff` engine
      the per-row diffs already use. No second parse, no second diff engine.
    * the STUDIO — a reopened session's fold header carries the summary, expands
      to the per-path list, and a turn that mutated NOTHING draws neither.

  The mutation reds by NAME:

    SAME-PATH MERGE — "three edits of ONE file are ONE entry whose counts sum".
                      Drop the `Map.fetch/2` merge branch in `tally_row/2` (emit
                      one entry per call) and this reds: 3 entries, last-write
                      counts. The numbers are ASYMMETRIC per edit so a wrong
                      reducer cannot coincidentally match the sum.
    GENERIC GATE    — "a non-mutating call contributes no path". Count `:generic`
                      as a changed file and this reds: the Bash/Read rows join
                      the list.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias BarkparkWeb.Studio.ChatToolRenderer

  @admin_token "chat-files-changed-admin-token"
  @settled_at "2026-09-02T10:03:12.000000Z"

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "files-changed admin", "production", [
        "read",
        "write",
        "admin"
      ])

    # The chat route needs a provider enabled. `cat` echoes our own NDJSON back
    # and NOTHING here ever sends — every turn in this suite is persisted
    # directly and replayed, so no subprocess is spawned at all.
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
  end

  # ── row builders (the transcript shape the renderer actually receives) ──────

  defp edit_row(path, old, new),
    do: %{input: %{"file_path" => path, "old_string" => old, "new_string" => new}}

  defp write_row(path, content), do: %{input: %{"file_path" => path, "content" => content}}
  defp generic_row(command), do: %{input: %{"command" => command}}

  # ── the derivation ─────────────────────────────────────────────────────────

  describe "files_changed/1 — one entry per mutated path, first-touch order" do
    test "an edit, a write and a non-mutating call list exactly the TWO mutated paths, once each" do
      rows = [
        edit_row("lib/a.ex", "one\ntwo\n", "one\nTWO\n"),
        generic_row("mix test"),
        write_row("lib/b.ex", "alpha\nbeta\n"),
        generic_row("cat lib/a.ex")
      ]

      assert [%{path: "lib/a.ex"}, %{path: "lib/b.ex"}] =
               ChatToolRenderer.files_changed(rows)

      # The generic rows contributed NO path at all — not an entry with zeroes.
      assert length(ChatToolRenderer.files_changed(rows)) == 2
    end

    test "first-touch order is the turn's order, not alphabetical and not last-touch" do
      rows = [
        write_row("z_first.ex", "z\n"),
        write_row("a_second.ex", "a\n"),
        # A re-touch of the FIRST path must not move it to the end.
        edit_row("z_first.ex", "z\n", "zz\n")
      ]

      assert ["z_first.ex", "a_second.ex"] =
               ChatToolRenderer.files_changed(rows) |> Enum.map(& &1.path)
    end

    test "a turn that mutated nothing aggregates to the empty list" do
      assert ChatToolRenderer.files_changed([generic_row("ls"), generic_row("grep x")]) == []
      assert ChatToolRenderer.files_changed([]) == []
    end

    test "the counts ARE the TextDiff lines the row already renders — no second engine" do
      # one line replaced: +1 / -1; the unchanged line is context, counted neither way.
      [entry] =
        ChatToolRenderer.files_changed([edit_row("lib/a.ex", "keep\nold\n", "keep\nnew\n")])

      assert entry == %{path: "lib/a.ex", added: 1, removed: 1}

      # a Write is a pure addition: every content line is `+`, nothing removed.
      [w] = ChatToolRenderer.files_changed([write_row("lib/new.ex", "one\ntwo\nthree\n")])
      assert w == %{path: "lib/new.ex", added: 3, removed: 0}
    end
  end

  describe "files_changed/1 — the same path twice is ONE entry with SUMMED counts" do
    test "three edits of one file sum to one entry (asymmetric per-edit numbers)" do
      # Per-edit ledger, deliberately asymmetric so no wrong reducer can match:
      #   edit 1: +1 / -1     (one line swapped)
      #   edit 2: +3 / -0     (three lines appended)
      #   edit 3: +0 / -2     (two lines deleted)
      # SUM = +4 / -3. Last-write would read +0/-2; first-write +1/-1;
      # max would read +3/-2 — every wrong reducer lands somewhere else.
      rows = [
        edit_row("lib/same.ex", "a\n", "A\n"),
        edit_row("lib/same.ex", "keep\n", "keep\nx\ny\nz\n"),
        edit_row("lib/same.ex", "keep\np\nq\n", "keep\n")
      ]

      assert [%{path: "lib/same.ex", added: 4, removed: 3}] =
               ChatToolRenderer.files_changed(rows)
    end

    test "summing is per path — a second file keeps its own totals" do
      rows = [
        edit_row("lib/one.ex", "a\n", "A\n"),
        edit_row("lib/two.ex", "b\nc\n", "B\nC\n"),
        edit_row("lib/one.ex", "keep\n", "keep\nx\ny\nz\n")
      ]

      assert [
               %{path: "lib/one.ex", added: 4, removed: 1},
               %{path: "lib/two.ex", added: 2, removed: 2}
             ] = ChatToolRenderer.files_changed(rows)
    end
  end

  describe "files_changed_label/1" do
    test "singular for one path, plural for many" do
      assert ChatToolRenderer.files_changed_label([%{path: "a", added: 1, removed: 0}]) ==
               "1 file changed"

      assert ChatToolRenderer.files_changed_label([
               %{path: "a", added: 1, removed: 0},
               %{path: "b", added: 1, removed: 0}
             ]) == "2 files changed"
    end
  end

  # ── the Studio surface ─────────────────────────────────────────────────────
  #
  # Rows are persisted with the SERVER settle stamp and the session reopened,
  # which is the fold's replay path (no subprocess, no fake runtime needed).

  defp settled_session(rows) do
    id = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})

    for {tuid, tool, input} <- rows do
      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "tool",
          source_markdown: "#{tool} — #{tuid}",
          metadata: %{
            "tool" => tool,
            "tool_use_id" => tuid,
            "input" => input,
            "output" => "done",
            "turn_settled" => true,
            "turn_settled_at" => @settled_at,
            "turn_duration_ms" => 192_000,
            "turn_outcome" => "settled"
          }
        })
    end

    id
  end

  describe "the settled turn's fold header (three states)" do
    test "FILES: the header carries the summary", %{conn: conn} do
      id =
        settled_session([
          {"fc-edit", "Edit",
           %{"file_path" => "lib/alpha.ex", "old_string" => "a\n", "new_string" => "A\n"}},
          {"fc-write", "Write", %{"file_path" => "lib/beta.ex", "content" => "one\ntwo\n"}}
        ])

      {:ok, _view, html} = live(conn, "/studio/chat/#{id}")

      assert html =~ "Worked for 3m 12s"
      assert html =~ "data-turn-files-changed"
      assert html =~ "2 files changed"
      # COLLAPSED: the summary is the header's, the per-path list is behind it.
      refute html =~ ~s(data-role="turn-files-changed")
      refute html =~ "data-turn-file="
    end

    test "NO FILES: a read-only turn renders no summary and no empty container",
         %{conn: conn} do
      id =
        settled_session([
          {"fc-bash", "Bash", %{"command" => "mix test"}},
          {"fc-read", "Read", %{"file_path" => "lib/alpha.ex", "offset" => 1}}
        ])

      {:ok, view, html} = live(conn, "/studio/chat/#{id}")

      assert html =~ "Worked for 3m 12s"
      refute html =~ "data-turn-files-changed"
      refute html =~ "files changed"
      refute html =~ ~s(data-role="turn-files-changed")

      # And still nothing once expanded — no empty container waiting inside.
      opened = view |> element("[data-turn-fold-toggle]") |> render_click()
      refute opened =~ ~s(data-role="turn-files-changed")
      refute opened =~ "files changed"
    end

    test "EXPAND: the summary expands to the per-path list with per-path totals",
         %{conn: conn} do
      id =
        settled_session([
          {"fc-e1", "Edit",
           %{"file_path" => "lib/alpha.ex", "old_string" => "a\n", "new_string" => "A\n"}},
          {"fc-bash", "Bash", %{"command" => "mix format"}},
          {"fc-e2", "Edit",
           %{
             "file_path" => "lib/alpha.ex",
             "old_string" => "keep\n",
             "new_string" => "keep\nx\ny\nz\n"
           }},
          {"fc-w", "Write", %{"file_path" => "lib/beta.ex", "content" => "one\ntwo\n"}}
        ])

      {:ok, view, _html} = live(conn, "/studio/chat/#{id}")

      opened = view |> element("[data-turn-fold-toggle]") |> render_click()

      assert opened =~ ~s(data-role="turn-files-changed")
      assert opened =~ "2 files changed"
      assert opened =~ ~s(data-turn-file="lib/alpha.ex")
      assert opened =~ ~s(data-turn-file="lib/beta.ex")

      # ONE row for lib/alpha.ex even though two Edits touched it, and its
      # counts are the SUM (+1/-1 then +3/-0 = +4/-1).
      assert length(String.split(opened, ~s(data-turn-file="lib/alpha.ex"))) == 2

      alpha = opened |> String.split(~s(data-turn-file="lib/alpha.ex")) |> Enum.at(1)
      assert alpha =~ "+4"
      assert alpha =~ "−1"

      # Exactly TWO per-path rows: the Bash call contributed no path.
      assert length(String.split(opened, "data-turn-file=")) == 3
    end

    test "a LIVE (unsettled) turn has no fold and therefore no files summary",
         %{conn: conn} do
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})

      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "tool",
          source_markdown: "Edit — live",
          metadata: %{
            "tool" => "Edit",
            "tool_use_id" => "fc-live",
            "input" => %{
              "file_path" => "lib/live.ex",
              "old_string" => "a\n",
              "new_string" => "A\n"
            }
          }
        })

      {:ok, _view, html} = live(conn, "/studio/chat/#{id}")

      refute html =~ ~s(data-role="turn-fold")
      refute html =~ "files changed"
    end
  end
end
