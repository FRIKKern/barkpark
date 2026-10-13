defmodule Mix.Tasks.Barkpark.Media.BackfillSha1 do
  @moduledoc """
  Hash the `media_files` rows born before `media_files.sha1` existed
  (task-b6e57c37f6928344), so `GET /v1/media/:ds?sha1=` and upload dedupe
  cover them too. Until it runs, those rows answer `sha1: null` and are
  invisible to both.

      mix barkpark.media.backfill_sha1
      mix barkpark.media.backfill_sha1 --dry-run
      mix barkpark.media.backfill_sha1 --batch 500

  Re-runnable: it only reads rows whose `sha1` is still NULL.

  On a box (a release has no mix tasks), the same function:

      bin/barkpark eval 'Barkpark.Release.backfill_media_sha1(dry_run: true)'
      bin/barkpark eval 'Barkpark.Release.backfill_media_sha1()'
  """
  @shortdoc "Backfill media_files.sha1 for existing uploads"

  use Mix.Task

  @switches [dry_run: :boolean, batch: :integer]

  @impl Mix.Task
  def run(args) do
    # Same narrowed boot as `mix barkpark.media.backfill` (task-557cf9a71e949768):
    # no Endpoint, so a one-shot never binds the live slot's port.
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown arguments: #{inspect(invalid)}")
    end

    stats = Barkpark.Media.backfill_sha1(opts)

    Mix.shell().info("""
    media sha1 backfill#{if opts[:dry_run], do: " (dry run, nothing read)", else: ""}:
      hashed:    #{stats.hashed}
      unreadable: #{stats.missing} (blob missing or unreadable; left NULL)
      remaining: #{stats.remaining}
    """)
  end
end
