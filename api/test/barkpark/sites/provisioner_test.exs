defmodule Barkpark.Sites.ProvisionerTest do
  @moduledoc """
  Unit tests for `Barkpark.Sites.Provisioner` — site source provisioning
  (site-spawner charter D33/D34).

  Everything runs against a TMP sites dir + a TMP stand-in template (never
  `/opt/barkpark`, never the real `templates/astro-starter`), configured through
  the same Application env `runtime.exs` sets. The invariants, each of which is a
  live-deploy bug if it does not hold:

    * a DEPLOY lands the template at the EXACT `<sites_dir>/<slug>/src`
      site-deploy.sh reads (else BUILD still finds nothing);
    * it is idempotent — a redeploy is a marker-guarded no-op that does NOT
      clobber the site's build cache;
    * it is fail-closed — a missing template returns `{:error,
      {:provision_failed, _}}` and leaves NO half-materialized `src`;
    * a ROLLBACK never provisions (its source is already there).
  """
  # async: false — mutates Application env for the singleton Provisioner config.
  use ExUnit.Case, async: false

  alias Barkpark.Sites.DeployRequest
  alias Barkpark.Sites.Provisioner

  setup do
    base = Path.join(System.tmp_dir!(), "bp-provisioner-#{System.unique_integer([:positive])}")
    sites = Path.join(base, "sites")
    template = Path.join(base, "template")

    # A minimal stand-in for templates/astro-starter: a package.json, a nested
    # src/ file, and a dotfile — enough to prove a recursive copy of CONTENTS.
    File.mkdir_p!(Path.join(template, "src/lib"))
    File.write!(Path.join(template, "package.json"), ~s({"name":"astro-stub"}))
    File.write!(Path.join(template, "astro.config.mjs"), "export default {}\n")
    File.write!(Path.join(template, "src/lib/barkpark.ts"), "// content fetch\n")
    File.write!(Path.join(template, ".gitignore"), "dist\n")

    # A stand-in for templates/next-starter (charter D63/D71) — a distinct
    # package.json + next.config so a runtime_target=node deploy provably lands
    # THIS tree, never the astro one.
    node_template = Path.join(base, "node-template")
    File.mkdir_p!(Path.join(node_template, "app"))
    File.write!(Path.join(node_template, "package.json"), ~s({"name":"next-stub"}))
    File.write!(Path.join(node_template, "next.config.mjs"), "export default {}\n")

    # A stand-in for templates/search-starter (search-template charter D7) — a
    # THIRD distinct package.json name so a template=search-starter deploy provably
    # lands THIS tree, never astro or next.
    search_template = Path.join(base, "search-template")
    File.mkdir_p!(Path.join(search_template, "app"))
    File.write!(Path.join(search_template, "package.json"), ~s({"name":"search-stub"}))
    File.write!(Path.join(search_template, "next.config.mjs"), "export default {basePath:'/x'}\n")

    put_cfg(
      sites_dir: sites,
      template_dir: template,
      node_template_dir: node_template,
      search_template_dir: search_template
    )

    on_exit(fn -> File.rm_rf(base) end)

    {:ok,
     sites: sites,
     template: template,
     node_template: node_template,
     search_template: search_template}
  end

  defp put_cfg(overrides) do
    prior = Application.get_env(:barkpark, Provisioner)
    Application.put_env(:barkpark, Provisioner, Keyword.merge(prior || [], overrides))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, Provisioner, prior),
        else: Application.delete_env(:barkpark, Provisioner)
    end)
  end

  defp deploy(slug, opts \\ []) do
    params =
      %{
        "slug" => slug,
        "build_id" => Keyword.get(opts, :build_id, "b1"),
        "mode" => Keyword.get(opts, :mode, "deploy")
      }
      |> maybe_put("runtime_target", Keyword.get(opts, :runtime_target))
      |> maybe_put("template", Keyword.get(opts, :template))

    {:ok, req} = DeployRequest.new(params)
    req
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── the happy path: template → <sites_dir>/<slug>/src ────────────────────

  describe "provision/1 (deploy)" do
    test "materializes the template CONTENTS into <sites_dir>/<slug>/src", %{sites: sites} do
      assert Provisioner.provision(deploy("my-blog")) == :ok

      src = Provisioner.src_dir("my-blog")
      # The path formula MUST match site-deploy.sh's <sites_dir>/<slug>/src.
      assert src == Path.join([sites, "my-blog", "src"])

      # Template CONTENTS land directly in src/ — NOT nested under template/.
      assert File.read!(Path.join(src, "package.json")) == ~s({"name":"astro-stub"})
      assert File.exists?(Path.join(src, "astro.config.mjs"))
      assert File.exists?(Path.join(src, "src/lib/barkpark.ts"))
      # Dotfiles copy too (cp_r! of the whole tree).
      assert File.exists?(Path.join(src, ".gitignore"))
    end

    test "writes a .bp-provisioned marker INSIDE src (the idempotency guard)" do
      assert Provisioner.provision(deploy("marked")) == :ok

      marker = Path.join(Provisioner.src_dir("marked"), ".bp-provisioned")
      assert File.regular?(marker)
      assert File.read!(marker) =~ "provisioned-at="
    end

    test "leaves no .partial staging dir behind on success" do
      assert Provisioner.provision(deploy("clean-stage")) == :ok
      refute File.exists?(Provisioner.src_dir("clean-stage") <> ".partial")
    end
  end

  # ── idempotency (marker-guarded no-op) ───────────────────────────────────

  describe "idempotency" do
    test "a second provision is a marker-guarded no-op that does NOT re-copy" do
      assert Provisioner.provision(deploy("redeploy")) == :ok

      # Simulate the site's build cache + a content-only edit the redeploy must
      # NOT clobber: a node_modules sentinel and an edited source file.
      src = Provisioner.src_dir("redeploy")
      File.mkdir_p!(Path.join(src, "node_modules"))
      File.write!(Path.join(src, "node_modules/.sentinel"), "cached")
      File.write!(Path.join(src, "package.json"), ~s({"name":"locally-edited"}))

      # Second deploy of the same slug: guard sees the marker, returns :ok, disk
      # untouched.
      assert Provisioner.provision(deploy("redeploy", build_id: "b2")) == :ok

      assert File.read!(Path.join(src, "node_modules/.sentinel")) == "cached"
      assert File.read!(Path.join(src, "package.json")) == ~s({"name":"locally-edited"})
    end

    test "a src WITHOUT its marker is NOT trusted — it re-materializes (self-heal)" do
      src = Provisioner.src_dir("half-baked")

      # A prior provision that died before writing the marker: a partial src with
      # NO .bp-provisioned marker.
      File.mkdir_p!(src)
      File.write!(Path.join(src, "package.json"), ~s({"name":"stale-partial"}))
      refute File.regular?(Path.join(src, ".bp-provisioned"))

      assert Provisioner.provision(deploy("half-baked")) == :ok

      # Re-materialized from the template, and now marked.
      assert File.read!(Path.join(src, "package.json")) == ~s({"name":"astro-stub"})
      assert File.regular?(Path.join(src, ".bp-provisioned"))
    end
  end

  # ── content freshness (search-template W1 live-proof fix) ─────────────────
  #
  # Proven live: search-capstone kept building a pre-.basepath template tree
  # because the old marker made EVERY re-provision a no-op — a template update
  # never reached an existing site until the src was hand-cleared on the box.

  describe "content freshness" do
    test "a TEMPLATE UPDATE re-materializes an already-provisioned src", %{template: template} do
      assert Provisioner.provision(deploy("freshen")) == :ok
      src = Provisioner.src_dir("freshen")
      assert File.read!(Path.join(src, "package.json")) == ~s({"name":"astro-stub"})

      # The shipped template changes (the .basepath scenario): a new file.
      File.write!(Path.join(template, ".basepath"), "marker\n")

      assert Provisioner.provision(deploy("freshen", build_id: "b2")) == :ok
      assert File.read!(Path.join(src, ".basepath")) == "marker\n"
    end

    test "an UNCHANGED template stays a no-op — the build cache survives" do
      assert Provisioner.provision(deploy("cache-keeper")) == :ok
      src = Provisioner.src_dir("cache-keeper")
      File.mkdir_p!(Path.join(src, "node_modules"))
      File.write!(Path.join(src, "node_modules/.sentinel"), "cached")

      assert Provisioner.provision(deploy("cache-keeper", build_id: "b2")) == :ok
      assert File.read!(Path.join(src, "node_modules/.sentinel")) == "cached"
    end

    test "a LEGACY marker (no template=/digest= lines) re-materializes once (safe upgrade)" do
      assert Provisioner.provision(deploy("legacy")) == :ok
      src = Provisioner.src_dir("legacy")

      # Rewrite the marker to the pre-freshness shape + plant a canary that a
      # re-materialize must sweep.
      File.write!(Path.join(src, ".bp-provisioned"), "provisioned-at=2026-07-01T00:00:00Z\n")
      File.write!(Path.join(src, "stale-canary.txt"), "old tree")

      assert Provisioner.provision(deploy("legacy", build_id: "b2")) == :ok
      refute File.exists?(Path.join(src, "stale-canary.txt"))
      assert File.read!(Path.join(src, ".bp-provisioned")) =~ "template=astro_starter"
    end

    test "a TEMPLATE SWITCH on an existing slug swaps the tree" do
      assert Provisioner.provision(
               deploy("switcher", template: "next-starter", runtime_target: "node")
             ) == :ok

      src = Provisioner.src_dir("switcher")
      assert File.read!(Path.join(src, "package.json")) == ~s({"name":"next-stub"})

      assert Provisioner.provision(
               deploy("switcher",
                 build_id: "b2",
                 template: "search-starter",
                 runtime_target: "node"
               )
             ) == :ok

      assert File.read!(Path.join(src, "package.json")) == ~s({"name":"search-stub"})
    end
  end

  # ── fail-closed ──────────────────────────────────────────────────────────

  describe "fail-closed" do
    test "a missing template dir → {:error, {:provision_failed, _}}, no src left" do
      put_cfg(
        template_dir:
          Path.join(
            System.tmp_dir!(),
            "bp-no-such-template-#{System.unique_integer([:positive])}"
          )
      )

      assert {:error, {:provision_failed, {:template_not_found, _}}} =
               Provisioner.provision(deploy("no-template"))

      # Fail-closed: nothing materialized.
      refute File.exists?(Provisioner.src_dir("no-template"))
    end

    test "a failure NEVER clobbers an existing good src (built in .partial first)" do
      # Provision once so a good src exists…
      assert Provisioner.provision(deploy("survivor")) == :ok
      src = Provisioner.src_dir("survivor")
      # …drop the marker so the next provision would try to re-materialize…
      File.rm!(Path.join(src, ".bp-provisioned"))
      # …then point the template at nothing so re-materialization fails.
      put_cfg(
        template_dir: Path.join(System.tmp_dir!(), "gone-#{System.unique_integer([:positive])}")
      )

      assert {:error, {:provision_failed, _}} = Provisioner.provision(deploy("survivor"))

      # The good source survives — the failure died before touching src (the
      # template check is BEFORE any rm_rf of src).
      assert File.read!(Path.join(src, "package.json")) == ~s({"name":"astro-stub"})
    end

    test "never raises — a bad sites_dir degrades to an error tuple" do
      # A sites_dir whose parent is a FILE (not a dir) makes mkdir_p! raise; the
      # rescue must turn it into a clean fail-closed tuple.
      file_path = Path.join(System.tmp_dir!(), "bp-file-#{System.unique_integer([:positive])}")
      File.write!(file_path, "i am a file, not a dir")
      on_exit(fn -> File.rm(file_path) end)

      put_cfg(sites_dir: file_path)

      assert {:error, {:provision_failed, _}} = Provisioner.provision(deploy("under-a-file"))
    end
  end

  # ── runtime_target template selection (charter D63/D71) ──────────────────

  describe "runtime_target selection" do
    test "a node/nextjs deploy materializes the next-starter template, not astro" do
      assert Provisioner.provision(deploy("next-blog", runtime_target: "node")) == :ok

      src = Provisioner.src_dir("next-blog")
      # The NODE template landed — the distinct package.json name proves it is
      # next-starter, never the astro-starter default.
      assert File.read!(Path.join(src, "package.json")) == ~s({"name":"next-stub"})
      assert File.exists?(Path.join(src, "next.config.mjs"))
      refute File.exists?(Path.join(src, "astro.config.mjs"))
      # Same framework-agnostic idempotency guard is written for node too.
      assert File.regular?(Path.join(src, ".bp-provisioned"))
      refute File.exists?(src <> ".partial")
    end

    test "a default (static) deploy still materializes the astro-starter template" do
      assert Provisioner.provision(deploy("astro-blog")) == :ok

      src = Provisioner.src_dir("astro-blog")
      assert File.read!(Path.join(src, "package.json")) == ~s({"name":"astro-stub"})
      refute File.exists?(Path.join(src, "next.config.mjs"))
    end

    test "a node deploy is idempotent — the marker guards a re-copy just like static" do
      assert Provisioner.provision(deploy("next-idem", runtime_target: "node")) == :ok

      src = Provisioner.src_dir("next-idem")
      File.write!(Path.join(src, "package.json"), ~s({"name":"locally-edited-next"}))

      # Second node deploy: marker seen, disk untouched (build cache preserved).
      assert Provisioner.provision(deploy("next-idem", build_id: "b2", runtime_target: "node")) ==
               :ok

      assert File.read!(Path.join(src, "package.json")) == ~s({"name":"locally-edited-next"})
    end
  end

  # ── template selection (search-template charter D7) ──────────────────────

  describe "template selection" do
    test "template=search-starter materializes the search-starter tree" do
      assert Provisioner.provision(deploy("search-blog", template: "search-starter")) == :ok

      src = Provisioner.src_dir("search-blog")
      # The distinct package.json name proves the SEARCH tree landed — never astro
      # or next.
      assert File.read!(Path.join(src, "package.json")) == ~s({"name":"search-stub"})
      assert File.exists?(Path.join(src, "next.config.mjs"))
      assert File.regular?(Path.join(src, ".bp-provisioned"))
      refute File.exists?(src <> ".partial")
    end

    test "an explicit template OVERRIDES the runtime_target default" do
      # runtime_target=node alone would pick next-starter; the explicit template
      # wins and picks search-starter.
      assert Provisioner.provision(
               deploy("override", runtime_target: "node", template: "search-starter")
             ) == :ok

      src = Provisioner.src_dir("override")
      assert File.read!(Path.join(src, "package.json")) == ~s({"name":"search-stub"})
    end

    test "template=astro-starter selects astro; template=next-starter selects next" do
      assert Provisioner.provision(deploy("t-astro", template: "astro-starter")) == :ok

      assert File.read!(Path.join(Provisioner.src_dir("t-astro"), "package.json")) ==
               ~s({"name":"astro-stub"})

      assert Provisioner.provision(deploy("t-next", template: "next-starter")) == :ok

      assert File.read!(Path.join(Provisioner.src_dir("t-next"), "package.json")) ==
               ~s({"name":"next-stub"})
    end

    test "no template falls back to the runtime_target default — unchanged behavior" do
      assert Provisioner.provision(deploy("fb-node", runtime_target: "node")) == :ok

      assert File.read!(Path.join(Provisioner.src_dir("fb-node"), "package.json")) ==
               ~s({"name":"next-stub"})

      assert Provisioner.provision(deploy("fb-static")) == :ok

      assert File.read!(Path.join(Provisioner.src_dir("fb-static"), "package.json")) ==
               ~s({"name":"astro-stub"})
    end
  end

  # ── mode gate ────────────────────────────────────────────────────────────

  describe "mode" do
    test "a rollback is a no-op — it materializes NOTHING" do
      {:ok, rollback} = DeployRequest.new(%{"slug" => "rb", "mode" => "rollback"})

      assert Provisioner.provision(rollback) == :ok
      refute File.exists?(Provisioner.src_dir("rb"))
    end
  end
end
