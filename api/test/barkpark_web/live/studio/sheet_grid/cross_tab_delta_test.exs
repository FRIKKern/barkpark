defmodule BarkparkWeb.Studio.SheetGrid.CrossTabDeltaTest do
  @moduledoc """
  A cross-tab edit settles as ONE flush that broadcasts one delta PER dirty
  tab, every one of them stamped with the SAME session rev
  (`Sheets.Session.Ops.flush_whole_doc/1`). The grid used to drop every frame
  after the first as a stale duplicate (`rev <= ours`), so the DEPENDENT tab
  kept its old values until a remount: edit `Sheet 1!A1`, switch to Sheet 2,
  and `='Sheet 1'!A3+1` still read the number from before the edit.

  Unit-driven through the public `Ops.apply_delta/2` (no session needed — the
  non-structural path never peeks), plus one end-to-end check against a real
  session that the flush really does emit two frames sharing a rev.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.SheetGrid.Ops

  defp build_socket(overrides \\ []) do
    base = %{
      rev: 0,
      epoch: nil,
      tab: 0,
      active: {1, 1},
      anchor: nil,
      editing: nil,
      notice: nil,
      content: %{
        "tabs" => [
          %{"name" => "Sheet 1", "cells" => %{"A1" => %{"v" => 10}}},
          %{
            "name" => "Sheet 2",
            "cells" => %{"A1" => %{"f" => "'Sheet 1'!A1+1", "t" => "n", "v" => 11}}
          }
        ]
      },
      slug: "ctd-nodb-#{System.unique_integer([:positive])}",
      dataset: "cross_tab_delta_nodb",
      find_query: nil,
      find_hits: MapSet.new(),
      filters: %{},
      filter_panel: nil
    }

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(Map.merge(base, Map.new(overrides)))
  end

  defp cell(socket, tab, addr) do
    socket.assigns.content["tabs"] |> Enum.at(tab) |> Map.get("cells") |> Map.get(addr)
  end

  test "every per-tab frame of one flush lands — the dependent tab is not left stale" do
    socket =
      build_socket()
      |> Ops.apply_delta(%{rev: 1, tab: 0, changed: %{"A1" => %{"v" => 100}}})
      |> Ops.apply_delta(%{
        rev: 1,
        tab: 1,
        changed: %{"A1" => %{"f" => "'Sheet 1'!A1+1", "t" => "n", "v" => 101}}
      })

    assert cell(socket, 0, "A1")["v"] == 100
    assert cell(socket, 1, "A1")["v"] == 101
    assert socket.assigns.rev == 1
  end

  test "a true duplicate (same rev, same tab) is still dropped" do
    socket =
      build_socket()
      |> Ops.apply_delta(%{rev: 1, tab: 0, changed: %{"A1" => %{"v" => 100}}})
      |> Ops.apply_delta(%{rev: 1, tab: 0, changed: %{"A1" => %{"v" => 999}}})

    assert cell(socket, 0, "A1")["v"] == 100
  end

  test "an older rev is still dropped, whichever tab it names" do
    socket =
      build_socket(rev: 5)
      |> Ops.apply_delta(%{rev: 4, tab: 1, changed: %{"A1" => %{"v" => -1}}})

    assert cell(socket, 1, "A1")["v"] == 11
  end

  test "the tabs already applied reset when the rev advances" do
    socket =
      build_socket()
      |> Ops.apply_delta(%{rev: 1, tab: 0, changed: %{"A1" => %{"v" => 100}}})
      |> Ops.apply_delta(%{rev: 2, tab: 1, changed: %{"A1" => %{"v" => 201}}})
      |> Ops.apply_delta(%{rev: 2, tab: 0, changed: %{"A1" => %{"v" => 200}}})

    assert cell(socket, 0, "A1")["v"] == 200
    assert cell(socket, 1, "A1")["v"] == 201
  end
end
