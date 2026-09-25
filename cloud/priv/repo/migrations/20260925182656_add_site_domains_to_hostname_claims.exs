defmodule BarkparkCloud.Repo.Migrations.AddSiteDomainsToHostnameClaims do
  @moduledoc """
  task-274fad4f639e6890: site domains join the ONE hostname namespace table.

  `hostname_claims` (create_hostname_claims) held barkpark url hosts and
  custom_hosts. A site domain vs a custom_host collision was still refused only
  by the advisory lock the claim doors share, and a site domain vs a
  provisioning url host (provisioning takes no hostname lock) by nothing. This
  migration lets a site own a claim:

    * `site_id` — nullable FK to `sites`, `on_delete: :delete_all`, so deleting a
      site (or its barkpark, which cascades to its sites) releases its claims in
      the same statement.
    * `barkpark_id` becomes nullable: a site claim has no barkpark owner.
    * `hostname_claims_kind_check` is widened to add `site_domain` (dropped and
      re-created; existing rows are all `url`/`custom_host`, so validation passes).
    * `hostname_claims_owner_check` — exactly one owner, matched to the kind:
      a `site_domain` claim names a site and no barkpark, every other kind names a
      barkpark and no site. Existing rows all satisfy it (barkpark_id NOT NULL
      until this migration, site_id new and NULL).

  ## The backfill NEVER raises on production data

  `Registry.backfill_site_domain_claims/1` inserts one claim per site domain
  with `ON CONFLICT (host) DO NOTHING`. A domain whose host is already claimed
  (a barkpark's url or custom_host, or an older site's domain) is SKIPPED,
  logged at warning level naming both sides, and left on the site row as it is.
  The claim already in the table holds; the function's doc states why.

  Why no backfill INSERT can violate a constraint:

    * `host <> ''` — hosts come from `Registry.hostname_claim_key/1`, which
      returns nil (the domain is dropped) for anything empty or without a letter
      or digit.
    * kind / owner CHECKs — the backfill writes only `kind = 'site_domain'` with
      `site_id` set and `barkpark_id` NULL.
    * the FK — every `site_id` is read inside this migration's transaction with
      `sites` held `IN SHARE MODE` (writes blocked, reads not), so no site can be
      deleted between the read and the insert, and none inserted and missed.
    * `UNIQUE (host)` — `ON CONFLICT (host) DO NOTHING`.

  Like create_hostname_claims, this migration calls application code on purpose
  so the backfill keys hosts with the same normaliser as the live writes.
  """
  use Ecto.Migration

  def up do
    alter table(:hostname_claims) do
      add :site_id, references(:sites, type: :binary_id, on_delete: :delete_all)
    end

    # DROP NOT NULL only — no type rewrite, the barkparks FK is untouched.
    execute "ALTER TABLE hostname_claims ALTER COLUMN barkpark_id DROP NOT NULL"

    create index(:hostname_claims, [:site_id])

    drop constraint(:hostname_claims, :hostname_claims_kind_check)

    create constraint(:hostname_claims, :hostname_claims_kind_check,
             check: "kind IN ('url', 'custom_host', 'site_domain')"
           )

    create constraint(:hostname_claims, :hostname_claims_owner_check,
             check:
               "(kind = 'site_domain' AND site_id IS NOT NULL AND barkpark_id IS NULL) OR " <>
                 "(kind <> 'site_domain' AND barkpark_id IS NOT NULL AND site_id IS NULL)"
           )

    execute "LOCK TABLE sites IN SHARE MODE"

    flush()

    BarkparkCloud.Registry.backfill_site_domain_claims(repo())
  end

  def down do
    execute "DELETE FROM hostname_claims WHERE kind = 'site_domain'"

    drop constraint(:hostname_claims, :hostname_claims_owner_check)
    drop constraint(:hostname_claims, :hostname_claims_kind_check)

    create constraint(:hostname_claims, :hostname_claims_kind_check,
             check: "kind IN ('url', 'custom_host')"
           )

    drop index(:hostname_claims, [:site_id])

    alter table(:hostname_claims) do
      remove :site_id
    end

    execute "ALTER TABLE hostname_claims ALTER COLUMN barkpark_id SET NOT NULL"
  end
end
