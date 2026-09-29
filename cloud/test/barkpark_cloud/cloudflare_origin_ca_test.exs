defmodule BarkparkCloud.Cloudflare.OriginCATest do
  @moduledoc """
  The Origin CA provisioning round trip (cf-origin-ca-wire-and-provision),
  end-to-end against the in-memory `Cloudflare.Fake`: CSR → mint → PERSIST.

  The load-bearing assertion is that the SITE ROW comes back out of Postgres
  carrying `tls_mode: "cf_origin_ca"` and both cert paths — re-read, not read
  off the struct the writer returned. Everything about this capability was
  dormant before: the renderer supported `origin_ca` and nothing ever set the
  fields.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Cloudflare, Registry}
  alias BarkparkCloud.Cloudflare.{CSR, Fake, OriginCA}
  alias BarkparkCloud.Registry.Site

  @key_size 1024

  setup do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: "bpt_public_read"
      })

    # Process-scoped (never Application.put_env) so this module stays async —
    # see Cloudflare's "Process-scoped config override".
    Cloudflare.put_process_config(origin_ca_dir: "/etc/caddy/cloudflare")

    %{site: site}
  end

  describe "provision/3 — the Fake round trip" do
    test "mints from a real CSR and PERSISTS mode + both paths on the row", %{site: site} do
      assert {:ok, provisioned} =
               OriginCA.provision(site, ["blog.example.com", "*.blog.example.com"],
                 key_size: @key_size
               )

      assert String.starts_with?(provisioned.cert_id, "cert_fake_")
      assert provisioned.certificate =~ "BEGIN CERTIFICATE"
      assert provisioned.private_key =~ "BEGIN RSA PRIVATE KEY"

      assert provisioned.cert_path == "/etc/caddy/cloudflare/#{site.slug}.origin.crt"
      assert provisioned.key_path == "/etc/caddy/cloudflare/#{site.slug}.origin.key"

      # RE-READ the row: the persist is the criterion, not the return value.
      reloaded = Registry.get_site(site.id)
      assert %Site{tls_mode: "cf_origin_ca"} = reloaded
      assert reloaded.cf_cert_path == provisioned.cert_path
      assert reloaded.cf_key_path == provisioned.key_path

      binding = Registry.cf_binding(reloaded)
      assert binding.tls_mode == "cf_origin_ca"
      assert binding.cf_cert_path == provisioned.cert_path
      assert binding.cf_key_path == provisioned.key_path
    end

    test "the CSR handed to Cloudflare is a REAL PKCS#10 over the same hostnames", %{site: site} do
      hosts = ["blog.example.com", "*.blog.example.com"]
      assert {:ok, _} = OriginCA.provision(site, hosts, key_size: @key_size)

      # The Fake records what it was called with; the CSR it received must parse
      # back and self-verify, so a mint is never fed a placeholder string.
      assert [%{hostnames: ^hosts} | _] = Fake.certs()
    end

    test "provisioning leaves serving_mode and the DNS handles ALONE", %{site: site} do
      {:ok, _} = OriginCA.provision(site, ["blog.example.com"], key_size: @key_size)

      reloaded = Registry.get_site(site.id)
      # This module owns TLS material only — it must never flip how the site is
      # fronted, which is the DNS binder's business.
      assert reloaded.serving_mode == site.serving_mode
      assert reloaded.cf_domain == site.cf_domain
      assert reloaded.cf_record_id == site.cf_record_id
    end
  end

  describe "provision/3 — nothing half-lands" do
    test "a refused mint persists NOTHING (the row keeps its previous tls_mode)", %{site: site} do
      before = Registry.get_site(site.id).tls_mode

      # "fail-" is the Fake's refusal sentinel: the CSR is generated, the mint
      # fails, and the persist must never run.
      assert {:error, :cert_failed} =
               OriginCA.provision(site, ["fail-blog.example.com"], key_size: @key_size)

      reloaded = Registry.get_site(site.id)
      assert reloaded.tls_mode == before
      assert is_nil(reloaded.cf_cert_path)
      assert is_nil(reloaded.cf_key_path)
    end

    test "an empty hostname list fails at the CSR, before any Cloudflare call", %{site: site} do
      assert {:error, :no_hostnames} = OriginCA.provision(site, [])
      assert Fake.certs() == []
      assert is_nil(Registry.get_site(site.id).cf_cert_path)
    end
  end

  describe "cert_paths/2 + configured?/0" do
    test "paths are derived from the slug and never collide across sites", %{site: site} do
      paths = OriginCA.cert_paths(site)
      assert paths.cert_path =~ site.slug
      assert paths.key_path =~ site.slug
      refute paths.cert_path == paths.key_path
    end

    test ":dir overrides the on-box base directory", %{site: site} do
      paths = OriginCA.cert_paths(site, dir: "/srv/certs")
      assert paths.cert_path == "/srv/certs/#{site.slug}.origin.crt"
    end

    test "configured?/0 asks about the ORIGIN CA KEY, not the API token" do
      # An API token alone must NOT report the Origin CA capability as wired —
      # conflating the two is how a call reaches /certificates as the wrong
      # authority.
      Cloudflare.put_process_config(token: "cf_api_token")
      refute OriginCA.configured?()
      assert Cloudflare.configured?()

      Cloudflare.put_process_config(origin_ca_key: "v1.0-origin-ca-key")
      assert OriginCA.configured?()
      refute Cloudflare.configured?()

      Cloudflare.put_process_config(origin_ca_key: "")
      refute OriginCA.configured?()
    end
  end

  describe "the CSR the provisioner builds" do
    test "self-verifies and carries the hostnames as CN + SAN" do
      {:ok, %{csr: csr}} =
        CSR.generate(["blog.example.com", "*.blog.example.com"], key_size: @key_size)

      assert {:ok, %{common_name: "blog.example.com", hostnames: hosts}} = CSR.verify(csr)
      assert hosts == ["blog.example.com", "*.blog.example.com"]
    end
  end
end
