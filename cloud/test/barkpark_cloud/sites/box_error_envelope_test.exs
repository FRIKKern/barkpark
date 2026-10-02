defmodule BarkparkCloud.Sites.BoxErrorEnvelopeTest do
  @moduledoc """
  task-3468f99ad5a4e9b8 criterion 0 — `box_error` NEVER emits a map, on BOTH
  build-log routes, and the envelope's `request_id` and `message` reach the wire
  under keys of their own instead of being dropped.

  THE BODY IS THE REAL ONE. `@observed_500_body` is the verbatim box answer
  `curl` read on 2026-09-18 for site `app`, deployment
  `91fe0b3f-0371-431d-8248-d437059dda84` — pasted into the row's description and
  decoded here by `Jason.decode!/1` rather than hand-built as an Elixir map, so a
  test that passes has passed on the shape that actually broke. (The row elides
  the tail of `hint` with `...`; `hint` is read by nothing here.)
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Sites.{BuildLog, BuildLogBytes}

  # VERBATIM from the row's `curl` capture of the box's generic 500 handler.
  @observed_500_body """
  {"error":{"code":"internal_error","hint":"Retry shortly; ...","message":"unknown error (FunctionClauseError)","request_id":"GNZOQHLsqlWoMDkAE8Vx"}}
  """

  defp observed, do: Jason.decode!(@observed_500_body)

  defp wires(reply) do
    %{
      record: BuildLog.wire(reply, "91fe0b3f-0371-431d-8248-d437059dda84", "0bc2581994dea0f8"),
      bytes: BuildLogBytes.wire(reply, "91fe0b3f-0371-431d-8248-d437059dda84", "0bc2581994dea0f8")
    }
  end

  describe "the observed box 500 envelope" do
    test "reduces to the code SLUG on both routes — never a map, never an inspected map" do
      %{record: {502, record}, bytes: {502, bytes}} = wires({:ok, 500, observed()})

      for {route, body} <- [record: record, bytes: bytes] do
        refute is_map(body.box_error), "#{route}: box_error is still a MAP"

        assert body.box_error == "internal_error",
               "#{route}: expected the envelope's code slug, got #{inspect(body.box_error)}"

        # THE CHEAP FAKE GREEN, refused by name: `inspect/1`/`to_string/1` on the
        # envelope is "not a map" and still unusable to an operator.
        refute body.box_error =~ "=>", "#{route}: box_error is a STRINGIFIED map"
        refute body.box_error =~ "%{", "#{route}: box_error is a STRINGIFIED map"
      end
    end

    test "carries request_id and message to the wire under keys of their own" do
      %{record: {502, record}, bytes: {502, bytes}} = wires({:ok, 500, observed()})

      for {route, body} <- [record: record, bytes: bytes] do
        assert body.box_error_request_id == "GNZOQHLsqlWoMDkAE8Vx",
               "#{route}: the one token that routes the incident was dropped"

        assert body.box_error_message == "unknown error (FunctionClauseError)",
               "#{route}: the box's own diagnosis was dropped"
      end
    end

    test "the whole 502 body survives JSON encoding with box_error as a STRING" do
      {502, record} = BuildLog.wire({:ok, 500, observed()}, "dep-1", "bld-1")

      decoded = record |> Jason.encode!() |> Jason.decode!()

      assert is_binary(decoded["box_error"])
      assert decoded["box_error"] == "internal_error"
      assert decoded["box_error_request_id"] == "GNZOQHLsqlWoMDkAE8Vx"
      assert decoded["box_error_message"] == "unknown error (FunctionClauseError)"
    end
  end

  describe "the existing slug-string case is unchanged" do
    test "a slug body passes through verbatim, with no companion facts invented" do
      # 500, not 422: the BYTES route gives 422 and 410 their own arms, so a
      # 422 here would compare the two routes on bodies they read differently.
      %{record: {502, record}, bytes: {502, bytes}} =
        wires({:ok, 500, %{"error" => "build_log_unscrubbed"}})

      for {route, body} <- [record: record, bytes: bytes] do
        assert body.box_error == "build_log_unscrubbed", "#{route}"
        assert body.box_error_request_id == nil, "#{route}"
        assert body.box_error_message == nil, "#{route}"
      end
    end

    test "the `code` fallback and the no-body case are unchanged" do
      %{record: {502, record}} = wires({:ok, 500, %{"code" => "build_log_evicted"}})
      assert record.box_error == "build_log_evicted"

      %{record: {502, empty}} = wires({:ok, 500, %{}})
      assert empty.box_error == nil
      assert empty.box_error_request_id == nil
    end
  end

  describe "the mirror is locked" do
    # The two clauses were byte-identical copies and the row exists because one
    # of them would be fixed alone. They now call ONE shared reducer
    # (`BoxErrorEnvelope.fields/1`); this arm proves it from the OUTSIDE, so a
    # future re-inlining of either copy reds here as well as at the call site.
    @bodies [
      %{"error" => "build_log_unscrubbed"},
      %{"code" => "build_log_evicted"},
      %{},
      %{"error" => 500},
      %{"error" => %{"code" => "internal_error"}}
    ]

    test "both routes produce TERM-IDENTICAL box_error fields for the same body" do
      for body <- [nil | @bodies] ++ [%{"body" => nil}] do
        %{record: {502, record}, bytes: {502, bytes}} = wires({:ok, 500, body || %{}})

        assert Map.take(record, [:box_error, :box_error_message, :box_error_request_id]) ==
                 Map.take(bytes, [:box_error, :box_error_message, :box_error_request_id]),
               "the two routes diverged on #{inspect(body)}"
      end
    end

    test "a non-string, non-map error reduces to nil rather than a typed lie" do
      %{record: {502, record}} = wires({:ok, 500, %{"error" => 500}})
      assert record.box_error == nil
    end
  end
end
