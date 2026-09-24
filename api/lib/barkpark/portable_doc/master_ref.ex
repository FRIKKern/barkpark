defmodule Barkpark.PortableDoc.MasterRef do
  @moduledoc """
  The `master-ref` block: a LINKED instance of a paper master
  (task-59f078a2fd248698, `docs/decisions/0010-paper-masters.md` §5).

      %{"id" => "mst-…", "type" => "master-ref",
        "master" => "<published master id>", "version" => nil | "<master _rev>"}

  The block stores only the reference. The renderer resolves it at READ time
  from a caller-supplied `:masters` map (`%{key => prerendered_html}`), the
  same pure-renderer + injected-resolution pattern as `:embeds`: the walker
  never reads the Repo. `version: nil` follows the master's latest content; a
  rev string pins the instance to that revision.

  Pure. Core owns the block shape and the key; the resolver that fills the map
  lives with masters, in the Bulldocs plugin.
  """

  alias Barkpark.PortableDoc.BodyWalk

  @type_name "master-ref"

  @doc "The block type."
  def type_name, do: @type_name

  @doc """
  The resolution key for a `master-ref` block (or a `{master, version}` pair):
  `"<master>@<version>"`, `"<master>@latest"` when unpinned. The walker looks
  the prerendered HTML up under this key.
  """
  def key(%{"master" => master} = block) when is_binary(master),
    do: key({master, version(block)})

  def key({master, nil}) when is_binary(master), do: master <> "@latest"

  def key({master, version}) when is_binary(master) and is_binary(version),
    do: master <> "@" <> version

  def key(_), do: nil

  @doc "The pinned version of a block (nil = follow latest)."
  def version(%{"version" => v}) when is_binary(v) and v != "", do: v
  def version(_), do: nil

  @doc """
  Every `{master, version}` pair referenced anywhere in `tree` (a block list or
  one node), distinct, document order. Blocks with no binary `master` are
  skipped (they render as unavailable).
  """
  def refs(tree) do
    tree
    |> BodyWalk.collect_nodes([@type_name])
    |> Enum.flat_map(fn
      %{"master" => master} = block when is_binary(master) and master != "" ->
        [{master, version(block)}]

      _ ->
        []
    end)
    |> Enum.uniq()
  end
end
