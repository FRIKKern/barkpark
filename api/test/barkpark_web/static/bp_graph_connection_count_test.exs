defmodule BarkparkWeb.Static.BpGraphConnectionCountTest do
  @moduledoc """
  The blast-radius graph names a node's edges "1 connection" / "N connections"
  in its accessible names and focus announcement (task-880a2d3f48ccbfcb). It
  said "1 connections". Source pin on the shipped file, like the other
  bp-graph.js locks in this directory.
  """
  use ExUnit.Case, async: true

  @js Path.expand("../../../priv/static/assets/bp-graph.js", __DIR__)

  test "both announcements count through connectionCount/1" do
    js = File.read!(@js)
    assert js =~ ~s|return n === 1 ? "1 connection" : n + " connections";|
    assert js =~ ~s|". " + connectionCount(nb) + "."|
    assert js =~ ~s|". " + connectionCount(cc) + ".";|
    refute js =~ ~s|" connections."|
  end
end
