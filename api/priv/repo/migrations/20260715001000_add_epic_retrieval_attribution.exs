defmodule Barkpark.Repo.Migrations.AddEpicRetrievalAttribution do
  use Ecto.Migration

  def change do
    alter table(:epic_benchmark_experiments) do
      add :artifact_format, :text,
        null: false,
        default: "barkpark-epic-benchmark-v1"

      add :retrieval_attribution, :map
      add :retrieval_attribution_digest, :text
    end

    create constraint(
             :epic_benchmark_experiments,
             :epic_benchmark_experiments_artifact_format,
             check:
               "artifact_format IN ('barkpark-epic-benchmark-v1', 'barkpark-epic-benchmark-v2')"
           )

    create constraint(
             :epic_benchmark_experiments,
             :epic_benchmark_experiments_retrieval_attribution,
             check: """
             (artifact_format = 'barkpark-epic-benchmark-v1'
               AND retrieval_attribution IS NULL
               AND retrieval_attribution_digest IS NULL)
             OR
             (artifact_format = 'barkpark-epic-benchmark-v2'
               AND retrieval_attribution IS NOT NULL
               AND retrieval_attribution_digest ~ '^[0-9a-f]{64}$')
             """
           )
  end
end
