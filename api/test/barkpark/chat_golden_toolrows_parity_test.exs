defmodule Barkpark.ChatGoldenToolrowsParityTest do
  @moduledoc """
  Cross-surface **chat tool/todo/thinking-row** parity lock (charter D25,
  Mechanism A) — the Elixir leg. The SIBLING of the reply-body golden, covering
  exactly the three rows D13 scoped OUT of it.

  `chat-tool-diff`, `chat-todo`, `chat-thinking` are first-class PortableDoc block
  types rendered on BOTH the Studio/reader surface (`compose_block` :article →
  `Components.chat_*_html/1`) AND the Go TUI (`internal/chat`) from ONE typed
  block map. ONE fixture (`GenGoldenToolrows.build/0` itself, five variants)
  written to two byte-equal mirrors, asserted here as:

    * the **freshness lock** — the committed api mirror equals a fresh `build/0`
      and the two mirrors decode term-identical (a `TextDiff`/`parse_todos`
      derivation change shipped without regenerating reds HERE, not silently on
      the TUI);
    * the **block round-trip** — per variant, `build_block(kind, source)` equals
      the committed `block` (the shared JSON both surfaces consume);
    * the **projection floor** — all three block types present, projection type
      sequence mirrors the block type;
    * the **HEEx-leg realization** — `render_component/2` over the REAL article
      render path (`Render.render_blocks/2`) realizes every projection's key text
      with ZERO `bp-unknown-block` fallback (the compose clauses exist);
    * the **controller-projection shape** — `ChatController.message_json/1` on a
      hand-built `chat_messages` row emits the typed block map the Go half decodes
      (plain ExUnit, no ConnCase — the ListenController seam convention).

  The Go leg — `internal/chat` realizes the same projection with zero unknown-block
  fallback — is `ct-blk-tui-toolrows`; it reads the SAME mirror.

  Regenerate with `mix barkpark.chat.gen_golden_toolrows` whenever the freshness
  lock reds.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.StudioChat.Message
  alias BarkparkWeb.ChatController
  alias Mix.Tasks.Barkpark.Chat.GenGoldenToolrows

  # A minimal function component that renders a block through the EXACT article
  # path the Studio chat rows now use, so `render_component/2` exercises the real
  # compose_block :article → Components emitter pipeline (draft_diff_test style).
  defmodule ArticleComponent do
    use Phoenix.Component

    attr :block, :map, required: true

    def article(assigns) do
      ~H"{Phoenix.HTML.raw(Barkpark.PortableDoc.Render.render_blocks([@block], %{style: :article}))}"
    end
  end

  @api_path Path.expand("../support/fixtures/chat_golden_toolrows.json", __DIR__)
  @go_path Path.expand(
             "../../../internal/pdrender/testdata/chat_golden_toolrows.json",
             __DIR__
           )

  defp decode!(path), do: path |> File.read!() |> Jason.decode!()

  defp fixture, do: decode!(@api_path)
  defp variants, do: fixture()["variants"]

  defp render_article(block),
    do: render_component(&ArticleComponent.article/1, %{block: block})

  # ── freshness lock ──────────────────────────────────────────────────────────

  describe "fixture freshness lock" do
    test "committed api mirror equals a fresh regeneration (build/0)" do
      assert decode!(@api_path) == GenGoldenToolrows.build(),
             "chat_golden_toolrows.json is stale — run " <>
               "`mix barkpark.chat.gen_golden_toolrows` and re-verify both surfaces."
    end

    test "the two mirrors decode term-identical" do
      assert decode!(@api_path) == decode!(@go_path),
             "the Go mirror drifted — run `mix barkpark.chat.gen_golden_toolrows`."
    end

    test "the mirror paths the generator writes match the paths this test reads" do
      assert GenGoldenToolrows.mirror_paths() == [@api_path, @go_path]
    end

    test "the fixture is toolrow-scoped and names its Go sibling slice" do
      f = fixture()
      assert f["scope"] == "chat-tool-todo-thinking-rows"

      assert f["_comment"] =~ "ct-bl-toolrow-renderers",
             "the fixture must state it covers exactly the D13-scoped toolrows."
    end
  end

  # ── the block round-trip (the shared JSON IS the derivation) ─────────────────

  describe "block round-trip (Components.chat_*_block)" do
    test "every variant's committed block equals a fresh derivation from its source" do
      for v <- variants() do
        assert GenGoldenToolrows.build_block(v["kind"], v["source"]) == v["block"],
               "variant #{inspect(v["name"])}: committed block drifted from the pure " <>
                 "derivation — regenerate the fixture."
      end
    end

    test "each projection's type mirrors its block's type" do
      for v <- variants() do
        assert v["projection"]["type"] == v["block"]["type"],
               "variant #{inspect(v["name"])}: projection type diverged from the block."
      end
    end
  end

  # ── the projection floor (a gutted regen reds here) ─────────────────────────

  describe "projection coverage floor" do
    test "there are at least eight toolrow variants" do
      assert length(variants()) >= 8
    end

    test "all six chat block types are present across the variants" do
      types = variants() |> Enum.map(& &1["block"]["type"]) |> MapSet.new()

      required =
        ~w(chat-tool-diff chat-todo chat-thinking chat-approval chat-question chat-plan)

      for t <- required do
        assert MapSet.member?(types, t),
               "block type #{inspect(t)} is missing — regen dropped coverage."
      end
    end

    test "a diff variant carries at least one added and one removed line" do
      edit = Enum.find(variants(), &(&1["name"] == "edit_diff"))
      block = edit["block"]

      assert block["added"] >= 1 and block["removed"] >= 1,
             "the edit diff must carry a real +/− hunk, not a degenerate all-add."
    end

    test "the multi-edit variant carries a gap separator between hunks" do
      multi = Enum.find(variants(), &(&1["name"] == "multi_edit_diff"))
      ops = multi["block"]["lines"] |> Enum.map(& &1["op"])

      assert "gap" in ops,
             "multi-edit hunks must be gap-separated (ChatToolRenderer parity)."
    end

    test "the budget variant has the exact geometry that adjudicates the fold (D40)" do
      budget = Enum.find(variants(), &(&1["name"] == "multi_edit_budget_diff"))
      assert budget, "the adjudicating budget variant is missing — regen shed the D40 lock."

      ops = budget["block"]["lines"] |> Enum.map(& &1["op"])
      drawable = Enum.count(ops, &(&1 != "gap"))

      gap_idx =
        ops
        |> Enum.with_index()
        |> Enum.filter(fn {op, _i} -> op == "gap" end)
        |> Enum.map(fn {_op, i} -> i end)

      # 24 drawable rows + 2 gaps, BOTH gaps inside the first 20 RAW elements —
      # the exact geometry on which the two fold readings disagree: drawable-only
      # (the ruling) folds 4 rows, a raw-element budget would fold 6.
      assert drawable == 24
      assert length(ops) == 26
      assert length(gap_idx) == 2 and Enum.all?(gap_idx, &(&1 < 20))
      assert budget["projection"]["overflow"] == 4
    end

    test "every diff projection carries the budget-aware overflow field" do
      for v <- variants(), v["kind"] == "tool-diff" do
        assert is_integer(v["projection"]["overflow"]) and v["projection"]["overflow"] >= 0,
               "variant #{inspect(v["name"])}: chat-tool-diff projections must carry " <>
                 "the drawable-only overflow count (D40)."
      end
    end

    test "the todo variant carries all three statuses" do
      todo = Enum.find(variants(), &(&1["name"] == "todo_card"))
      statuses = todo["block"]["todos"] |> Enum.map(& &1["status"]) |> MapSet.new()

      for s <- ~w(pending in_progress completed) do
        assert MapSet.member?(statuses, s), "todo status #{inspect(s)} missing."
      end
    end

    test "every projection entry carries non-empty key text" do
      for v <- variants() do
        text = v["projection"]["text"]

        assert is_binary(text) and text != "",
               "variant #{inspect(v["name"])}: empty projection text."
      end
    end
  end

  # ── the HEEx leg realizes the projection (render_component/2) ────────────────

  describe "GUI/reader render (compose_block :article → Components)" do
    test "every block renders through the real article path with NO unknown-block fallback" do
      for v <- variants() do
        html = render_article(v["block"])

        refute html =~ "bp-unknown-block",
               "variant #{inspect(v["name"])}: compose_block has no clause — " <>
                 "the block degraded to the unknown-block placeholder."
      end
    end

    test "each rendered block realizes its projection key text" do
      for v <- variants() do
        html = render_article(v["block"])

        # The projection text is surface-NEUTRAL (the Go leg asserts raw stripped
        # ANSI); the HEEx leg HTML-escapes it at walk time, so escape each word
        # before matching (a `"` in a diff line lands as `&quot;`).
        for word <- String.split(v["projection"]["text"], " ", trim: true) do
          escaped = Barkpark.PortableDoc.Render.escape_html(word)

          assert html =~ escaped,
                 "variant #{inspect(v["name"])}: article render is missing projected text " <>
                   inspect(word)
        end
      end
    end

    test "the tool-diff render carries the terminal +/− chrome" do
      edit = Enum.find(variants(), &(&1["name"] == "edit_diff"))
      html = render_article(edit["block"])

      assert html =~ "bp-chat-tool-diff"
      assert html =~ "var(--ok)"
      assert html =~ "var(--danger)"
    end

    test "the budget variant folds at the drawable-only number — +4, never the raw +6 (D40)" do
      budget = Enum.find(variants(), &(&1["name"] == "multi_edit_budget_diff"))
      html = render_article(budget["block"])

      # The literal NUMBER adjudicates: word-presence is blind to it — a
      # raw-element budget would honestly claim "+6 more lines" here.
      assert html =~ "… +4 more lines"
      refute html =~ "+6 more lines"

      # The web surface KEEPS the folded tail behind <details> — parity with
      # the terminal/mobile discard is the budget arithmetic, never the DOM.
      assert html =~ "<details>"
      assert html =~ "hunkcharlie8"
    end

    test "ChatToolRenderer.tool_diff (the Studio live surface) folds at the same drawable row" do
      edits =
        for hunk <- ["alpha", "bravo", "charlie"] do
          %{"old_string" => "", "new_string" => Enum.map_join(1..8, "\n", &"live#{hunk}#{&1}")}
        end

      html =
        render_component(
          &BarkparkWeb.Studio.ChatToolRenderer.tool_diff/1,
          %{input: %{"file_path" => "lib/live.ex", "edits" => edits}}
        )

      assert html =~ "+4 more lines"
      refute html =~ "+6 more lines"
      # The 20th drawable row stays in the summary; the 21st folds.
      assert html =~ "livecharlie4"
      assert html =~ "livecharlie5"
    end

    test "the todo render carries the ☐/◐/☒ checklist glyphs and progress read" do
      todo = Enum.find(variants(), &(&1["name"] == "todo_card"))
      html = render_article(todo["block"])

      assert html =~ "Update todos"
      assert html =~ "1/3 done"
      assert html =~ "☒" and html =~ "◐" and html =~ "☐"
    end

    test "the thinking render is the dim ✻ count row" do
      thinking = Enum.find(variants(), &(&1["name"] == "thinking_bout"))
      html = render_article(thinking["block"])

      assert html =~ "✻"
      assert html =~ "thought for ~1280 tokens"
    end

    test "the approval render is a read-only card with tool + preview + status" do
      approval = Enum.find(variants(), &(&1["name"] == "approval_card"))
      html = render_article(approval["block"])

      assert html =~ "bp-chat-approval"
      assert html =~ "Allow Bash?"
      assert html =~ "command:"
      assert html =~ "pending"
      # D35: the read-only card carries NO answer control (that rides the envelope).
      refute html =~ "phx-click"
    end

    test "the question render lists the prompt and its option chips" do
      question = Enum.find(variants(), &(&1["name"] == "question_card"))
      html = render_article(question["block"])

      assert html =~ "bp-chat-question"
      assert html =~ "Which database should we target?"
      assert html =~ "Postgres" and html =~ "SQLite"
      refute html =~ "phx-click"
    end

    test "the plan render is the title + clamped lede" do
      plan = Enum.find(variants(), &(&1["name"] == "plan_card"))
      html = render_article(plan["block"])

      assert html =~ "bp-chat-plan"
      assert html =~ "Ship the parser"
      assert html =~ "Refactor the tokenizer"
      refute html =~ "phx-click"
    end
  end

  # ── the controller projection emits the typed blocks the Go half decodes ─────

  describe "ChatController.message_json/1 toolrow projection" do
    defp row(role, metadata),
      do: %Message{seq: 7, role: role, source_markdown: nil, metadata: metadata}

    test "a file-mutating tool row projects a one-element chat-tool-diff block" do
      input = %{
        "file_path" => "x.ex",
        "old_string" => "a",
        "new_string" => "b"
      }

      json = ChatController.message_json(row("tool", %{"input" => input, "tool" => "Edit"}))

      assert [%{"type" => "chat-tool-diff"} = block] = json.blocks
      assert block["input"] == input
      assert is_list(block["lines"]) and block["lines"] != []
    end

    test "a non-diff tool row projects NO blocks (the generic ⎿ row stands alone)" do
      json = ChatController.message_json(row("tool", %{"input" => %{"pattern" => "foo"}}))
      refute Map.has_key?(json, :blocks)
    end

    test "a todo row projects a chat-todo block from its metadata input" do
      input = %{"todos" => [%{"content" => "Ship it", "status" => "pending"}]}
      json = ChatController.message_json(row("todo", %{"input" => input}))

      assert [%{"type" => "chat-todo", "todos" => [%{"content" => "Ship it"}]}] = json.blocks
    end

    test "a thinking row projects a chat-thinking block from its token count" do
      json = ChatController.message_json(row("thinking", %{"tokens" => 42}))
      assert [%{"type" => "chat-thinking", "tokens" => 42}] = json.blocks
    end

    test "a thinking row with no persisted count projects no blocks" do
      json = ChatController.message_json(row("thinking", %{}))
      refute Map.has_key?(json, :blocks)
    end

    test "an approval row projects a chat-approval block from its metadata (D35)" do
      meta = %{
        "request_id" => "req-1",
        "tool_name" => "Bash",
        "input" => %{"command" => "ls"},
        "approval_status" => "pending"
      }

      json = ChatController.message_json(row("approval", meta))

      assert [%{"type" => "chat-approval", "tool_name" => "Bash"} = block] = json.blocks
      assert block["approval_status"] == "pending"
      # The ENVELOPE still carries the answer state — answerability is NOT on the
      # block (D35): the metadata request_id/approval_status must survive.
      assert json.metadata["request_id"] == "req-1"
      assert json.metadata["approval_status"] == "pending"
    end

    test "a question row projects a chat-question block carrying its prompts" do
      meta = %{
        "request_id" => "req-2",
        "tool_name" => "AskUserQuestion",
        "input" => %{"questions" => [%{"question" => "Ship it?", "options" => ["yes"]}]},
        "approval_status" => "pending"
      }

      json = ChatController.message_json(row("question", meta))

      assert [%{"type" => "chat-question", "questions" => [q]}] = json.blocks
      assert q["question"] == "Ship it?"
      assert q["options"] == ["yes"]
    end

    test "a plan row projects a chat-plan block with the first heading as title" do
      meta = %{
        "request_id" => "req-3",
        "tool_name" => "ExitPlanMode",
        "input" => %{"plan" => "# Do the thing\n\nStep one."},
        "approval_status" => "allowed"
      }

      json = ChatController.message_json(row("plan", meta))

      assert [%{"type" => "chat-plan", "title" => "Do the thing"} = block] = json.blocks
      assert block["approval_status"] == "allowed"
    end

    test "an assistant row still projects reply-body blocks (D8 preserved)" do
      json =
        ChatController.message_json(%Message{
          seq: 1,
          role: "assistant",
          source_markdown: "# Title\n\nbody",
          metadata: %{}
        })

      assert is_list(json.blocks) and json.blocks != []
      assert Enum.any?(json.blocks, &(&1["type"] == "heading"))
    end
  end
end
