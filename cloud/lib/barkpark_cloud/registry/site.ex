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

  # ssw8-bl-accepted-frameworks-no-implementation: the SHIPPED half of the
  # enums above. `@frameworks`/`@scale_modes` are the kind-legality VOCABULARY
  # (charter D2) and the HISTORY — rows written before this door exist, and must
  # keep loading, serializing and listing. These two lists are the narrower,
  # harder truth: what the spawner can actually BUILD and RUN today. Only the
  # create/update DOOR consults them.
  #
  # @shipped_starters is keyed to the starter tree the deploy relay provisions
  # (`templates/<slug>`) and is the single source `Sites.Deploy.site_template/1`
  # reads, so the two can never drift; `site_shipped_frameworks_test.exs` reads
  # `templates/` off disk and asserts every slug here exists and that no
  # UNSHIPPED framework has grown a starter tree behind this list's back.
  @shipped_starters %{"astro" => "astro-starter", "nextjs" => "next-starter"}

  # Frameworks that ship with NO starter tree because they need no build step:
  # "static" is a folder of files the box serves as-is.
  @starterless_frameworks ~w(static)

  @shipped_frameworks Map.keys(@shipped_starters) ++ @starterless_frameworks

  # Only `always_on` is implemented. `zero` names an idle-stop agent and a
  # wakeup handler that do not exist: `grep -rn scale_mode cloud/lib` finds the
  # value cast, stored and echoed on the wire — and read by NOTHING.
  @shipped_scale_modes ~w(always_on)

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

  # ssw8-persist-binding-verdict (site-spawner W8, charter D73): the PERSISTED
  # verdict of the create-time content-binding read. `content_bound` on the wire
  # is DERIVED from this — it used to be `not is_nil(read_token_encrypted)`, i.e.
  # "a token was minted", which every content-bound site has.
  #
  #   * "bound"          — the site read its OWN content with its OWN token.
  #   * "unverified"     — the read could not be performed, or its body could not
  #                        be interpreted. NOT a verdict on the user's content.
  #   * "not_applicable" — a container site: there is no binding to check.
  #   * "never_checked"  — nobody ever looked. THE DEFAULT, and its own value
  #                        rather than a nullable `bound`: a NULL that a reader
  #                        rounds up to "probably fine" is the un-backed field
  #                        this column exists to retire.
  @binding_verdicts ~w(bound unverified not_applicable never_checked)

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

    # ssw8-persist-binding-verdict (charter D73): what the control plane OBSERVED
    # when it read this site's binding at create, and when. Written by
    # `POST /v1/sites` from `verify_content_binding/2`; `never_checked` until
    # something actually looks.
    field :content_binding_verdict, :string, default: "never_checked"
    field :content_binding_checked_at, :utc_datetime_usec

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

  @doc """
  The framework → shipped-starter-slug map (`templates/<slug>`). The deploy
  relay reads this to pick the tree it provisions; a framework absent from it
  either needs no starter (`@starterless_frameworks`) or is not shipped at all.
  """
  def shipped_starters, do: @shipped_starters

  @doc """
  The frameworks the spawner can actually build today, across all kinds — the
  subset of `frameworks/0` the create door accepts. See `shipped_frameworks_for_kind/1`
  for the per-kind menu a refusal names.
  """
  def shipped_frameworks, do: @shipped_frameworks

  @doc """
  The scale modes the runtime can actually honour today. `scale_modes/0` stays
  the stored vocabulary (existing rows may carry `zero`); this is what a create
  accepts.
  """
  def shipped_scale_modes, do: @shipped_scale_modes

  @doc """
  The frameworks a NEW site of this `kind` can be created with: kind-legal
  (charter D2) AND shipped. This is the list a 422 names, so it is derived from
  `frameworks_for_kind/1` rather than written out a second time — adding a
  framework to a kind cannot silently skip the refusal copy.
  """
  def shipped_frameworks_for_kind(kind) do
    kind |> frameworks_for_kind() |> Enum.filter(&(&1 in @shipped_frameworks))
  end

  def serving_modes, do: @serving_modes
  def tls_modes, do: @tls_modes
  def binding_verdicts, do: @binding_verdicts
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
      # ssw8-persist-binding-verdict: written by the create route from the
      # binding read it already performs.
      :content_binding_verdict,
      :content_binding_checked_at,
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
    |> validate_framework_is_shipped()
    |> validate_template()
    |> validate_theme()
    |> validate_inclusion(:scale_mode, @scale_modes)
    |> validate_scale_mode_is_shipped()
    # A verdict outside the enum is a validation error, never a silent bad row:
    # `content_bound` is DERIVED from this string, so an unknown value would be
    # a wire answer nothing downstream could read.
    |> validate_inclusion(:content_binding_verdict, @binding_verdicts)
    |> validate_required([:content_binding_verdict])
    |> validate_github_repo()
    |> validate_length(:github_branch, max: 255)
    |> normalize_domains()
    |> validate_domains()
    |> assoc_constraint(:barkpark)
    |> assoc_constraint(:team)
    # cch-w37-bl — see `TeamInvitation.changeset/2`. Opening the list with the
    # `belongs_to` key made POST /v1/sites answer "team id already has a site
    # with this slug" for a duplicate name; `:slug` is the field the creator
    # typed (or the one `slugify/1` derived from the name they typed).
    |> unique_constraint([:slug, :team_id],
      name: :sites_team_slug_unique_idx,
      message: "is already taken by another site on this team"
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

  # ssw8-bl-accepted-frameworks-no-implementation: the SHIPPED gate, and the
  # reason it reads `get_change` rather than `get_field`.
  #
  # A site row carrying `hugo` (or `nuxt`/`sveltekit`) may ALREADY EXIST — the
  # enum accepted it for months. `Site.changeset/2` is not only the create path:
  # setting env, attaching a domain and `set_site_github/4` all run it on a
  # LOADED row. Keying on `get_field` would resolve the stored `hugo` and refuse
  # every one of those, retroactively bricking rows this task is not about.
  # `get_change` fires only when the caller is NAMING the value — i.e. at the
  # door — which is exactly the ruling: refuse the create, never the row.
  #
  # Skipped when the kind-gate already rejected the pair, so the caller sees the
  # real cause (`is not valid for a container site`) instead of two errors.
  defp validate_framework_is_shipped(changeset) do
    kind = get_field(changeset, :kind)

    case get_change(changeset, :framework) do
      nil ->
        changeset

      framework ->
        cond do
          kind not in @kinds -> changeset
          framework not in frameworks_for_kind(kind) -> changeset
          framework in @shipped_frameworks -> changeset
          true -> add_unshipped_framework_error(changeset, kind)
        end
    end
  end

  defp add_unshipped_framework_error(changeset, kind) do
    shipped = shipped_frameworks_for_kind(kind)

    add_error(
      changeset,
      :framework,
      "has no shipped builder yet — a #{kind} site can be created with: " <>
        Enum.join(shipped, ", "),
      validation: :inclusion,
      enum: shipped
    )
  end

  # Same shape, same reason (see above): only a caller NAMING `zero` is refused;
  # a stored `zero` row still saves its env and its domains. Skipped when the
  # value is outside the stored vocabulary entirely — `validate_inclusion/3` has
  # already said so.
  defp validate_scale_mode_is_shipped(changeset) do
    case get_change(changeset, :scale_mode) do
      nil ->
        changeset

      mode ->
        cond do
          mode not in @scale_modes ->
            changeset

          mode in @shipped_scale_modes ->
            changeset

          true ->
            add_error(
              changeset,
              :scale_mode,
              "has no runtime yet — supported: " <> Enum.join(@shipped_scale_modes, ", "),
              validation: :inclusion,
              enum: @shipped_scale_modes
            )
        end
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
  task-b3e3ec0f433b217d: NARROW changeset for a public-read credential ROTATION —
  `Registry.rotate_site_read_token/1` and nothing else.

  Casts ONE column, and deliberately not through `changeset/2`: the rotate runs
  against a site row loaded some time earlier, so a wide cast would write back
  whatever that stale struct happened to hold for `domains`, `env_encrypted` or
  `current_deployment_id`. A credential swap must move the credential and
  nothing else.

  `read_token_encrypted` is required here: an unset (or explicitly `nil`) value
  would blank the site's credential — the "site goes dark" outcome the rotate
  exists to make impossible.
  """
  def read_token_changeset(site, attrs) do
    site
    |> cast(attrs, [:read_token_encrypted])
    |> validate_required([:read_token_encrypted])
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
