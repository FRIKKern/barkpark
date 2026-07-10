defmodule Mix.Tasks.Barkpark.Tags.Seed do
  @moduledoc """
  Import the legacy flat-string tag vocabulary as DRAFT `type:tag` documents.

  Usage:

      mix barkpark.tags.seed                       # dataset "production"
      mix barkpark.tags.seed --dataset staging

  One-time bridge for the authoring-excellence weighted-label rollout
  (charter D3): sweeps every schema type's DISTINCT legacy `content.tags`
  strings (`Content.search_tags_for_type/5` — the old flat shape, which is
  exactly what legacy data carries) and creates one draft tag doc per name
  that has no tag doc yet.

  **Nothing is published.** A draft tag is NOT registered — the publish
  wall's E3 gate only resolves PUBLISHED tag docs. Promotion (publishing) is
  a deliberate human/curator act per name, so the legacy vocabulary is
  reviewed into the registry, never migrated into it wholesale. Idempotent:
  re-running skips every name that already has a tag doc (either variant).
  """

  @shortdoc "Import legacy distinct tags as DRAFT type:tag docs (never published)"

  use Mix.Task

  alias Barkpark.Content.TagRegistry

  @switches [dataset: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)
    dataset = Keyword.get(opts, :dataset, "production")

    Mix.Task.run("app.start")

    %{created: created, skipped: skipped} = TagRegistry.seed_legacy_drafts(dataset)

    Enum.each(created, &Mix.shell().info("  draft tag: #{&1}"))

    Mix.shell().info(
      "barkpark.tags.seed (#{dataset}): #{length(created)} draft tag doc(s) created, " <>
        "#{length(skipped)} already present — none published; review and publish to register."
    )
  end
end
