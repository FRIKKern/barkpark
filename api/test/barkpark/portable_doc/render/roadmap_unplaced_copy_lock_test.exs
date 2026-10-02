defmodule Barkpark.PortableDoc.Render.RoadmapUnplacedCopyLockTest do
  @moduledoc """
  THE ROADMAP CANNOT-PLACE COPY, LOCKED ACROSS THREE SURFACES (task-e8e80abb16460f44).

  The Elixir View emitter owns the two strings (`Components.roadmap_unplaced_copy/0`
  and `roadmap_lane_unplaced_copy/0`). The Go terminal twin
  (internal/pdrender/taskblocks.go) and the JS reader twin
  (js/packages/react/src/blocks/core.ts) each carry a literal copy. Nothing
  derived one from another, so each suite stayed green while readers saw
  different answers. This test reads BOTH twins' literals and asserts they equal
  the Elixir strings, so changing the Elixir copy alone reds here.

  The extraction is a named-constant match, not a substring search, and it
  answers `:error` on an empty or constant-less read. The positive controls
  below prove that, so a moved or emptied file fails loudly instead of passing
  on nothing.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Components

  @repo Path.expand("../../../../..", __DIR__)
  @go_path Path.join(@repo, "internal/pdrender/taskblocks.go")
  @ts_path Path.join(@repo, "js/packages/react/src/blocks/core.ts")

  # name => {go constant, ts constant, the Elixir source of truth}
  @pairs [
    {"roadmapUnplacedCopy", "ROADMAP_UNPLACED_COPY", &Components.roadmap_unplaced_copy/0},
    {"roadmapLaneUnplacedCopy", "ROADMAP_LANE_UNPLACED_COPY",
     &Components.roadmap_lane_unplaced_copy/0}
  ]

  @doc false
  def go_literal(source, name) do
    case Regex.run(~r/^\s*#{name}\s*=\s*"((?:[^"\\]|\\.)*)"\s*$/m, source) do
      [_, value] -> {:ok, value}
      _ -> :error
    end
  end

  @doc false
  def ts_literal(source, name) do
    case Regex.run(~r/^export const #{name} = '((?:[^'\\]|\\.)*)'\s*$/m, source) do
      [_, value] -> {:ok, value}
      _ -> :error
    end
  end

  test "the Go and JS twins carry the SAME two strings the Elixir emitter exposes" do
    go = File.read!(@go_path)
    ts = File.read!(@ts_path)

    for {go_name, ts_name, elixir} <- @pairs do
      want = elixir.()
      assert is_binary(want) and want != "", "Elixir copy for #{go_name} is empty"

      assert go_literal(go, go_name) == {:ok, want},
             "#{@go_path} const #{go_name} != Elixir #{inspect(want)}"

      assert ts_literal(ts, ts_name) == {:ok, want},
             "#{@ts_path} const #{ts_name} != Elixir #{inspect(want)}"
    end
  end

  test "the copy the Elixir emitter RENDERS is the copy it exposes (no second literal)" do
    all_unplaced =
      Components.roadmap_html(%{"snapshot" => [%{"title" => "A", "status" => "ready"}]})

    assert all_unplaced =~ Components.roadmap_unplaced_copy()

    partial =
      Components.roadmap_html(%{
        "snapshot" => [
          %{"title" => "P", "status" => "ready", "left" => 0, "width" => 20},
          %{"title" => "U", "status" => "ready"}
        ]
      })

    assert partial =~
             ~s|<span class="bp-rm__unplaced">#{Components.roadmap_lane_unplaced_copy()}</span>|
  end

  describe "POSITIVE CONTROL: the lock cannot pass on an empty read" do
    test "an empty source yields :error for every constant, on both extractors" do
      for {go_name, ts_name, _} <- @pairs do
        assert go_literal("", go_name) == :error
        assert ts_literal("", ts_name) == :error
      end
    end

    test "a source missing the constant yields :error, a drifted one yields the drift" do
      assert go_literal(~s|const other = "x"|, "roadmapUnplacedCopy") == :error
      assert ts_literal(~s|export const OTHER = 'x'|, "ROADMAP_UNPLACED_COPY") == :error

      drifted = ~s|export const ROADMAP_UNPLACED_COPY = 'Nothing to place.'|
      assert ts_literal(drifted, "ROADMAP_UNPLACED_COPY") == {:ok, "Nothing to place."}

      refute ts_literal(drifted, "ROADMAP_UNPLACED_COPY") ==
               {:ok, Components.roadmap_unplaced_copy()}
    end
  end
end
