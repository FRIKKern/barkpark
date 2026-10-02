defmodule BarkparkCloud.Repo.Migrations.CreateHostnameClaims do
  @moduledoc """
  dr-w24-bl-hostname-claims-table-backstop: ONE hostname namespace, ONE table.

  Each barkparks row claims two hostnames (its `url` host and its
  `custom_host`); the two per-column unique indexes cannot see a collision
  between different columns of different rows. `hostname_claims` holds one row
  per claimed host with `UNIQUE (host)`, so the database refuses that collision
  atomically. See `BarkparkCloud.Registry.HostnameClaim`.

  ## The backfill NEVER raises on production data

  Existing claims are copied in by `Registry.backfill_hostname_claims/1`, one
  `INSERT … ON CONFLICT DO NOTHING` per claim. A pre-existing collision (the
  known one: a June-29 ghost row whose `url` is a host another row now serves
  as its `custom_host`) is SKIPPED and logged at warning level with both row
  ids; the rows themselves are left exactly as they are. Only NEW writes are
  refused. `custom_host` claims are inserted before `url` claims, so on a
  pre-existing collision the customer's deliberate claim holds the host and the
  platform-minted url is the one skipped.

  ## Why no backfill INSERT can violate a constraint

    * `host <> ''` — every host comes from `Registry.hostname_claim_key/1`,
      which returns `nil` (and the candidate is dropped) for anything empty or
      without a letter or digit.
    * `kind IN ('url','custom_host')` — the backfill writes only those two
      literals.
    * the FK — every `barkpark_id` is read from `barkparks` inside this
      migration's transaction, with `barkparks` held `IN SHARE MODE`, so no row
      can be deleted between the read and the insert.
    * `UNIQUE (host)` — `ON CONFLICT (host) DO NOTHING`.

  `test/barkpark_cloud/registry_hostname_claims_migration_test.exs` runs this
  module's `up/0` against the Gyldendal ghost shape and the junk spellings.

  ## Why this migration calls application code

  The repo's migrations normally copy what they need (a migration must keep
  meaning what it meant the day it ran). This one deliberately does not: the
  host must be normalised by the SAME function the live claim writes use
  (`Registry.normalize_claim_host/1`), and a copied normaliser is exactly the
  drift the claim-walk twins census exists to catch. The backfill is idempotent
  (`ON CONFLICT DO NOTHING`), so re-running it later — including by hand via
  `bin/barkpark_cloud eval`, which re-lists every skipped collision — can only
  add claims, never remove or overwrite one.
  """
  use Ecto.Migration

  def up do
    create table(:hostname_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :host, :text, null: false

      add :barkpark_id, references(:barkparks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:hostname_claims, [:host], name: :hostname_claims_host_unique_idx)
    create index(:hostname_claims, [:barkpark_id])

    create constraint(:hostname_claims, :hostname_claims_kind_check,
             check: "kind IN ('url', 'custom_host')"
           )

    create constraint(:hostname_claims, :hostname_claims_host_nonempty_check, check: "host <> ''")

    # SHARE blocks barkparks writes (never reads) until this migration's
    # transaction commits — milliseconds for a fleet-sized table. Without it a
    # barkpark deleted between the backfill's SELECT and its INSERT would fail
    # the FK and RAISE, and a row inserted in that window would be missed.
    execute "LOCK TABLE barkparks IN SHARE MODE"

    # The table must exist, and the lock be held, before the backfill runs.
    flush()

    BarkparkCloud.Registry.backfill_hostname_claims(repo())
  end

  def down do
    drop table(:hostname_claims)
  end
end
