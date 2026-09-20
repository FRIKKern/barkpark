defmodule Barkpark.Tasks.HistoryEventsCallerWireLockTest do
  @moduledoc """
  PRODUCER-SIDE LOCK on the `payload.caller` wire shape that `bp task history`
  decodes (task-0647db6033962337).

  ## The gap this closes

  `internal/cli/tasks_history_events_test.go` carries a CAPTURED SNAPSHOT of
  this emitter's wire shape — "the live shape, verbatim from guerrilla
  2026-09-20 event 462527". The capture is real and says so at its definition,
  which is the good half. The absent half was a lock: nothing on the producer
  side regenerated it, freshness-checked it, or asserted conformance back.

  So the api could rename or drop a `caller` field and BOTH suites stay green —
  the Elixir suite because it never read the Go fixture, the Go suite because it
  decodes its own stale snapshot. `bp task history` would then report
  UNMEASURED or a partial caller block to every operator, and the first person
  to notice is the one asking "who closed this row" during an incident.

  ## Which of the two shapes this is

  This is the FIRST of the two the row names: **a test under the required
  Elixir gate that reads the Go fixture's literal bytes and asserts the live
  emitter still produces that shape.** It is NOT a regenerate-plus-freshness
  check, and it is deliberately not a paths-filtered workflow: a guard that
  publishes no check run on a non-matching PR can never be made required
  without deadlocking the branch (#15374 -> #15521).

  ## Why it is not a tautology

  The fixture is never asserted against itself. One side is READ FROM DISK
  (the Go test file's JSON literals, parsed with Jason); the other side is
  CALLED AT RUNTIME (`Internal.caller_stamp/2`, the real emitter every task
  mutation path threads — claim.ex, close.ex, pulse.ex, release.ex all call
  it). A rename on either side moves exactly one of the two and reds.

  ## Precedent followed

  `api/test/barkpark/tasks/board_theme_parity_test.exs` — an api-side ExUnit
  test that reads `../internal/taskboard/*.go` from the mix root and parses it,
  cited by SYMBOL rather than by line. Same shape, same read-only posture
  toward the Go tree. (The Go-side mirror of this idea is
  `internal/cloudclient/producer_contract_test.go`, which reads the Elixir
  serializer; this row asked for the direction that fires under the gate that
  already blocks.)

  ## Anti-vacuity

  `read_go_source!/1` REFUSES on an unreadable or empty read, and
  `caller_wire_keys!/2` REFUSES when the literals it needs are absent, rather
  than yielding an empty set that would compare equal to nothing and pass. The
  positive control feeds the extractor a renamed synthetic source and asserts
  the extraction MOVES with the bytes, so a scan that had silently stopped
  seeing the fields it guards cannot report success.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Internal

  # The mix root is `api/`; the Go CLI lives one level up. The fixture is the
  # captured snapshot; the decoder is the consumer that must be able to read
  # whatever the emitter writes.
  @go_fixture "../internal/cli/tasks_history_events_test.go"
  @go_decoder "../internal/cli/tasks_history_events.go"

  # A `"caller": { … }` object literal inside a Go backtick/interpreted string.
  # Non-greedy to the first `}` — the caller block is flat by construction
  # (`caller_identity_stamp/2` builds a one-level map of binaries).
  @caller_object ~r/"caller"\s*:\s*\{(.*?)\}/s

  # ── the extractor, and its refusals ──────────────────────────────────────

  defp read_go_source!(path) do
    case File.read(path) do
      {:ok, body} ->
        if String.trim(body) == "" do
          flunk("""
          REFUSING an empty read of #{path}.
          An empty source yields an empty key set, which compares equal to
          nothing and would let this lock pass while guarding nothing.
          """)
        end

        body

      {:error, reason} ->
        flunk("""
        REFUSING an unreadable read of #{path} (#{:file.format_error(reason)}).
        The Go side of this contract has moved or been deleted. Re-point this
        test at the file that now carries the fixture — do NOT soften the read
        into a skip: a lock that tolerates a missing subject is a vacuous pass.
        """)
    end
  end

  @doc false
  # The union of the field names of every `"caller": {…}` literal in `src`.
  # Raises (via flunk) rather than returning `[]` when it finds nothing.
  def caller_wire_keys!(src, whence) do
    objects = Regex.scan(@caller_object, src, capture: :all_but_first)

    if objects == [] do
      flunk("""
      REFUSING: no `"caller": { … }` literal found in #{whence}.
      The extractor can no longer see the fields it guards, so any verdict it
      prints is a verdict about nothing.
      """)
    end

    keys =
      objects
      |> Enum.flat_map(fn [body] ->
        case Jason.decode("{" <> body <> "}") do
          {:ok, map} when is_map(map) -> Map.keys(map)
          _ -> []
        end
      end)
      |> MapSet.new()

    if MapSet.size(keys) == 0 do
      flunk("""
      REFUSING: every `"caller": { … }` literal in #{whence} failed to decode.
      #{length(objects)} literal(s) matched and none yielded a field name.
      """)
    end

    keys
  end

  # The values the fixture pins for a given caller field (non-empty only).
  defp caller_field_values(src, field) do
    @caller_object
    |> Regex.scan(src, capture: :all_but_first)
    |> Enum.flat_map(fn [body] ->
      case Jason.decode("{" <> body <> "}") do
        {:ok, %{^field => v}} when is_binary(v) and v != "" -> [v]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # The live emitter, called — not read. `caller_stamp/2` is what claim.ex,
  # close.ex, pulse.ex and release.ex each merge into their mutation event's
  # document map.
  defp emitted_caller do
    stamp = Internal.caller_stamp("e5ce2b91-e38d-426e-ae68-5006dc414b97", "s_a27da76950c664eb")
    Map.fetch!(stamp, "caller")
  end

  # ── the lock ─────────────────────────────────────────────────────────────

  describe "the Go fixture's captured caller shape vs the live Elixir emitter" do
    test "the emitter's caller field names are EXACTLY the ones the Go fixture captured" do
      fixture = caller_wire_keys!(read_go_source!(@go_fixture), @go_fixture)
      emitted = emitted_caller() |> Map.keys() |> MapSet.new()

      assert MapSet.equal?(emitted, fixture), """
      The task-event `payload.caller` wire shape and its captured snapshot in
      the Go CLI have DRIFTED.

        emitted by Internal.caller_stamp/2 : #{inspect(Enum.sort(emitted))}
        captured in #{@go_fixture} : #{inspect(Enum.sort(fixture))}

        only in the emitter : #{inspect(emitted |> MapSet.difference(fixture) |> Enum.sort())}
        only in the fixture : #{inspect(fixture |> MapSet.difference(emitted) |> Enum.sort())}

      If the api deliberately changed the shape, update the Go fixture AND
      internal/cli/tasks_history_events.go's decodeEventCaller in the SAME
      change — `bp task history` reads this block to answer "who mutated this
      row", and a field it cannot find reads as UNMEASURED to every operator.
      """
    end

    test "the emitter's caller block is nested under the key the Go decoder looks for" do
      stamp = Internal.caller_stamp("tok-1", "s_1")

      assert Map.has_key?(stamp, "caller"), """
      caller_stamp/2 no longer writes a top-level "caller" key. decodeEventCaller
      in #{@go_decoder} unmarshals `json:"caller"` and returns nil for anything
      else, which the CLI renders as UNMEASURED.
      """

      decoder = read_go_source!(@go_decoder)

      assert decoder =~ ~s(json:"caller"), """
      #{@go_decoder} no longer declares a `json:"caller"` tag — the consumer
      moved and this lock is pointed at the wrong file.
      """
    end

    test "the emitter's caller.kind value is the literal the fixture pins" do
      fixture_kinds = caller_field_values(read_go_source!(@go_fixture), "kind")

      assert fixture_kinds != [], """
      REFUSING: the fixture pins no non-empty caller.kind value, so this arm
      would assert nothing.
      """

      assert Map.fetch!(emitted_caller(), "kind") in fixture_kinds,
             "emitted caller.kind=#{inspect(Map.fetch!(emitted_caller(), "kind"))} " <>
               "is not among the values the Go fixture captured: #{inspect(fixture_kinds)}"
    end

    test "a tokenless caller still emits NO caller key, the UNMEASURED case the Go side splits on" do
      # The Go decoder distinguishes an absent caller (nil, UNMEASURED) from a
      # present-but-empty one (ANSWERED-EMPTY). Emitting `%{}` here would
      # collapse that split for the whole back catalogue.
      assert Internal.caller_identity_stamp(nil, nil) == %{}
      assert Internal.caller_identity_stamp("", "") == %{}
    end
  end

  # ── the positive control: the extractor can SEE what it guards ───────────

  describe "extractor controls" do
    test "the extractor reads the bytes it is given, not a constant" do
      real = read_go_source!(@go_fixture)
      keys = caller_wire_keys!(real, "the real fixture")

      # Positive control: it can see the three fields this lock exists for.
      for field <- ~w(kind id session) do
        assert MapSet.member?(keys, field),
               "the extractor cannot see caller.#{field} in the real fixture — " <>
                 "it has gone blind to a field it is supposed to guard"
      end

      # And it MOVES when the bytes move: rename one field in a synthetic
      # source and the extraction must follow. A constant would not.
      renamed = String.replace(real, ~s("kind":"api_token"), ~s("principal_kind":"api_token"))
      refute renamed == real, "the control mutation did not apply — the fixture literal moved"

      renamed_keys = caller_wire_keys!(renamed, "a renamed synthetic source")

      assert MapSet.member?(renamed_keys, "principal_kind"),
             "the extractor did not follow a renamed field — it is not reading the source"
    end

    test "the extractor REFUSES an empty source rather than returning an empty set" do
      assert_raise ExUnit.AssertionError, fn -> caller_wire_keys!("", "an empty source") end
    end

    test "the extractor REFUSES a source with no caller literal" do
      assert_raise ExUnit.AssertionError, fn ->
        caller_wire_keys!(~s(package cli\n// nothing to see here\n), "a caller-less source")
      end
    end

    test "the reader REFUSES a path that does not exist" do
      assert_raise ExUnit.AssertionError, fn ->
        read_go_source!("../internal/cli/this_file_does_not_exist.go")
      end
    end
  end
end
