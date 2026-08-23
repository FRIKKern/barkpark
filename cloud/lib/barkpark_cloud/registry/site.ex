defmodule BarkparkCloud.Registry.Site do
  @moduledoc """
  A hosted website running co-located with a Barkpark instance — the runtime
  half of the cloud-website-hosting story. Belongs to a `Barkpark` (the box it
  runs on) and through it to a `Team`.

  The `(team_id, slug)` pair is unique — a Team names each of its sites once.
  `domains` is an array because one site can answer on the apex, www, and any
  number of custom hostnames; the array carries a GIN index so the on-demand
  TLS `/v1/tls/ask` gate can answer "is this domain registered?" in O(1).

  `env_encrypted` is `Vault.encrypt/1`'d JSON; the plaintext is never persisted.
  Setting env always replaces the whole blob.

  Two scale modes:

    * `always_on` — the runtime container stays warm for instant response.
    * `zero`     — agent stops idle containers; a wakeup handler boots on first
                   request. Cheaper, cold-start latency.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @slug_format ~r/^[a-z0-9][a-z0-9-]*$/
  @domain_format ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/

  # site-spawner W1 (charter D1): `kind` is THE discriminator between the two
  # ways a Site is built and served.
  #
  #   * "container" — BYO-repo runtime: a Next.js/Nuxt/SvelteKit app runs as a
  #     long-lived container next to Phoenix (the pre-W1 shape, the default).
  #   * "static"    — content-bound static build: Astro/Hugo/plain HTML built once
  #     from a Barkpark dataset and served as files. The flagship spawn path.
  #   * "node"      — site-spawner W7 (charter D62): content-bound SSR build served
  #     by a per-site long-running Node process (the node-slot runtime target).
  #     Next.js/Nuxt/SvelteKit built FROM a Barkpark dataset (like static) but
  #     served as a running process behind a blue/green Caddy upstream flip — NOT
  #     the pre-W1 "container" BYO-repo path (which routes to the dead off-box
  #     builder, has no content binding, and has no instant rollback).
  @kinds ~w(container static node)

  # Framework legality is kind-GATED (charter D2/D62): a static site can't be a
  # Next.js container app and vice-versa. `@frameworks` stays the union (the
  # public `frameworks/0` surface + the migration/history), but the changeset
  # only accepts the sublist that matches the row's `kind`. The container
  # frameworks are ALSO legal under `node` — a node site fetches content like a
  # static one but serves it via SSR.
  @container_frameworks ~w(nextjs nuxt sveltekit)
  @static_frameworks ~w(astro hugo static)
  @frameworks @container_frameworks ++ @static_frameworks
  @scale_modes ~w(always_on zero)

  # site-spawner W6 (charter D51): the CF-in-front edge-binding enums.
  #
  #   * @serving_modes — how the box is fronted. "direct" is the standalone
  #     default (the box answers on its own origin, TODAY's behavior); "cf_proxied"
  #     means an orange-cloud CF record fronts the box.
  #   * @tls_modes — how TLS terminates at the box origin. "on_demand" is the
  #     standalone default (box Caddy on-demand ACME); "cf_internal" is Caddy
  #     `tls internal` under CF Full (526-avoidance, charter D55); "cf_origin_ca"
  #     is a CF Origin-CA cert on disk under CF Full Strict (deferred hardening).
  @serving_modes ~w(direct cf_proxied)
  @tls_modes ~w(on_demand cf_internal cf_origin_ca)

  # owner/repo — the only shape GitHub uses for repos, e.g. "FRIKKern/barkpark".
  # Two segments separated by one slash; each segment is letters/digits/_/-/.
  @github_repo_format ~r/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/

  schema "sites" do
    field :name, :string
    field :slug, :string
    field :kind, :string, default: "container"
    field :framework, :string, default: "nextjs"
    # search-template W2 (D8): explicit shipped-starter selection; nil = the
    # framework-derived default (deploy relay: astro->astro-starter, nextjs->
    # next-starter). Closed set — the slug indexes a filesystem path on the box.
    field :template, :string
    # search-template W6: the deploy-pinned palette. Nullable — nil keeps the
    # template default; the relay injects BARKPARK_THEME only when set.
    field :theme, :string
    field :domains, {:array, :string}, default: []
    field :env_encrypted, :binary
    field :scale_mode, :string, default: "always_on"
    field :port, :integer

    # site-spawner W7 (charter D68): the per-site node-slot port BASE, allocated
    # ONCE at create for a kind=node site (the lowest-free EVEN base in
    # [7002,7998]). Blue slot = port_base, green slot = port_base + 1; `port`
    # above stays the currently-LIVE serving port (whichever slot the Caddy
    # upstream points at). Null on static/container sites (no per-site process).
    field :port_base, :integer
    field :current_deployment_id, :binary_id

    # site-spawner W1 (charter D3): the content binding — WHICH Barkpark dataset a
    # static build fetches from over the internal link. Mirrors the Barkpark row's
    # own bootstrap_* triple. Null on container sites (they bring their own repo).
    field :bootstrap_workspace, :string
    field :bootstrap_project, :string
    field :bootstrap_dataset, :string

    # site-spawner W4 (charter D35): the content TYPE the static build's flagship
    # fetch reads (baked into BARKPARK_DOC_TYPE at build time). "post" is the
    # canonical default; a site created with `--doc-type paper` reads papers
    # instead — the guerrilla live proof needs `paper` because `production/post`
    # has zero docs there and a real Astro build hard-fails on the empty type.
    field :doc_type, :string, default: "post"

    # A public-read-scoped token the static build uses to read that dataset.
    # `Vault.encrypt/1`'d exactly like `env_encrypted`; the plaintext is never
    # persisted and never serialized. Set through `Registry.create_site/2`
    # (accepts a plaintext `:read_token`, stores only ciphertext).
    field :read_token_encrypted, :binary

    # P7 github-webhook: a GitHub push to `github_branch` of `github_repo`
    # triggers /v1/webhooks/github/:site_id, which verifies the HMAC with the
    # encrypted secret and enqueues a Deployment with git_ref = the pushed sha.
    field :github_repo, :string
    field :github_branch, :string, default: "main"
    field :github_webhook_secret_encrypted, :string

    # site-spawner W5 (charter D47): the per-site HMAC secret the CP mints at
    # create, registers on the box's dataset webhook, and verifies inbound
    # content-publish deliveries against (POST /v1/sites/webhooks/content-publish/
    # :site_id). `Vault.encrypt/1`'d at rest exactly like
    # github_webhook_secret_encrypted; the plaintext is never persisted and never
    # serialized. Null on container sites (no content webhook).
    field :content_webhook_secret_encrypted, :binary

    # gh-6: per-site kill switch for branch previews. Default ON — a connected
    # repo previews non-production branches unless the team opts out. When false,
    # the inbound webhook ignores non-`github_branch` pushes (the pre-gh-6
    # branch_mismatch no-op).
    field :previews_enabled, :boolean, default: true

    # site-spawner W9 (charter D87): the per-site opt-in for PREBUILT deploys —
    # bytes built somewhere other than the serving box and uploaded as a tarball.
    # Default FALSE, and deliberately per-site rather than fleet-wide: accepting
    # output the control plane did not produce is a different trust statement
    # from building it on the box, so it is always an explicit choice for THIS
    # site. With it off, `{"source":"prebuilt"}` is refused and the deploy path is
    # byte-identical to today.
    field :prebuilt_enabled, :boolean, default: false

    # site-spawner W6 (charter D51): CLOUDFLARE-IN-FRONT edge binding. The user's
    # OWN domain (blog.example.com), bound to THIS deployed site through the user's
    # CF account — the OPPOSITE of `Barkpark.custom_host` (platform own-zone, box
    # instance, `*.barkpark.cloud`-locked). One CF-bound domain per site (v1 =
    # singular `--domain`). Every field is nullable/defaulted so a pure-standalone
    # site (no CF account connected) is byte-identical to today (charter D58
    # standalone-degrade).
    #
    #   * cf_domain    — the user's hostname fronting this site.
    #   * cf_zone_id   — the CF zone the DNS writer targets.
    #   * cf_record_id — the CF DNS record the writer created (idempotent re-write
    #     + teardown handle).
    #   * serving_mode — "direct" (box answers on its own origin — TODAY's default,
    #     the standalone path) | "cf_proxied" (orange-cloud CF record fronts the
    #     box). Drives the box's TLS render (mergeSite) and the domain-status rung.
    #   * tls_mode     — "on_demand" (box Caddy on-demand ACME — TODAY's default) |
    #     "cf_internal" (Caddy `tls internal` under CF Full — 526-avoidance,
    #     charter D55) | "cf_origin_ca" (CF Origin-CA cert on disk under CF Full
    #     Strict — DEFERRED hardening).
    #   * cf_cert_path / cf_key_path — on-disk CF Origin-CA cert+key paths
    #     (populated only by the deferred origin-CA provisioning path).
    field :cf_domain, :string
    field :cf_zone_id, :string
    field :cf_record_id, :string
    field :serving_mode, :string, default: "direct"
    field :tls_mode, :string, default: "on_demand"
    field :cf_cert_path, :string
    field :cf_key_path, :string

    belongs_to :barkpark, BarkparkCloud.Registry.Barkpark
    belongs_to :team, BarkparkCloud.Accounts.Team

    has_many :deployments, BarkparkCloud.Registry.Deployment

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def frameworks, do: @frameworks
  def kinds, do: @kinds
  def scale_modes, do: @scale_modes
  def serving_modes, do: @serving_modes
  def tls_modes, do: @tls_modes
  def domain_format, do: @domain_format

  @doc """
  The frameworks legal for a given `kind` (charter D2). An unknown/nil kind
  falls back to the full union so a bad kind fails on the `kind` inclusion check
  rather than silently emptying the framework allow-list.
  """
  def frameworks_for_kind("static"), do: @static_frameworks
  def frameworks_for_kind("container"), do: @container_frameworks
  def frameworks_for_kind("node"), do: @container_frameworks
  def frameworks_for_kind(_), do: @frameworks

  @doc """
  Changeset for creating / updating a Site. `name`, `slug`, `barkpark_id`, and
  `team_id` are required. `domains` are normalised to lowercase and validated
  against the public-suffix-ish DNS shape; an invalid domain in the list is a
  validation error on the whole changeset.
  """
  def changeset(site, attrs) do
    site
    |> cast(attrs, [
      :name,
      :slug,
      :kind,
      :framework,
      :template,
      :theme,
      :domains,
      :env_encrypted,
      :scale_mode,
      :port,
      :port_base,
      :current_deployment_id,
      :bootstrap_workspace,
      :bootstrap_project,
      :bootstrap_dataset,
      :doc_type,
      :read_token_encrypted,
      :github_repo,
      :github_branch,
      :github_webhook_secret_encrypted,
      :content_webhook_secret_encrypted,
      :previews_enabled,
      # site-spawner W9 (charter D87): settable at create so a site can be
      # spawned prebuilt-first (a CI runner never has to make a second call).
      :prebuilt_enabled,
      :barkpark_id,
      :team_id
    ])
    |> validate_required([:name, :slug, :kind, :barkpark_id, :team_id])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:slug, min: 1, max: 63)
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_inclusion(:kind, @kinds)
    |> validate_framework_for_kind()
    |> validate_template()
    |> validate_theme()
    |> validate_inclusion(:scale_mode, @scale_modes)
    |> validate_github_repo()
    |> validate_length(:github_branch, max: 255)
    |> normalize_domains()
    |> validate_domains()
    |> assoc_constraint(:barkpark)
    |> assoc_constraint(:team)
    |> unique_constraint([:team_id, :slug],
      name: :sites_team_slug_unique_idx,
      message: "already has a site with this slug"
    )
  end

  # Kind-gated framework legality (charter D2). A static site accepts only
  # {astro,hugo,static}; a container site only {nextjs,nuxt,sveltekit}. Runs off
  # the RESOLVED values (`get_field`, so the schema defaults count) — a static
  # site left on the default framework "nextjs" is correctly rejected rather than
  # silently allowed. Skipped when `kind` itself is invalid (that error already
  # fires) so the caller sees the real cause.
  defp validate_framework_for_kind(changeset) do
    kind = get_field(changeset, :kind)
    framework = get_field(changeset, :framework)

    cond do
      kind not in @kinds ->
        changeset

      framework in frameworks_for_kind(kind) ->
        changeset

      true ->
        add_error(
          changeset,
          :framework,
          "is not valid for a #{kind} site",
          validation: :inclusion,
          enum: frameworks_for_kind(kind)
        )
    end
  end

  # search-template W2 (D8): the template slug indexes a filesystem path on the
  # box (templates/<slug>), so it is a CLOSED set — mirror of the box engine's
  # DeployRequest.validate_template/1. nil = framework-derived default.
  # One slug per line: new templates insert at the head (scaffy
  # add-site-template); the validation message enumerates in this order.
  @known_site_templates [
    # new deployable site-template slugs land here (head of list)
    "astro-search-starter",
    "astro-starter",
    "next-starter",
    "search-starter"
  ]

  # The shipped palettes (design/themes/<name>.json) — mirror of the manifest
  # schema's theme enum and the template loader's knownThemes.
  @known_site_themes ~w(charple ember evergreen fjord)

  defp validate_template(changeset) do
    validate_inclusion(changeset, :template, @known_site_templates,
      message: "must be one of: #{Enum.join(@known_site_templates, ", ")}"
    )
  end

  defp validate_theme(changeset) do
    validate_inclusion(changeset, :theme, @known_site_themes,
      message: "must be one of: #{Enum.join(@known_site_themes, ", ")}"
    )
  end

  @doc """
  The operator-settings changeset (search-template W8): ONLY the fields safe to
  change between deploys. Same closed-set validations as create.

  site-spawner W9 (charter D87) adds `prebuilt_enabled` — WHERE this site's next
  build runs is exactly a between-deploys operator decision, and the only way to
  flip it without a re-spawn. Note the router's PATCH route keeps its OWN
  hard-coded `Map.take/2` allow-list: casting a field here and forgetting it
  there is a green-looking no-op (200, an unchanged row, and no error anywhere).
  """
  def settings_changeset(site, attrs) do
    site
    |> cast(attrs, [:theme, :doc_type, :prebuilt_enabled])
    |> validate_theme()
    |> validate_length(:doc_type, min: 1, max: 100)
  end

  defp validate_github_repo(changeset) do
    case get_change(changeset, :github_repo) do
      nil ->
        changeset

      "" ->
        changeset

      repo when is_binary(repo) ->
        if Regex.match?(@github_repo_format, repo) do
          changeset
        else
          add_error(changeset, :github_repo, "must be in 'owner/repo' form")
        end
    end
  end

  @doc """
  Narrow changeset for the on-box agent / control-plane runtime that allocates
  the runtime port and stamps the live deployment pointer. Cannot rename or
  re-team the site.
  """
  def runtime_changeset(site, attrs) do
    site
    |> cast(attrs, [:port, :current_deployment_id])
  end

  @doc """
  site-spawner W6 (charter D51): NARROW changeset for the Cloudflare-in-front
  edge binding. Casts ONLY the CF columns — it can never rename, re-team, or
  re-point the site's runtime (containment, mirroring `custom_host_changeset`).
  The two mode enums are inclusion-validated so a bad `serving_mode` /
  `tls_mode` is a validation error, never a silent bad row that the box render
  (mergeSite) or the domain-status rung would then misinterpret.

  `cf_domain` is normalized (lower-cased, trimmed, trailing-dot stripped) exactly
  like `domains`, and validated against the generic `@domain_format` — a user's
  own arbitrary hostname (blog.example.com), NOT zone-locked to the platform.
  """
  def cf_binding_changeset(site, attrs) do
    site
    |> cast(attrs, [
      :cf_domain,
      :cf_zone_id,
      :cf_record_id,
      :serving_mode,
      :tls_mode,
      :cf_cert_path,
      :cf_key_path
    ])
    |> update_change(:cf_domain, &normalize_domain/1)
    |> validate_inclusion(:serving_mode, @serving_modes)
    |> validate_inclusion(:tls_mode, @tls_modes)
    |> validate_cf_domain()
  end

  # A CF-bound domain, when present, must be a well-formed generic hostname (the
  # user's own domain — not zone-locked). A nil cf_domain (pure-standalone, or a
  # binding that only flips serving_mode) is left alone.
  defp validate_cf_domain(changeset) do
    case get_field(changeset, :cf_domain) do
      nil ->
        changeset

      d when is_binary(d) ->
        if String.length(d) <= 253 and Regex.match?(@domain_format, d) do
          changeset
        else
          add_error(changeset, :cf_domain, "is invalid: #{inspect(d)}")
        end
    end
  end

  defp normalize_domains(changeset) do
    case get_change(changeset, :domains) do
      nil ->
        changeset

      domains when is_list(domains) ->
        normed =
          domains
          |> Enum.map(&normalize_domain/1)
          |> Enum.uniq()

        put_change(changeset, :domains, normed)
    end
  end

  defp normalize_domain(d) when is_binary(d) do
    d |> String.downcase() |> String.trim() |> String.trim_trailing(".")
  end

  defp normalize_domain(other), do: other

  defp validate_domains(changeset) do
    validate_change(changeset, :domains, fn :domains, list ->
      bad =
        Enum.reject(list, fn d ->
          is_binary(d) and String.length(d) <= 253 and Regex.match?(@domain_format, d)
        end)

      case bad do
        [] -> []
        [b | _] -> [domains: "invalid domain: #{inspect(b)}"]
      end
    end)
  end
end
