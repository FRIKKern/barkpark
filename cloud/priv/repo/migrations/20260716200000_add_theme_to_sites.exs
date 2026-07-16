defmodule BarkparkCloud.Repo.Migrations.AddThemeToSites do
  use Ecto.Migration

  # search-template W6: the deploy-pinned palette (evergreen | ember | fjord |
  # charple). Nullable — nil keeps the template's own default; the relay only
  # injects BARKPARK_THEME when set, so existing sites deploy byte-identical.
  def change do
    alter table(:sites) do
      add :theme, :string
    end
  end
end
