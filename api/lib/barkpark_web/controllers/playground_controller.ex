defmodule BarkparkWeb.PlaygroundController do
  @moduledoc """
  The Cloud playground front door (perfect-plan-build W2c, charter D25/D27).

  `POST /api/playground` provisions a self-cleaning, disposable workspace so a
  visitor gets a REAL, immediately-writable Barkpark in one call:

    1. a real ephemeral `%Workspace{}` with `tier: "playground"` and
       `expires_at: now + 48h` (the TTL the W3 reaper sweeps), plus its Default
       Project + "production" Dataset — via `Tenancy.create_workspace_with_owner/2`;
    2. a document-count quota of 100 via `Tenancy.Quota.set_quota/2` — the abuse
       ceiling that bounds a free disposable workspace;
    3. a curated showcase paper seeded into the workspace so the front door is
       NOT empty on first read (charter D47, reconciling
       `/papers/one-shot-onboarding`'s "seeded with the showcase paper");
    4. a freshly-minted, workspace-scoped, NON-admin `ApiToken`
       (`["read", "write"]` → a `member` membership, never `admin`) via
       `Auth.create_token/5` — the visitor's credential for that workspace only.

  Returns `201` with `{workspace_slug, project_slug, dataset, token, tier,
  expires_at}`. The raw token is returned ONCE here (only its hash is stored) —
  the visitor's single write credential for the disposable workspace. The
  `project_slug` + `dataset` are the write coordinates the caller needs to hit
  the scoped mutate route `/w/:workspace_slug/p/:project_slug/v1/data/mutate/:dataset`
  — returned in-band (charter D34/D46) so the caller learns the write URL rather
  than hardcoding `default`/`production`.

  ## Identity (charter D27, reconciling `/papers/one-shot-onboarding`)

  A playground visitor is NOT anonymous/tokenless — there is no anon-write path
  (the router requires a token twice), and reusing `AssignDefaultScope`'s
  singleton Default Workspace would co-mingle every visitor. So each visitor
  gets a per-visitor real workspace + a per-visitor minted scoped token, with a
  48h TTL — the shape `/papers/one-shot-onboarding` specifies.

  ## Gate (charter D22)

  Mounted as a BARE `[:api, :require_admin]` router route — NOT a capabilities
  manifest command — so it trips ZERO OpenAPI drift (`docs/openapi.json` is
  manifest-derived; a bare route is invisible to the drift gate, mirroring the
  W1 workspace DELETE). The public, rate-limited, anon-facing exposure of this
  endpoint is W3 backlog (`bpb-playground-rate-limit`); this wave ships the
  provision path behind the admin gate.
  """
  use BarkparkWeb, :controller

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Quota

  action_fallback BarkparkWeb.FallbackController

  # Disposable-workspace lifetime and abuse ceiling. 48h reconciles
  # `/papers/one-shot-onboarding`; 100 documents is the free-tier write cap.
  @ttl_seconds 48 * 60 * 60
  @playground_quota 100
  @playground_tier "playground"
  @token_prefix "bpplay_"
  # The "production" dataset `create_workspace_with_owner/2` seeds — the scope
  # the minted visitor token is bound to, and the dataset the showcase paper is
  # seeded into.
  @production_dataset "production"

  @doc """
  The disposable-playground lifetime in seconds — the TTL `provision/2` stamps
  into `expires_at` and the one the reaper sweeps against.

  Public because it is now read by a SECOND caller:
  `BarkparkWeb.WorkspaceReinstateController` re-arms an ALREADY-ELAPSED
  playground TTL by exactly this window, and a second literal `48 * 60 * 60`
  beside this one would let the mint and the rescue drift apart silently. One
  constant, two readers.
  """
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  # The curated showcase paper seeded into a fresh playground so the front door
  # is not empty (charter D47). A modest multi-block PortableDoc — NOT the full
  # 101-block showcase — carrying its own top-level description so it is a real,
  # self-describing first read.
  @showcase_blocks [
    %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "Welcome to your playground"},
    %{
      "id" => "p1",
      "type" => "paragraph",
      "content" => [
        %{
          "type" => "text",
          "value" =>
            "This is a disposable Barkpark workspace — a real, writable content " <>
              "backend that expires in 48 hours. Everything here is yours to break: " <>
              "create documents, edit this paper, wire up a surface."
        }
      ]
    },
    %{
      "id" => "p2",
      "type" => "paragraph",
      "content" => [
        %{
          "type" => "text",
          "value" =>
            "Your write credential is the token returned when this workspace was " <>
              "provisioned. Point it at the mutate route below and start writing."
        }
      ]
    },
    %{
      "id" => "code1",
      "type" => "code",
      "value" =>
        "# create a document in this workspace\n" <>
          "POST /w/<workspace>/p/<project>/v1/data/mutate/production\n" <>
          "  Authorization: Bearer <your playground token>\n" <>
          "  {\"mutations\":[{\"create\":{\"_type\":\"post\",\"title\":\"Hello\"}}]}"
    }
  ]

  @doc """
  POST /api/playground — provision a disposable playground workspace + a
  workspace-scoped visitor token in one call.

  On success → 201 with the workspace slug, the raw minted token, the tier, and
  the `expires_at` TTL. A changeset error (e.g. an impossibly-colliding slug)
  flows to the `FallbackController` as a 422.
  """
  def provision(conn, _params) do
    admin_token = conn.assigns[:api_token]
    expires_at = DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)

    attrs = %{
      name: "Playground",
      slug: playground_slug(),
      tier: @playground_tier,
      expires_at: expires_at
    }

    with {:ok, workspace} <- Tenancy.create_workspace_with_owner(attrs, admin_token),
         # `create_workspace_with_owner/2` returns the Default Project inline
         # (`workspace.projects == [project]`), so the write coordinates are in
         # hand without a re-derive. Captured BEFORE `set_quota/2`, whose
         # `Repo.update` need not preserve the preloaded association.
         project = default_project(workspace),
         {:ok, workspace} <- Quota.set_quota(workspace, @playground_quota),
         {:ok, _paper} <- seed_showcase_paper(workspace, project),
         raw_token = mint_raw_token(),
         {:ok, _token} <-
           Auth.create_token(
             raw_token,
             "playground:#{workspace.slug}",
             @production_dataset,
             ["read", "write"],
             workspace.id
           ) do
      conn
      |> put_status(:created)
      |> json(%{
        workspace_slug: workspace.slug,
        project_slug: project.slug,
        dataset: @production_dataset,
        token: raw_token,
        tier: workspace.tier,
        expires_at: workspace.expires_at
      })
    end
  end

  # The Default Project `create_workspace_with_owner/2` seeded inline. The write
  # coordinate (`project.slug == "default"`) the caller needs for the scoped
  # mutate route, and the scope the showcase paper is seeded under.
  defp default_project(%{projects: [project | _]}), do: project

  # Seed the curated showcase paper into the fresh playground so the front door
  # is not empty (charter D47). Skip-if-present mirrors
  # `Seeds.Clean.seed_welcome_paper/1` — a fresh workspace can't already hold it,
  # but the probe keeps a re-provision against the same workspace idempotent.
  # BOTH `workspace_id` AND `project_id` are passed: `paper_scope_opts/1`
  # (content/papers/block_ops.ex) silently drops `project_id` when blank.
  defp seed_showcase_paper(workspace, project) do
    slug = showcase_slug(workspace)

    case Content.get_paper(slug, @production_dataset, workspace_id: workspace.id) do
      nil ->
        Content.upsert_paper(
          %{
            "slug" => slug,
            "dataset" => @production_dataset,
            "workspace_id" => workspace.id,
            "project_id" => project.id,
            "blocks" => @showcase_blocks,
            "style" => "article"
          },
          # bypass_wall (charter D26/D47 audit): a FRESH playground's E3 tag
          # registry is empty and the showcase carries no top-level
          # description/tags, so the LabelSpine wall (`check_description`) 422s a
          # naive upsert. Curated host content seeded into a brand-new tenant —
          # explicit, audited exemption (mirrors Seeds.Clean.seed_welcome_paper/1).
          bypass_wall: true
        )

      existing ->
        {:ok, existing}
    end
  end

  # A per-workspace-DISTINCT showcase slug derived from the (globally-unique)
  # workspace slug — NOT the literal `portabledoc-showcase` doc_id. The authoring
  # exemption ledger keys on `(doc_id, dataset)` with NO workspace_id (charter
  # D47), so reusing one doc_id across playgrounds would inherit an unrelated
  # tenant's grandfather exemption. A `pg-…`-derived slug is globally unique.
  defp showcase_slug(%{slug: ws_slug}), do: "showcase-" <> ws_slug

  # A collision-resistant, routing-safe playground slug (lowercase alnum +
  # hyphen; never a reserved slug). 12 random hex chars keep the odds of a
  # unique-constraint clash negligible; a clash surfaces as a clean 422.
  defp playground_slug do
    "pg-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end

  # A high-entropy raw token, prefixed so it is recognisable in logs/support as
  # a playground credential. Only its hash is persisted (see `Auth.create_token/5`).
  defp mint_raw_token do
    @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end
end
