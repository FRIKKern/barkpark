defmodule BarkparkWeb.Studio.ChatToolRenderer do
  @moduledoc """
  Renders a Studio-chat tool-call row the way the Claude Code terminal does:
  file-mutating tool calls become real colored line diffs (`+` added, `-`
  removed, unchanged context dim) beneath the `●` tool header.

  ## Dispatch on SHAPE, never on tool NAME

  The tool name is host-binary-dependent — the cmux fork emits `Agent` where
  vanilla Claude Code emits `Task`, and lacks `TodoWrite`/`MultiEdit` entirely.
  So `classify/1` keys on the INPUT MAP's shape (wire-proven on v2.1.205):

    * `%{"file_path", "old_string", "new_string"}`  → `:edit`  (line diff)
    * `%{"file_path", "content"}`                    → `:write` (all-added)
    * `%{"file_path", "edits" => [_ | _]}`           → `:multi_edit` (stacked
      hunks, defensive — unverified on this host)
    * anything else                                   → `:generic` (no diff;
      the caller keeps the existing `●`/`⎿` row)

  A tool renamed by the host binary but carrying an Edit-shaped input STILL
  renders a diff — the whole point of shape dispatch.

  ## One diff engine

  Diffs come from `Barkpark.Papers.TextDiff.diff_lines/2` (DP-LCS, `op ∈ =/+/-`
  per line). We never add a second Myers/diff engine (capability-dup). Chrome is
  emitted design tokens only (`--ok`/`--ok-soft` add, `--danger`/`--danger-soft`
  removed) so `scripts/studio-literal-check.sh` stays green.

  ## Honest truncation is a RENDER concern only

  A diff over `@collapsed_budget` DRAWABLE lines (gap separators never spend
  budget — charter D40) collapses behind a `<details>` (exactly like the
  existing `⎿` output block): the first 20 drawable lines stay in the summary
  with an accurate `+N more lines` (drawable rows only), the rest reveals on
  expand. Persistence
  (recorder.ex) keeps the FULL input verbatim, so a reopened session replays the
  identical diff — truncation never touches the store.

  ## TodoWrite living checklist (charter D39)

  A TodoWrite-shaped call renders as ONE ☐/◐/☒ card that updates in place
  across a turn: the Recorder collapses every TodoWrite of a turn into one
  persisted row and the ChatLive reducer supersedes the in-memory card, so both
  live and replay reach `todo_card/1` with the turn's LATEST list. Tolerant of
  the modern `{content, status, activeForm}` and legacy
  `{content, status, priority, id}` item shapes.

  ## Task / agent spawns (charter D40)

  A sub-agent SPAWN is any `tool_use` that is named `Task`/`Agent` OR carries
  the `{description, prompt, subagent_type}` input shape under any name. The
  spawn row draws the `description` prominent; every frame the sub-agent emits
  carries a top-level `parent_tool_use_id` equal to the spawn's id, and those
  child rows render INDENTED beneath it, live and on replay.
  """
  use Phoenix.Component

  alias Barkpark.Chat.ToolRows
  alias Barkpark.Papers.TextDiff

  # Lines shown before a diff collapses behind a details/summary. The terminal
  # shows a compact hunk; anything larger folds with an honest overflow count.
  @collapsed_budget 20

  @doc """
  Classify a tool-call input map by SHAPE — thin delegation to the core
  `Barkpark.Chat.ToolRows.classify/1` (the pure derivation lives in core so this
  web module no longer owns it; every caller stays unchanged).
  """
  @spec classify(map() | any()) :: :edit | :write | :multi_edit | :generic
  defdelegate classify(input), to: ToolRows

  @doc "True when the input is a file-mutation shape we render as a diff (core delegation)."
  @spec diff?(map() | any()) :: boolean()
  defdelegate diff?(input), to: ToolRows

  @doc """
  Render the diff for a diff-shaped tool input. A non-diff shape (or an input
  that produces no diff lines) renders nothing — the caller's generic `●`/`⎿`
  row already stands on its own.
  """
  attr :input, :map, required: true

  def tool_diff(assigns) do
    lines = build_lines(assigns.input)
    drawable = Enum.count(lines, &(&1.op != "gap"))
    {head, rest} = budget_split(lines)

    assigns =
      assign(assigns,
        head: head,
        rest: rest,
        added: Enum.count(lines, &(&1.op == "+")),
        removed: Enum.count(lines, &(&1.op == "-")),
        overflow: max(drawable - @collapsed_budget, 0),
        over?: drawable > @collapsed_budget,
        empty?: lines == []
      )

    ~H"""
    <div
      :if={not @empty?}
      class="text-xs"
      style="font-family: var(--font-mono); margin: 4px 0 0 16px; background: var(--muted-surface); border-radius: 6px; padding: 6px 8px; overflow-x: auto; line-height: 1.5;"
    >
      <div class="text-dim" style="font-size: 11px; margin-bottom: 4px;">
        <span style="color: var(--ok);">+<%= @added %></span>
        <span style="color: var(--danger);">−<%= @removed %></span>
      </div>
      <%= if @over? do %>
        <details>
          <summary style="cursor: pointer; list-style: none;">
            <.diff_rows lines={@head} />
            <div class="text-dim" style="font-size: 11px; padding: 1px 0;">
              … +<%= @overflow %> more lines
            </div>
          </summary>
          <.diff_rows lines={@rest} />
        </details>
      <% else %>
        <.diff_rows lines={@head} />
      <% end %>
    </div>
    """
  end

  # One rendered `<div>` per diff line, tokenized by op. Context lines are dim;
  # added/removed carry the soft-background + role-color pair.
  attr :lines, :list, required: true

  defp diff_rows(assigns) do
    ~H"""
    <div
      :for={line <- @lines}
      style={row_style(line.op)}
    ><%= prefix(line.op) %><%= line.text %></div>
    """
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # Split the diff after the budget-th DRAWABLE row (charter D40): a `gap` hunk
  # separator never spends budget — it rides free in the head — and never stays
  # in the summary once the budget is spent (a gap at or past the fold belongs
  # to the `<details>` tail it separates). The overflow footnote counts
  # undisplayed DRAWABLE rows only. Mirrors Components.chat_diff_budget_split/1
  # (string-keyed twin) plus chat_blocks.go and mobile chat.tsx.
  defp budget_split(lines) do
    {head, rest, _drawn} =
      Enum.reduce(lines, {[], [], 0}, fn line, {head, rest, drawn} ->
        if drawn < @collapsed_budget do
          {[line | head], rest, drawn + if(line.op == "gap", do: 0, else: 1)}
        else
          {head, [line | rest], drawn}
        end
      end)

    {Enum.reverse(head), Enum.reverse(rest)}
  end

  # Build the flat diff-line list from the input shape, reusing TextDiff — the
  # ONE line-diff engine. `diff_lines/2` tolerates nil, so a defensively-missing
  # MultiEdit field yields no lines rather than crashing.
  defp build_lines(input) do
    case classify(input) do
      :edit ->
        TextDiff.diff_lines(input["old_string"], input["new_string"])

      :write ->
        # A fresh Write is a pure addition: every content line is `+`.
        TextDiff.diff_lines("", input["content"])

      :multi_edit ->
        multi_edit_lines(input["edits"])

      :generic ->
        []
    end
  end

  # Stack each edit's hunk, separated by a faint gap row. Defensive: MultiEdit is
  # unverified on this host, so a malformed edit entry contributes an empty hunk
  # instead of raising.
  defp multi_edit_lines(edits) when is_list(edits) do
    edits
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn e -> TextDiff.diff_lines(e["old_string"], e["new_string"]) end)
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([%{op: "gap", text: ""}])
    |> List.flatten()
  end

  defp multi_edit_lines(_), do: []

  defp row_style("+"),
    do:
      "color: var(--ok); background: var(--ok-soft); white-space: pre-wrap; overflow-wrap: anywhere; padding: 0 2px;"

  defp row_style("-"),
    do:
      "color: var(--danger); background: var(--danger-soft); white-space: pre-wrap; overflow-wrap: anywhere; padding: 0 2px;"

  defp row_style("gap"),
    do: "border-top: 1px solid var(--border-muted); margin: 4px 0; height: 0;"

  defp row_style(_),
    do: "color: var(--fg-dim); white-space: pre-wrap; overflow-wrap: anywhere; padding: 0 2px;"

  defp prefix("+"), do: "+ "
  defp prefix("-"), do: "- "
  defp prefix("gap"), do: ""
  defp prefix(_), do: "  "

  # ═══ TodoWrite living checklist (charter D39) ═══════════════════════════════

  @doc """
  Normalize a TodoWrite-shaped `input` into a display list of
  `%{content, status, active_form}` — thin delegation to
  `Barkpark.Chat.ToolRows.parse_todos/1` (the pure derivation lives in core).
  """
  @spec parse_todos(any()) :: [
          %{content: String.t(), status: atom(), active_form: String.t() | nil}
        ]
  defdelegate parse_todos(input), to: ToolRows

  @doc """
  The living checklist card (charter D39). `@todos` is a `parse_todos/1` list;
  an empty list still renders the header + an honest "no items" line, never a
  blank box. Evergreen tokens only (`var(--…)`), so `studio-literal-check` passes.
  """
  attr :todos, :list, required: true

  def todo_card(assigns) do
    ~H"""
    <div style="font-family: var(--font-mono);">
      <div class="text-xs" style="overflow-wrap: anywhere;">
        <span style="color: var(--primary);">●</span>
        <span>Update todos</span>
        <span :if={@todos != []} style="opacity: 0.6;"> · <%= todo_progress(@todos) %></span>
      </div>
      <ul
        :if={@todos != []}
        style="list-style: none; margin: 4px 0 0; padding: 0 0 0 16px; display: flex; flex-direction: column; gap: 2px;"
      >
        <li :for={todo <- @todos} class="text-xs">
          <div style="display: flex; gap: 6px; align-items: baseline;">
            <span aria-hidden="true" style={todo_glyph_style(todo.status)}>
              <%= todo_glyph(todo.status) %>
            </span>
            <span style={todo_text_style(todo.status)} data-gutter-text><%= todo.content %></span>
          </div>
          <div
            :if={todo.status == :in_progress and todo.active_form}
            class="text-dim"
            style="padding-left: 20px; opacity: 0.75;"
          >
            → <%= todo.active_form %>
          </div>
        </li>
      </ul>
      <div :if={@todos == []} class="text-xs text-dim" style="padding-left: 16px;">
        ⎿ no items
      </div>
    </div>
    """
  end

  # ── glyphs + styling (the terminal's checklist marks) ──────────────────────

  @doc "The checklist glyph for a todo status (core delegation): ☐ todo · ◐ doing · ☒ done."
  @spec todo_glyph(atom()) :: String.t()
  defdelegate todo_glyph(status), to: ToolRows

  defp todo_glyph_style(:completed), do: "flex: none; color: var(--ok);"
  defp todo_glyph_style(:in_progress), do: "flex: none; color: var(--primary);"
  defp todo_glyph_style(_), do: "flex: none; opacity: 0.6;"

  defp todo_text_style(:completed),
    do: "overflow-wrap: anywhere; opacity: 0.6; text-decoration: line-through;"

  defp todo_text_style(:in_progress),
    do: "overflow-wrap: anywhere; color: var(--primary); font-weight: 600;"

  defp todo_text_style(_), do: "overflow-wrap: anywhere;"

  # "1/3 done" — a compact honest progress summary; in-progress is not "done".
  defp todo_progress(todos) do
    done = Enum.count(todos, &(&1.status == :completed))
    "#{done}/#{length(todos)} done"
  end

  # ═══ Task / agent spawns (charter D40) ══════════════════════════════════════

  # The spawn tool NAMES are host-binary divergence knowledge — sourced from the
  # ONE capability matrix (charter D66) rather than duplicated as a literal here.
  # Compile-time read of a pure constructor: byte-identical to the old
  # `~w(Task Agent)` (the no-tax golden proves the render never moved).
  @spawn_names Barkpark.StudioChat.Runtime.Capabilities.claude().agent_spawn_names

  @doc """
  True when a tool_use is a sub-agent spawn. Tolerant by design: the tool name
  `Task`/`Agent`, OR the `{description, prompt, subagent_type}` input shape under
  any name — the wire has shipped both forms (the cmux fork emits `Agent`).
  """
  @spec spawn?(String.t() | nil, map() | nil) :: boolean()
  def spawn?(name, input) do
    name in @spawn_names or spawn_shape?(input)
  end

  defp spawn_shape?(input) when is_map(input) do
    is_binary(input["description"]) and is_binary(input["prompt"]) and
      is_binary(input["subagent_type"])
  end

  defp spawn_shape?(_), do: false

  @doc """
  The label shown on the ● spawn row: the sub-agent `description` (the human
  headline), suffixed with its `subagent_type` when both are present. Falls back
  to the type, then to the tool name, so a thinner spawn frame still reads
  honestly.
  """
  @spec spawn_label(String.t() | nil, map() | nil) :: String.t()
  def spawn_label(name, input) when is_map(input) do
    desc = input["description"]
    type = input["subagent_type"]

    cond do
      is_binary(desc) and desc != "" and is_binary(type) and type != "" -> "#{desc} · #{type}"
      is_binary(desc) and desc != "" -> desc
      is_binary(type) and type != "" -> type
      true -> name || "Task"
    end
  end

  def spawn_label(name, _input), do: name || "Task"

  # ═══ MCP result chips (charter D64) ═════════════════════════════════════════
  #
  # A DELIBERATE narrow exception to D38's shape-only dispatch: chip
  # classification keys on OUR tool NAME (the `mcp__barkpark__` prefix) — safe
  # ONLY because Barkpark controls the loopback server's naming (`bp mcp serve`).
  # Host tool names stay shape-dispatched (`classify/1` above); this seam never
  # fires for them, so the D38 law is untouched for anything we don't name.
  @mcp_prefix "mcp__barkpark__"

  # Summarize law (charter payload law): task_ready shipped 112,838 chars in ONE
  # block. A chip NEVER dumps a result set — it shows at most this many hits with
  # an honest "+N more"; the store keeps everything for the generic ⎿ row.
  @chip_hit_cap 8

  @list_keys ~w(docs hits results)

  # ── the task_prime queue chip ───────────────────────────────────────────────
  #
  # `task_prime` answers with `{ok, worker, counts, in_progress, ready, rails,
  # recent_events}` — a shape that matches NEITHER the result-LIST branch
  # (docs/hits/results) nor the single-entity branch (doc/doc_id/id), so the
  # richest queue-state tool used to draw no chip at all. Detection stays
  # SHAPE-keyed: the `counts` + `ready` key PAIR is unique to prime among our
  # MCP results, and it is disjoint from both existing branches (a prime payload
  # carries no docs/hits/results and no top-level doc/doc_id/id), so the search
  # and entity chips are byte-unchanged for every payload that is not prime.
  @prime_keys ~w(counts ready)

  # Ready-head rows drawn before the honest "+N more" (payload law, as the
  # search chip's @chip_hit_cap).
  @prime_ready_cap 5

  # The lifecycle vocabulary that OWNS a `--life-*` token (defined in
  # root.html.heex; `rail_status_color/1` in chat_live.ex is the sibling reader).
  # A status outside it is dim-NEUTRAL — an unknown state must never borrow a
  # known state's color, which would report queue state that does not exist.
  @life_states ~w(open ready in_progress blocked done closed cancelled considering researching)

  # Emitted token, never a copied literal (studio-literal-check).
  @life_neutral "var(--fg-dim)"

  # Count keys in board order. Any OTHER key the server later adds still renders,
  # appended in sorted order, so the chip never silently drops a lifecycle state.
  @count_order ~w(open ready in_progress blocked done closed cancelled)

  @doc """
  Classify an MCP tool RESULT into a first-class chip, or `nil` (keep the generic
  `●`/`⎿` row). `tool` is the persisted tool name, `output` the single text
  block's text (charter D64). Two gates, both required:

    1. `tool` begins with `mcp__barkpark__` — OUR loopback server.
    2. `output` Jason-decodes to a JSON object. An `is_error` result is a PLAIN
       string (never JSON) and a payload the recorder truncated mid-object is
       invalid JSON — both fail the decode and honestly degrade to the generic
       row. A `{"ok": false}` outcome (e.g. the empty-queue claim) is a real
       non-result and also yields no chip.

  Kind comes from the decoded payload: a `counts` + `ready` pair is a `:prime`
  queue chip (lifecycle counts + a colored ready head); a non-empty result LIST
  (`docs`/`hits`/`results`) is a `:search` chip (inline expandable hits, each
  deep-linked by its OWN `type`); a single entity is a `:task` or `:paper` chip
  by its `type`, deep-linking to the board (`/admin/projects?task=`) or the
  public reader (`/papers/`). Pure + total — the SAME call on the live-append
  and replayed paths yields identical HTML (the `diff?`/`spawn?` parity
  precedent).
  """
  @spec chip(String.t() | nil, String.t() | nil) :: map() | nil
  def chip(tool, output) when is_binary(tool) and is_binary(output) do
    with true <- String.starts_with?(tool, @mcp_prefix),
         {:ok, payload} when is_map(payload) <- decode_payload(output),
         false <- payload["ok"] == false do
      suffix =
        binary_part(tool, byte_size(@mcp_prefix), byte_size(tool) - byte_size(@mcp_prefix))

      build_chip(suffix, payload)
    else
      _ -> nil
    end
  end

  def chip(_, _), do: nil

  defp decode_payload(output) do
    case Jason.decode(output) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  # A prime payload is a queue chip; a non-empty result LIST a search chip;
  # otherwise a single entity chip.
  defp build_chip(suffix, payload) do
    cond do
      prime?(payload) ->
        prime_chip(payload)

      true ->
        case result_list(payload) do
          [_ | _] = list -> search_chip(list)
          _ -> entity_chip(payload, suffix)
        end
    end
  end

  defp prime?(payload), do: Enum.all?(@prime_keys, &Map.has_key?(payload, &1))

  defp result_list(payload) do
    Enum.find_value(@list_keys, [], fn k ->
      case payload[k] do
        [_ | _] = list -> list
        _ -> nil
      end
    end)
  end

  # A created/updated/fetched single entity: `{"doc": {…}}` (get/claim), or a
  # top-level receipt carrying its own id (`{"id", "draft", "status"}` from
  # task_create). Deep-links to the board for a task, the reader for a paper.
  defp entity_chip(payload, suffix) do
    case single_entity(payload) do
      nil ->
        nil

      entity ->
        if paper?(entity, suffix) do
          %{kind: :paper, label: entity_label(entity), href: paper_href(entity)}
        else
          %{kind: :task, label: entity_label(entity), href: task_href(entity)}
        end
    end
  end

  defp single_entity(%{"doc" => doc}) when is_map(doc), do: doc
  defp single_entity(%{"doc_id" => _} = payload), do: payload
  defp single_entity(%{"id" => _} = payload), do: payload
  defp single_entity(_), do: nil

  # `type` on the payload is authoritative; the tool-name suffix is a fallback
  # hint for a thinner receipt that omits it.
  defp paper?(entity, suffix) do
    entity["type"] == "paper" or String.starts_with?(suffix, "paper")
  end

  defp entity_label(entity) do
    entity["title"] || entity_id(entity) || "result"
  end

  defp entity_id(entity) do
    first_binary([entity["doc_id"], entity["id"], entity["_id"]])
  end

  defp task_href(entity) do
    case entity_id(entity) do
      id when is_binary(id) and id != "" -> "/admin/projects?task=" <> URI.encode_www_form(id)
      _ -> nil
    end
  end

  defp paper_href(entity) do
    case first_binary([entity["slug"], entity_id(entity)]) do
      slug when is_binary(slug) and slug != "" -> "/papers/" <> slug
      _ -> nil
    end
  end

  # Summarize a result set to at most @chip_hit_cap hits (payload law). Each hit
  # deep-links by its OWN type — a task hit peeks the board, a paper hit opens
  # the reader, anything else is honest inline text (no route exists nor should).
  defp search_chip(list) do
    shown =
      list
      |> Enum.take(@chip_hit_cap)
      |> Enum.map(&hit/1)
      |> Enum.reject(&is_nil/1)

    total = length(list)
    %{kind: :search, hits: shown, total: total, overflow: max(total - length(shown), 0)}
  end

  defp hit(h) when is_map(h) do
    case first_binary([h["title"], entity_id(h)]) do
      label when is_binary(label) and label != "" ->
        %{label: label, type: h["type"], href: hit_href(h)}

      _ ->
        nil
    end
  end

  defp hit(_), do: nil

  defp hit_href(%{"type" => "paper"} = h), do: paper_href(h)
  defp hit_href(%{"type" => "task"} = h), do: task_href(h)
  defp hit_href(_), do: nil

  # Summarize a prime payload into `{counts, ready head}`. EVERY field is read
  # defensively: a partial or malformed payload (counts that is not a map, ready
  # that is not a list, rows that are not maps, non-integer count values) yields
  # an EMPTY slice rather than a crash or an invented number — the chip still
  # draws, neutrally, and the generic ⎿ row still holds the full response.
  defp prime_chip(payload) do
    ready = as_list(payload["ready"])

    rows =
      ready
      |> Enum.take(@prime_ready_cap)
      |> Enum.map(&prime_row/1)
      |> Enum.reject(&is_nil/1)

    %{
      kind: :prime,
      counts: prime_counts(payload["counts"]),
      ready: rows,
      ready_total: length(ready),
      overflow: max(length(ready) - length(rows), 0)
    }
  end

  # Board order first, then any unrecognized state the server added, sorted —
  # a new lifecycle state renders (dim-neutral) instead of vanishing.
  defp prime_counts(counts) when is_map(counts) do
    extra =
      counts
      |> Map.keys()
      |> Enum.filter(&(is_binary(&1) and &1 not in @count_order))
      |> Enum.sort()

    for state <- @count_order ++ extra, is_integer(counts[state]) do
      %{state: state, count: counts[state], color: life_color(state)}
    end
  end

  defp prime_counts(_), do: []

  # One ready-head row: its title (or id), its lifecycle color, and the board
  # deep link. A row carrying neither a title nor an id has nothing to draw.
  defp prime_row(row) when is_map(row) do
    case first_binary([row["title"], entity_id(row)]) do
      label when is_binary(label) ->
        state = prime_state(row["lifecycle_status"])
        %{label: label, state: state, color: life_color(state), href: task_href(row)}

      _ ->
        nil
    end
  end

  defp prime_row(_), do: nil

  # A BRIEF card omits `lifecycle_status` exactly when it is "open"
  # (`put_unless(:lifecycle_status, …, "open")` in tasks_controller/params.ex),
  # so an ABSENT value honestly reads open — it is not an unknown state.
  defp prime_state(s) when is_binary(s) and s != "", do: s
  defp prime_state(_), do: "open"

  defp life_color(state) when is_binary(state) do
    if state in @life_states, do: "var(--life-" <> state <> ")", else: @life_neutral
  end

  defp life_color(_), do: @life_neutral

  defp as_list(v) when is_list(v), do: v
  defp as_list(_), do: []

  defp first_binary(values) do
    Enum.find(values, fn v -> is_binary(v) and v != "" end)
  end

  @doc """
  Render an MCP result chip (charter D64). `@chip` is a `chip/2` map. A task or
  paper chip is a single deep-link pill; a search chip is an inline expandable
  hit list, summarized to the first #{@chip_hit_cap} with an honest "+N more".
  Emitted design tokens only (`var(--…)`), so `studio-literal-check` stays green.
  """
  attr :chip, :map, required: true

  def tool_chip(%{chip: %{kind: :search}} = assigns) do
    ~H"""
    <div style="margin: 4px 0 0 16px;">
      <details style="font-family: var(--font-mono); font-size: 12px;">
        <summary
          style="cursor: pointer; list-style: none; display: inline-flex; align-items: center; gap: 6px; padding: 4px 10px; border: 1px solid var(--border-muted); border-radius: 999px; background: var(--muted-surface);"
        >
          <span style="color: var(--primary);">◍</span>
          <span data-gutter-text><%= @chip.total %> <%= result_word(@chip.total) %></span>
        </summary>
        <ul
          :if={@chip.hits != []}
          style="list-style: none; margin: 6px 0 0; padding: 0 0 0 12px; display: flex; flex-direction: column; gap: 3px;"
        >
          <li :for={hit <- @chip.hits} style="display: flex; gap: 6px; align-items: baseline;">
            <span style="color: var(--primary); flex: none;">·</span>
            <a
              :if={hit.href}
              href={hit.href}
              style="color: var(--primary); text-decoration: none; overflow-wrap: anywhere;"
              data-gutter-text
            ><%= hit.label %></a>
            <span
              :if={is_nil(hit.href)}
              style="overflow-wrap: anywhere;"
              data-gutter-text
            ><%= hit.label %></span>
            <span :if={hit.type} class="text-dim" style="opacity: 0.6; flex: none;">
              <%= hit.type %>
            </span>
          </li>
        </ul>
        <div
          :if={@chip.overflow > 0}
          class="text-dim"
          style="padding: 3px 0 0 12px; opacity: 0.7;"
        >
          … +<%= @chip.overflow %> more
        </div>
      </details>
    </div>
    """
  end

  def tool_chip(%{chip: %{kind: :prime}} = assigns) do
    ~H"""
    <div style="margin: 4px 0 0 16px;">
      <details style="font-family: var(--font-mono); font-size: 12px;">
        <summary
          style="cursor: pointer; list-style: none; display: inline-flex; align-items: center; flex-wrap: wrap; gap: 8px; padding: 4px 10px; border: 1px solid var(--border-muted); border-radius: 999px; background: var(--muted-surface);"
        >
          <span style="color: var(--primary); flex: none;"><%= chip_glyph(:prime) %></span>
          <span data-gutter-text><%= @chip.ready_total %> ready</span>
          <span
            :for={c <- @chip.counts}
            style="display: inline-flex; align-items: center; gap: 4px; flex: none;"
          >
            <span style={life_dot_style(c.color)}></span>
            <span class="text-dim" style="opacity: 0.7;"><%= c.state %> <%= c.count %></span>
          </span>
        </summary>
        <ul
          :if={@chip.ready != []}
          style="list-style: none; margin: 6px 0 0; padding: 0 0 0 12px; display: flex; flex-direction: column; gap: 3px;"
        >
          <li :for={row <- @chip.ready} style="display: flex; gap: 6px; align-items: baseline;">
            <span style={life_dot_style(row.color)}></span>
            <a
              :if={row.href}
              href={row.href}
              style="color: var(--primary); text-decoration: none; overflow-wrap: anywhere;"
              data-gutter-text
            ><%= row.label %></a>
            <span
              :if={is_nil(row.href)}
              style="overflow-wrap: anywhere;"
              data-gutter-text
            ><%= row.label %></span>
            <span class="text-dim" style="opacity: 0.6; flex: none;"><%= row.state %></span>
          </li>
        </ul>
        <div
          :if={@chip.overflow > 0}
          class="text-dim"
          style="padding: 3px 0 0 12px; opacity: 0.7;"
        >
          … +<%= @chip.overflow %> more
        </div>
      </details>
    </div>
    """
  end

  def tool_chip(%{chip: %{kind: kind}} = assigns) when kind in [:task, :paper] do
    ~H"""
    <a
      :if={@chip.href}
      href={@chip.href}
      style="display: inline-flex; align-items: center; gap: 6px; margin: 4px 0 0 16px; padding: 4px 10px; border: 1px solid var(--border-muted); border-radius: 999px; background: var(--muted-surface); text-decoration: none; color: inherit; font-family: var(--font-mono); font-size: 12px;"
    >
      <span style="color: var(--primary); flex: none;"><%= chip_glyph(@chip.kind) %></span>
      <span style="overflow-wrap: anywhere;" data-gutter-text><%= @chip.label %></span>
      <span class="text-dim" style="opacity: 0.6; flex: none;">
        <%= chip_kind_label(@chip.kind) %> →
      </span>
    </a>
    <div
      :if={is_nil(@chip.href)}
      style="display: inline-flex; align-items: center; gap: 6px; margin: 4px 0 0 16px; padding: 4px 10px; border: 1px solid var(--border-muted); border-radius: 999px; background: var(--muted-surface); font-family: var(--font-mono); font-size: 12px;"
    >
      <span style="color: var(--primary); flex: none;"><%= chip_glyph(@chip.kind) %></span>
      <span style="overflow-wrap: anywhere;" data-gutter-text><%= @chip.label %></span>
    </div>
    """
  end

  def tool_chip(assigns), do: ~H""

  # The lifecycle dot every prime row and count pill carries. The color is a
  # `var(--life-*)` token (or the neutral token for an unknown state), never a
  # copied literal — studio-literal-check stays green.
  defp life_dot_style(color) do
    "display: inline-block; flex: none; width: 6px; height: 6px; border-radius: 999px; " <>
      "background: " <> color <> ";"
  end

  defp chip_glyph(:prime), do: "◷"
  defp chip_glyph(:task), do: "◈"
  defp chip_glyph(:paper), do: "❐"
  defp chip_glyph(_), do: "●"

  defp chip_kind_label(:task), do: "task"
  defp chip_kind_label(:paper), do: "paper"
  defp chip_kind_label(_), do: ""

  defp result_word(1), do: "result"
  defp result_word(_), do: "results"
end
