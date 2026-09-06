defmodule BarkparkCloud.Registry.SiteTest do
  @moduledoc """
  site-spawner W1 (charter D1/D2/D3): pure, no-DB changeset gates over the
  content-bound static-site extension of the Site substrate —

    * `kind` is THE discriminator (container | static), required, defaulting to
      "container" so every pre-W1 row keeps its meaning
    * framework legality is KIND-GATED: static ⇒ {astro,hugo,static},
      container ⇒ {nextjs,nuxt,sveltekit}; the cross pairs (astro+container,
      nextjs+static) are rejected
    * the bootstrap_* dataset triple binds a static build to a Barkpark dataset
    * read_token_encrypted is a binary at-rest field the changeset accepts as
      ciphertext (the plaintext is encrypted upstream in `create_site/2`)
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry.Site

  @bp_id "11111111-1111-1111-1111-111111111111"
  @team_id "22222222-2222-2222-2222-222222222222"

  defp base(attrs) do
    Map.merge(
      %{name: "Shop", slug: "shop", barkpark_id: @bp_id, team_id: @team_id},
      Map.new(attrs)
    )
  end

  defp changeset(attrs), do: Site.changeset(%Site{}, base(attrs))

  # Local mini errors_on (DataCase's helper without the DB dependency).
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "kind discriminator" do
    test "defaults to container (the pre-W1 shape) when unspecified" do
      # A container site with the container-default framework is valid.
      cs = changeset(framework: "nextjs")
      assert cs.valid?, inspect(errors_on(cs))
      assert Ecto.Changeset.get_field(cs, :kind) == "container"
    end

    test "the legal kinds are container, static, and node" do
      assert Site.kinds() == ~w(container static node)
    end

    test "node is a valid kind (site-spawner W7 — the node-slot SSR runtime target)" do
      cs = changeset(kind: "node", framework: "nextjs")
      assert cs.valid?, inspect(errors_on(cs))
    end

    test "container is a valid kind" do
      cs = changeset(kind: "container", framework: "nextjs")
      assert cs.valid?, inspect(errors_on(cs))
    end

    test "static is a valid kind" do
      cs = changeset(kind: "static", framework: "astro")
      assert cs.valid?, inspect(errors_on(cs))
    end

    test "an unknown kind is rejected" do
      cs = changeset(kind: "serverless", framework: "astro")
      refute cs.valid?
      assert %{kind: [_ | _]} = errors_on(cs)
    end
  end

  describe "kind-gated framework legality (charter D2)" do
    # ssw8-bl-accepted-frameworks-no-implementation: KIND-legality and
    # SHIPPED-ness are two different questions, and these tests used to conflate
    # them — `static+hugo` is kind-legal (a hugo site is a static site) and is
    # NOT creatable (nothing builds it). The vocabulary assertion stays, on
    # `frameworks_for_kind/1`; the creatability assertion moves to the shipped
    # sublist. Weakening the door to keep the old `cs.valid?` green would have
    # been the wrong repair.
    test "static's kind-legal vocabulary is astro, hugo, static — and only astro/static are creatable" do
      assert Site.frameworks_for_kind("static") == ~w(astro hugo static)

      for fw <- ~w(astro static) do
        cs = changeset(kind: "static", framework: fw)
        assert cs.valid?, "static+#{fw} should be creatable: #{inspect(errors_on(cs))}"
      end

      cs = changeset(kind: "static", framework: "hugo")
      refute cs.valid?
      assert %{framework: [msg]} = errors_on(cs)
      assert msg =~ "no shipped builder"
    end

    test "container's kind-legal vocabulary is nextjs, nuxt, sveltekit — and only nextjs is creatable" do
      assert Site.frameworks_for_kind("container") == ~w(nextjs nuxt sveltekit)

      cs = changeset(kind: "container", framework: "nextjs")
      assert cs.valid?, inspect(errors_on(cs))

      for fw <- ~w(nuxt sveltekit) do
        cs = changeset(kind: "container", framework: fw)
        refute cs.valid?, "container+#{fw} has no shipped builder and must be refused"
        assert %{framework: [msg]} = errors_on(cs)
        assert msg =~ "no shipped builder"
      end
    end

    test "node reuses the container vocabulary (site-spawner W7) and its creatable sublist" do
      assert Site.frameworks_for_kind("node") == ~w(nextjs nuxt sveltekit)

      cs = changeset(kind: "node", framework: "nextjs")
      assert cs.valid?, inspect(errors_on(cs))

      for fw <- ~w(nuxt sveltekit) do
        cs = changeset(kind: "node", framework: fw)
        refute cs.valid?, "node+#{fw} has no shipped builder and must be refused"
      end
    end

    # The two refusals are DIFFERENT facts and must not collapse into one
    # message: "astro is not valid for a container site" (a kind mistake — pick
    # another kind) is not "sveltekit has no shipped builder" (a timing fact —
    # nothing you can pick fixes it today).
    test "a kind-illegal framework reports the KIND error, not the shipped one" do
      cs = changeset(kind: "container", framework: "astro")
      refute cs.valid?
      assert %{framework: [msg]} = errors_on(cs)
      assert msg =~ "is not valid for a container site"
      refute msg =~ "no shipped builder"
    end

    test "astro (a static framework) on a node site is rejected" do
      cs = changeset(kind: "node", framework: "astro")
      refute cs.valid?
      assert %{framework: [_ | _]} = errors_on(cs)
    end

    test "astro on a container site is rejected" do
      cs = changeset(kind: "container", framework: "astro")
      refute cs.valid?
      assert %{framework: [_ | _]} = errors_on(cs)
    end

    test "nextjs on a static site is rejected" do
      cs = changeset(kind: "static", framework: "nextjs")
      refute cs.valid?
      assert %{framework: [_ | _]} = errors_on(cs)
    end

    test "a static site left on the container-default framework is rejected" do
      # No framework given → the schema default "nextjs" resolves, which is
      # illegal for a static site. The changeset must catch it (get_field, not
      # get_change) rather than silently allow it.
      cs = changeset(kind: "static")
      refute cs.valid?
      assert %{framework: [_ | _]} = errors_on(cs)
    end

    test "frameworks_for_kind maps each kind to its sublist" do
      assert Site.frameworks_for_kind("static") == ~w(astro hugo static)
      assert Site.frameworks_for_kind("container") == ~w(nextjs nuxt sveltekit)
      # site-spawner W7: node reuses the container frameworks (SSR from content).
      assert Site.frameworks_for_kind("node") == ~w(nextjs nuxt sveltekit)
      # Unknown kind → the full union (so the kind-inclusion check, not an empty
      # allow-list, is what fails).
      assert Site.frameworks_for_kind("bogus") == Site.frameworks()
    end
  end

  describe "content binding (the bootstrap_* dataset triple)" do
    test "the dataset triple is cast onto a static site" do
      cs =
        changeset(
          kind: "static",
          framework: "astro",
          bootstrap_workspace: "acme",
          bootstrap_project: "marketing",
          bootstrap_dataset: "production"
        )

      assert cs.valid?, inspect(errors_on(cs))
      assert Ecto.Changeset.get_field(cs, :bootstrap_workspace) == "acme"
      assert Ecto.Changeset.get_field(cs, :bootstrap_project) == "marketing"
      assert Ecto.Changeset.get_field(cs, :bootstrap_dataset) == "production"
    end

    test "a container site carries no dataset binding (all nil)" do
      cs = changeset(kind: "container", framework: "nextjs")
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :bootstrap_dataset) == nil
    end
  end

  describe "doc_type (charter D35)" do
    test "defaults to the canonical 'post' when unspecified" do
      cs = changeset(kind: "static", framework: "astro")
      assert cs.valid?, inspect(errors_on(cs))
      assert Ecto.Changeset.get_field(cs, :doc_type) == "post"
    end

    test "an explicit doc_type is cast onto the site" do
      cs = changeset(kind: "static", framework: "astro", doc_type: "paper")
      assert cs.valid?, inspect(errors_on(cs))
      assert Ecto.Changeset.get_field(cs, :doc_type) == "paper"
    end
  end

  describe "read_token_encrypted (encrypted-at-rest field)" do
    test "the changeset accepts ciphertext as the read_token_encrypted binary" do
      cipher = <<1, 2, 3, 4>>

      cs =
        changeset(
          kind: "static",
          framework: "astro",
          read_token_encrypted: cipher
        )

      assert cs.valid?, inspect(errors_on(cs))
      assert Ecto.Changeset.get_field(cs, :read_token_encrypted) == cipher
    end

    test "no plaintext read_token field is ever cast onto the row" do
      # The plaintext key is NOT a schema field — the changeset must ignore it,
      # so a caller can't accidentally persist a plaintext token by naming the
      # field directly. Encryption happens in Registry.create_site/2.
      cs = changeset(kind: "static", framework: "astro", read_token: "plain-secret")
      assert cs.valid?
      refute Map.has_key?(cs.changes, :read_token)
      assert Ecto.Changeset.get_field(cs, :read_token_encrypted) == nil
    end
  end

  describe "CF edge binding — schema defaults (charter D51/D58 standalone-degrade)" do
    test "serving_mode defaults to direct (the standalone path)" do
      cs = changeset(kind: "static", framework: "astro")
      assert cs.valid?, inspect(errors_on(cs))
      assert Ecto.Changeset.get_field(cs, :serving_mode) == "direct"
    end

    test "tls_mode defaults to on_demand (today's box Caddy ACME)" do
      cs = changeset(kind: "static", framework: "astro")
      assert cs.valid?, inspect(errors_on(cs))
      assert Ecto.Changeset.get_field(cs, :tls_mode) == "on_demand"
    end

    test "a default site carries no CF handles (all nil)" do
      cs = changeset(kind: "container", framework: "nextjs")
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :cf_domain) == nil
      assert Ecto.Changeset.get_field(cs, :cf_zone_id) == nil
      assert Ecto.Changeset.get_field(cs, :cf_record_id) == nil
    end

    test "the mode enums expose their legal values" do
      assert Site.serving_modes() == ~w(direct cf_proxied)
      assert Site.tls_modes() == ~w(on_demand cf_internal cf_origin_ca)
    end

    test "the main changeset does NOT cast CF columns (containment — narrow changeset owns them)" do
      # The edge binding is written ONLY through cf_binding_changeset/2, never the
      # broad create/update path — so a create call can't back-door a CF binding.
      cs =
        changeset(
          kind: "static",
          framework: "astro",
          cf_domain: "blog.example.com",
          serving_mode: "cf_proxied"
        )

      assert cs.valid?
      refute Map.has_key?(cs.changes, :cf_domain)
      refute Map.has_key?(cs.changes, :serving_mode)
      # …and the resolved values stay at the standalone defaults.
      assert Ecto.Changeset.get_field(cs, :cf_domain) == nil
      assert Ecto.Changeset.get_field(cs, :serving_mode) == "direct"
    end
  end

  describe "cf_binding_changeset (the narrow CF-binding write path, charter D51)" do
    defp cf_cs(attrs), do: Site.cf_binding_changeset(%Site{}, Map.new(attrs))

    test "casts the CF handles + modes onto the site" do
      cs =
        cf_cs(
          cf_domain: "blog.example.com",
          cf_zone_id: "zone_abc",
          cf_record_id: "rec_123",
          serving_mode: "cf_proxied",
          tls_mode: "cf_internal"
        )

      assert cs.valid?, inspect(errors_on(cs))
      assert Ecto.Changeset.get_field(cs, :cf_domain) == "blog.example.com"
      assert Ecto.Changeset.get_field(cs, :cf_zone_id) == "zone_abc"
      assert Ecto.Changeset.get_field(cs, :cf_record_id) == "rec_123"
      assert Ecto.Changeset.get_field(cs, :serving_mode) == "cf_proxied"
      assert Ecto.Changeset.get_field(cs, :tls_mode) == "cf_internal"
    end

    test "normalizes cf_domain (case-folds, trims, strips trailing dot)" do
      cs = cf_cs(cf_domain: " Blog.Example.COM. ")
      assert cs.valid?, inspect(errors_on(cs))
      assert Ecto.Changeset.get_field(cs, :cf_domain) == "blog.example.com"
    end

    test "an unknown serving_mode is rejected" do
      cs = cf_cs(serving_mode: "sideways")
      refute cs.valid?
      assert %{serving_mode: [_ | _]} = errors_on(cs)
    end

    test "an unknown tls_mode is rejected" do
      cs = cf_cs(tls_mode: "letsencrypt")
      refute cs.valid?
      assert %{tls_mode: [_ | _]} = errors_on(cs)
    end

    test "cf_origin_ca tls_mode + cert/key paths are accepted (deferred hardening shape)" do
      cs =
        cf_cs(
          serving_mode: "cf_proxied",
          tls_mode: "cf_origin_ca",
          cf_cert_path: "/etc/caddy/cf/blog.crt",
          cf_key_path: "/etc/caddy/cf/blog.key"
        )

      assert cs.valid?, inspect(errors_on(cs))
      assert Ecto.Changeset.get_field(cs, :cf_cert_path) == "/etc/caddy/cf/blog.crt"
      assert Ecto.Changeset.get_field(cs, :cf_key_path) == "/etc/caddy/cf/blog.key"
    end

    test "a malformed cf_domain is rejected" do
      cs = cf_cs(cf_domain: "not a domain")
      refute cs.valid?
      assert %{cf_domain: [_ | _]} = errors_on(cs)
    end

    test "the narrow changeset can NOT rename or re-team the site (containment)" do
      cs =
        Site.cf_binding_changeset(%Site{}, %{
          name: "hijacked",
          slug: "hijacked",
          team_id: "99999999-9999-9999-9999-999999999999",
          serving_mode: "cf_proxied"
        })

      refute Map.has_key?(cs.changes, :name)
      refute Map.has_key?(cs.changes, :slug)
      refute Map.has_key?(cs.changes, :team_id)
      assert Ecto.Changeset.get_field(cs, :serving_mode) == "cf_proxied"
    end
  end

  ## ssw8-persist-binding-verdict (charter D73) — THE VERDICT IS A COLUMN.
  ##
  ## `content_bound` on the wire was `not is_nil(read_token_encrypted)` — "a token
  ## was minted", which every content-bound site has. It is now DERIVED from this
  ## persisted verdict, so the changeset is the door that keeps the value legal.

  describe "content_binding_verdict (ssw8): the persisted create-time verdict" do
    test "defaults to never_checked — nobody has looked, and that is its OWN value" do
      cs = changeset(kind: "container", framework: "nextjs")
      assert cs.valid?
      # NOT nil, and NOT a nullable `bound`: a NULL a reader rounds up to
      # "probably fine" is exactly the un-backed field this column retires.
      assert Ecto.Changeset.get_field(cs, :content_binding_verdict) == "never_checked"
      assert Ecto.Changeset.get_field(cs, :content_binding_checked_at) == nil
    end

    test "accepts each of the four honest verdicts, and the checked-at stamp" do
      at = ~U[2026-09-06 12:00:00.000000Z]

      for verdict <- Site.binding_verdicts() do
        cs =
          changeset(
            kind: "container",
            framework: "nextjs",
            content_binding_verdict: verdict,
            content_binding_checked_at: at
          )

        assert cs.valid?, "#{verdict} must be a legal verdict"
        assert Ecto.Changeset.get_field(cs, :content_binding_verdict) == verdict
        assert Ecto.Changeset.get_field(cs, :content_binding_checked_at) == at
      end

      assert Enum.sort(Site.binding_verdicts()) ==
               ~w(bound never_checked not_applicable unverified)
    end

    test "a verdict outside the enum is a validation error, never a silent bad row" do
      cs = changeset(kind: "container", framework: "nextjs", content_binding_verdict: "probably")
      refute cs.valid?
      assert {"is invalid", _} = cs.errors[:content_binding_verdict]
    end

    test "an explicit nil verdict is refused — the derivation has no reading for it" do
      cs = changeset(kind: "container", framework: "nextjs", content_binding_verdict: nil)
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:content_binding_verdict]
    end
  end
end

defmodule BarkparkCloud.Registry.SitePersistenceTest do
  @moduledoc """
  site-spawner W1: the DB round-trip for `create_site/2` — a static site persists
  its kind + dataset binding, and its read token lands ONLY as ciphertext
  (encrypted at rest, decryptable back to the plaintext).
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Site

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  test "a static site round-trips: kind + dataset binding persist, read token is encrypted at rest" do
    bp = barkpark_fixture(team_fixture())

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Marketing",
        slug: "marketing",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "web",
        bootstrap_dataset: "production",
        read_token: "sk_read_public_abc123"
      })

    reloaded = Repo.get!(Site, site.id)

    assert reloaded.kind == "static"
    assert reloaded.framework == "astro"
    assert reloaded.bootstrap_workspace == "acme"
    assert reloaded.bootstrap_project == "web"
    assert reloaded.bootstrap_dataset == "production"

    # Encrypted at rest: the stored bytes are ciphertext, never the plaintext.
    assert is_binary(reloaded.read_token_encrypted)
    refute reloaded.read_token_encrypted == "sk_read_public_abc123"
    # …and it decrypts back to the original plaintext.
    assert {:ok, "sk_read_public_abc123"} = Registry.reveal_site_read_token(reloaded)
  end

  test "a container site persists with no dataset binding and no read token" do
    bp = barkpark_fixture(team_fixture())

    {:ok, site} =
      Registry.create_site(bp, %{name: "App", slug: "app", framework: "nextjs"})

    reloaded = Repo.get!(Site, site.id)

    assert reloaded.kind == "container"
    assert reloaded.bootstrap_dataset == nil
    assert reloaded.read_token_encrypted == nil
    assert {:ok, nil} = Registry.reveal_site_read_token(reloaded)
  end

  describe "CF edge binding round-trip (charter D51)" do
    test "a freshly created site defaults to the standalone binding (direct / on_demand, no handles)" do
      bp = barkpark_fixture(team_fixture())
      {:ok, site} = Registry.create_site(bp, %{name: "App", slug: "app", framework: "nextjs"})

      reloaded = Repo.get!(Site, site.id)
      assert reloaded.serving_mode == "direct"
      assert reloaded.tls_mode == "on_demand"

      assert Registry.cf_binding(reloaded) == %{
               cf_domain: nil,
               cf_zone_id: nil,
               cf_record_id: nil,
               serving_mode: "direct",
               tls_mode: "on_demand",
               cf_cert_path: nil,
               cf_key_path: nil
             }
    end

    test "set_cf_binding persists the edge binding atomically and cf_binding reads it back" do
      bp = barkpark_fixture(team_fixture())

      {:ok, site} =
        Registry.create_site(bp, %{
          name: "Marketing",
          slug: "marketing",
          kind: "static",
          framework: "astro",
          bootstrap_dataset: "production"
        })

      {:ok, bound} =
        Registry.set_cf_binding(site, %{
          cf_domain: "blog.example.com",
          cf_zone_id: "zone_abc",
          cf_record_id: "rec_123",
          serving_mode: "cf_proxied",
          tls_mode: "cf_internal"
        })

      assert bound.serving_mode == "cf_proxied"

      reloaded = Repo.get!(Site, site.id)

      assert Registry.cf_binding(reloaded) == %{
               cf_domain: "blog.example.com",
               cf_zone_id: "zone_abc",
               cf_record_id: "rec_123",
               serving_mode: "cf_proxied",
               tls_mode: "cf_internal",
               cf_cert_path: nil,
               cf_key_path: nil
             }
    end

    test "set_cf_binding rejects a bad mode without persisting (transactional, row unchanged)" do
      bp = barkpark_fixture(team_fixture())
      {:ok, site} = Registry.create_site(bp, %{name: "App", slug: "app", framework: "nextjs"})

      assert {:error, %Ecto.Changeset{}} =
               Registry.set_cf_binding(site, %{serving_mode: "sideways"})

      # The row keeps its standalone defaults — nothing half-persisted.
      reloaded = Repo.get!(Site, site.id)
      assert reloaded.serving_mode == "direct"
      assert reloaded.tls_mode == "on_demand"
    end
  end
end
