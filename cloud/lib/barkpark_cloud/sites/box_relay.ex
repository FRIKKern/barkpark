defmodule BarkparkCloud.Sites.BoxRelay do
  @moduledoc """
  site-spawner D22 — the seam between the control plane and the BOX that actually
  runs a static site deploy.

  A spawned site is built and served ON the Barkpark instance it is bound to (the
  box stays the origin — charter D4/D7): `deploy/site-deploy.sh` walks PLAN →
  BUILD → STAGE → HEALTH → SWITCH → RETIRE there, and only the box can read the
  dataset, run npm, own the release dirs, and flip the `current` symlink. The
  control plane's job is to DRIVE that script over the instance-admin relay
  (`POST/GET /v1/admin/site-deploy`, built by the sibling instance-side slice) and
  narrate what it sees back onto the Deployment row.

  Every outbound call to a box goes through this behaviour so the tests are €0 and
  hermetic — the house pattern (Vercel / GitHub / Azure / Hetzner all do exactly
  this). `impl/0` reads `:site_box_relay` from config; prod gets
  `BarkparkCloud.Sites.BoxRelay.HTTP` (the real admin relay), test gets
  `BarkparkCloud.Sites.FakeBoxRelay` (an in-memory box that can be programmed to
  walk any stage stream, including a HEALTH failure).

  ## The wire contract

  `start_deploy/2` POSTs the deploy request; the box answers 202 and runs the
  script asynchronously. `poll_deploy/3` reads the run's current state.
  `rollback/2` performs the sub-second symlink repoint and answers only when the
  flip has actually happened (charter D5 — a rollback that answers before the flip
  would bake a vacuous "sub-second" into the wire).

  Each returns the box's verdict INTACT — `{:ok, http_status, decoded_body}` — so
  the caller can distinguish "the box said no" (a 409/422 with a reason) from "the
  box could not be reached" (`{:error, reason}`). Nothing is invented on the
  control-plane side; an unreachable box is reported as an unreachable box.
  """

  alias BarkparkCloud.Registry.Barkpark

  @typedoc "The box's verdict: its HTTP status + decoded JSON body, intact."
  @type reply ::
          {:ok, non_neg_integer(), map()}
          | {:error, :not_live | :no_admin_token | :decrypt_failed | :instance_error | term()}

  @doc "Start a deploy run on the box (POST /v1/admin/site-deploy). 202 = started."
  @callback start_deploy(Barkpark.t(), map()) :: reply()

  @doc "Read the current state of a deploy run (GET /v1/admin/site-deploy)."
  @callback poll_deploy(Barkpark.t(), String.t(), String.t()) :: reply()

  @doc """
  Roll the site back to its previous release — `site-deploy.sh --rollback`, an
  atomic symlink repoint. BLOCKS until the flip has really happened; a box that
  cannot roll back (no previous release) answers non-2xx and the router relays
  that honestly.
  """
  @callback rollback(Barkpark.t(), map()) :: reply()

  @doc """
  The configured relay implementation. Defaults to the real HTTP admin relay; the
  test env swaps in the in-memory fake through `:site_box_relay`.
  """
  @spec impl() :: module()
  def impl,
    do: Application.get_env(:barkpark_cloud, :site_box_relay, BarkparkCloud.Sites.BoxRelay.HTTP)

  @spec start_deploy(Barkpark.t(), map()) :: reply()
  def start_deploy(bp, payload), do: impl().start_deploy(bp, payload)

  @spec poll_deploy(Barkpark.t(), String.t(), String.t()) :: reply()
  def poll_deploy(bp, slug, build_id), do: impl().poll_deploy(bp, slug, build_id)

  @spec rollback(Barkpark.t(), map()) :: reply()
  def rollback(bp, payload), do: impl().rollback(bp, payload)
end

defmodule BarkparkCloud.Sites.BoxRelay.HTTP do
  @moduledoc """
  The real `BoxRelay` — the instance-admin relay (`Registry.relay_admin/4`):
  reveal the box's stored admin token, call `/v1/admin/site-deploy` on it, hand
  back its verdict verbatim.

  This is the same transport seam the self-update / rollback triggers already ride
  (`:studio_link_http_client`), with ONE difference that is the whole reason
  `relay_admin/4` exists: those triggers hard-code `body: "{}"`, and a site deploy
  is all argv — slug, build id, content rev, and the scrubbed `BARKPARK_*` build
  env (including the site's freshly-revealed public-read token). A body-less relay
  cannot start a deploy at all.
  """

  @behaviour BarkparkCloud.Sites.BoxRelay

  alias BarkparkCloud.Registry

  @path "/v1/admin/site-deploy"

  @impl true
  def start_deploy(bp, payload) when is_map(payload) do
    # `mode` is the DRIVER's word, not the transport's: it decides deploy vs
    # rollback, and a test must be able to prove which one went over the wire.
    Registry.relay_admin(bp, :post, @path, Map.put_new(payload, :mode, "deploy"))
  end

  @impl true
  def poll_deploy(bp, slug, build_id) do
    query = URI.encode_query(%{"slug" => slug, "build_id" => build_id})
    Registry.relay_admin(bp, :get, @path <> "?" <> query, nil)
  end

  @impl true
  def rollback(bp, payload) when is_map(payload) do
    # mode: "rollback" → `site-deploy.sh --rollback` on the box. NEVER
    # Deployment.promotion_attrs (charter D5): a promote is a NEW build (seconds
    # to minutes); a static rollback is a symlink repoint (25ms measured).
    Registry.relay_admin(bp, :post, @path, Map.put_new(payload, :mode, "rollback"))
  end
end
