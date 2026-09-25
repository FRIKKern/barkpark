defmodule BarkparkCloud.Repo.Migrations.AddFormsEnabledToSites do
  use Ecto.Migration

  # task-71082f5541c13b53 (N-08): the one bit of form state the control plane
  # keeps. The endpoint itself lives on the box (a `form_endpoint` document in
  # the site's bound dataset); this column only decides whether the next deploy
  # hands the build BARKPARK_FORMS_URL. NOT NULL DEFAULT false, so every
  # existing site deploys byte-identical until its owner turns forms on.
  def change do
    alter table(:sites) do
      add :forms_enabled, :boolean, null: false, default: false
    end
  end
end
