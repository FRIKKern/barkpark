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
    3. a freshly-minted, workspace-scoped, NON-admin `ApiToken`
       (`["read", "write"]` → a `member` membership, never `admin`) via
       `Auth.create_token/5` — the visitor's credential for that workspace only.

  Returns `201` with `{workspace_slug, token, expires_at, tier}`. The raw token
  is returned ONCE here (only its hash is stored) — the visitor's single write
  credential for the disposable workspace.

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

  alias Barkpark.{Auth, Tenancy}
  alias Barkpark.Tenancy.Quota

  action_fallback BarkparkWeb.FallbackController

  # Disposable-workspace lifetime and abuse ceiling. 48h reconciles
  # `/papers/one-shot-onboarding`; 100 documents is the free-tier write cap.
  @ttl_seconds 48 * 60 * 60
  @playground_quota 100
  @playground_tier "playground"
  @token_prefix "bpplay_"
  # The "production" dataset `create_workspace_with_owner/2` seeds — the scope
  # the minted visitor token is bound to.
  @production_dataset "production"

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
         {:ok, workspace} <- Quota.set_quota(workspace, @playground_quota),
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
        token: raw_token,
        tier: workspace.tier,
        expires_at: workspace.expires_at
      })
    end
  end

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
