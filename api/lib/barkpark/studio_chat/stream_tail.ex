defmodule Barkpark.StudioChat.StreamTail do
  @moduledoc """
  The progressive-streaming state machine for a chat turn: where the accumulated
  text is SAFE to commit as rendered blocks, and what the still-forming remainder
  is turning into.

  Extracted out of `BarkparkWeb.Studio.ChatLive` (mobile charter D58/D68,
  chat-TUI D81) so an SSE producer can compute the SAME boundary the LiveView
  bubble uses. Zero web coupling: the renderer is INJECTED into `advance/3`
  (`&render_paper_html/1` on the web, a blocks encoder on the wire), so this
  module never learns what a stable prefix becomes.

  ## The boundary law (D62 / D81 clause 2)

  The stable prefix ends at the last BLANK LINE (`"\\n\\n"`) that is not inside an
  open code fence — never split a forming ```` ```mermaid ```` or
  ```` ```portabledoc ```` fence, because half a fence renders as a broken block.
  A fence line is CommonMark-shaped, not a substring:

    * indent ≤ 3 spaces (4+ is indented-code CONTENT, not a fence)
    * marker run of ≥ 3 of the SAME char, `` ` `` or `~`
    * an opening backtick fence's info string may not contain a backtick
    * the close is the same char, run ≥ the opening run, whitespace only after

  Three properties this replaces a substring count with, each a run-proven
  defect of the old `rem(length(:binary.matches(prefix, "```")), 2) == 0`:
  one stray inline ```` ``` ```` in prose pinned the boundary at 0 for the whole
  turn; `~~~` fences were invisible; 4-space-indented backticks froze it.

  ## Incrementality is a PREREQUISITE, not an optimization

  The scan is a FOLD over `scan` — each line is examined exactly once, ever. A
  naive full rescan costs ~10.7 s per delta on a 12 KB unterminated fence (every
  blank-line candidate re-splits the whole prefix); the fold is microseconds.
  `classify/1` reads the same fold state, so the duplicate fence counters that
  used to live in `classify_tail/1` and `balanced_fences?/1` are gone.

  ## CRLF

  Normalization runs on the CARRY, with a pending-`\\r` holdback, because a delta
  can split between `\\r` and `\\n` (per-delta normalization diverges from a whole
  -text scan). It is scoped to this stream path only — the render function never
  sees a re-normalized document.

  ## Tripwires

    * The state is a BARE MAP, never a struct: the chat HEEx reads
      `@streaming[:capped]` with Access brackets, which a struct raises on at
      RENDER time.
    * The display cap reads `:barkpark / :claude_chat / :max_streaming_display_bytes`.
  """

  # DISPLAY-ONLY CAP (felix W22, charter D131). The accumulator is a purely
  # cosmetic in-flight preview for BOTH providers — the durable text is the
  # claude full-frame append and the codex Recorder runtime_text, never this.
  # A runaway or hostile stream of many small WELL-FORMED deltas would otherwise
  # grow one assign unboundedly for the whole turn AND compound cost (each new
  # boundary re-renders the FULL prefix). So the DISPLAY is bounded at a
  # config-overridable byte cap: on breach we do one final render up to the last
  # stable boundary, drop the still-forming tail (NEVER a mid-fence byte slice),
  # and freeze. Truncating the live bubble loses ZERO durable data; the full
  # response lands on completion. Turn-abort was rejected (D131).
  @default_max_streaming_display_bytes 1_048_576

  @typedoc "The streaming state — a BARE MAP (see the tripwire above)."
  @type t :: %{
          text: binary(),
          stable_html: term(),
          stable_len: non_neg_integer(),
          capped: boolean(),
          scan: map()
        }

  @doc "A fresh, empty streaming state."
  @spec new() :: t()
  def new do
    %{text: "", stable_html: nil, stable_len: 0, capped: false, scan: new_scan()}
  end

  defp new_scan do
    %{pos: 0, fence: nil, fence_start: nil, boundary: 0, component: nil, pending_cr: false}
  end

  @doc """
  Fold one delta into the streaming state, re-rendering only when the stable
  boundary actually advances.

  `render_fun` is the injected renderer applied to the stable PREFIX (a binary)
  whenever the boundary moves — `&render_paper_html/1` on the web, a blocks
  encoder on the SSE wire. It is never called for the forming tail.
  """
  # @canonical capability:chat-stable-boundary aka:advance_streaming,stable_boundary,progressive,streaming-tail doc:docs/cards/studio.md
  @spec advance(t() | nil, binary(), (binary() -> term())) :: t()
  def advance(state, delta, render_fun)

  def advance(nil, delta, render_fun), do: advance(new(), delta, render_fun)

  # Once capped the live bubble is frozen: every further delta is ignored, so
  # neither the accumulator nor the per-delta re-render can grow. The terminal
  # state is safe because the durable full text still arrives on completion.
  def advance(%{capped: true} = state, _delta, _render_fun), do: state

  def advance(state, delta, render_fun) when is_binary(delta) do
    {chunk, pending_cr} = normalize_carry(delta, state.scan.pending_cr)
    text = state.text <> chunk
    scan = fold(%{state.scan | pending_cr: pending_cr}, text)
    state = %{state | text: text, scan: scan}

    if byte_size(text) > max_streaming_display_bytes() do
      freeze(state, render_fun)
    else
      commit(state, render_fun)
    end
  end

  @doc "The still-forming remainder after the committed stable prefix."
  @spec tail(t()) :: binary()
  def tail(%{text: text, stable_len: stable_len}) do
    binary_part(text, stable_len, byte_size(text) - stable_len)
  end

  @doc """
  Classify the forming tail as prose or as a component under construction.

  Returns `{:text, tail}` or `{:component, kind, prose_before_component}` — the
  prose above the first triggering line keeps streaming as live text while the
  component itself stands in as a skeleton (its raw source reads as noise).

  Every arm splits at the FIRST triggering line, including the `>` (callout) and
  `|` (table) arms, which used to hide 100 % of a forming component's bytes by
  passing an unconditional empty prose.
  """
  @spec classify(t()) :: {:text, binary()} | {:component, binary(), binary()}
  def classify(state) do
    tail = tail(state)

    case component_offset(state) do
      {kind, offset} when offset >= state.stable_len ->
        rel = offset - state.stable_len
        {:component, kind, binary_part(tail, 0, rel)}

      _ ->
        {:text, tail}
    end
  end

  @doc "The 7-label skeleton vocabulary (charter D67)."
  @spec skeleton_label(binary()) :: binary()
  def skeleton_label("diagram"), do: "diagram"
  def skeleton_label("chart"), do: "chart"
  def skeleton_label("stats"), do: "stats"
  def skeleton_label("table"), do: "table"
  def skeleton_label("callout"), do: "callout"
  def skeleton_label("code"), do: "code"
  def skeleton_label(_), do: "block"

  @doc """
  Drop every COMPLETE fenced block from `text`, keeping the lines outside fences.

  The one caller is `StreamSegments`' odd-backtick-run guard (charter D60), which
  must count INLINE backtick runs and would otherwise count a fenced code block's
  own backticks. It lives here, not there, because fence recognition is this
  module's law — a second recognizer is exactly the fork D62 deleted.

  An UNCLOSED fence drops its opening line and everything after it: an open fence
  never carries a committed segment, so its bytes have no vote on parity.
  """
  @spec strip_fences(binary()) :: binary()
  def strip_fences(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> strip_fences(nil, [])
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp strip_fences([], _fence, kept), do: kept

  defp strip_fences([line | rest], nil, kept) do
    case fence_marker(line) do
      {marker, run, info} ->
        if opens_fence?(marker, info),
          do: strip_fences(rest, {marker, run}, kept),
          else: strip_fences(rest, nil, [line | kept])

      nil ->
        strip_fences(rest, nil, [line | kept])
    end
  end

  defp strip_fences([line | rest], {marker, run} = fence, kept) do
    case fence_marker(line) do
      {^marker, close_run, info} when close_run >= run ->
        if blank?(info), do: strip_fences(rest, nil, kept), else: strip_fences(rest, fence, kept)

      _ ->
        strip_fences(rest, fence, kept)
    end
  end

  @doc """
  The display byte cap (`:barkpark / :claude_chat / :max_streaming_display_bytes`).
  """
  @spec max_streaming_display_bytes() :: pos_integer()
  def max_streaming_display_bytes do
    :barkpark
    |> Application.get_env(:claude_chat, [])
    |> Keyword.get(:max_streaming_display_bytes, @default_max_streaming_display_bytes)
  end

  # ── commit / freeze ─────────────────────────────────────────────────────

  defp commit(state, render_fun) do
    boundary = state.scan.boundary

    if boundary > state.stable_len do
      prefix = binary_part(state.text, 0, boundary)
      %{state | stable_len: boundary, stable_html: render_fun.(prefix)}
    else
      state
    end
  end

  # Cap breached: do ONE last render up to the last stable boundary, discard the
  # still-forming tail (so `tail/1` yields nothing and the template shows the
  # honest marker), and mark the state terminal. If no boundary exists yet
  # (one giant unbroken block) the bubble shows only the marker; the durable
  # full text is unaffected.
  defp freeze(state, render_fun) do
    state = commit(state, render_fun)

    # The scan is reset to the truncated text's own end, not left pointing past
    # it: `capped` is terminal today, but a `scan.pos`/`fence_start` beyond
    # `byte_size(text)` would make `classify/1` raise on any caller that forgets
    # the `capped` guard — and an SSE producer resuming a capped holder is
    # exactly the shape this wave's round 2 builds. Coherent state costs 5 lines.
    scan = %{new_scan() | pos: state.stable_len, boundary: state.stable_len}

    %{state | text: binary_part(state.text, 0, state.stable_len), capped: true, scan: scan}
  end

  # ── CRLF on the carry ───────────────────────────────────────────────────

  # A delta can split between "\r" and "\n", so the trailing "\r" is HELD BACK
  # and re-prefixed onto the next delta. Per-delta normalization without the
  # holdback diverges from a whole-text scan.
  defp normalize_carry(delta, pending_cr) do
    raw = if pending_cr, do: "\r" <> delta, else: delta
    normalized = :binary.replace(raw, "\r\n", "\n", [:global])
    size = byte_size(normalized)

    if size > 0 and binary_part(normalized, size - 1, 1) == "\r" do
      {binary_part(normalized, 0, size - 1), true}
    else
      {normalized, false}
    end
  end

  # ── the fold ────────────────────────────────────────────────────────────

  # Only COMPLETE lines are folded, and each exactly once: `scan.pos` is the
  # offset of the current partial line, and it only ever moves forward.
  defp fold(scan, text), do: fold(scan, text, byte_size(text))

  defp fold(%{pos: pos} = scan, text, size) do
    case :binary.match(text, "\n", scope: {pos, size - pos}) do
      :nomatch ->
        scan

      {nl, 1} ->
        scan =
          scan
          |> apply_line(binary_part(text, pos, nl - pos), pos, nl)
          |> Map.put(:pos, nl + 1)

        fold(scan, text, size)
    end
  end

  # Outside a fence: an opening fence starts one, a blank line is a boundary
  # candidate, a `>` or `|` line starts a forming component.
  defp apply_line(%{fence: nil} = scan, line, line_start, nl) do
    case fence_marker(line) do
      {marker, run, info} ->
        if opens_fence?(marker, info) do
          %{scan | fence: {marker, run}, fence_start: line_start}
        else
          scan
        end

      nil ->
        cond do
          # A blank line outside every fence is where the prefix is safe to cut.
          # Committing it retires any component we were tracking below it.
          #
          # BLANK MEANS `blank?/1`, NOT `== ""` (mob-bl-streamtail-blank-line-law).
          # CommonMark's blank line is "whitespace only", and a provider that
          # emits `"\n   \n"` between two paragraphs is emitting a paragraph
          # break — the strict byte comparison saw prose there and pinned the
          # boundary before it, so the whole rest of the turn re-rendered as one
          # forming tail. The module already defined `blank?/1` as the trim
          # comparison and already used it on BOTH fence clauses (:194, :315);
          # this one clause was the last strict reader, so the fold disagreed
          # with itself about what "blank" meant.
          blank?(line) ->
            %{scan | boundary: nl + 1, component: nil}

          scan.component == nil ->
            case component_kind(line) do
              nil -> scan
              kind -> %{scan | component: {kind, line_start}}
            end

          true ->
            scan
        end
    end
  end

  # Inside a fence: only a matching closer (same char, run ≥ opening, nothing
  # but whitespace after) ends it. A blank line here is NOT a boundary.
  defp apply_line(%{fence: {marker, run}} = scan, line, _line_start, _nl) do
    case fence_marker(line) do
      {^marker, close_run, info} when close_run >= run ->
        if blank?(info), do: %{scan | fence: nil, fence_start: nil}, else: scan

      _ ->
        scan
    end
  end

  # ── CommonMark-shaped fence recognition ─────────────────────────────────

  # `{marker_byte, run_length, info_string}` for a fence-shaped line, else nil.
  defp fence_marker(line) do
    case strip_indent(line, 0) do
      {indent, <<marker, _::binary>> = rest} when indent <= 3 and marker in [?`, ?~] ->
        run = marker_run(rest, marker, 0)

        if run >= 3 do
          {marker, run, binary_part(rest, run, byte_size(rest) - run)}
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp strip_indent(<<" ", rest::binary>>, n) when n < 4, do: strip_indent(rest, n + 1)
  defp strip_indent(rest, n), do: {n, rest}

  defp marker_run(<<c, rest::binary>>, c, n), do: marker_run(rest, c, n + 1)
  defp marker_run(_, _c, n), do: n

  # CommonMark: a backtick fence's info string may not contain a backtick
  # (otherwise `` ```a```b `` at line start is inline code in a paragraph).
  defp opens_fence?(?`, info), do: not String.contains?(info, "`")
  defp opens_fence?(_marker, _info), do: true

  defp blank?(s), do: String.trim(s) == ""

  # ── forming-component classification ────────────────────────────────────

  # The fence arm wins: a still-open fence is the component, and everything
  # above its opening line is prose that keeps streaming. Otherwise the first
  # `|` or `>` line does — including one still being typed (the partial line
  # after `scan.pos`, so the skeleton appears the moment the line starts).
  defp component_offset(%{scan: %{fence: {_marker, _run}, fence_start: start}} = state)
       when is_integer(start) do
    {fence_kind(binary_part(state.text, start, byte_size(state.text) - start)), start}
  end

  defp component_offset(%{scan: %{component: {kind, offset}}}), do: {kind, offset}

  defp component_offset(%{scan: %{pos: pos}} = state) do
    partial = binary_part(state.text, pos, byte_size(state.text) - pos)

    case component_kind(partial) do
      nil -> nil
      kind -> {kind, pos}
    end
  end

  defp component_kind(line) do
    case String.trim_leading(line) do
      "|" <> _ -> "table"
      ">" <> _ -> "callout"
      _ -> nil
    end
  end

  defp fence_kind(fence) do
    info =
      fence
      |> first_line()
      |> fence_marker()
      |> case do
        {_marker, _run, info} -> String.trim(info)
        nil -> ""
      end

    case info do
      "mermaid" -> "diagram"
      "portabledoc" -> portabledoc_kind(fence)
      _ -> "code"
    end
  end

  defp first_line(text) do
    case :binary.match(text, "\n") do
      :nomatch -> text
      {pos, _} -> binary_part(text, 0, pos)
    end
  end

  # Sniff the first "type" in the (partial) JSON to pick the skeleton shape.
  defp portabledoc_kind(fence_body) do
    case Regex.run(~r/"type"\s*:\s*"([\w-]+)"/, fence_body) do
      [_, "chart"] -> "chart"
      [_, "heatmap"] -> "chart"
      [_, t] when t in ["stat", "stats"] -> "stats"
      [_, "table"] -> "table"
      [_, "callout"] -> "callout"
      [_, "divider"] -> "code"
      [_, _other] -> "block"
      _ -> "block"
    end
  end
end
