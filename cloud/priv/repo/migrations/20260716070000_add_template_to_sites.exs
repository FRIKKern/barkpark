defmodule BarkparkCloud.Repo.Migrations.AddTemplateToSites do
  use Ecto.Migration

  # search-template W2 (charter D8): WHICH shipped starter tree the box
  # provisions for this site — nullable; nil keeps the framework-derived
  # default (astro→astro-starter, nextjs→next-starter) byte-identical.
  def change do
    alter table(:sites) do
      add :template, :string
    end
  end
end
