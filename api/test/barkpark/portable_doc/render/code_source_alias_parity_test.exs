defmodule Barkpark.PortableDoc.Render.CodeSourceAliasParityTest do
  @moduledoc """
  The Elixir leg of the code-block SOURCE-FIELD parity lock
  (task-e9af9f95d290307d).

  Both render engines read ONE fixture file —
  `api/test/support/fixtures/code-source-aliases.json` — and assert the SAME
  property over it: for each authored block shape, is the source PRESENT in the
  render, and is it the source the contract selects? The Go leg is
  `internal/pdrender/code_source_alias_parity_test.go`, which opens that same
  path through `../../api/...`.

  It is deliberately ONE file, not a generated mirror pair. A mirror pair drifts
  the moment one side is regenerated and the other is not — which is the exact
  class of bug this task exists to close (Go read `code`||`value`, compose.ex
  read `value`, and nothing compared them).

  DRIFT PROOF: change `@code_source_keys` in compose.ex (drop `"code"`, or put
  `"text"` first) and the shapes below red here while the Go leg stays green —
  and vice versa. Neither engine can move alone.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Compose

  @fixture Path.expand("../../../support/fixtures/code-source-aliases.json", __DIR__)

  @external_resource @fixture

  @cases @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")

  test "the shared fixture is the one both engines read" do
    assert File.exists?(@fixture),
           "the shared code-source fixture is missing: #{@fixture} — " <>
             "internal/pdrender/code_source_alias_parity_test.go reads the same path"

    assert length(@cases) >= 10,
           "the shared fixture must keep covering code-only / value-only / both / blank / missing"
  end

  for {c, i} <- Enum.with_index(@cases) do
    @case c
    @idx i

    test "#{i}: #{c["name"]} — :article composes the contract's source" do
      composed = Compose.compose_block(@case["block"], :article)
      html = Map.get(composed, "html", "")

      if @case["content_present"] do
        refute html == "",
               "case #{@idx} (#{@case["name"]}): expected content, got an EMPTY compose — " <>
                 "this is the hollow-render shape the task closes"

        assert String.contains?(html, @case["source"]),
               "case #{@idx} (#{@case["name"]}): expected source #{inspect(@case["source"])} " <>
                 "in the composed html, got #{inspect(html)}"
      else
        assert html == "",
               "case #{@idx} (#{@case["name"]}): expected NO content, got #{inspect(html)}"
      end
    end

    test "#{i}: #{c["name"]} — the default (email) arm agrees with :article" do
      composed = Compose.compose_block(@case["block"], :email)

      present? =
        case composed do
          %{"kind" => "_raw", "html" => ""} -> false
          _ -> true
        end

      assert present? == @case["content_present"],
             "case #{@idx} (#{@case["name"]}): the two style arms disagree about " <>
               "whether this shape has content — got #{inspect(composed)}"

      if @case["content_present"] do
        text =
          composed
          |> Map.get("children", [])
          |> Enum.flat_map(&Map.get(&1, "children", []))
          |> Enum.map_join("\n", &Map.get(&1, "value", ""))

        assert String.contains?(text, @case["source"]),
               "case #{@idx} (#{@case["name"]}): expected source #{inspect(@case["source"])} " <>
                 "in the email arm, got #{inspect(text)}"
      end
    end
  end
end
