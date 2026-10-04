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
      mix barkpark.content.reseal_marked_fields --upgrade-v1                    # v1 census + plan
      mix barkpark.content.reseal_marked_fields --upgrade-v1 --apply --workspace acme

  `--upgrade-v1` (owner ruling #18 bind half) works on version-1 envelopes,
  sealed before field seals were bound to their document and field, which can
  still be copied between documents of one workspace. It prints a census per
  workspace, type and field, and with `--apply --workspace <slug>` (`-` = rows
  with no workspace, the Default workspace allowed) rewrites each one as a
  bound version-2 seal in place, fenced on the row's rev. Re-running finds
  nothing left. Deploy the binding code (#21609) on the box first.

  `--apply` needs `--workspace`: one workspace per run, in batches of
  `--batch-size` (default 100). Each named row, draft or published, is sealed
  in place and keeps its rev (the value it decrypts to is unchanged); a row
  saved since the plan read it is reported, not overwritten. It refuses
  when this box's KEK cannot wrap and unwrap a key, and it never touches the
  Default workspace. The previous plaintext stays in `revisions`, earlier
  `mutation_events` and delivered webhook payloads; scrubbing those is a
  separate owner decision.
  """
  @shortdoc "Census (default) or reseal plaintext in encrypted fields, one workspace at a time"

  use Mix.Task

  alias Barkpark.Content.Reseal

  @switches [
    apply: :boolean,
    dry_run: :boolean,
    workspace: :string,
    batch_size: :integer,
    upgrade_v1: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    # Narrowed one-shot boot (Repo only), like the other backfills.
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("Unknown arguments: #{inspect(invalid)}")

    apply? = Keyword.get(opts, :apply, false) and not Keyword.get(opts, :dry_run, false)
    workspace = Keyword.get(opts, :workspace)

    if Keyword.get(opts, :upgrade_v1, false),
      do: upgrade_v1(apply?, workspace, opts),
      else: reseal_plaintext(apply?, workspace, opts)
  end

  # Owner ruling #18 bind half: version-1 envelopes (sealed before #21609) can
  # still be copied between documents; this upgrades them to bound v2 seals.
  defp upgrade_v1(apply?, workspace, opts) do
    {top, docs} = Reseal.v1_census()
    print_census("V1 CENSUS — top-level fields holding a version-1 envelope", top)
    print_census("V1 CENSUS — documents holding a version-1 envelope anywhere", docs)

    plan = Reseal.upgrade_plan(if workspace, do: [workspace: workspace], else: [])
    Mix.shell().info("UPGRADE PLAN — #{length(plan)} document(s) change")

    plan
    |> Enum.group_by(& &1.workspace)
    |> Enum.each(fn {ws, rows} -> Mix.shell().info("  #{ws}\t#{length(rows)}") end)

    cond do
      not apply? ->
        Mix.shell().info(
          "Dry run: nothing was written. Re-run with --upgrade-v1 --apply --workspace <slug> (- = rows with no workspace)."
        )

      not is_binary(workspace) ->
        Mix.raise("--apply needs --workspace <slug>: one workspace per run.")

      true ->
        case Reseal.upgrade_apply(workspace, Keyword.take(opts, [:batch_size])) do
          {:ok, %{upgraded: n, failed: failed}} ->
            Mix.shell().info(
              "Upgraded #{n} document(s) in #{workspace}; #{length(failed)} failed."
            )

            Enum.each(failed, &Mix.shell().error("  #{&1.doc_id}: #{&1.reason}"))
            {top_after, _} = Reseal.v1_census()
            print_census("V1 CENSUS AFTER", top_after)

          {:error, reason} ->
            Mix.raise("Refused: #{reason}")
        end
    end
  end

  defp reseal_plaintext(apply?, workspace, opts) do
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
