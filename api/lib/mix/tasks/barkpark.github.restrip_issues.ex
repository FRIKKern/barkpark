defmodule Mix.Tasks.Barkpark.Github.RestripIssues do
  @moduledoc """
  Rewrite every GitHub issue mirrored before the body strip (owner ruling #11).

  A bare run is a DRY RUN: it counts the mirrored tasks and how many issue
  bodies the strip would change, and calls nothing on GitHub.

      mix barkpark.github.restrip_issues                       # count only
      mix barkpark.github.restrip_issues --dataset production
      mix barkpark.github.restrip_issues --apply               # enqueue the re-PATCH
      mix barkpark.github.restrip_issues --apply --limit 50 --interval-seconds 3

  `--apply` inserts one `Github.RestripJob` per changed issue, spaced
  `--interval-seconds` apart (default 2, so 10,000 issues take about 5.5
  hours). The jobs run in the LIVE app's Oban `:github_mirror` queue with the
  mirror's own GitHub App credential, so run this on the box that mirrors
  (it only inserts jobs; it never calls GitHub itself). Re-running is safe:
  a task whose restrip job is still waiting is skipped, and every issue the
  mirror has written since the strip is counted under `stripped`, not
  `would change`. Run the dry run again after the jobs drain: `would change`
  should read 0.

  With `BARKPARK_GITHUB_INTAKE_WORKSPACE_ID` set, only that workspace's tasks
  are considered — the same scope the outbound mirror uses (ruling #12).
  """
  @shortdoc "Count (default) or re-PATCH GitHub issues to the stripped body"

  use Mix.Task

  alias Barkpark.Plugins.Github.{Restrip, Settings}

  @switches [
    apply: :boolean,
    dry_run: :boolean,
    dataset: :string,
    limit: :integer,
    interval_seconds: :integer
  ]

  @impl Mix.Task
  def run(args) do
    # Narrowed one-shot boot (Repo only): the jobs this inserts run in the live
    # app's Oban, never in this process.
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("Unknown arguments: #{inspect(invalid)}")

    apply? = Keyword.get(opts, :apply, false) and not Keyword.get(opts, :dry_run, false)
    dataset = Keyword.get(opts, :dataset, "production")

    scope =
      case Settings.intake_workspace_id() do
        ws when is_binary(ws) -> [workspace_id: ws]
        _ -> []
      end

    plan = Restrip.plan(dataset, scope)

    Mix.shell().info("""
    dataset        #{plan.dataset}
    mirrored       #{plan.mirrored}   (published tasks with a live issue link)
    would change   #{plan.would_change}   (internal brief on the public issue today)
    stripped       #{plan.stripped}   (already rewritten under the strip)
    allow-listed   #{plan.allowlisted}   (gh-<num> intake or labelled `public`: brief stays)
    unchanged      #{plan.unchanged}   (no brief to strip)
    truncated      #{plan.truncated}
    """)

    if apply? do
      {:ok, n} =
        Restrip.enqueue(
          dataset,
          scope ++ Keyword.take(opts, [:limit, :interval_seconds])
        )

      Mix.shell().info("Enqueued #{n} restrip job(s) on the :github_mirror queue.")
    else
      Mix.shell().info(
        "Dry run: nothing was enqueued and GitHub was not called. Re-run with --apply."
      )
    end
  end
end
