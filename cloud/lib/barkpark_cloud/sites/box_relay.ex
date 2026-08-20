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
  @callback teardown(Barkpark.t(), map()) :: reply()

  # The verbs that only READ the box. Everything else is a WRITE and is fenced
  # below for a box that has already refused our stored admin credential.
  @reads [:poll_deploy]

  @spec start_deploy(Barkpark.t(), map()) :: reply()
  def start_deploy(bp, payload), do: dispatch(bp, :start_deploy, [bp, payload])

  @spec poll_deploy(Barkpark.t(), String.t(), String.t()) :: reply()
  def poll_deploy(bp, slug, build_id), do: dispatch(bp, :poll_deploy, [bp, slug, build_id])

  @spec rollback(Barkpark.t(), map()) :: reply()
  def rollback(bp, payload), do: dispatch(bp, :rollback, [bp, payload])

  @spec teardown(Barkpark.t(), map()) :: reply()
  def teardown(bp, payload), do: dispatch(bp, :teardown, [bp, payload])

  # THE SITE-WRITE FENCE (cloud-console-hardening D741). `Registry.relay_admin_post/3`
  # already refuses an INSTANCE write to a box whose `update_unavailable_reason` is
  # "identity_refused" — the box answered our stored admin credential with a 401,
  # so the same credential over the same address cannot do anything but 401 again.
  # The SITE writes ride `relay_admin/4` and bypassed that fence by construction:
  # every deploy, rollback and teardown for such a box spent a full request (and,
  # for a deploy, a whole build) to be told no again, and the plane then reported
  # it as an unreachable box — a 502 about the network for a refusal about identity.
  #
  # The fence lands HERE, at the dispatcher, and NOT one seam up in `Sites.Deploy`:
  # hoisting it would also refuse the READ (`poll_deploy`) and the read-token mint,
  # which are exactly what still tells a human the truth about a refused box. So the
  # three WRITES refuse and the READ stays open.
  defp dispatch(%Barkpark{update_unavailable_reason: "identity_refused"}, verb, _args)
       when verb not in @reads,
       do: {:error, :identity_refused}

  defp dispatch(_bp, verb, args), do: apply(impl(), verb, args)

  # The configured relay implementation. Defaults to the real HTTP admin relay; the
  # test env swaps in the in-memory fake through `:site_box_relay`. PRIVATE on
  # purpose: every outbound call must go through `dispatch/3` above, and a caller
  # holding the module could reach the box around the fence.
  @spec impl() :: module()
  defp impl,
    do: Application.get_env(:barkpark_cloud, :site_box_relay, BarkparkCloud.Sites.BoxRelay.HTTP)
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

  # The flip is a rename(2) — measured at 25ms on the box — so the wait settles on
  # the first or second poll. The budget sits far inside the CLI's 15s client
  # timeout: a rollback we cannot CONFIRM quickly is a rollback we must not claim
  # happened.
  @rollback_poll_ms 50
  @rollback_budget_ms 10_000
  # A teardown stops the slots + disarms Caddy + deletes the tree — a few seconds,
  # but a cold node slot stop can lag, so allow more headroom than a pointer flip.
  @teardown_budget_ms 30_000

  @impl true
  def rollback(bp, payload) when is_map(payload) do
    # mode: "rollback" → `site-deploy.sh --rollback` on the box. NEVER
    # Deployment.promotion_attrs (charter D5): a promote is a NEW build (seconds
    # to minutes); a static rollback is a symlink repoint (25ms measured).
    slug = payload[:slug] || payload["slug"]

    case Registry.relay_admin(bp, :post, @path, Map.put_new(payload, :mode, "rollback")) do
      {:ok, status, _body} when status in 200..299 ->
        # /v1/admin/site-deploy is ASYNCHRONOUS: it answers 202 `started` and runs
        # the engine behind a Port. Returning here would report a successful
        # rollback for a symlink that has NOT moved yet — and would bake a vacuous
        # "sub-second" into the wire, since the thing being timed would be the
        # accept, not the flip. This behaviour promises to answer only once the
        # flip has really happened (charter D5), so: wait for it.
        await_flip(bp, slug, @rollback_budget_ms)

      # 409 lock held, 4xx/5xx refusal, unreachable box — relay the box's own
      # verdict verbatim. Nothing is invented here.
      other ->
        other
    end
  end

  defp await_flip(_bp, _slug, left_ms) when left_ms <= 0 do
    {:ok, 504,
     %{
       "error" =>
         "the instance did not confirm the rollback in time — it may still be flipping; " <>
           "check `bp cloud site status`"
     }}
  end

  defp await_flip(bp, slug, left_ms) do
    # build_id is irrelevant to a rollback (there is exactly one run per slug and
    # the box's GET keys on slug alone) — the empty string keeps the behaviour's
    # 3-arity poll contract without inventing a build we do not have.
    case poll_deploy(bp, slug, "") do
      {:ok, status, body} when status in 200..299 ->
        if to_string(body["state"]) == "done" do
          settle_flip(body)
        else
          Process.sleep(@rollback_poll_ms)
          await_flip(bp, slug, left_ms - @rollback_poll_ms)
        end

      other ->
        other
    end
  end

  # The box's own verdict, translated into the reply the driver reads. exit_code is
  # the truth: 0 is a real flip; 21 (no previous release) / 22 / 23 / 24 are honest
  # refusals that must NOT read as success.
  defp settle_flip(body) do
    if body["exit_code"] == 0 do
      {:ok, 200, %{"status" => "rolled_back", "build_id" => target_build(body)}}
    else
      {:ok, 422,
       %{
         "error" => body["failure_reason"] || "the instance could not roll this site back"
       }}
    end
  end

  # A rollback emits NO BPSTAGE lines (it is a pointer flip, not a deploy) — the
  # engine prints `TARGET_BUILD=<build_id>` on stdout instead. That line is how the
  # control plane learns which build is now live.
  defp target_build(body) do
    (body["log"] || [])
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^TARGET_BUILD=(\S+)/, String.trim(to_string(line))) do
        [_, id] -> id
        _ -> nil
      end
    end)
  end

  @impl true
  def teardown(bp, payload) when is_map(payload) do
    # mode: "teardown" → `site-deploy[.-node].sh --teardown` on the box: stop the
    # slots, disarm the Caddy route, delete the tree. Like a rollback it runs
    # ASYNC behind the runner and emits no BPSTAGE, so we wait for the run to
    # finish (a `TORN_DOWN=` line finalizes it exit 0) before reporting success —
    # otherwise the CP would deregister the row while the box still serves it.
    slug = payload[:slug] || payload["slug"]

    case Registry.relay_admin(bp, :post, @path, Map.put_new(payload, :mode, "teardown")) do
      {:ok, status, _body} when status in 200..299 ->
        await_teardown(bp, slug, @teardown_budget_ms)

      other ->
        other
    end
  end

  defp await_teardown(_bp, _slug, left_ms) when left_ms <= 0 do
    {:ok, 504,
     %{
       "error" =>
         "the instance did not confirm the teardown in time — it may still be tearing down; " <>
           "check `bp cloud site status`"
     }}
  end

  defp await_teardown(bp, slug, left_ms) do
    case poll_deploy(bp, slug, "") do
      {:ok, status, body} when status in 200..299 ->
        if to_string(body["state"]) == "done" do
          settle_teardown(body)
        else
          Process.sleep(@rollback_poll_ms)
          await_teardown(bp, slug, left_ms - @rollback_poll_ms)
        end

      other ->
        other
    end
  end

  # exit_code 0 (the engine printed `TORN_DOWN=<slug>`) is a real teardown;
  # anything else is an honest failure that must NOT read as deleted.
  defp settle_teardown(body) do
    if body["exit_code"] == 0 do
      {:ok, 200, %{"status" => "torn_down"}}
    else
      {:ok, 422,
       %{"error" => body["failure_reason"] || "the instance could not tear this site down"}}
    end
  end
end
