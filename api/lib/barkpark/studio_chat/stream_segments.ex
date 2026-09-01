defmodule Barkpark.StudioChat.StreamSegments do
  @moduledoc """
  The APPEND-ONLY half of the progressive chat stream: which bytes of a turn are
  safe to put on the wire as rendered blocks, emitted as NEW segments only.

  This module owns the wire contract (mobile charter D59), the segment rule
  (D60), the settle self-check (D61) and the four-number bound (D64). It does
  NOT own the boundary — `Barkpark.StudioChat.StreamTail` does, and this module
  CALLS it. A second boundary implementation would fork the law s1 unified and
  reintroduce three run-proven defects (an inline ```` ``` ```` pinning the
  boundary at 0, blindness to `~~~`, and a 4-space-indented backtick freeze).

  ## Append-only, and why it is the point

  A frame carries only `[from, to)` — the bytes committed since the last frame —
  never the whole prefix. Total wire bytes are therefore O(total) rather than
  O(n²), and every byte is CONVERTED exactly once. That is what lets the client
  memoize a settled segment so a paragraph that stopped changing never
  re-renders; bandwidth is the smaller half of the prize.

  ## The segment rule (D60): commit all but the OPEN block

  The blank-line boundary already excludes the block still being typed. What it
  does NOT exclude is a block that SPANS blank lines — a loose list, a
  blockquote run, an indented code block — where piecewise conversion diverges
  from whole conversion (`"- a\\n\\n"` is a one-item list; `"- a\\n\\n- b\\n\\n"` is a
  two-item list, run-verified). So a candidate segment is HELD whenever the
  remainder could still continue its last unit:

      last unit        remainder that continues it
      ---------------  -------------------------------
      list item        another list marker, or a 4-space indent
      blockquote `>`   another `>`
      indented code    another 4-space indent

  The probe is two LINES, never a conversion, so a hold costs nothing and the
  held region is converted once when the run ends. A `:list`/`:callout`/
  `:indented_code` last unit with no decisive remainder yet also holds — absence
  of evidence is not evidence of a block boundary.

  Two divergence classes are CONVERTER faults no boundary law can fix, and each
  stops emission for the turn (D60), landing the turn on today's plain-tail
  floor rather than committing a block that would later mutate:

    * a **link reference definition** anywhere in the accumulator — it rewrites
      an already-committed paragraph into a hyperlink at unbounded distance
      (run-verified: `"See [foo] here."` becomes a link 3 blocks later).
    * an **odd number of backtick runs** in the fence-stripped prefix — an
      unpaired inline run makes EarmarkParser swallow later paragraph breaks
      into the committed block (run-verified: `"Use the ` operator\\n\\n"` then
      `"Then it works.\\n\\n"` converts to ONE paragraph).

  A third class is not a converter fault but a BYTE-SPACE fault, and stops the
  turn the same way: a stream carrying `\\r\\n`. Our offsets index StreamTail's
  CRLF-normalized text while the client walks its RAW tail counting `to - from`
  bytes, so the two spaces drift one byte per collapsed `\\r\\n` — invisibly,
  because the client's `from == cursor` check counts the SERVER's space on both
  sides. Both providers emit `\\n` today; a second offset space would be
  complexity for a hypothetical, so a CRLF turn degrades to plain instead.

  ## The settle self-check (D61)

  At turn completion the emitter compares `concat(emitted blocks)` against
  `FromMarkdown.blocks(durable_text)` — the text that ACTUALLY PERSISTS, not the
  accumulated deltas, because the client suppresses the persisted row on
  `settled` and must never suppress a row it has not been shown byte-for-byte.
  A prefix match yields one final `stable` frame carrying the remainder (the
  held-back open block, converted IN CONTEXT) then `stable_end reason=settled`.
  Anything else yields `stable_end reason=degraded`, and the client drops its
  segments for today's exact behaviour. Every unforeseen divergence class is
  therefore a measured, self-reported degrade instead of a visible pop.

  ## The bound (D64): four numbers, and terminal means FREEZE

  Three of the four terminate into the SAME `stable_end reason=capped` and the
  stream STAYS OPEN — never shed-and-close (D24). `min_segment_interval_ms` is
  the exception BY DESIGN: it is a coalescer, not a cap, so it has no terminal
  state — freezing on a rate limiter would discard content the settle is still
  obliged to deliver. `Process.flag(:max_heap_size)` is a placebo here and is
  deliberately absent: the text and block terms are off-heap refc binaries, so a
  holder of 2,354,954 B reports 2,648 B on-heap.

  ### The byte cap is a LATENCY bound, and it sits BELOW the converter's knee

  `settle/2` parses the whole turn in ONE `handle_info`, so the cap is what
  bounds how long the Recorder — the hottest persistence process — can block.
  That parse is SUPERLINEAR, so the cap cannot be chosen as a memory number and
  read as a latency one; the two disagree by an order of magnitude:

      turn size    settle/2 blocks for   ms per KiB
      ---------    -------------------   ----------
       16 KiB        38 ms                 2.4
       32 KiB        63 ms                 2.0
       64 KiB       116 ms                 1.8
      128 KiB       298 ms                 2.3   <- the cap
      192 KiB       881 ms                 4.6
      256 KiB      1604 ms                 6.3   <- the old cap

  Single-shot on a LOADED shared box (load average 58). Min-of-5 on the same
  box reads 157 ms at 128 KiB and 1565 ms at 256 KiB — the same 10x, and the
  numbers `stream_segments_test.exs` asserts the ratio of.

  Roughly linear to 128 KiB, then a KNEE: 2x the input past it costs ~5x the
  time. Do NOT restate this as a single constant or as hardware variance — both
  were tried and both were wrong (mobile charter D64). The numbers above were
  taken on a LOADED shared box, so read the RATIOS, not the milliseconds; on an
  idle box the same curve reads ~0.93 ms/KiB flat to 64 KiB and 1025 ms at
  192 KiB. Either box shows the same knee in the same place.

  ROOT CAUSE, and why it is not fixed here. It is not our code and not
  `FromMarkdown` — the mapping over the AST is linear, and D61's
  `List.starts_with?` self-check over 3,639 blocks costs 0.1 ms. It is
  `EarmarkParser.Context._prepend/2`, which does
  `List.flatten([block | accumulated])` ONCE PER TOP-LEVEL BLOCK: quadratic in
  block count, and `lists:do_flatten/2` is 56% of the profile (6,292,361 calls
  for a 7,085-block document). Still present in earmark_parser 1.4.46, the
  latest release. Removing it means forking a markdown parser, so this module
  does the thing it CAN do: keep the cap on the near side of the knee.

  So the cap is 131,072 (128 KiB), set by LATENCY and not by memory — the memory
  argument alone would have allowed 256 KiB. Halving the cap cuts the worst-case
  Recorder stall ~5x rather than 2x, exactly because the curve is superlinear,
  and 128 KiB still sits an order of magnitude above every realistic reply
  (4-12 KB, i.e. single-digit to tens of ms).

  ONE CONSEQUENCE, named rather than discovered. At the old cap a cap-sized
  settle (~1.1-1.6 s) far exceeded `stable_snapshot_timeout_ms` (250 ms), so a
  mid-turn attach during one reliably timed out and degraded to the plain floor.
  At 128 KiB it is 157 ms — UNDER that timeout — so such an attach now queues
  and succeeds instead. That is better for the client (it gets its snapshot) but
  it IS a behaviour change, and it is why the timeout stays at 250 ms rather
  than being tightened alongside the cap: tightening both would re-open the
  degrade this closes.
  """

  alias Barkpark.PortableDoc.FromMarkdown
  alias Barkpark.StudioChat.StreamTail

  # (a) A LATENCY policy first and a memory policy second — the binding number is
  # the settle knee documented above, not the footprint. Memory alone would have
  # allowed 256 KiB (a 1 MiB turn measures 2,354,954 B resident server-side and
  # 2,203,964 B of segment JSON per client, so 128 KiB prices one in-flight turn
  # at ~308 KiB server / ~230 KB device); latency does not, because the
  # converter's cost per KiB triples between 128 and 256 KiB. This is a SEPARATE
  # key from StreamTail's `:max_streaming_display_bytes` (1 MiB) ON PURPOSE:
  # that one governs the LiveView bubble, which this wave must not change (D63
  # "two holders, one law"). Ours is strictly tighter, so it always fires first.
  @default_max_stream_display_bytes 131_072

  # (b) Taste-free at the measured real rate of 2.11 text_delta frames/s: it
  # only bites under burst. A min-BYTES knob was rejected — the p50 segment
  # source is 148 B, so it would visibly merge a heading with its first line.
  @default_min_segment_interval_ms 50

  # (c) The second unbounded axis a byte cap cannot see: 1 MiB of `"a\n\n"`
  # advances 349,525 times with every frame under any byte cap. 4096 is 1.6× the
  # 2,611 frames the densest realistic shape demands at a 256 KiB cap (measured
  # 4.06–10.2 advances/KiB on real prose) and clips the pathological shape 21×.
  @default_max_segments_per_turn 4096

  # (d) The third axis: append-only bounds the TOTAL, not the FRAME, and one
  # closed fence is one boundary jump — a single segment at the old 1 MiB cap
  # JSON-encodes to 1,077,745 B, over Go's hard 1,048,575-byte line ceiling.
  @default_max_segment_frame_bytes 262_144

  # The connect-time snapshot is a synchronous call into a process that may be
  # mid-persist, so it MUST be able to give up. On timeout the late joiner gets
  # no snapshot and renders the plain tail — today's floor, not a broken stream.
  @default_snapshot_timeout_ms 250

  @typedoc """
  The per-turn accumulator — a BARE MAP, matching StreamTail's tripwire so the
  two holders stay shape-compatible for a reader.
  """
  @type t :: %{
          turn: pos_integer(),
          tail: StreamTail.t(),
          emitted_to: non_neg_integer(),
          unit_start: non_neg_integer(),
          segments: non_neg_integer(),
          blocks: [map()],
          last_emit_ms: integer() | nil,
          phase: :live | :ended,
          reason: binary() | nil,
          guard_pos: non_neg_integer(),
          linkref: boolean(),
          crlf: boolean(),
          pending_cr: boolean(),
          backtick_runs: non_neg_integer(),
          converter: (binary() -> [map()])
        }

  @typedoc """
  A wire frame, ready for the SSE serializer. Both kinds are id-LESS: Go and
  mobile both advance their resume cursor for ANY id-carrying frame BEFORE
  dispatch, so an `id:` here would strand the next reconnect.
  """
  @type frame ::
          {:stable,
           %{
             turn: pos_integer(),
             from: non_neg_integer(),
             to: non_neg_integer(),
             blocks: [map()],
             skeleton: %{kind: binary(), prose: binary()} | nil
           }}
          | {:stable_end, %{turn: pos_integer(), from: non_neg_integer(), reason: binary()}}

  @doc """
  A fresh accumulator for `turn`.

  `:converter` is INJECTED (default `FromMarkdown.blocks/1`) — the same seam
  StreamTail uses for its renderer. It is what makes D61's degrade arm
  red-testable: a converter whose whole-text answer disagrees with its
  piecewise answer drives the self-check to `degraded` without any test-only
  branch in the production path.
  """
  @spec new(pos_integer(), keyword()) :: t()
  def new(turn, opts \\ []) when is_integer(turn) and turn > 0 do
    %{
      turn: turn,
      tail: StreamTail.new(),
      emitted_to: 0,
      unit_start: 0,
      segments: 0,
      blocks: [],
      last_emit_ms: nil,
      phase: :live,
      reason: nil,
      guard_pos: 0,
      linkref: false,
      crlf: false,
      pending_cr: false,
      backtick_runs: 0,
      converter: Keyword.get(opts, :converter, &FromMarkdown.blocks/1)
    }
  end

  @doc """
  Fold one provider delta in and return `{state, frames}` — at most one `stable`
  frame, or the single terminal frame that freezes the turn.

  `now_ms` is passed in rather than read from the clock so the min-interval bound
  is assertable without sleeping.
  """
  # @canonical capability:chat-stable-segments aka:append_only,stable_frame,segment_emitter,progressive_stream doc:docs/cards/studio.md
  @spec advance(t(), binary(), integer()) :: {t(), [frame()]}
  def advance(state, delta, now_ms)

  # Terminal is terminal: a capped or degraded turn emits nothing further, and
  # the accumulator stops growing. The next turn gets a fresh holder.
  def advance(%{phase: :ended} = state, _delta, _now_ms), do: {state, []}

  def advance(state, delta, now_ms) when is_binary(delta) do
    boundary_before = state.tail.stable_len
    tail = StreamTail.advance(state.tail, delta, &no_render/1)

    state =
      %{state | tail: tail}
      |> scan_crlf(delta)
      |> track_unit_start(boundary_before)
      |> scan_link_references()

    cond do
      # (a) the byte cap, plus StreamTail's own cap as a coherence backstop in
      # case a deployment configures it BELOW ours (it truncates `text`, which
      # would silently shorten the byte space our offsets live in).
      byte_size(tail.text) > max_stream_display_bytes() or tail.capped ->
        terminate(state, "capped")

      state.crlf ->
        terminate(state, "degraded")

      state.linkref ->
        terminate(state, "degraded")

      true ->
        maybe_emit(state, now_ms)
    end
  end

  @doc """
  Close the turn against the text that ACTUALLY PERSISTS (D61).

  `durable_text` is the assistant frame's text for the claude lane and
  `runtime_text` for the codex lane — never the accumulated deltas, because
  `settled` licenses the client to SUPPRESS the persisted row.
  """
  @spec settle(t(), binary()) :: {t(), [frame()]}
  def settle(state, durable_text)

  def settle(%{phase: :ended} = state, _durable_text), do: {state, []}

  def settle(state, durable_text) when is_binary(durable_text) do
    whole = normalize_newlines(durable_text)

    # The latency bound lives on the PARSE, and `durable_text` is the one input
    # to it `advance/3` never saw — its byte cap is checked against the
    # ACCUMULATED DELTAS. The two are the same text in every lane today, so this
    # arm is a backstop, not a live path; but a provider that persists more than
    # it streamed would otherwise buy an UNBOUNDED parse inside the Recorder,
    # which is the exact thing the cap exists to stop. Freeze the way `advance/3`
    # freezes rather than parsing it to find out how big it was.
    if byte_size(whole) > max_stream_display_bytes() do
      terminate(state, "capped")
    else
      settle_within_bound(state, whole)
    end
  end

  defp settle_within_bound(state, whole) do
    emitted = Enum.reverse(state.blocks)

    case whole_blocks(state, whole) do
      {:ok, all} ->
        if List.starts_with?(all, emitted) do
          settled_frames(state, whole, Enum.drop(all, length(emitted)))
        else
          terminate(state, "degraded")
        end

      :error ->
        terminate(state, "degraded")
    end
  end

  @doc """
  The connect-time snapshot (D63): ONE `stable` frame from 0 carrying every
  segment committed so far, so a client attaching MID-TURN is not stranded.

  This is the only reconnect fix available — there is no mid-turn tail endpoint
  anywhere, and `?since=<seq>` replays only PERSISTED rows. Returns `nil`
  (degrade to plain) when nothing is committed, when the turn already froze, or
  when the snapshot would exceed the frame bound.
  """
  @spec snapshot(t()) :: frame() | nil
  def snapshot(%{phase: :ended}), do: nil
  def snapshot(%{emitted_to: 0}), do: nil

  def snapshot(state) do
    frame =
      {:stable,
       %{
         turn: state.turn,
         from: 0,
         to: state.emitted_to,
         blocks: Enum.reverse(state.blocks),
         skeleton: skeleton(state, state.emitted_to)
       }}

    if oversize?(frame), do: nil, else: frame
  end

  # ── emission ────────────────────────────────────────────────────────────

  # The newest COMPLETE unit's start, recomputed ONLY when the boundary actually
  # moves. Deriving it on every delta instead would re-scan the whole held region
  # each time (quadratic on a long list run); deriving it from `boundary_before`
  # alone was WRONG on a delta that moved no boundary — the probe then read an
  # empty window, called it undecidable, and released a segment the very next
  # delta would have continued (run-caught: an indented-code block committed in
  # two halves and settled `degraded`).
  defp track_unit_start(state, boundary_before) do
    to = state.tail.stable_len

    if to > boundary_before do
      floor = max(boundary_before, state.emitted_to)
      %{state | unit_start: last_unit_start(state.tail.text, floor, to)}
    else
      state
    end
  end

  defp maybe_emit(state, now_ms) do
    to = state.tail.stable_len

    cond do
      to <= state.emitted_to -> {state, []}
      throttled?(state, now_ms) -> {state, []}
      held?(state, to) -> {state, []}
      state.segments >= max_segments_per_turn() -> terminate(state, "capped")
      true -> emit(state, to, now_ms)
    end
  end

  defp emit(state, to, now_ms) do
    from = state.emitted_to
    source = binary_part(state.tail.text, from, to - from)

    case count_backtick_runs(state, source) do
      {:degraded, state} ->
        terminate(state, "degraded")

      {:ok, state} ->
        case segment_blocks(state, source) do
          :error ->
            # A converter fault is not a reason to end the recording, and it is
            # not a reason to guess: freeze the turn onto the plain floor.
            terminate(state, "degraded")

          {:ok, blocks} ->
            frame =
              {:stable,
               %{
                 turn: state.turn,
                 from: from,
                 to: to,
                 blocks: blocks,
                 skeleton: skeleton(state, to)
               }}

            if oversize?(frame) do
              terminate(state, "capped")
            else
              {%{
                 state
                 | emitted_to: to,
                   segments: state.segments + 1,
                   blocks: Enum.reverse(blocks, state.blocks),
                   last_emit_ms: now_ms
               }, [frame]}
            end
        end
    end
  end

  defp settled_frames(state, whole, remainder) do
    from = state.emitted_to
    # The cursor space is the turn's source markdown, and `durable_text` is its
    # authority. The clamp only matters when a provider trims trailing bytes the
    # deltas carried: a frame may never run backwards.
    to = max(byte_size(whole), from)

    closer = {:stable_end, %{turn: state.turn, from: to, reason: "settled"}}

    cond do
      # Nothing left over: the last boundary already reached the end of the
      # turn, so the terminal frame's `from` IS the committed total.
      remainder == [] and to == from ->
        {ended(state, "settled"), [closer]}

      true ->
        frame =
          {:stable, %{turn: state.turn, from: from, to: to, blocks: remainder, skeleton: nil}}

        if oversize?(frame) do
          terminate(state, "capped")
        else
          {ended(state, "settled"), [frame, closer]}
        end
    end
  end

  defp terminate(state, reason) do
    # `from` on a terminal frame is the committed cursor. On `degraded` the
    # client does not cursor-check it at all (it drops every segment); on
    # `capped` it is where the frozen document ends — legitimately 0 when one
    # unbroken block never settled anything.
    {ended(state, reason),
     [{:stable_end, %{turn: state.turn, from: state.emitted_to, reason: reason}}]}
  end

  # Terminal RELEASES the accumulator. `max_stream_display_bytes` is a memory
  # policy, so the frozen state must actually give the bytes back rather than
  # pin ~617 KiB of text plus block terms until the turn ends — and nothing
  # reads either field once `phase` is `:ended` (`advance/3`, `settle/3` and
  # `snapshot/1` all short-circuit on it).
  defp ended(state, reason),
    do: %{state | phase: :ended, reason: reason, tail: StreamTail.new(), blocks: []}

  defp throttled?(%{last_emit_ms: nil}, _now_ms), do: false

  defp throttled?(%{last_emit_ms: last}, now_ms),
    do: now_ms - last < min_segment_interval_ms()

  # ── D60: hold a segment whose last unit could still be continued ─────────

  defp held?(state, to) do
    text = state.tail.text
    unit_start = max(state.unit_start, state.emitted_to)

    case unit_class(first_content_line(text, unit_start, to)) do
      class when class in [:list, :callout, :indented_code] ->
        continues?(class, unit_class(first_content_line(text, to, byte_size(text))))

      _ ->
        false
    end
  end

  # A single delta can carry several blank lines, so the boundary may jump past
  # more than one unit. Scanning [before, to) forward is bounded by the delta
  # plus the carried partial line, so this stays O(total) over the turn.
  defp last_unit_start(text, before, to) do
    scan_from = max(before - 1, 0)

    text
    |> :binary.matches("\n\n", scope: {scan_from, to - scan_from})
    |> Enum.reduce(before, fn {pos, _len}, acc ->
      start = pos + 2
      if start < to and start > acc, do: start, else: acc
    end)
  end

  # The first line with content in [from, to), skipping blank lines. Returns
  # `:none` when the window holds nothing decisive yet — whitespace with no
  # newline could still become a 4-space indent.
  defp first_content_line(_text, from, to) when from >= to, do: :none

  defp first_content_line(text, from, to) do
    window = binary_part(text, from, to - from)

    case :binary.match(window, "\n") do
      {0, 1} ->
        first_content_line(text, from + 1, to)

      {pos, 1} ->
        binary_part(window, 0, pos)

      :nomatch ->
        if String.trim(window) == "", do: :none, else: window
    end
  end

  defp unit_class(:none), do: :none

  defp unit_class(line) do
    cond do
      # Indent first: 4 spaces or a tab is CONTENT, and must not be read as the
      # list/quote marker it may contain.
      String.starts_with?(line, "    ") or String.starts_with?(line, "\t") -> :indented_code
      Regex.match?(~r/^ {0,3}(?:[-*+]|\d{1,9}[.)])(?:\s|$)/, line) -> :list
      Regex.match?(~r/^ {0,3}>/, line) -> :callout
      true -> :other
    end
  end

  # No decisive remainder yet is a HOLD for every continuable class: waiting
  # costs a delta of latency, guessing costs a pop.
  defp continues?(_class, :none), do: true
  defp continues?(:list, remainder), do: remainder in [:list, :indented_code]
  defp continues?(:callout, remainder), do: remainder == :callout
  defp continues?(:indented_code, remainder), do: remainder == :indented_code

  # ── D60 degrade class (c): the client's byte space is not ours ───────────

  # Our offsets index StreamTail's CRLF-NORMALIZED text; the client walks its RAW
  # tail counting `to - from` bytes. Identical for a `\n` stream — both providers
  # today — and one byte apart per collapsed `\r\n` otherwise, which the client's
  # `from == cursor` check structurally CANNOT see: both sides count the SERVER's
  # space, so the gap detector stays silent while the plain remainder repeats
  # bytes a segment already drew, and `settled` then licenses suppressing the
  # persisted row. A second offset space would be complexity for a hypothetical
  # provider; degrading onto the plain floor is the answer the other two classes
  # already give, and never silently mis-renders.
  #
  # The pending-`\r` holdback mirrors StreamTail's, and must: a delta can split
  # between `\r` and `\n`, and detection without it misses exactly that case.
  # This is raw-space bookkeeping, not a second normalizer — StreamTail's state
  # is normalized and so cannot answer a raw-space question.
  defp scan_crlf(%{crlf: true} = state, _delta), do: state

  defp scan_crlf(state, delta) do
    raw = if state.pending_cr, do: "\r" <> delta, else: delta
    size = byte_size(raw)

    %{
      state
      | crlf: :binary.match(raw, "\r\n") != :nomatch,
        pending_cr: size > 0 and binary_part(raw, size - 1, 1) == "\r"
    }
  end

  # ── D60 degrade class (a): link reference definitions ────────────────────

  # Incremental over COMPLETE lines only — each line is examined exactly once,
  # ever, so a 12 KB turn costs 12 KB of scanning and not 12 KB per delta. A
  # linkref inside a fence is a false positive we accept: it degrades to the
  # existing floor, which is always safe, and the guard stays fence-free.
  defp scan_link_references(%{linkref: true} = state), do: state

  defp scan_link_references(state) do
    text = state.tail.text
    size = byte_size(text)

    scan_link_references(state, text, size, state.guard_pos)
  end

  defp scan_link_references(state, text, size, pos) do
    case :binary.match(text, "\n", scope: {pos, size - pos}) do
      :nomatch ->
        %{state | guard_pos: pos}

      {nl, 1} ->
        line = binary_part(text, pos, nl - pos)

        if link_reference_definition?(line) do
          %{state | guard_pos: nl + 1, linkref: true}
        else
          scan_link_references(state, text, size, nl + 1)
        end
    end
  end

  defp link_reference_definition?(line), do: Regex.match?(~r/^ {0,3}\[[^\]]+\]:/, line)

  # ── D60 degrade class (b): an odd number of backtick runs ────────────────

  # Counted on the FENCE-STRIPPED source, using StreamTail's own fence
  # recognition — a second fence parser here would fork the law s1 unified. The
  # parity is cumulative over the turn because the swallow it detects is a
  # property of the whole prefix EarmarkParser sees, not of one segment.
  defp count_backtick_runs(state, source) do
    runs = state.backtick_runs + backtick_runs(StreamTail.strip_fences(source))

    if rem(runs, 2) == 0 do
      {:ok, %{state | backtick_runs: runs}}
    else
      {:degraded, %{state | backtick_runs: runs}}
    end
  end

  defp backtick_runs(text), do: backtick_runs(text, 0)

  defp backtick_runs(<<>>, acc), do: acc

  defp backtick_runs(<<"`", rest::binary>>, acc),
    do: rest |> skip_backticks() |> backtick_runs(acc + 1)

  defp backtick_runs(<<_byte, rest::binary>>, acc), do: backtick_runs(rest, acc)

  defp skip_backticks(<<"`", rest::binary>>), do: skip_backticks(rest)
  defp skip_backticks(rest), do: rest

  # ── conversion ──────────────────────────────────────────────────────────

  defp segment_blocks(state, source) do
    {:ok, source |> state.converter.() |> strip_edge_gaps()}
  rescue
    _ -> :error
  end

  defp whole_blocks(state, whole) do
    {:ok, state.converter.(whole)}
  rescue
    _ -> :error
  end

  # An HTML block converts to a phantom empty paragraph at a piece edge, and an
  # empty paragraph IS the Mechanical-Spacing gap unit — fabricated content is
  # forbidden, so strip it at both edges of a segment.
  defp strip_edge_gaps(blocks) do
    blocks
    |> Enum.drop_while(&gap_block?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&gap_block?/1)
    |> Enum.reverse()
  end

  defp gap_block?(%{"type" => "paragraph", "content" => []}), do: true
  defp gap_block?(_), do: false

  defp normalize_newlines(text), do: :binary.replace(text, "\r\n", "\n", [:global])

  # ── the skeleton, relative to `to` ───────────────────────────────────────

  # `skeleton.prose` is the prose ABOVE the forming component, measured from
  # `to` — NOT from the boundary. When a segment is held back, those held bytes
  # sit between `to` and the component and MUST stream as live text; dropping
  # them is exactly the D67 defect where a forming component hid 100 % of the
  # bytes above it. Legitimately "" when the component starts at `to`.
  defp skeleton(state, to) do
    case StreamTail.classify(state.tail) do
      {:component, kind, prose} ->
        held = binary_part(state.tail.text, to, state.tail.stable_len - to)
        %{kind: StreamTail.skeleton_label(kind), prose: held <> prose}

      {:text, _tail} ->
        nil
    end
  end

  defp no_render(_prefix), do: nil

  # ── the frame bound ─────────────────────────────────────────────────────

  # Measured on the ENCODED frame, because the bound exists to keep a line under
  # Go's 1,048,575-byte ceiling and only the encoding knows that length.
  defp oversize?({_kind, payload}),
    do: byte_size(Jason.encode!(payload)) > max_segment_frame_bytes()

  # ── the four numbers ────────────────────────────────────────────────────

  @doc "(D64a) The accumulator's memory policy, in bytes."
  @spec max_stream_display_bytes() :: pos_integer()
  def max_stream_display_bytes,
    do: config(:max_stream_display_bytes, @default_max_stream_display_bytes)

  @doc "(D64b) The minimum wall gap between two segments of one turn."
  @spec min_segment_interval_ms() :: non_neg_integer()
  def min_segment_interval_ms,
    do: config(:min_segment_interval_ms, @default_min_segment_interval_ms)

  @doc "(D64c) The frame-count bound — the axis a byte cap cannot see."
  @spec max_segments_per_turn() :: pos_integer()
  def max_segments_per_turn,
    do: config(:max_segments_per_turn, @default_max_segments_per_turn)

  @doc "(D64d) The per-FRAME encoded byte bound."
  @spec max_segment_frame_bytes() :: pos_integer()
  def max_segment_frame_bytes,
    do: config(:max_segment_frame_bytes, @default_max_segment_frame_bytes)

  @doc "The connect-time snapshot call timeout."
  @spec snapshot_timeout_ms() :: pos_integer()
  def snapshot_timeout_ms, do: config(:stable_snapshot_timeout_ms, @default_snapshot_timeout_ms)

  defp config(key, default) do
    :barkpark
    |> Application.get_env(:claude_chat, [])
    |> Keyword.get(key, default)
  end
end
