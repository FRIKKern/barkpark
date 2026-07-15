defmodule BarkparkCloud.Repo.Migrations.AddCfEdgeBindingToSites do
  use Ecto.Migration

  # site-spawner W6 (charter D51): CLOUDFLARE-IN-FRONT edge binding. Let a user
  # OPTIONALLY put Cloudflare in front of the standalone box — free wildcard
  # Universal SSL, DNS API, unlimited-bandwidth CDN, DDoS — WITHOUT giving up the
  # standalone-first law: the box still builds+serves its own content over its own
  # origin; connecting a CF account only ADDS capability and DEGRADES GRACEFULLY.
  #
  # The edge binding lives on `sites` (NOT `Barkpark.custom_host`, charter D51):
  # a user's own domain binds to a deployed SITE, not the box instance, and
  # `custom_host` is regex-locked to `*.barkpark.cloud` (the platform's own-zone
  # custody model, the OPPOSITE of CF-in-front's user-zone/user-token/per-site
  # model). Scalar columns mirroring the W1 content-binding precedent
  # (`20260713120000`): one CF-bound domain per site (v1 = singular `--domain`).
  #
  # sites gains:
  #   * cf_domain    — the user's own hostname bound to this site (blog.example.com).
  #     Null on a pure-standalone site (no CF account connected).
  #   * cf_zone_id   — the CF zone the domain lives in (the DNS-writer target).
  #   * cf_record_id — the CF DNS record the writer created/updated (for idempotent
  #     re-writes + teardown).
  #   * serving_mode — how the box is fronted: "direct" (the box answers on its own
  #     origin, TODAY's exact behavior — the standalone default) or "cf_proxied"
  #     (an orange-cloud CF record fronts the box). Defaults "direct" so every
  #     existing row keeps its meaning (standalone-degrade).
  #   * tls_mode     — how TLS is terminated at the box origin: "on_demand" (the
  #     box's Caddy on-demand ACME, TODAY's default) or, when CF proxies,
  #     "cf_internal" (Caddy `tls internal` under CF Full — on-demand ACME can't
  #     complete behind the orange cloud, CF error 526, charter D55) or
  #     "cf_origin_ca" (a CF-minted Origin-CA cert on disk under CF Full Strict —
  #     DEFERRED hardening). Defaults "on_demand" so an existing row is byte-identical.
  #   * cf_cert_path / cf_key_path — on-disk paths of a CF Origin-CA cert+key
  #     (nullable; populated only by the deferred `cf_origin_ca` provisioning path).
  #
  # Every column is nullable / defaulted so a pre-W6 site row is byte-identical to
  # today: the standalone path is untouched (charter D58 standalone-degrade).
  def change do
    alter table(:sites) do
      add :cf_domain, :string
      add :cf_zone_id, :string
      add :cf_record_id, :string
      add :serving_mode, :string, null: false, default: "direct"
      add :tls_mode, :string, null: false, default: "on_demand"
      add :cf_cert_path, :string
      add :cf_key_path, :string
    end
  end
end
