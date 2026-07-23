defmodule BarkparkCloud.Repo.Migrations.AddFleetGroupToBarkparks do
  use Ecto.Migration

  # Personal Dev Fleet Wave C (PDF-D61) — the fleet GROUP record. A "main" is the
  # developer's home base; "support" boxes attach to it. Rather than a new table
  # or a join row (the shape is exactly two-tier main -> N supports), the group
  # identity rides three ADDITIVE nullable columns on the existing `barkparks`
  # machine registry, matching the `add_*_to_barkparks` precedent (metadata-only
  # ADD COLUMN, no default, no backfill — every existing row stays untouched and
  # `fleet_role IS NULL` reads as "ungrouped", an honest legacy state).
  #
  #   * `fleet_role`      — "main" | "support" | NULL (ungrouped). NULL by default,
  #                         so no existing row is retro-classified.
  #   * `fleet_parent_id` — a SELF-referential FK to the main's `barkparks.id`, set
  #                         ONLY on support rows. `on_delete: :nilify_all` — deleting
  #                         a main orphans (does not cascade-delete) its supports;
  #                         they become ungrouped rather than silently vanishing.
  #   * `fleet_token_id`  — the OPAQUE id of the minted ledger token (for later
  #                         revocation). Deliberately NOT the secret: the custody
  #                         precedent is `admin_token_encrypted` (Vault-encrypted
  #                         secrets); this column is a plain identifier and is safe
  #                         to serialize, so it never rides the encrypt-at-rest seam.
  #
  # The index on `fleet_parent_id` backs both the "supports of this main" lookup
  # and the `nilify_all` scan a main-delete triggers — partial so the many
  # NULL (ungrouped / main) rows stay outside it.
  def change do
    alter table(:barkparks) do
      add :fleet_role, :string
      add :fleet_parent_id, references(:barkparks, type: :binary_id, on_delete: :nilify_all)
      add :fleet_token_id, :string
    end

    create index(:barkparks, [:fleet_parent_id],
             name: :barkparks_fleet_parent_id_idx,
             where: "fleet_parent_id IS NOT NULL"
           )
  end
end
