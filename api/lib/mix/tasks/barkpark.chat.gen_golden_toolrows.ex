defmodule Mix.Tasks.Barkpark.Chat.GenGoldenToolrows do
  @moduledoc """
  Generate the cross-surface **chat tool/todo/thinking-row parity fixture** and
  write it to both mirror paths — the SIBLING of `gen_golden_transcript` for the
  three non-text chat rows that D13 explicitly scoped OUT of the reply-body
  harness (charter D25).

      mix barkpark.chat.gen_golden_toolrows

  ## Scope — the three dual-surface chat block types (Law 1)

  `chat-tool-diff`, `chat-todo`, `chat-thinking` are first-class PortableDoc block
  types (compose_block :article → `Components.chat_*_html/1`), rendered on BOTH
  the Studio/reader surface AND the Go TUI (`internal/chat`) from ONE typed block
  map. This fixture is the executable source of truth both surfaces agree on, so
  "identical" is a CI fact — the toolrow analog of the reply-body golden.

  ## Mechanism A — field/structural projection, never cross-engine byte-diff

  A HEEx string can never byte-equal an ANSI terminal string, so each variant
  carries FOUR fields (the sheets/preview 3-mirror pattern, plus the raw source):

    * `kind` — `tool-diff` | `todo` | `thinking` (which pure derivation applies);
    * `source` — the RAW row payload (tool input map, or thinking-token count) as
      persisted in a `chat_messages` row's `metadata`;
    * `block` — the EXACT `Components.chat_*_block(source)` output (never
      hand-typed — `build/0` derives it), the shared typed block JSON both
      surfaces consume; the freshness lock asserts `block == derive(source)`, so
      a diff/parse-derivation change shipped without regenerating reds HERE;
    * `projection` — a structural projection (`type` + the KEY TEXT the block must
      realize), the surface-neutral contract each renderer answers to in its OWN
      native form (Elixir article HEEx / Go ANSI).

  Every derivation is REUSED verbatim — `Barkpark.Papers.TextDiff.diff_lines/2`
  (the ONE line diff), `ChatToolRenderer.{classify,parse_todos,todo_glyph}`, and
  the "thought for ~N tokens" count label — so this fixture can never certify a
  row shape the live renderer would not produce.

  Emits pretty-printed JSON to two byte-identical mirrors:

    * `api/test/support/fixtures/chat_golden_toolrows.json`
    * `internal/pdrender/testdata/chat_golden_toolrows.json`

  Do NOT hand-edit either mirror — re-run this task and re-verify both surfaces.
  The Elixir freshness + projection lock lives in
  `test/barkpark/chat_golden_toolrows_parity_test.exs`; the Go leg
  (`ct-blk-tui-toolrows`) reads the SAME mirror.

  `build/0` is PURE (only the pure `Components`/`ChatToolRenderer`/`TextDiff`
  derivations; no app boot, no `Mix.Task`) so the freshness test regenerates
  in-memory.
  """
  @shortdoc "Regenerate the cross-surface chat tool/todo/thinking-row parity fixture (two mirrors)"

  use Mix.Task

  alias Barkpark.PortableDoc.Render.Components

  # ── the canonical toolrow variants ──────────────────────────────────────────
  #
  # Each variant is a RAW row source only. The `block`/`projection` are never
  # hand-typed — `build/0` runs the SAME pure derivation the live renderer + the
  # controller projection use, so the fixture is the derivation, not a snapshot.

  @edit_input %{
    "file_path" => "lib/barkpark/chat.ex",
    "old_string" => "def greet do\n  \"hi\"\nend",
    "new_string" => "def greet do\n  \"hello there\"\nend"
  }

  @write_input %{
    "file_path" => "lib/barkpark/new_mod.ex",
    "content" => "defmodule NewMod do\n  def run, do: :ok\nend"
  }

  @multi_edit_input %{
    "file_path" => "lib/barkpark/multi.ex",
    "edits" => [
      %{"old_string" => "alpha", "new_string" => "alpha_renamed"},
      %{"old_string" => "beta", "new_string" => "beta_renamed"}
    ]
  }

  # The ADJUDICATING budget variant (charter D40): three all-added hunks of 8
  # lines each — 24 drawable rows + 2 gap separators, BOTH gaps inside the first
  # 20 RAW elements (raw indices 8 and 17). The two fold readings therefore
  # disagree on the literal overflow number: drawable-only (the D40 ruling)
  # folds 4 rows ("+4 more lines"), a raw-element budget folds 6 ("+6 more
  # lines"). Every consumer asserts the NUMBER, so the non-ratified reading
  # cannot pass on word-presence alone. Each line is one distinct alnum token so
  # the projection's significant-word check bites per row.
  @budget_edit_lines %{
    "one" =>
      ~w(hunkalpha1 hunkalpha2 hunkalpha3 hunkalpha4 hunkalpha5 hunkalpha6 hunkalpha7 hunkalpha8),
    "two" =>
      ~w(hunkbravo1 hunkbravo2 hunkbravo3 hunkbravo4 hunkbravo5 hunkbravo6 hunkbravo7 hunkbravo8),
    "three" =>
      ~w(hunkcharlie1 hunkcharlie2 hunkcharlie3 hunkcharlie4 hunkcharlie5 hunkcharlie6 hunkcharlie7 hunkcharlie8)
  }

  @multi_edit_budget_input %{
    "file_path" => "lib/barkpark/budget.ex",
    "edits" => [
      %{"old_string" => "", "new_string" => Enum.join(@budget_edit_lines["one"], "\n")},
      %{"old_string" => "", "new_string" => Enum.join(@budget_edit_lines["two"], "\n")},
      %{"old_string" => "", "new_string" => Enum.join(@budget_edit_lines["three"], "\n")}
    ]
  }

  @todo_input %{
    "todos" => [
      %{"content" => "Wire the transport", "status" => "completed"},
      %{
        "content" => "Render the toolrows",
        "status" => "in_progress",
        "activeForm" => "Rendering the toolrows"
      },
      %{"content" => "Prove the parity gate", "status" => "pending"}
    ]
  }

  # The three INTERACTIVE cards (charter D35) — each variant's `source` is the RAW
  # row metadata the Recorder persists (`persist_approval_ask`: request_id,
  # tool_name, input, approval_status), so `build_block` runs the SAME read-time
  # synthesis the live controller projection uses. The block is the VISUAL only;
  # the answer path stays on the envelope (asserted on the TUI/Studio sides).
  @approval_meta %{
    "request_id" => "req-approval-1",
    "tool_name" => "Bash",
    "input" => %{"command" => "rm -rf build"},
    "approval_status" => "pending"
  }

  @question_meta %{
    "request_id" => "req-question-1",
    "tool_name" => "AskUserQuestion",
    "input" => %{
      "questions" => [
        %{
          "question" => "Which database should we target?",
          "options" => [
            %{"label" => "Postgres"},
            %{"label" => "SQLite"}
          ]
        }
      ]
    },
    "approval_status" => "pending"
  }

  @plan_meta %{
    "request_id" => "req-plan-1",
    "tool_name" => "ExitPlanMode",
    "input" => %{
      "plan" => "# Ship the parser\n\nRefactor the tokenizer, then add tests."
    },
    "approval_status" => "pending"
  }

  @variants [
    %{name: "edit_diff", kind: "tool-diff", source: @edit_input},
    %{name: "write_diff", kind: "tool-diff", source: @write_input},
    %{name: "multi_edit_diff", kind: "tool-diff", source: @multi_edit_input},
    %{name: "multi_edit_budget_diff", kind: "tool-diff", source: @multi_edit_budget_input},
    %{name: "todo_card", kind: "todo", source: @todo_input},
    %{name: "thinking_bout", kind: "thinking", source: 1280},
    %{name: "approval_card", kind: "approval", source: @approval_meta},
    %{name: "question_card", kind: "question", source: @question_meta},
    %{name: "plan_card", kind: "plan", source: @plan_meta}
  ]

  @comment "Generated by `mix barkpark.chat.gen_golden_toolrows` — DO NOT hand-edit. " <>
             "Cross-surface chat non-text-row parity lock (Elixir Components.chat_*_html/1 " <>
             "+ Go internal/chat + pdrender renderers). Six dual-surface PortableDoc block " <>
             "types: the inert rows (chat-tool-diff | chat-todo | chat-thinking, charter D25) " <>
             "plus the INTERACTIVE cards (chat-approval | chat-question | chat-plan, charter " <>
             "D35) — the D13-scoped toolrow rows (ct-bl-toolrow-renderers) the reply-body " <>
             "golden deliberately excludes. The blocks ARE the read-time synthesis " <>
             "(TextDiff.diff_lines/2 + parse_todos + token count + the card visuals) — the " <>
             "answer path stays on the message envelope (D35); regenerate, never edit."

  @scope "chat-tool-todo-thinking-rows"

  @api_path Path.expand("../../../test/support/fixtures/chat_golden_toolrows.json", __DIR__)
  @go_path Path.expand(
             "../../../../internal/pdrender/testdata/chat_golden_toolrows.json",
             __DIR__
           )

  @doc "The two mirror paths the fixture is written to (also read by the freshness test)."
  def mirror_paths, do: [@api_path, @go_path]

  @impl Mix.Task
  def run(_args) do
    json = Jason.encode!(build(), pretty: true) <> "\n"

    for path <- mirror_paths() do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, json)
      Mix.shell().info("wrote #{path}")
    end

    Mix.shell().info("gen_golden_toolrows: 2 mirror(s) written — re-verify both surfaces.")
  end

  @doc """
  Build the chat toolrow parity fixture data map (pure — the `Components`
  derivations over each variant's raw source; no app boot). The freshness test
  regenerates through this and asserts term-equality with the committed api
  mirror. Every term is JSON-safe (string keys, lists not tuples, `nil` → null)
  so a Jason encode → decode round-trip is the identity.
  """
  def build do
    variants =
      Enum.map(@variants, fn %{name: name, kind: kind, source: source} ->
        block = build_block(kind, source)

        %{
          "name" => name,
          "kind" => kind,
          "source" => source,
          "block" => block,
          "projection" => project_block(block)
        }
      end)

    %{
      "_comment" => @comment,
      "scope" => @scope,
      "variants" => variants
    }
  end

  @doc """
  Derive the typed block for a variant `kind` from its raw `source` — the ONE
  shared derivation the live renderer + controller projection also call. Public
  so the freshness test can re-derive without duplicating the dispatch.
  """
  def build_block("tool-diff", source), do: Components.chat_tool_diff_block(source)
  def build_block("todo", source), do: Components.chat_todo_block_from_input(source)
  def build_block("thinking", source), do: Components.chat_thinking_block(source)
  def build_block("approval", source), do: Components.chat_approval_block(source)
  def build_block("question", source), do: Components.chat_question_block(source)
  def build_block("plan", source), do: Components.chat_plan_block(source)

  # ── structural projection (derived from the REAL block, never hand-typed) ─────
  #
  # `type` + the surface-neutral KEY TEXT the block must realize on every surface.
  # Each renderer surfaces it in its own native form (HEEx run / ANSI run), so the
  # Go leg asserts realization by stripped-ANSI presence, not a byte-diff.

  # The shared fold budget — the sixth hand-synced copy of components.ex
  # `@chat_diff_budget` (chat_tool_renderer.ex @collapsed_budget, chat_blocks.go
  # chatDiffBudget, react + mobile CHAT_DIFF_BUDGET). The projection must be
  # BUDGET-AWARE (D40): terminal/mobile DISCARD the folded tail, so projecting a
  # word past the fold would false-red the Go leg (only the web keeps the tail
  # inside `<details>`).
  @chat_diff_budget 20

  defp project_block(%{"type" => "chat-tool-diff", "lines" => lines}) do
    drawable = Enum.reject(lines, &(&1["op"] == "gap"))

    # Key text confined to the first @chat_diff_budget DRAWABLE rows — exactly
    # what every surface draws — plus the literal overflow count each consumer
    # asserts as a NUMBER ("+4 more lines"), the fact that adjudicates the
    # drawable-only reading against a raw-element budget (D40).
    text =
      drawable
      |> Enum.take(@chat_diff_budget)
      |> Enum.map(& &1["text"])
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    %{
      "type" => "chat-tool-diff",
      "text" => text,
      "overflow" => max(length(drawable) - @chat_diff_budget, 0)
    }
  end

  defp project_block(%{"type" => "chat-todo", "todos" => todos}) do
    text =
      todos
      |> Enum.flat_map(fn t ->
        [t["content"], t["active_form"]]
      end)
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join(" ")

    %{"type" => "chat-todo", "text" => text}
  end

  defp project_block(%{"type" => "chat-thinking", "tokens" => tokens}) do
    %{"type" => "chat-thinking", "text" => "thought for ~#{tokens} tokens"}
  end

  # The three interactive cards project their read-time VISUAL text (the summary /
  # question prompts+options / plan title+lede) — the surface-neutral key text
  # both renderers must realize. The card's ANSWER path is NOT projected here (it
  # rides the envelope, D35); only the block's visual is a cross-surface fact.
  defp project_block(%{"type" => "chat-approval", "summary" => summary}) do
    %{"type" => "chat-approval", "text" => summary}
  end

  defp project_block(%{"type" => "chat-question", "questions" => questions}) do
    text =
      questions
      |> Enum.flat_map(fn q -> [q["question"] | q["options"] || []] end)
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join(" ")

    %{"type" => "chat-question", "text" => text}
  end

  defp project_block(%{"type" => "chat-plan", "title" => title, "preview" => preview}) do
    %{"type" => "chat-plan", "text" => String.trim("#{title} #{preview}")}
  end
end
