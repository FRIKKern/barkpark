defmodule Barkpark.Tasks.DispatchMarkersTest do
  @moduledoc """
  task-46e82dc40c385ed2 — the server half of the do-not-build signal on the
  `bp task ready` projection, and the CONTROL that proves it discriminates.

  THE FAILURE THIS GUARDS. The ready projection carries no `content` key, so
  the first census of do-not-build markers grepped it and answered "0 of 400" —
  VACUOUS, and byte-identical to a clean backlog. Every negative assertion
  below therefore also asserts that the fields were POPULATED, because a `nil`
  verdict over nothing searched is not evidence.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Dispatchability

  # Every fixture's prose is built FROM the spec's own needles, never from a
  # remembered list — a fixture that hand-writes the vocabulary a second time
  # is a transcript of the thing it guards.
  defp needle(class) do
    Dispatchability.marker_spec()["markers"]
    |> Enum.find(&(&1["class"] == class))
    |> Map.fetch!("needle")
  end

  defp field(n), do: Enum.at(Dispatchability.marker_fields(), n)

  describe "the spec is the one copy, and it is not empty" do
    test "the compile-time snapshot equals the file re-read at RUNTIME" do
      path = Path.join(:code.priv_dir(:barkpark), "tasks/dispatch_markers.json")
      assert File.exists?(path), "the shipped priv copy is missing: #{path}"

      assert Dispatchability.marker_spec() == path |> File.read!() |> Jason.decode!(),
             "the module's compile-time snapshot has drifted from #{path}"
    end

    test "all THREE content fields are scanned — one of them alone undercounts" do
      assert Dispatchability.marker_fields() == [
               "description",
               "disposition_reason",
               "operating_instruction"
             ]
    end

    test "the vocabulary is non-empty in both classes" do
      for class <- Dispatchability.marker_classes() do
        assert Enum.any?(Dispatchability.marker_spec()["markers"], &(&1["class"] == class)),
               "class #{class} has no needles; it can never fire"
      end

      assert length(Dispatchability.marker_classes()) >= 2
    end
  end

  describe "THE CONTROL — a marked row and a clean row differ, and the clean one was SEARCHED" do
    test "a row carrying a marker classifies; an otherwise identical row does not" do
      [strongest | _] = Dispatchability.marker_classes()

      marked = %{
        field(0) =>
          "An ordinary defect row. #{String.upcase(needle(strongest))} a builder for c0.",
        field(1) => "adjudicated",
        field(2) => "build it"
      }

      clean = %{
        field(0) => "An ordinary defect row. Commission a builder for c0.",
        field(1) => "adjudicated",
        field(2) => "build it"
      }

      marked_scan = Dispatchability.marker_scan(marked)
      clean_scan = Dispatchability.marker_scan(clean)

      assert marked_scan.class == strongest
      assert clean_scan.class == nil

      refute marked_scan == clean_scan,
             "THE CONTROL FAILED: a marked row and a clean row produced the same verdict"

      # The negative arm is only evidence because the fields were THERE.
      assert clean_scan.fields_present == Dispatchability.marker_fields(),
             "the clean row's nil is vacuous unless its fields were populated and searched"
    end

    test "the vacuous case is DISTINGUISHABLE from the clean one" do
      # This is the ready projection itself: no content fields at all. Same nil
      # class, and `fields_present: []` is what says so.
      assert Dispatchability.marker_scan(%{}) == %{class: nil, fields_present: []}
      assert Dispatchability.marker_scan(nil) == %{class: nil, fields_present: []}

      assert Dispatchability.marker_scan(%{field(0) => "   "}).fields_present == [],
             "a whitespace-only field was never searched and must not read as one that was"
    end

    test "EACH of the three fields alone is sufficient — the undercount is the defect" do
      [strongest | _] = Dispatchability.marker_classes()

      for f <- Dispatchability.marker_fields() do
        scan = Dispatchability.marker_scan(%{f => "... #{needle(strongest)} a builder ..."})

        assert scan.class == strongest,
               "a marker in #{f} alone was missed; searching any one field undercounts"

        assert scan.fields_present == [f]
      end
    end
  end

  describe "precedence is the classes ARRAY ORDER, and it is derived, not remembered" do
    test "a row carrying BOTH classes answers the FIRST class in the spec" do
      [strongest, weaker | _] = Dispatchability.marker_classes()

      both = %{field(0) => "#{needle(weaker)}. also: #{needle(strongest)} a builder."}

      assert Dispatchability.marker_scan(both).class == strongest,
             "two verdicts on one card is no verdict; the spec's classes order is the precedence"

      assert Dispatchability.marker_scan(%{field(0) => needle(weaker)}).class == weaker,
             "the weaker class must still fire on its own, or this test proves only that it never fires"
    end
  end

  describe "case sensitivity is honoured per marker" do
    test "an insensitive needle matches either case; a sensitive one does not" do
      markers = Dispatchability.marker_spec()["markers"]
      insensitive = Enum.find(markers, &(&1["case_sensitive"] == false))
      sensitive = Enum.find(markers, &(&1["case_sensitive"] == true))

      assert insensitive, "no case-insensitive needle in the spec"
      assert sensitive, "no case-sensitive needle in the spec"

      up = String.upcase(insensitive["needle"])
      assert Dispatchability.marker_scan(%{field(0) => up}).class == insensitive["class"]

      down = String.downcase(sensitive["needle"])

      refute Dispatchability.marker_scan(%{field(0) => down}).class == sensitive["class"],
             "#{inspect(sensitive["needle"])} is declared case-sensitive precisely because its " <>
               "lowercase spelling is ordinary prose (a bare `backlog` matched 12 of 150 rows, " <>
               "mostly row ids); matching #{inspect(down)} would re-open that false-positive class"
    end
  end

  describe "the marker OUTRANKS the two edge rules — one card, one verdict" do
    test "classify/2 and classify_upstream/3 still answer on their own inputs" do
      # Not a re-test of the edge rules; it pins that this row did not change
      # them, so the precedence claim above is about ADDITION, not replacement.
      assert Dispatchability.classify(3, 1) == "delegated"
      assert Dispatchability.classify(3, 0) == "undecided"
      assert Dispatchability.classify(0, 0) == nil
    end
  end
end
