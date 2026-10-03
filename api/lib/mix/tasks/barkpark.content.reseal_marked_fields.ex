defmodule Mix.Tasks.Barkpark.Content.ResealMarkedFields do
  @moduledoc """
  Count, and on request reseal, plaintext left in `encrypted: true` fields of
  non-Default workspaces (owner ruling #19, task-5aba9d644eb3b40c).

  A bare run is a DRY RUN. It prints the read-only census (per workspace,
  type and top-level field), its positive control (sealed rows in the Default
  workspace), and the per-row plan (every document whose content changes when
  sealed, nested fields and bound block copies included). It writes nothing.

      mix barkpark.content.reseal_marked_fields                      # census + plan
      mix barkpark.content.reseal_marked_fields --workspace acme     # one workspace
      mix barkpark.content.reseal_marked_fields --apply --workspace acme

  `--apply` needs `--workspace`: one workspace per run, resealed through the
  normal document save, in batches of `--batch-size` (default 100). It refuses
  when this box's KEK cannot wrap and unwrap a key, and it never touches the
  Default workspace. The previous plaintext stays in `revisions`, earlier
  `mutation_events` and delivered webhook payloads; scrubbing those is a
  separate owner decision.
  """
  @shortdoc "Census (default) or reseal plaintext in encrypted fields, one workspace at a time"

  use Mix.Task

  alias Barkpark.Content.Reseal

  @switches [apply: :boolean, dry_run: :boolean, workspace: :string, batch_size: :integer]

  @impl Mix.Task
  def run(args) do
    # Narrowed one-shot boot (Repo only), like the other backfills.
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("Unknown arguments: #{inspect(invalid)}")

    apply? = Keyword.get(opts, :apply, false) and not Keyword.get(opts, :dry_run, false)
    workspace = Keyword.get(opts, :workspace)

    print_census("CENSUS — plaintext marked fields, non-Default workspaces", Reseal.census())

    print_census(
      "POSITIVE CONTROL — sealed marked fields, Default workspace",
      Reseal.census(:control)
    )

    plan = Reseal.plan(if workspace, do: [workspace: workspace], else: [])
    Mix.shell().info("PLAN — #{length(plan)} document(s) change when sealed")

    plan
    |> Enum.group_by(& &1.workspace)
    |> Enum.each(fn {ws, rows} ->
      Mix.shell().info(
        "  #{ws}\t#{length(rows)}\t#{rows |> Enum.map(& &1.doc_id) |> Enum.join(" ")}"
      )
    end)

    cond do
      not apply? ->
        Mix.shell().info("Dry run: nothing was written. Re-run with --apply --workspace <slug>.")

      not is_binary(workspace) ->
        Mix.raise("--apply needs --workspace <slug>: one workspace per run.")

      true ->
        case Reseal.apply(workspace, Keyword.take(opts, [:batch_size])) do
          {:ok, %{resealed: n, failed: failed}} ->
            Mix.shell().info(
              "Resealed #{n} document(s) in #{workspace}; #{length(failed)} failed."
            )

            Enum.each(failed, &Mix.shell().error("  #{&1.doc_id}: #{&1.reason}"))
            print_census("CENSUS AFTER", Reseal.census())

          {:error, reason} ->
            Mix.raise("Refused: #{reason}")
        end
    end
  end

  defp print_census(title, rows) do
    Mix.shell().info(title)

    if rows == [] do
      Mix.shell().info("  (none)")
    else
      Enum.each(rows, fn r ->
        Mix.shell().info("  #{r.workspace}\t#{r.type}\t#{r.field}\t#{r.rows}")
      end)
    end
  end
end
