defmodule BarkparkWeb.Static.BpGraphConnectionCountTest do
  @moduledoc """
  The blast-radius graph names a node's edges "1 connection" / "N connections"
  in its accessible names and focus announcement (task-880a2d3f48ccbfcb). It
  said "1 connections". Source pin on the shipped file, like the other
  bp-graph.js locks in this directory.
  """
  use ExUnit.Case, async: true

  @js Path.expand("../../../priv/static/assets/bp-graph.js", __DIR__)

  # task-d1c2ef3924bde715 moved the count into the renderer's gtCount/1 so it
  # reads in the Studio language; the singular form stays.
  test "both announcements count through gtCount/1" do
    js = File.read!(@js)

    assert js =~
             ~s|return n === 1 ? gt("1 connection") : gt("%{count} connections", { count: n });|

    assert js =~ ~s|". " + gtCount(nb) + "."|
    assert js =~ ~s|" " + gtCount(cc) + ".";|
    refute js =~ ~s|" connections."|
  end
end
