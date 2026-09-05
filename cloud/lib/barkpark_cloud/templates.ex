defmodule BarkparkCloud.Templates do
  @moduledoc """
  The PUBLIC template catalog the `/new?template=…` launch flow (dwb-6) renders:
  title, one-line description, "what you get" bullets, the env KEYS the Vercel
  deploy handoff prefills, and the deployable repo + docs links.

  ## Why a mirror (and not the manifest itself)

  The authoritative template manifests (`templates/<slug>/barkpark.template.json`)
  live at the repo ROOT and are embedded into the **Go** provisioner/worker — the
  control plane (this Elixir app) is built from `cloud/` alone (see `cloud/Dockerfile`
  — it `COPY`s only `lib/ priv/ config/`), so the manifest JSON is NOT reachable at
  compile OR run time here. Rather than vendor drift-prone copies into `cloud/priv`,
  we mirror only the DISPLAY fields the marketing surface needs, and pin the mirror
  with a lock test:

    * `slugs/0` MUST equal `BarkparkCloud.Registry.known_templates/0` — which is
      itself lock-tested against the Go worker's embedded allowlist
      (`bootstrap_template_test.exs`). So a template added/removed on the Go side
      fails the cloud lock test until this mirror is updated: no SILENT drift on
      which templates exist.
    * The env KEYS mirror each manifest's `env[].key`. They are prefill HINTS on
      the Vercel clone URL (values are pasted by the user from the copy block), so
      a stale key is cosmetic, never a correctness break; the Go
      `internal/template.TestRealManifests` drift gate owns the manifest truth.

  Keep this list sorted by slug to match `known_templates/0`.
  """

  @env_common ~w(BARKPARK_API_URL BARKPARK_TOKEN BARKPARK_WORKSPACE BARKPARK_PROJECT BARKPARK_DATASET)

  # The deployable starters live in the monorepo (js/packages/create-barkpark-app/
  # templates/<slug>); until each ships as a standalone repo, the Vercel clone
  # handoff points at the monorepo.
  #
  # This is the DEFAULT, not the value. It used to be a compile-time module
  # attribute baked into every @catalog entry, which a release BUILD freezes —
  # so anyone running this control plane against a FORK still handed their users
  # a clone URL pointing at OUR repo, with no way to serve their own starters
  # short of editing source and rebuilding (gh-9531 residual,
  # task-eeabfd9bf3ed8371). `repo/0` reads
  # `config :barkpark_cloud, :templates_repo_url` (TEMPLATES_REPO_URL) at CALL
  # time and falls back to this literal.
  @default_repo "https://github.com/FRIKKern/barkpark"

  # The manifest index INSIDE that repo. Derived from `repo/0` rather than
  # configured separately: a fork that serves its own templates serves its own
  # MANIFEST.md, and two independent knobs is how the two halves start pointing
  # at different repos.
  @docs_path "/blob/main/templates/MANIFEST.md"

  @catalog [
    %{
      slug: "astro-search-starter",
      title: "Search Starter (Astro)",
      description:
        "The flagship search site, statically generated: every document pre-rendered by the canonical PortableDoc at build, the corpus graph baked to JSON, live search browser-direct — pure static files, symlink-swap deploys.",
      framework: "astro",
      demo_content: true,
      what_you_get: [
        "Every published document pre-rendered as static HTML by the canonical @barkpark/react PortableDoc",
        "The zero-dependency Canvas2D corpus graph, baked to graph.json at build — instant landing, no runtime token",
        "Per-keystroke live search straight from the browser (Phoenix WebSocket, HTTP fallback)",
        "Symlink-swap deploys: immutable releases, health-gated, instant rollback"
      ],
      env_keys: @env_common ++ ~w(BARKPARK_DOC_TYPE)
    },
    %{
      slug: "blog-starter",
      title: "Blog Starter",
      description:
        "A minimal blog: a `post` document type (title, excerpt, body, date) a Next.js blog renders as a list + detail pages.",
      framework: "nextjs",
      demo_content: true,
      what_you_get: [
        "A `post` content type — title, excerpt, body, date",
        "A Next.js blog: index list + per-post detail pages",
        "Demo posts seeded so it's live from the first deploy"
      ],
      env_keys: @env_common ++ ~w(BARKPARK_WEBHOOK_SECRET)
    },
    %{
      slug: "place-directory",
      title: "Place Directory",
      description:
        "A map-backed listing site: a `place` document type plotted as pins on a Next.js map (powers hundesteder.no).",
      framework: "nextjs",
      demo_content: true,
      what_you_get: [
        "A `place` content type plotted as map pins",
        "A Next.js map-backed listing site",
        "Demo places seeded so the map is populated on first deploy"
      ],
      env_keys: @env_common ++ ~w(NEXT_PUBLIC_FINDER_LANDING BARKPARK_WEBHOOK_SECRET)
    },
    %{
      slug: "search-starter",
      title: "Search Starter",
      description:
        "The flagship search site: instant live search with misspellings widened server-side by Postgres trigram, an interactive corpus graph, and canonical PortableDoc document pages — over any Barkpark dataset.",
      framework: "nextjs",
      demo_content: true,
      what_you_get: [
        "Instant per-keystroke live search (Phoenix WebSocket, HTTP fallback)",
        "A zero-dependency Canvas2D corpus graph — documents lit by relevance",
        "An `entry` content type seeded reference-rich, so the graph is alive from minute one",
        "Document pages rendered by the canonical @barkpark/react PortableDoc"
      ],
      env_keys: @env_common ++ ~w(BARKPARK_DOC_TYPE)
    },
    %{
      slug: "website-starter",
      title: "Website Starter",
      description:
        "A minimal marketing website: a `page` document type (hero + body) a Next.js site renders. The bare scaffold to start a brand-new site from.",
      framework: "nextjs",
      demo_content: true,
      what_you_get: [
        "A `page` content type — hero + body",
        "A minimal Next.js marketing site",
        "Demo pages seeded so it renders on first deploy"
      ],
      env_keys: @env_common ++ ~w(BARKPARK_WEBHOOK_SECRET)
    }
  ]

  @doc """
  The deployable repo the launch flow's clone handoff points at.

  Read at CALL time from `config :barkpark_cloud, :templates_repo_url`
  (`TEMPLATES_REPO_URL` in `config/runtime.exs`), defaulting to the upstream
  monorepo — an unconfigured deployment is byte-identical to before.

  FAILS CLOSED: a configured-but-malformed URL raises rather than falling back
  to ours. A silent fallback would hand a fork's users OUR starters while the
  operator believed their own were being served.
  `BarkparkCloud.Application.start/2` resolves it once at boot, so a typo
  refuses the node instead of surfacing as a stranger's failed deploy.
  """
  @spec repo() :: String.t()
  def repo do
    case Application.get_env(:barkpark_cloud, :templates_repo_url) do
      nil -> @default_repo
      configured -> validate_repo!(configured)
    end
  end

  @doc "The template MANIFEST.md URL inside `repo/0`."
  @spec docs() :: String.t()
  def docs, do: repo() <> @docs_path

  @doc "The compile-time fallback repo URL — what \"unconfigured\" means, for tests."
  @spec default_repo() :: String.t()
  def default_repo, do: @default_repo

  # The value is rendered into a clone URL a stranger clicks, so the accepted
  # shape is narrow: an http(s) origin with a host and no whitespace, control
  # characters, query, fragment or trailing slash (a trailing slash would mint
  # `…//blob/main/…` for `docs/0`).
  @repo_url_format ~r{^https?://[a-zA-Z0-9._~-]+(:[0-9]+)?(/[a-zA-Z0-9._~%!$&'()*+,;=:@-]+)*$}

  defp validate_repo!(value) when is_binary(value) do
    if String.length(value) <= 2000 and Regex.match?(@repo_url_format, value) do
      value
    else
      bad_repo!(value)
    end
  end

  defp validate_repo!(other), do: bad_repo!(other)

  defp bad_repo!(value) do
    raise ArgumentError, """
    invalid template repo URL: #{inspect(value)}.

    Expected an http(s) repository URL with no trailing slash, query or
    fragment, e.g. "https://github.com/acme/barkpark".

    Set TEMPLATES_REPO_URL to the fork that carries your starters, or leave it
    unset to keep the #{@default_repo} default.
    """
  end

  @doc """
  The full public catalog — display metadata for every known template, sorted by
  slug. `repo` and `docs` are injected at READ time from `repo/0`, so a fork's
  clone handoff points at the fork.
  """
  @spec catalog() :: [map()]
  def catalog do
    repo = repo()
    docs = repo <> @docs_path

    Enum.map(@catalog, &Map.merge(&1, %{repo: repo, docs: docs}))
  end

  @doc "The catalog slugs (sorted) — the lock-test anchor against `Registry.known_templates/0`."
  @spec slugs() :: [String.t()]
  def slugs, do: Enum.map(@catalog, & &1.slug)

  @doc "One template's display metadata by slug, or `nil` when unknown."
  @spec get(String.t()) :: map() | nil
  def get(slug) when is_binary(slug), do: Enum.find(catalog(), &(&1.slug == slug))
  def get(_), do: nil
end
