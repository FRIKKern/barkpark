defmodule BarkparkCloud.Repo.Migrations.AddCustomHostToBarkparks do
  use Ecto.Migration

  # Instance custom domains (isu follow-up): the bare platform-zone host
  # (e.g. gyldendal.barkpark.cloud) a team attaches to a managed instance.
  # Nullable — most rows never attach one. The partial unique index is the
  # never-two-instances-on-one-host backstop (mirrors barkparks_url_unique_idx);
  # partial so the many NULL rows stay outside it.
  def change do
    alter table(:barkparks) do
      add :custom_host, :string
    end

    create unique_index(:barkparks, [:custom_host],
             name: :barkparks_custom_host_unique_idx,
             where: "custom_host IS NOT NULL"
           )
  end
end
