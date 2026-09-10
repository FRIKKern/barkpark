defmodule BarkparkWeb.Studio.StudioPreGateBadgeTest do
  @moduledoc """
  The pre-gate badge on the STUDIO paper view — the editor twin of the public
  reader (`bulldocs_pre_gate_badge_test.exs` proves the reader; this proves the
  Studio pane emits the SAME mark in the SAME place from the SAME emitter).

  Studio streams its view-mode blocks through
  `Shared.Paper.paper_stream_items/4`, which calls
  `Content.Papers.PreGateRegister.annotate/3` on the STORED blocks before any
  resolution — one emitter, no parallel producer. These tests assert the emitted
  stream directly (the pane's own seam) rather than mounting the desk, so the
  assertion cannot pass on a coincidence of chrome.

  D5 also locked here: the badge is SYNTHESISED into the render stream and never
  into the source list, so a save right after a view can never write it back.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content.Document
  alias Barkpark.Content.Papers.PreGateRegister
  alias Barkpark.TenancyFixtures
  alias BarkparkWeb.Studio.StudioLive.Shared
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @dataset "production"

  # An id from the #15234 register (tooling/pds/pre-gate-papers.json) and one
  # that is deliberately NOT in it.
  @register_id "agent-flight-recorder-charter"
  @outsider_id "heggemsnes-act"

  # The gate refuses `header:` on a table (it reads `head:`) — the exact shape
  # the ruling grandfathered.
  @refused_table %{
    "type" => "table",
    "id" => "block-5",
    "header" => ["Moment", "What is stored"],
    "rows" => [[[%{"type" => "text", "value" => "claim"}], [%{"type" => "text", "value" => "x"}]]]
  }

  @healed_table %{
    "type" => "table",
    "id" => "block-5",
    "head" => ["Moment", "What is stored"],
    "rows" => [[[%{"type" => "text", "value" => "claim"}], [%{"type" => "text", "value" => "x"}]]]
  }

  defp blocks(table) do
    [
      %{"type" => "heading", "id" => "b1", "level" => 1, "text" => "Planted paper"},
      %{"type" => "byline", "id" => "b2", "items" => ["planted", "2026-07-17"]},
      table
    ]
  end

  setup do
    assert PreGateRegister.loaded?(), "register absent — this PR lands after #15234"
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    %{scope: [workspace_id: ws.id, project_id: project.id]}
  end

  defp ids(items), do: Enum.map(items, & &1.id)
  defp html(items), do: items |> Enum.map(& &1.html) |> Enum.join("\n")

  test "a register id the gate still refuses wears the badge under the byline", %{scope: scope} do
    source = blocks(@refused_table)
    items = Paper.paper_stream_items(source, @dataset, scope, @register_id)

    assert "pre-gate-badge" in ids(items)

    # Position: directly after the byline's stream item, before the table's.
    assert Enum.find_index(ids(items), &(&1 == "b2")) <
             Enum.find_index(ids(items), &(&1 == "pre-gate-badge"))

    assert Enum.find_index(ids(items), &(&1 == "pre-gate-badge")) <
             Enum.find_index(ids(items), &(&1 == "block-5"))

    rendered = html(items)
    assert rendered =~ ~s(<p class="bp-pregate bp-pregate--neutral bp-pregate--tucked")
    assert rendered =~ ">Published before the block gate</p>"
    assert rendered =~ ~s( title="GRANDFATHERED.)

    # D5: the SOURCE list is untouched — the badge can never be saved back.
    assert source == blocks(@refused_table)
  end

  test "a non-register paper with the SAME refused blocks wears none", %{scope: scope} do
    items = Paper.paper_stream_items(blocks(@refused_table), @dataset, scope, @outsider_id)

    refute "pre-gate-badge" in ids(items)
    refute html(items) =~ "bp-pregate"
  end

  test "a healed register id wears none — no register edit needed", %{scope: scope} do
    items = Paper.paper_stream_items(blocks(@healed_table), @dataset, scope, @register_id)

    refute "pre-gate-badge" in ids(items)
    refute html(items) =~ "bp-pregate"
  end

  test "no paper id at all (the pane has no doc) is not an error", %{scope: scope} do
    items = Paper.paper_stream_items(blocks(@refused_table), @dataset, scope, nil)
    refute html(items) =~ "bp-pregate"

    # ... and the 3-arity call every other Studio caller still uses is unchanged.
    assert Paper.paper_stream_items(blocks(@refused_table), @dataset, scope) == items
  end

  test "paper_doc_id reads the pane doc in both shapes the pane carries" do
    assert Shared.paper_doc_id(%Document{doc_id: @register_id}) == @register_id
    assert Shared.paper_doc_id(%{"doc_id" => @register_id}) == @register_id
    assert Shared.paper_doc_id(nil) == nil
    assert Shared.paper_doc_id(%{}) == nil
  end
end
