defmodule BarkparkCloud.Repo.Migrations.AddBarkparksUrlUniqueIndex do
  use Ecto.Migration

  # Defense in depth for the globally-unique provisioning subdomain.
  #
  # The bug this guards: `barkparks.slug` is unique only PER TEAM, so before this
  # change two teams that both picked slug "prod" provisioned colliding boxes and
  # shared/overwrote `prod.barkpark.cloud` (a cross-tenant DNS overwrite — a
  # multi-tenant security bug). The fix derives a GLOBALLY-unique subdomain
  # `<slug>-<team_short_id>` in `Barkpark.provisioning_subdomain/1` and stores the
  # resolved customer-facing FQDN in `url`. That URL is collision-free BY
  # CONSTRUCTION; this index is the backstop so even a logic bug can never stand
  # up two boxes on the same FQDN.
  #
  # Partial index (WHERE url IS NOT NULL): `url` is nullable and self-hosted / BYO
  # / not-yet-provisioned rows may carry no url. NULLs are distinct in a plain
  # unique index anyway, but the partial form makes the intent explicit and keeps
  # the index small.
  def change do
    create unique_index(:barkparks, [:url],
             where: "url IS NOT NULL",
             name: :barkparks_url_unique_idx
           )
  end
end
