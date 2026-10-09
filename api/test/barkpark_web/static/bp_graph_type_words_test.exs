defmodule BarkparkWeb.Static.BpGraphTypeWordsTest do
  @moduledoc """
  task-96f9a40da119c8c6: the impact graph announced each node with its raw
  type id ("Ingrid Ness. author. 1 kobling.") and printed the same id in its
  tooltip, while every other Studio surface names a type by its type word. The
  renderer now names types through `opts.typeLabels` (the raw id when the host
  names none), and the GraphPane hook passes the Studio shell's
  `data-type-labels` map. Source pin on the shipped file, like the other
  bp-graph.js locks in this directory.
  """
  use ExUnit.Case, async: true

  @js Path.expand("../../../priv/static/assets/bp-graph.js", __DIR__)

  test "node labels and the tooltip name the type through typeWord" do
    js = File.read!(@js)

    assert js =~ ~s|var typeLabels = opts.typeLabels \|\| {};|
    assert js =~ ~s|n.title + ". " + typeWord(n.type) + statusPart|
    assert js =~ ~s|esc(typeWord(node.type))|
    refute js =~ ~s|n.title + ". " + n.type + statusPart|
    refute js =~ ~s|esc(node.type) + "</div>"|
  end

  test "the GraphPane hook passes the shell's type-label map" do
    js = File.read!(@js)

    assert js =~ ~s|typeLabels: (function (host) {|
    assert js =~ ~s|this.el.closest("[data-type-labels]")|
  end
end
