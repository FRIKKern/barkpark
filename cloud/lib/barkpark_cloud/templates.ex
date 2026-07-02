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
  # handoff points at the monorepo. One place to change per template when that lands.
  @repo "https://github.com/FRIKKern/barkpark"
  @docs "https://github.com/FRIKKern/barkpark/blob/main/templates/MANIFEST.md"

  @catalog [
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
      env_keys: @env_common ++ ~w(BARKPARK_WEBHOOK_SECRET),
      repo: @repo,
      docs: @docs
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
      env_keys: @env_common ++ ~w(NEXT_PUBLIC_FINDER_LANDING BARKPARK_WEBHOOK_SECRET),
      repo: @repo,
      docs: @docs
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
      env_keys: @env_common ++ ~w(BARKPARK_WEBHOOK_SECRET),
      repo: @repo,
      docs: @docs
    }
  ]

  @doc "The full public catalog — display metadata for every known template, sorted by slug."
  @spec catalog() :: [map()]
  def catalog, do: @catalog

  @doc "The catalog slugs (sorted) — the lock-test anchor against `Registry.known_templates/0`."
  @spec slugs() :: [String.t()]
  def slugs, do: Enum.map(@catalog, & &1.slug)

  @doc "One template's display metadata by slug, or `nil` when unknown."
  @spec get(String.t()) :: map() | nil
  def get(slug) when is_binary(slug), do: Enum.find(@catalog, &(&1.slug == slug))
  def get(_), do: nil
end
