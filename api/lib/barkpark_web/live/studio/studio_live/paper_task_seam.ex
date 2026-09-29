defmodule BarkparkWeb.Studio.StudioLive.PaperTaskSeam do
  @moduledoc """
  The ONE place Studio asks for the paper task resolver
  (task-f4d19b64198780b6), without naming the plugin that provides it.

  This is NOT a second seam. The resolver itself comes from
  `Barkpark.Content.PaperTaskResolver.get/0` — the content-owned seam the
  Tasks plugin fills through `Barkpark.Plugin.paper_task_resolver/0`
  (task-9c59aa555e1e015e), the same entry point `Barkpark.Content.Papers`
  reads for the /papers reader. That seam answers from the BOOT load order
  only. Studio renders inside one workspace, so this module adds the one
  thing the seam does not check, in the same shape as `PaperMastersSeam`:
  the plugin that declared the resolver must be enabled for the workspace
  (`Barkpark.Plugins.Enablement`).

  `nil` means "tasks unavailable": the editor preview marks every
  query-carrying task block with `TaskResolver.mark_unavailable/1`, and the
  reader's own emitter paints the explicit placeholder — never a crash and
  never an empty board that reads as "no tasks".
  """

  alias Barkpark.Content.PaperTaskResolver
  alias Barkpark.Plugins.{Enablement, Registry}

  @doc "The paper task resolver for `workspace_id`, or nil when tasks are unavailable."
  @spec resolver(binary() | nil) :: module() | nil
  def resolver(workspace_id) do
    with resolver when is_atom(resolver) and not is_nil(resolver) <- PaperTaskResolver.get(),
         name when is_binary(name) <- declaring_plugin(resolver),
         true <- Enablement.enabled?(Enablement.effective(workspace_id), name) do
      resolver
    else
      _ -> nil
    end
  end

  # The registered plugin whose `paper_task_resolver/0` declared `resolver`.
  # Unknown ⇒ nil (fail closed: a resolver no registered plugin owns cannot be
  # checked against the workspace's enablement).
  defp declaring_plugin(resolver) do
    Enum.find_value(Registry.all(), fn %{module: mod, name: name} ->
      if Code.ensure_loaded?(mod) and function_exported?(mod, :paper_task_resolver, 0) and
           mod.paper_task_resolver() == resolver,
         do: name
    end)
  end
end
