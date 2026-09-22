defmodule Barkpark.Tenancy.CliDatasetFlag do
  @moduledoc """
  THE ONE DEFINITION of the `?dataset=` disambiguator declaration — the flag
  literal, and the route predicate that decides which CLI commands carry it.

  ## Why it lives in the tenancy kernel, and not in either caller

  The rule has TWO application points, deliberately:

    * `Barkpark.Plugins.Registry.collect_cli_commands/1` applies it at
      ASSEMBLY, over every plugin's declaration, so a `/v1/tasks/:doc_id`
      command declared in ANOTHER plugin (`session.link-task`, declared in
      `Barkpark.Plugins.Bulldocs`) cannot escape it.
    * `Barkpark.Plugins.Tasks.cli_commands/0` applies it to its OWN list, so
      that list is self-consistent when read directly — tests and tooling do
      read it directly, without going through the registry.

  Both must apply the SAME predicate and append the SAME flag. Hosting it in
  either caller makes the other one call sideways into a peer feature: the
  tasks plugin delegating to the plugins registry was exactly that, and it
  reddened the architecture boundary gate on every PR from 2026-09-18
  (`REGRESSION — new feature→feature sideways edge "tasks>registry"`,
  task-9a90596e9194f370). Concepts depend INWARD on the kernel, never
  sideways, so the shared rule belongs in a kernel concept both already reach.

  `tenancy` is that kernel, and it is not merely a convenient one: the thing
  being declared IS a dataset selector. A doc_id may live in two datasets of a
  single workspace+project — `Barkpark.Tenancy.Dataset` is the axis — and the
  409 `ambiguous_dataset` refusal exists because the task doors will not pick
  one for you. This module holds the name of the remedy that refusal prints.

  ## The predicate

  `":doc_id UNDER /v1/tasks"`, not `":doc_id anywhere"`. Every such route
  resolves through `BarkparkWeb.TasksController.find_task_by_doc_id/2` and can
  therefore answer the 409; a `:doc_id` route some other family mounts
  elsewhere would get a flag its route never reads. Derived from the ROUTE, not
  from a hand-written list of verbs — a list goes stale silently, which is the
  defect the original rule (#18611) was written to repair.

  ## The shapes it tolerates

  Idempotent: a command that already declares `dataset` (task.ready,
  task.events, task.ls …) is left verbatim, so applying the rule twice — once
  on the tasks plugin's own list and again at assembly — appends nothing twice.
  Tolerant on shape: only a command with an atom-keyed `http.path_template`
  plus a `flags` list is rewritten; anything else falls to the catch-all
  unchanged rather than raising inside a boot-time collector.

  Typed as `map()` rather than `Barkpark.Plugin.cli_command()` ON PURPOSE: a
  kernel module naming a feature module's type is the WRONG-DIRECTION edge the
  same gate reds on (kernel→feature). The callers keep the precise type on
  their own public specs.
  """

  @task_doc_id_dataset_flag %{
    name: "dataset",
    type: "string",
    summary:
      "Name the dataset this doc_id lives in. THE DISAMBIGUATOR the 409 " <>
        "`ambiguous_dataset` refusal names: one doc_id may live in two datasets of a " <>
        "single workspace+project, and the task doors REFUSE such an id rather than " <>
        "picking a dataset you did not name. Omit it and nothing is picked for you — " <>
        "an unambiguous id reads normally and an ambiguous one is still refused."
  }

  @doc """
  The flag map this module appends. Public so a test can assert the literal
  without reaching into either caller.
  """
  @spec flag() :: map()
  def flag, do: @task_doc_id_dataset_flag

  @doc """
  Declare the `?dataset=` disambiguator on a command whose ROUTE is a
  `/v1/tasks/:doc_id` route, whichever plugin declared the command.
  """
  @spec declare_on_task_doc_id_route(map()) :: map()
  def declare_on_task_doc_id_route(%{http: %{path_template: path}, flags: flags} = cmd)
      when is_binary(path) and is_list(flags) do
    if task_doc_id_route?(path) and not Enum.any?(flags, &(flag_name(&1) == "dataset")) do
      %{cmd | flags: flags ++ [@task_doc_id_dataset_flag]}
    else
      cmd
    end
  end

  def declare_on_task_doc_id_route(cmd), do: cmd

  @doc """
  True when `path` is a `/v1/tasks/…:doc_id…` route — the family whose doors
  can answer a 409 `ambiguous_dataset`.
  """
  @spec task_doc_id_route?(String.t()) :: boolean()
  def task_doc_id_route?(path) when is_binary(path) do
    String.starts_with?(path, "/v1/tasks/") and String.contains?(path, ":doc_id")
  end

  defp flag_name(%{name: name}), do: name
  defp flag_name(%{"name" => name}), do: name
  defp flag_name(_), do: nil
end
