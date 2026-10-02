defmodule BarkparkWeb.Studio.StudioLive.PaperMastersSeam do
  @moduledoc """
  The ONE place Studio resolves the paper-masters implementation
  (task-3b6e562e916c8ce4), without naming the plugin that provides it.

  Masters live in the Bulldocs plugin, and Barkpark must work with every
  plugin off (`Barkpark.Plugin` §Fresh-install invariant, pinned by
  `Barkpark.PluginFreeBootTest` tier 5). So Studio never aliases the plugin:
  it asks the plugin REGISTRY for the registered `"bulldocs"` plugin, checks
  that plugin exports `paper_masters/0`, and checks the plugin is enabled for
  the paper's workspace (`Barkpark.Plugins.Enablement`). Any "no" answers
  `nil`, and every masters affordance (the picker carrier, the Save actions,
  both socket events) treats `nil` as "masters are absent" — never a crash.

  The returned module implements `list_for_paper/1`, `master_id/1`,
  `save_master/4`, `insert_op/4` and `masterable?/1`, and for LINKED
  instances (task-59f078a2fd248698) `linked_insert_op/4`, `detach_op/3`,
  `pin_op/3`, `linked?/1` and `render_map/3`.
  """

  alias Barkpark.PortableDoc.MasterRef

  alias Barkpark.Plugins.{Enablement, Registry}

  @plugin "bulldocs"

  @doc "The masters implementation for a paper in `workspace_id`, or nil."
  @spec impl(binary() | nil) :: module() | nil
  def impl(workspace_id) do
    with %{module: plugin} <- Enum.find(Registry.all(), &(&1.name == @plugin)),
         true <- Code.ensure_loaded?(plugin) and function_exported?(plugin, :paper_masters, 0),
         true <- Enablement.enabled?(Enablement.effective(workspace_id), @plugin) do
      plugin.paper_masters()
    else
      _ -> nil
    end
  end

  @doc """
  The `:masters` render option for `paper`'s `blocks`: the prerendered HTML of
  every linked master instance they hold, resolved at READ time inside the
  paper's own workspace, project and dataset (`render_map/3`). `opts` pass
  through (`published_only: true` on the public reader).

  A paper with no `master-ref` block answers `%{}` WITHOUT touching the plugin
  registry or the database, so a paper that uses no masters pays nothing. With
  the plugin off, or no paper, every instance renders as unavailable (`%{}`).
  """
  @spec render_map(map() | nil, list(), keyword()) :: map()
  def render_map(paper, blocks, opts \\ []) do
    with [_ | _] <- MasterRef.refs(blocks),
         %{workspace_id: workspace_id} <- paper,
         impl when not is_nil(impl) <- impl(workspace_id) do
      impl.render_map(paper, blocks, opts)
    else
      _ -> %{}
    end
  end
end
