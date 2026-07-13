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
    test "there are at least five toolrow variants" do
      assert length(variants()) >= 5
    end

    test "all three chat block types are present across the variants" do
      types = variants() |> Enum.map(& &1["block"]["type"]) |> MapSet.new()
      required = ~w(chat-tool-diff chat-todo chat-thinking)

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
