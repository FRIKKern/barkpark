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

    test "the two legal kinds are container and static" do
      assert Site.kinds() == ~w(container static)
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
    test "static allows astro, hugo, and static" do
      for fw <- ~w(astro hugo static) do
        cs = changeset(kind: "static", framework: fw)
        assert cs.valid?, "static+#{fw} should be legal: #{inspect(errors_on(cs))}"
      end
    end

    test "container allows nextjs, nuxt, and sveltekit" do
      for fw <- ~w(nextjs nuxt sveltekit) do
        cs = changeset(kind: "container", framework: fw)
        assert cs.valid?, "container+#{fw} should be legal: #{inspect(errors_on(cs))}"
      end
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
end
