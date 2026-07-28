defmodule Barkpark.StudioChat.StreamSegmentsTest do
  @moduledoc """
  The server half of the progressive live document (mobile charter D59-D64).

  These tests exist because NOTHING else can prove the real server emits the
  shape the frozen fixture records: `internal/pdrender/testdata/chat_stable_frames.json`
  had two independent CONSUMERS reaching identical outcomes and zero producers.
  So the wire-contract tests here derive their assertions FROM that fixture
  (key sets, the reason enum, the cursor rule) rather than restating them — a
  fixture regen re-fires this suite exactly as it re-fires the Go and mobile
  consumers.

  `async: false` because the bound tests swap `:barkpark / :claude_chat`, which
  is node-global; `AsyncGlobalSeamGuardTest` correctly rejects an `async: true`
  module that does that, and the guard must not be widened for this file.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.PortableDoc.FromMarkdown
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Recorder, StreamSegments, StreamTail}
  alias Barkpark.StudioChat.Runtime.Event
  alias BarkparkWeb.ChatController

  @fixture Path.expand(
             "../../../../internal/pdrender/testdata/chat_stable_frames.json",
             __DIR__
           )

  # ── driving a turn ───────────────────────────────────────────────────────

  # Split `text` into `chunk`-byte deltas — the shape a provider actually
  # streams. `tick` is the ms advance per delta, so a test can put the
  # min-interval bound in or out of play without sleeping.
  defp deltas(text, chunk) do
    count = div(byte_size(text), chunk)
    whole = for i <- 0..max(count - 1, 0), i < count, do: binary_part(text, i * chunk, chunk)
    rest = binary_part(text, count * chunk, byte_size(text) - count * chunk)
    if rest == "", do: whole, else: whole ++ [rest]
  end

  defp drive(text, opts) do
    chunk = Keyword.get(opts, :chunk, 13)
    tick = Keyword.get(opts, :tick, 1_000)
    turn = Keyword.get(opts, :turn, 1)
    new_opts = Keyword.take(opts, [:converter])

    text
    |> deltas(chunk)
    |> Enum.reduce({StreamSegments.new(turn, new_opts), [], 0}, fn delta, {state, acc, n} ->
      {state, frames} = StreamSegments.advance(state, delta, 10_000 + n * tick)
      {state, acc ++ frames, n + 1}
    end)
    |> then(fn {state, frames, _n} -> {state, frames} end)
  end

  # A whole turn: stream it, then settle against the durable text.
  defp turn(text, opts \\ []) do
    {state, frames} = drive(text, opts)
    durable = Keyword.get(opts, :durable, text)
    {state, settle_frames} = StreamSegments.settle(state, durable)
    {state, frames ++ settle_frames}
  end

  defp stables(frames), do: for({:stable, payload} <- frames, do: payload)
  defp reasons(frames), do: for({:stable_end, payload} <- frames, do: payload.reason)

  defp blocks_of(frames), do: frames |> stables() |> Enum.flat_map(& &1.blocks)

  # ── the D59 wire contract, derived from the fixture ──────────────────────

  defp contract do
    @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("contract")
  end

  # The keys EVERY recorded frame of a kind carries — read off the fixture's own
  # sequences rather than retyped here, so a contract regen re-fires this suite.
  # Intersection, not union: `unknown_future_fields_tolerated` deliberately adds
  # `hint`/`cost`/`trace_id`, which are optional by construction.
  defp required_keys(kind) do
    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("sequences")
    |> Enum.flat_map(fn seq ->
      for %{"event" => ^kind, "data" => data} <- seq["frames"], do: data
    end)
    |> Enum.map(&MapSet.new(Map.keys(&1)))
    |> Enum.reduce(&MapSet.intersection/2)
  end

  defp fixture_sequence(name) do
    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("sequences")
    |> Enum.find(&(&1["name"] == name))
  end

  defp reason_enum do
    contract()
    |> Map.fetch!("stable_end")
    |> then(&Regex.run(~r/"reason":"([^"]+)"/, &1))
    |> Enum.at(1)
    |> String.split("|")
    |> MapSet.new()
  end

  # The fixture's `cursor_rule`, implemented once: adopt a new turn and reset,
  # accept iff from == cursor, advance to `to`. Returns the walk's outcome.
  defp walk(frames) do
    Enum.reduce(frames, %{turn: nil, cursor: 0, accepted: 0, outcome: :open}, fn
      _frame, %{outcome: :gap} = acc ->
        acc

      {:stable, p}, acc ->
        acc = adopt(acc, p.turn)

        if p.from == acc.cursor,
          do: %{acc | cursor: p.to, accepted: acc.accepted + 1},
          else: %{acc | outcome: :gap}

      {:stable_end, p}, acc ->
        acc = adopt(acc, p.turn)

        case p.reason do
          "degraded" ->
            %{acc | cursor: 0, outcome: :degraded}

          reason ->
            if p.from == acc.cursor, do: %{acc | outcome: reason}, else: %{acc | outcome: :gap}
        end
    end)
    |> then(&%{&1 | outcome: if(&1.outcome == "settled", do: :settled, else: &1.outcome)})
  end

  defp adopt(%{turn: turn} = acc, turn), do: acc
  defp adopt(acc, turn), do: %{acc | turn: turn, cursor: 0}

  describe "the wire contract (D59) — real frames against the frozen fixture" do
    test "every emitted frame carries EXACTLY the fixture's key set, and is id-less" do
      stable_keys = required_keys("stable")
      end_keys = required_keys("stable_end")

      # Non-vacuity: the fixture must actually name the four terms D59 fought for.
      assert MapSet.equal?(stable_keys, MapSet.new(~w(turn from to blocks skeleton)))
      assert MapSet.equal?(end_keys, MapSet.new(~w(turn from reason)))

      {_state, frames} =
        turn("## Head\n\nSome prose that settles.\n\n- one\n- two\n\ntail para\n\n")

      assert stables(frames) != [], "no stable frame emitted — the test would be vacuous"

      for frame <- frames do
        {kind, payload} = frame
        keys = payload |> Map.keys() |> Enum.map(&Atom.to_string/1) |> MapSet.new()

        expected = if kind == :stable, do: stable_keys, else: end_keys
        assert MapSet.equal?(keys, expected), "#{kind} carried #{inspect(keys)}"

        # ID-LESS on both kinds: an `id:` would advance the resume cursor on Go
        # and mobile BEFORE dispatch and strand the next reconnect.
        refute Map.has_key?(payload, :id)
        refute ChatController.sse_stable_frame(frame) =~ ~r/^id:/m
      end
    end

    test "the fixture's OWN sources, streamed through the real emitter, reproduce its recorded offsets" do
      # The strongest form of the criterion: not merely "the shape conforms" but
      # "the server produces these exact segments for these exact bytes". Two of
      # the fixture's sequences are single-turn and fully determined by their
      # source, so they can be replayed against the real emitter. `skeleton` is
      # deliberately NOT compared — it is a property of the remainder AT EMISSION
      # TIME (D67), and the fixture was hand-authored as if frame 0 of
      # open_fence_skeleton went out while the fence was still open, whereas the
      # emitter releases it at the boundary, before the fence has arrived.
      for name <- ~w(clean_three_segments_settled open_fence_skeleton) do
        seq = fixture_sequence(name)
        source = seq |> Map.fetch!("sources") |> Map.fetch!("1")

        {_state, frames} = turn(source, chunk: 11)

        actual =
          Enum.map(frames, fn
            {:stable, p} -> {"stable", p.from, p.to}
            {:stable_end, p} -> {"stable_end", p.from, p.reason}
          end)

        expected =
          Enum.map(seq["frames"], fn
            %{"event" => "stable", "data" => d} -> {"stable", d["from"], d["to"]}
            %{"event" => "stable_end", "data" => d} -> {"stable_end", d["from"], d["reason"]}
          end)

        assert actual == expected, "#{name}: emitter produced #{inspect(actual)}"
      end
    end

    test "types match: turn/from/to integers, blocks a list, skeleton a kind+prose map or null" do
      {_state, frames} =
        turn("intro para\n\nbelow is a table\n| a | b |\n| - | - |\n\nafter\n\n")

      for {:stable, p} <- frames do
        assert is_integer(p.turn) and p.turn > 0
        assert is_integer(p.from) and is_integer(p.to)
        assert p.to >= p.from
        assert is_list(p.blocks)

        case p.skeleton do
          nil ->
            :ok

          skeleton ->
            assert %{kind: kind, prose: prose} = skeleton
            assert is_binary(prose), "skeleton.prose is legitimately \"\" but must be a string"
            assert kind in ~w(code diagram chart stats table callout block)
        end
      end

      for {:stable_end, p} <- frames do
        assert is_integer(p.turn) and is_integer(p.from)
        assert MapSet.member?(reason_enum(), p.reason)
      end
    end

    test "a real turn's frames pass the fixture's own cursor rule and are append-only" do
      text = "## Streaming stables\n\nThe reply commits in segments.\n\n- a cursor\n- a turn\n\n"
      {_state, frames} = turn(text)

      walked = walk(frames)
      assert walked.outcome == :settled
      assert walked.accepted == length(stables(frames))

      # APPEND-ONLY, stated as the two properties that define it: contiguous and
      # strictly forward. A prefix-resend would break the first; an overlap the
      # second.
      offsets = frames |> stables() |> Enum.map(&{&1.from, &1.to})

      assert Enum.all?(offsets, fn {from, to} -> to > from end)

      offsets
      |> Enum.zip(tl(offsets) ++ [nil])
      |> Enum.each(fn
        {_last, nil} -> :ok
        {{_f1, to1}, {f2, _t2}} -> assert f2 == to1, "segments must not overlap or skip"
      end)
    end

    test "wire bytes are O(total), not O(n^2) — the whole prefix is never re-sent" do
      # The discriminator is the CURVE, not an absolute ratio: a per-frame JSON
      # envelope is a constant factor, so only doubling the input separates
      # linear from quadratic. Append-only doubles; full-prefix resend quadruples.
      wire = fn n ->
        text = String.duplicate("A paragraph of perfectly ordinary prose.\n\n", n)
        {_state, frames} = turn(text)

        {length(stables(frames)),
         frames |> Enum.map(&ChatController.sse_stable_frame/1) |> IO.iodata_length()}
      end

      {segments_30, bytes_30} = wire.(30)
      {segments_60, bytes_60} = wire.(60)

      assert segments_30 > 20, "only #{segments_30} segments — too few to discriminate"
      assert segments_60 > segments_30

      growth = bytes_60 / bytes_30

      assert growth < 2.4,
             "#{bytes_30} → #{bytes_60} bytes is #{Float.round(growth, 2)}x for 2x the input " <>
               "— quadratic would be ~4x"
    end
  end

  describe "the segment rule (D60) — the open block is held back" do
    test "a loose list commits as ONE list, not one list per item" do
      {_state, frames} = turn("- alpha\n\n- beta\n\n- gamma\n\nclosing para\n\n")

      lists = for %{"type" => "list"} = b <- blocks_of(frames), do: b

      assert [%{"items" => items}] = lists,
             "expected exactly one list block, got #{length(lists)}"

      assert length(items) == 3
      assert reasons(frames) == ["settled"]
    end

    test "an indented code block spanning a blank line commits as ONE code block" do
      {_state, frames} = turn("    first\n\n    second\n\nprose after\n\n")

      codes = for %{"type" => "code"} = b <- blocks_of(frames), do: b
      assert [%{"value" => value}] = codes
      assert value == "first\n\nsecond"
      assert reasons(frames) == ["settled"]
    end

    test "a still-forming fence is never split, and its skeleton names the remainder" do
      text = "para one\n\npara two\n\n```go\nfunc x() {}\n```\n\nlast\n\n"
      {_state, frames} = turn(text, chunk: 9)

      # No committed block may contain half a fence.
      refute Enum.any?(blocks_of(frames), fn
               %{"value" => v} when is_binary(v) -> String.contains?(v, "```")
               _ -> false
             end)

      skeletons = frames |> stables() |> Enum.map(& &1.skeleton) |> Enum.filter(& &1)

      assert Enum.any?(skeletons, &(&1.kind == "code")),
             "a boundary advanced while the fence was open, so a code skeleton was due"

      assert reasons(frames) == ["settled"]
    end

    test "skeleton.prose is the prose ABOVE the component, measured from `to`" do
      # The `|` line follows a prose line with no blank line between them, so the
      # prose must stream live while only the table stands behind a placeholder.
      # This is the D67 defect the web still has (it passes "" unconditionally).
      {_state, frames} = drive("para\n\nlead in text\n| a | b |", chunk: 200)

      assert [%{skeleton: %{kind: "table", prose: prose}}] = stables(frames)
      assert prose == "lead in text\n"
    end

    test "DEGRADE (a): a link reference definition stops emission for the turn" do
      # Run-verified mutation at distance: the linkref rewrites the FIRST
      # paragraph into a hyperlink three blocks later, so any segment already
      # committed is now wrong.
      with_ref = "See [foo] here.\n\nmore prose\n\n[foo]: http://x\n\n"
      without = "See [foo] here.\n\nmore prose\n\n"

      assert FromMarkdown.blocks(with_ref) != FromMarkdown.blocks(without),
             "the corpus doc no longer mutates at distance — the guard's reason is gone"

      # The GUARD's job is to stop EARLY. Without it the settle self-check would
      # still degrade this turn, so `reason` alone cannot discriminate the two —
      # the frame COUNT can: two segments settle before the definition line
      # completes, and nothing may be committed after it, however much prose
      # follows.
      trailing = with_ref <> "after one\n\nafter two\n\nafter three\n\n"
      {_state, frames} = turn(trailing)

      assert reasons(frames) == ["degraded"]

      assert length(stables(frames)) == 2,
             "emission must stop at the definition line, not merely degrade at settle"

      # And the CONTROL: the same prose without the definition settles, so the
      # degrade is caused by the linkref and not by the shape around it.
      {_state, clean} = turn(without)
      assert reasons(clean) == ["settled"]
    end

    test "DEGRADE (b): an odd number of backtick runs yields ZERO commits" do
      # EarmarkParser swallows the later paragraph break into the committed
      # block — a converter fault no boundary law can fix, so the turn falls all
      # the way back to today's plain-tail floor.
      swallow = "Use the ` operator\n\nThen it works.\n\n"

      assert [%{"type" => "paragraph"}] = FromMarkdown.blocks(swallow),
             "the swallow is gone from the converter — this guard's reason with it"

      {_state, frames} = turn(swallow)
      assert stables(frames) == [], "no segment may be committed once parity is odd"
      assert reasons(frames) == ["degraded"]

      # PAIRED runs are ordinary prose and must still stream.
      {_state, paired} = turn("Use the `map` operator\n\nThen it works.\n\n")
      assert stables(paired) != []
      assert reasons(paired) == ["settled"]
    end

    test "backticks INSIDE a fence do not count toward parity" do
      # Stripping fences is StreamTail's law, reused rather than reimplemented.
      # The fence holds exactly ONE inline run, so an unstripped count would be
      # odd (open marker + inline + close marker = 3) and degrade the turn —
      # which is what makes this test able to fail if the strip is removed.
      text = "intro\n\n```\na ` b\n```\n\nafter\n\n"

      assert StreamTail.strip_fences("```\na ` b\n```\n") == "",
             "the fence must vanish entirely, markers included"

      {_state, frames} = turn(text)

      assert reasons(frames) == ["settled"]
      assert stables(frames) != []
    end

    test "a fabricated empty paragraph is stripped from a segment's edges" do
      # An empty paragraph IS the Mechanical-Spacing gap unit, so emitting one the
      # source did not contain fabricates content.
      #
      # HONEST NOTE: the HTML-block shape D60 cites as the natural producer of this
      # phantom does NOT reproduce on this converter — every `<div>`/`<!-- -->`/
      # `<table>` probe yields real paragraphs and zero empty ones. So the strip is
      # pinned at the seam that CAN fail: an injected converter that emits the gap
      # at both edges, which is exactly the shape a future divergence class would.
      gap = %{"type" => "paragraph", "content" => []}
      real = %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "kept"}]}

      {_state, frames} =
        drive("one\n\ntwo\n\n", chunk: 4, converter: fn _ -> [gap, real, gap] end)

      assert [%{blocks: blocks} | _] = stables(frames)
      assert blocks == [real], "edge gap blocks must never reach the wire"
    end
  end

  describe "the settle self-check (D61)" do
    test "concat(segments) == whole yields reason=settled" do
      text = "## Verified\n\nThe segments cover this turn byte for byte.\n\ntail\n\n"
      {_state, frames} = turn(text)

      assert reasons(frames) == ["settled"]
      assert blocks_of(frames) == FromMarkdown.blocks(text)
    end

    test "an injected divergence yields reason=degraded and never claims settled" do
      # The converter is the injected seam, so the divergence is introduced the
      # way a real unforeseen class would be — at conversion — with no test-only
      # branch anywhere in the production path.
      diverge = fn source ->
        if String.contains?(source, "tail"),
          do: [%{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "OTHER"}]}],
          else: FromMarkdown.blocks(source)
      end

      {_state, frames} =
        turn("first para\n\nsecond para\n\ntail para\n\n", converter: diverge)

      assert reasons(frames) == ["degraded"]

      # The walk proves the CLIENT consequence: a degrade drops every segment, so
      # committed bytes go back to 0 and the persisted row is what renders.
      assert %{outcome: :degraded, cursor: 0} = walk(frames)
    end

    test "the settle compares against the DURABLE text, not the accumulated deltas" do
      # The client SUPPRESSES the persisted row on `settled`, so a stream whose
      # deltas disagree with the row that persisted must degrade rather than
      # license a suppression of content the client never saw.
      {_state, frames} =
        turn("streamed para\n\nsecond\n\n", durable: "a COMPLETELY different answer\n\n")

      assert reasons(frames) == ["degraded"]
    end

    test "the final frame carries the held-back open block, converted in context" do
      # "tail para" never reaches a blank line, so it can only arrive at settle.
      text = "committed para\n\ntail para with no trailing blank"
      {_state, frames} = turn(text)

      assert reasons(frames) == ["settled"]
      assert blocks_of(frames) == FromMarkdown.blocks(text)

      last = frames |> stables() |> List.last()
      assert last.skeleton == nil, "a settled final frame has no forming remainder"
    end
  end

  describe "the bound (D64) — four numbers, and terminal means FREEZE" do
    setup do
      prev = Application.get_env(:barkpark, :claude_chat)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, :claude_chat, prev),
          else: Application.delete_env(:barkpark, :claude_chat)
      end)

      :ok
    end

    defp put_bound(key, value) do
      existing = Application.get_env(:barkpark, :claude_chat, [])
      Application.put_env(:barkpark, :claude_chat, Keyword.put(existing, key, value))
    end

    test "(a) max_stream_display_bytes caps one unbroken block with ZERO segments" do
      assert StreamSegments.max_stream_display_bytes() == 262_144

      put_bound(:max_stream_display_bytes, 4_096)
      assert StreamSegments.max_stream_display_bytes() == 4_096

      {state, frames} = drive(String.duplicate("x", 8_192), chunk: 1_024)

      # The fixture's `capped_after_zero_stable_frames` shape, produced for real.
      assert stables(frames) == []
      assert reasons(frames) == ["capped"]
      assert state.phase == :ended

      # FREEZE, not shed: further deltas are ignored and NOTHING further is
      # emitted — the caller's stream stays open.
      {state, more} = StreamSegments.advance(state, "more bytes", 99_999)
      assert more == []
      assert state.phase == :ended
    end

    test "(a) the capped state RELEASES the bytes it was holding" do
      put_bound(:max_stream_display_bytes, 4_096)
      {state, _frames} = drive(String.duplicate("para\n\n", 2_000), chunk: 512)

      assert state.phase == :ended
      # A memory policy that keeps the memory is not a policy.
      assert byte_size(state.tail.text) == 0
      assert state.blocks == []
    end

    test "(b) min_segment_interval_ms coalesces a burst without losing bytes" do
      assert StreamSegments.min_segment_interval_ms() == 50

      text = "a\n\nb\n\nc\n\nd\n\ne\n\n"

      # tick 0: every delta shares one timestamp, so the interval bites.
      {_state, throttled} = drive(text, chunk: 3, tick: 0)
      # tick 1000: well past the interval, so each boundary emits.
      {_state, free} = drive(text, chunk: 3, tick: 1_000)

      assert length(stables(throttled)) < length(stables(free))

      # NOTHING is shed: a coalesced turn still settles with the same document.
      {_state, whole} = turn(text, chunk: 3, tick: 0)
      assert reasons(whole) == ["settled"]
      assert blocks_of(whole) == FromMarkdown.blocks(text)
    end

    test "(b) is config-overridable, and is a COALESCER — never a terminal state" do
      put_bound(:min_segment_interval_ms, 5_000)
      assert StreamSegments.min_segment_interval_ms() == 5_000

      text = "a\n\nb\n\nc\n\nd\n\n"
      # Deltas 400 ms apart: every boundary after the first is inside the interval.
      {_state, frames} = drive(text, chunk: 3, tick: 400)
      assert length(stables(frames)) == 1

      # CONTESTED (see the report): D64 says all FOUR numbers terminate into
      # `capped`, but a rate limiter has nothing to terminate — coalescing loses
      # no bytes, and freezing here would DROP content the settle must still
      # deliver. So (b) emits no terminal frame, and the turn still settles whole.
      assert reasons(frames) == []

      {_state, whole} = turn(text, chunk: 3, tick: 400)
      assert reasons(whole) == ["settled"]
      assert blocks_of(whole) == FromMarkdown.blocks(text)
    end

    test "(c) max_segments_per_turn stops the pathological shape UNDER the byte cap" do
      assert StreamSegments.max_segments_per_turn() == 4_096

      # 1 MiB of "a\n\n" advances 349,525 times with every frame tiny — the axis a
      # byte cap structurally cannot see.
      {state, frames} = drive(String.duplicate("a\n\n", 20_000), chunk: 3)

      assert length(stables(frames)) == 4_096
      assert reasons(frames) == ["capped"]

      assert byte_size(state.tail.text) == 0, "the frozen state released its bytes"
      # The discriminating half: the frame bound stopped it, not the byte bound.
      assert 4_096 * 3 < StreamSegments.max_stream_display_bytes()
    end

    test "(c) is config-overridable" do
      put_bound(:max_segments_per_turn, 3)
      assert StreamSegments.max_segments_per_turn() == 3

      {_state, frames} = drive(String.duplicate("a\n\n", 50), chunk: 3)
      assert length(stables(frames)) == 3
      assert reasons(frames) == ["capped"]
    end

    test "(d) max_segment_frame_bytes never lets an oversize frame reach the wire" do
      assert StreamSegments.max_segment_frame_bytes() == 262_144

      put_bound(:max_segment_frame_bytes, 512)

      # One closed fence is ONE boundary jump, so a single segment can be huge —
      # append-only bounds the TOTAL, not the frame.
      fence = "```\n" <> String.duplicate("x", 4_000) <> "\n```\n\n"
      {_state, frames} = drive(fence, chunk: 500)

      assert stables(frames) == []
      assert reasons(frames) == ["capped"]
    end

    test "(d) every emitted frame is under the bound, measured on the ENCODED bytes" do
      {_state, frames} = turn(String.duplicate("Ordinary prose paragraph.\n\n", 40))

      for frame <- frames do
        encoded = ChatController.sse_stable_frame(frame)

        assert byte_size(encoded) <= StreamSegments.max_segment_frame_bytes() + 64,
               "a frame encoded to #{byte_size(encoded)} bytes"

        # Go's hard per-line ceiling, the reason the bound exists at all.
        assert byte_size(encoded) < 1_048_575
      end
    end
  end

  describe "the connect-time snapshot (D63)" do
    test "carries every committed segment from 0, and a fresh client accepts it" do
      {state, frames} = drive("## Head\n\nfirst para\n\nsecond para\n\nstill forming", chunk: 11)

      assert {:stable, snapshot} = StreamSegments.snapshot(state)
      assert snapshot.from == 0
      assert snapshot.to == state.emitted_to
      assert snapshot.turn == 1

      # Every block committed so far, in order — this IS the reconnect fix.
      assert snapshot.blocks == blocks_of(frames)

      # A client that attaches cold and sees ONLY the snapshot is caught up.
      assert %{outcome: :open, cursor: cursor, accepted: 1} = walk([{:stable, snapshot}])
      assert cursor == state.emitted_to
    end

    test "degrades to nil rather than half-answering" do
      # Nothing committed yet.
      {fresh, _} = drive("no boundary yet", chunk: 5)
      assert StreamSegments.snapshot(fresh) == nil

      # A frozen turn: the client renders the persisted row, not a stale prefix.
      {ended, _} = turn("para\n\n")
      assert ended.phase == :ended
      assert StreamSegments.snapshot(ended) == nil
    end

    test "a snapshot over the frame bound is dropped, not truncated" do
      {state, _frames} = drive("para one\n\npara two\n\nforming", chunk: 8)
      assert StreamSegments.snapshot(state) != nil

      prev = Application.get_env(:barkpark, :claude_chat)
      on_exit(fn -> restore_claude_chat(prev) end)
      put_bound(:max_segment_frame_bytes, 16)

      assert StreamSegments.snapshot(state) == nil
    end

    test "a snapshot's skeleton.prose carries the HELD bytes as well as the prose above" do
      # The only path where `to` lags the boundary: a segment is held (here by the
      # min-interval bound) while a component starts forming past it. Those held
      # bytes sit between `to` and the component, so the snapshot MUST stream them
      # as live text — dropping them is precisely the D67 defect where a forming
      # component hides 100 % of the bytes above it.
      {state, frames} =
        ["intro\n\n", "more prose\n\nlead\n| x |"]
        |> Enum.reduce({StreamSegments.new(1), [], 0}, fn delta, {st, acc, n} ->
          {st, fs} = StreamSegments.advance(st, delta, 10_000 + n * 0)
          {st, acc ++ fs, n + 1}
        end)
        |> then(fn {st, fs, _n} -> {st, fs} end)

      assert [%{to: 7}] = stables(frames), "the first paragraph committed, the rest held"
      assert state.tail.stable_len == 19, "a later boundary exists but was throttled"

      assert {:stable, %{to: 7, skeleton: %{kind: "table", prose: prose}}} =
               StreamSegments.snapshot(state)

      assert prose == "more prose\n\nlead\n"
    end

    test "Recorder.stable_snapshot/1 answers nil for a session with no recorder" do
      assert Recorder.stable_snapshot(Ecto.UUID.generate()) == nil
    end
  end

  describe "the Recorder seam (D63) — both provider lanes, fail-soft" do
    setup do
      prev = Application.get_env(:barkpark, :claude_chat)
      prev_demo = Application.get_env(:barkpark, :public_demo_studio)
      # `cat` echoes stdin; frames are delivered to the Recorder directly (the
      # Session's sink shape), so no CLI runs. `public_demo_studio` must be false
      # or `ClaudeChat.enabled?/0` fails closed and no Recorder starts at all.
      Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
      Application.put_env(:barkpark, :public_demo_studio, false)

      on_exit(fn ->
        Barkpark.StudioChat.RuntimeSupervisor
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn
          {_, pid, _, _} when is_pid(pid) ->
            DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)

          _ ->
            :ok
        end)

        restore_claude_chat(prev)
        Application.put_env(:barkpark, :public_demo_studio, prev_demo)
      end)

      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, mode: "plan"})
      {:ok, recorder} = Recorder.ensure(%{session_id: id, mode: "plan", resume: false})
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(id))
      %{sid: id, recorder: recorder}
    end

    defp send_frame(recorder, msg) do
      send(recorder, msg)
      :sys.get_state(recorder)
      :ok
    end

    defp claude_delta(text) do
      {:claude_chat_event,
       %{
         "type" => "stream_event",
         "event" => %{
           "type" => "content_block_delta",
           "delta" => %{"type" => "text_delta", "text" => text}
         }
       }}
    end

    defp collect_stable(acc \\ []) do
      receive do
        {:chat_stable, frame} -> collect_stable([frame | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "the CLAUDE lane emits stable frames and settles against the assistant row",
         %{recorder: recorder} do
      send_frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
      send_frame(recorder, claude_delta("## Live\n\n"))
      send_frame(recorder, claude_delta("A paragraph that settles.\n\n"))
      send_frame(recorder, claude_delta("tail\n"))

      whole = "## Live\n\nA paragraph that settles.\n\ntail\n"

      send_frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{"content" => [%{"type" => "text", "text" => whole}]}
         }}
      )

      frames = collect_stable()
      assert stables(frames) != [], "the claude lane emitted no segments"
      assert reasons(frames) == ["settled"]
      assert walk(frames).outcome == :settled
      assert blocks_of(frames) == FromMarkdown.blocks(whole)
    end

    test "the settle degrades when the persisted row disagrees with the streamed deltas",
         %{recorder: recorder} do
      # The client SUPPRESSES the persisted row on `settled`, so the Recorder must
      # hand the settle the text that ACTUALLY PERSISTED — never its own
      # accumulator, which would make the comparison trivially self-agreeing and
      # license suppressing a row the client was never shown.
      send_frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
      send_frame(recorder, claude_delta("streamed answer\n\nmore streamed\n\n"))
      assert stables(collect_stable()) != []

      send_frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [%{"type" => "text", "text" => "a COMPLETELY different row\n\n"}]
           }
         }}
      )

      assert reasons(collect_stable()) == ["degraded"]
    end

    test "a thinking_delta on the SAME envelope contributes NOTHING to the document",
         %{recorder: recorder} do
      send_frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})

      send_frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "stream_event",
           "event" => %{
             "type" => "content_block_delta",
             "delta" => %{"type" => "thinking_delta", "thinking" => "secret reasoning\n\n"}
           }
         }}
      )

      # A `tool_delta` carrying a `text` key is the shape that makes the clause's
      # TYPE check load-bearing: without it, a loose `%{"text" => text}` match
      # splices command output into the answer. (`thinking_delta` above cannot
      # reach it either way — it carries `thinking`, not `text` — so this frame is
      # what actually discriminates.)
      send_frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "stream_event",
           "event" => %{
             "type" => "content_block_delta",
             "delta" => %{"type" => "tool_delta", "text" => "SPLICED COMMAND OUTPUT\n\n"}
           }
         }}
      )

      send_frame(recorder, claude_delta("real answer\n\nsecond\n\n"))

      frames = collect_stable()
      text = frames |> blocks_of() |> Jason.encode!()
      refute text =~ "secret reasoning"
      refute text =~ "SPLICED COMMAND OUTPUT"
      assert text =~ "real answer"
    end

    test "the RUNTIME (codex) lane feeds the same accumulator", %{recorder: recorder} do
      send_frame(recorder, {:studio_chat_runtime_event, %Event{kind: :turn_started}})

      for chunk <- ["## Codex\n", "\nfirst para\n", "\nsecond para\n\n"] do
        send_frame(
          recorder,
          {:studio_chat_runtime_event,
           %Event{kind: :text_delta, native: %{"params" => %{"delta" => chunk}}}}
        )
      end

      send_frame(recorder, {:studio_chat_runtime_event, %Event{kind: :turn_completed}})

      frames = collect_stable()
      assert stables(frames) != [], "the codex lane emitted no segments"
      assert reasons(frames) == ["settled"]
      assert walk(frames).outcome == :settled
    end

    test "the per-session turn counter is monotone across turns", %{recorder: recorder} do
      for text <- ["turn one para\n\nmore\n\n", "turn two para\n\nmore\n\n"] do
        send_frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
        send_frame(recorder, claude_delta(text))

        send_frame(
          recorder,
          {:claude_chat_event,
           %{
             "type" => "assistant",
             "message" => %{"content" => [%{"type" => "text", "text" => text}]}
           }}
        )
      end

      turns =
        collect_stable()
        |> Enum.map(fn {_kind, payload} -> payload.turn end)
        |> Enum.uniq()

      assert turns == [1, 2], "turn identity must be server-authored and monotone"
    end

    test "a derivation FAULT degrades the segments and NEVER ends the recording",
         %{sid: sid, recorder: recorder} do
      send_frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
      send_frame(recorder, claude_delta("healthy para\n\nmore\n\n"))
      assert stables(collect_stable()) != []

      # Force the derivation to raise the way a converter or fold bug would, by
      # corrupting the accumulator the next delta folds into.
      :sys.replace_state(recorder, fn state -> %{state | stable: %{state.stable | tail: %{}}} end)

      send_frame(recorder, claude_delta("this delta faults\n\n"))

      # The recording SURVIVES — `restart: :temporary` means a crash here would
      # have ended it and lost the turn's durable text.
      assert Process.alive?(recorder)
      assert reasons(collect_stable()) == ["degraded"]

      # And the durable path still works after the fault.
      send_frame(
        recorder,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{"content" => [%{"type" => "text", "text" => "durable answer"}]}
         }}
      )

      assert Enum.any?(StudioChat.list_messages(sid), &(&1.source_markdown == "durable answer"))
    end

    test "after a fault, NO further stable frames are emitted for that turn",
         %{recorder: recorder} do
      send_frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
      send_frame(recorder, claude_delta("healthy\n\nmore\n\n"))
      collect_stable()

      :sys.replace_state(recorder, fn state -> %{state | stable: %{state.stable | tail: %{}}} end)
      send_frame(recorder, claude_delta("faults\n\n"))
      assert reasons(collect_stable()) == ["degraded"]

      send_frame(recorder, claude_delta("still nothing\n\nmore\n\n"))
      assert collect_stable() == []

      # Re-armed at the next turn boundary, not stuck off forever.
      send_frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
      send_frame(recorder, claude_delta("fresh turn\n\nmore\n\n"))
      assert stables(collect_stable()) != []
    end

    test "a mid-turn snapshot from the LIVE recorder carries the committed prefix",
         %{sid: sid, recorder: recorder} do
      send_frame(recorder, {:claude_chat_event, %{"type" => "system", "subtype" => "init"}})
      send_frame(recorder, claude_delta("first para\n\nsecond para\n\nstill forming"))

      emitted = collect_stable()
      assert {:stable, snapshot} = Recorder.stable_snapshot(sid)
      assert snapshot.from == 0
      assert snapshot.blocks == blocks_of(emitted)
    end
  end

  describe "blast radius — the OTHER subscriber to the same topic" do
    test "the Studio LiveView ignores a stable frame instead of crashing" do
      # `chat_live.ex` subscribes to the very topic the Recorder now broadcasts
      # `{:chat_stable, _}` on. It has no clause for it, so it MUST fall to the
      # catch-all — a greedier clause added later, or the catch-all removed, would
      # take down every open Studio tab on the first streaming turn.
      socket = %Phoenix.LiveView.Socket{}

      frame = {:stable, %{turn: 1, from: 0, to: 4, blocks: [], skeleton: nil}}

      assert {:noreply, ^socket} =
               BarkparkWeb.Studio.ChatLive.handle_info({:chat_stable, frame}, socket)

      assert {:noreply, ^socket} =
               BarkparkWeb.Studio.ChatLive.handle_info(
                 {:chat_stable, {:stable_end, %{turn: 1, from: 4, reason: "settled"}}},
                 socket
               )
    end
  end

  describe "the SSE seam" do
    test "serializes both kinds as id-less event/data pairs" do
      stable =
        {:stable, %{turn: 3, from: 10, to: 20, blocks: [%{"type" => "divider"}], skeleton: nil}}

      # Compared as DECODED JSON, not as a byte string: Jason emits map keys in
      # term order, so a byte assertion would pin an ordering the contract never
      # claimed and would red on an unrelated key rename.
      assert {"stable", payload} = split_frame(ChatController.sse_stable_frame(stable))

      assert payload == %{
               "turn" => 3,
               "from" => 10,
               "to" => 20,
               "blocks" => [%{"type" => "divider"}],
               "skeleton" => nil
             }

      closer = {:stable_end, %{turn: 3, from: 20, reason: "settled"}}
      assert {"stable_end", end_payload} = split_frame(ChatController.sse_stable_frame(closer))
      assert end_payload == %{"turn" => 3, "from" => 20, "reason" => "settled"}
    end

    test "the payload is JSON, never raw markdown" do
      {_state, frames} = turn("# Head\n\nprose with  spaces\n\n")
      assert frames != []

      for frame <- frames do
        assert {event, payload} = split_frame(ChatController.sse_stable_frame(frame))
        assert event in ~w(stable stable_end)
        assert is_map(payload)
      end
    end
  end

  # `event: <name>\ndata: <json>\n\n` → `{name, decoded}`.
  defp split_frame(serialized) do
    ["event: " <> event, "data: " <> data, "", ""] = String.split(serialized, "\n")
    {event, Jason.decode!(data)}
  end

  defp restore_claude_chat(prev) do
    if prev,
      do: Application.put_env(:barkpark, :claude_chat, prev),
      else: Application.delete_env(:barkpark, :claude_chat)
  end
end
