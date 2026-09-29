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

  @doc """
  Read the DURABLE per-build record for a finished deploy — the black box
  recorder's terminal record, keyed on `{slug, build_id}`
  (`dr-bl-recorder-http-read-path`).

  This is NOT `poll_deploy/3` with a different name. `poll_deploy/3` asks about
  the run the box is holding IN MEMORY, and its 404 means KEEP WAITING (charter
  D34); once the slug goes idle that door can say nothing at all about a build
  that finished last week. This one asks the same route for `record=1`, which the
  box answers from `<slug>-<tag>.terminal.json` on disk — including for a log its
  retention has already evicted, because an eviction leaves a tombstone behind.

  A READ, so it stays open for a box whose credential was refused: telling a human
  why a build failed is exactly what must survive an unreachable-for-writes box.
  """
  @callback build_record(Barkpark.t(), String.t(), String.t()) :: reply()

  @doc """
  Read the recorded build log's BYTES for a finished deploy — a BOUNDED TAIL, or
  the box's refusal (`dr-bl-recorder-http-read-path` c1).

  A strictly larger surface than `build_record/3`, so it is a separate verb with a
  separate opt-in on the wire (`record=1&bytes=1`). The box refuses with 422
  `build_log_unscrubbed` for a record whose `log_scrub` is nil — bytes that were
  never folded through the secret scrubber — and that refusal is relayed, never
  reinterpreted: this end invents nothing about bytes it did not receive.

  A READ, for the same reason `build_record/3` is: a box whose credential was
  refused is exactly the box whose last failed build a human needs to read.
  """
  @callback build_log_bytes(Barkpark.t(), String.t(), String.t()) :: reply()

  # The verbs that only READ the box. Everything else is a WRITE and is fenced
  # below for a box that has already refused our stored admin credential.
  @reads [:poll_deploy, :build_record, :build_log_bytes]

  @spec start_deploy(Barkpark.t(), map()) :: reply()
  def start_deploy(bp, payload), do: dispatch(bp, :start_deploy, [bp, payload])

  @spec poll_deploy(Barkpark.t(), String.t(), String.t()) :: reply()
  def poll_deploy(bp, slug, build_id), do: dispatch(bp, :poll_deploy, [bp, slug, build_id])

  @spec build_record(Barkpark.t(), String.t(), String.t()) :: reply()
  def build_record(bp, slug, build_id), do: dispatch(bp, :build_record, [bp, slug, build_id])

  @spec build_log_bytes(Barkpark.t(), String.t(), String.t()) :: reply()
  def build_log_bytes(bp, slug, build_id),
    do: dispatch(bp, :build_log_bytes, [bp, slug, build_id])

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

  require Logger

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Sites.RollbackAttribution

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

  # `record=1` is the box door's OPT-IN for the durable terminal record
  # (`SiteDeployController.record_requested?/1`). The opt-in is the design: the
  # poll above rides the same route and its 404-means-keep-waiting contract is
  # load-bearing, so the record must never arrive by changing what the poll
  # receives. A box too old to know the flag ignores it and answers the live
  # status, whose `log_state` is absent — which `Sites.BuildLog` reports as
  # "we do not know", never as "nothing was recorded".
  @impl true
  def build_record(bp, slug, build_id) do
    query = URI.encode_query(%{"slug" => slug, "build_id" => build_id, "record" => "1"})
    Registry.relay_admin(bp, :get, @path <> "?" <> query, nil)
  end

  # `bytes=1` rides ON TOP of `record=1` — the box's `bytes_requested?/1` only
  # means anything alongside the record flag. A box too old to know it answers the
  # RECORD, which carries no `tail` key at all; `Sites.BuildLogBytes` reads that as
  # a shape it does not understand rather than as an empty log, so an old box can
  # never be mistaken for one reporting no bytes.
  @impl true
  def build_log_bytes(bp, slug, build_id) do
    query =
      URI.encode_query(%{
        "slug" => slug,
        "build_id" => build_id,
        "record" => "1",
        "bytes" => "1"
      })

    Registry.relay_admin(bp, :get, @path <> "?" <> query, nil)
  end

  # The flip is a rename(2) — measured at 25ms on the box — so the wait settles on
  # the first or second poll. The budget sits far inside the CLI's 15s client
  # timeout: a rollback we cannot CONFIRM quickly is a rollback we must not claim
  # happened.
  @rollback_poll_ms 50
  @rollback_budget_default_ms 10_000
  # A teardown stops the slots + disarms Caddy + deletes the tree — a few seconds,
  # but a cold node slot stop can lag, so allow more headroom than a pointer flip.
  @teardown_budget_default_ms 30_000

  # Both budgets are WALL-CLOCK, and both are overridable so a test can drive them
  # down far enough to prove the deadline actually bites (prior art:
  # `BarkparkCloud.Usage`'s `:usage_fanout_budget_ms` aggregate deadline).
  defp rollback_budget_ms,
    do:
      Application.get_env(
        :barkpark_cloud,
        :site_rollback_budget_ms,
        @rollback_budget_default_ms
      )

  defp teardown_budget_ms,
    do:
      Application.get_env(
        :barkpark_cloud,
        :site_teardown_budget_ms,
        @teardown_budget_default_ms
      )

  @impl true
  def rollback(bp, payload) when is_map(payload) do
    # mode: "rollback" → `site-deploy.sh --rollback` on the box. NEVER
    # Deployment.promotion_attrs (charter D5): a promote is a NEW build (seconds
    # to minutes); a static rollback is a symlink repoint (25ms measured).
    slug = payload[:slug] || payload["slug"]
    started_at = System.monotonic_time(:millisecond)

    case Registry.relay_admin(bp, :post, @path, Map.put_new(payload, :mode, "rollback")) do
      {:ok, status, _body} when status in 200..299 ->
        # /v1/admin/site-deploy is ASYNCHRONOUS: it answers 202 `started` and runs
        # the engine behind a Port. Returning here would report a successful
        # rollback for a symlink that has NOT moved yet — and would bake a vacuous
        # "sub-second" into the wire, since the thing being timed would be the
        # accept, not the flip. This behaviour promises to answer only once the
        # flip has really happened (charter D5), so: wait for it.
        attribute(:rollback, slug, started_at, fn ->
          await_flip(bp, slug, deadline(rollback_budget_ms()), zero_split())
        end)

      # 409 lock held, 4xx/5xx refusal, unreachable box — relay the box's own
      # verdict verbatim. Nothing is invented here.
      other ->
        other
    end
  end

  # THE DEADLINE IS WALL-CLOCK, NOT AN ITERATION COUNT (rollback-latency c0).
  # This loop used to recur on `left_ms - @rollback_poll_ms`, subtracting only its
  # own SLEEP and never the round trip it had just spent on the wire. That made
  # `@rollback_budget_ms` a budget of 200 ITERATIONS, not of 10 seconds: each
  # iteration also costs a full CP->box poll, and the box's own status read is
  # allowed to take up to 20s (`DeployRunner.@status_call_timeout_ms`), so a slow
  # box could hold the control plane far past the CLI's 15s client timeout while
  # the code believed it was inside budget. A monotonic deadline cannot drift that
  # way — it counts the wire time too.
  #
  # `split` accumulates the ATTRIBUTION (how many polls, how much of the wait was
  # relay wire time vs this loop's own quantisation); `attribute/4` logs it.
  defp await_flip(bp, slug, deadline, split) do
    if expired?(deadline) do
      {timed_out(:rollback), split}
    else
      {reply, split} = poll_once(bp, slug, split)

      case reply do
        {:ok, status, body} when status in 200..299 ->
          if to_string(body["state"]) == "done" do
            {settle_flip(body), box_done_by(split)}
          else
            await_flip(bp, slug, deadline, nap(deadline, box_still_running(split)))
          end

        other ->
          {other, split}
      end
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
    started_at = System.monotonic_time(:millisecond)

    case Registry.relay_admin(bp, :post, @path, Map.put_new(payload, :mode, "teardown")) do
      {:ok, status, _body} when status in 200..299 ->
        attribute(:teardown, slug, started_at, fn ->
          await_teardown(bp, slug, deadline(teardown_budget_ms()), zero_split())
        end)

      other ->
        other
    end
  end

  # Same wall-clock deadline as `await_flip/4` — the iteration-count defect was
  # byte-identical here, and a teardown's 30s budget made it 600 iterations.
  defp await_teardown(bp, slug, deadline, split) do
    if expired?(deadline) do
      {timed_out(:teardown), split}
    else
      {reply, split} = poll_once(bp, slug, split)

      case reply do
        {:ok, status, body} when status in 200..299 ->
          if to_string(body["state"]) == "done" do
            {settle_teardown(body), box_done_by(split)}
          else
            await_teardown(bp, slug, deadline, nap(deadline, box_still_running(split)))
          end

        other ->
          {other, split}
      end
    end
  end

  # ── the shared wait mechanics + the attribution split ──────────────────────

  defp deadline(budget_ms), do: System.monotonic_time(:millisecond) + budget_ms

  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  # THE SPLIT, opened the instant the accept came back. `accept_done_at` is the
  # zero of the BOX's clock as this plane can observe it: everything the box does
  # for this run happens after that mark, so every poll answer brackets the box's
  # execution against it.
  defp zero_split,
    do: %{
      polls: 0,
      poll_wire_ms: 0,
      sleep_ms: 0,
      accept_done_at: System.monotonic_time(:millisecond),
      poll_sent_at: nil,
      poll_back_at: nil,
      box_min_ms: 0,
      box_max_ms: nil
    }

  # THE BOX'S OWN EXECUTION, BRACKETED — not guessed from a residue
  # (rollback-latency c0). The relay's accept/poll/sleep legs say how much of the
  # wait was THIS plane; they say nothing about how long `site-deploy.sh
  # --rollback` actually ran, because the box works CONCURRENTLY with the wait
  # loop. Two facts each poll answer carries settle it without a new wire field:
  #
  #   * an answer of `running` proves the box was still working when that answer
  #     was PRODUCED — a lower bound;
  #   * an answer of `done` proves it had finished before that read was SENT — an
  #     upper bound.
  #
  # A `box_max_ms` far under `total_ms` acquits the box; a `box_min_ms` near it
  # convicts it. The old residue could do neither, because it also carried this
  # loop's own sleep.
  defp box_still_running(%{accept_done_at: a, poll_back_at: back} = split)
       when is_integer(a) and is_integer(back),
       do: %{split | box_min_ms: max(split.box_min_ms, back - a)}

  defp box_still_running(split), do: split

  defp box_done_by(%{accept_done_at: a, poll_sent_at: sent} = split)
       when is_integer(a) and is_integer(sent),
       do: %{split | box_max_ms: max(sent - a, 0)}

  defp box_done_by(split), do: split

  # One CP->box status read, with its WIRE time charged to the split. This is the
  # component `@rollback_poll_ms` never accounted for.
  defp poll_once(bp, slug, split) do
    # build_id is irrelevant to a rollback (there is exactly one run per slug and
    # the box's GET keys on slug alone) — the empty string keeps the behaviour's
    # 3-arity poll contract without inventing a build we do not have.
    at = System.monotonic_time(:millisecond)
    reply = poll_deploy(bp, slug, "")
    back = System.monotonic_time(:millisecond)

    {reply,
     %{
       split
       | polls: split.polls + 1,
         poll_wire_ms: split.poll_wire_ms + (back - at),
         poll_sent_at: at,
         poll_back_at: back
     }}
  end

  # Sleep the poll interval, but never PAST the deadline: overshooting it is how a
  # bounded wait turns into budget + one interval on every single call.
  defp nap(deadline, split) do
    ms =
      @rollback_poll_ms
      |> min(max(deadline - System.monotonic_time(:millisecond), 0))

    Process.sleep(ms)
    %{split | sleep_ms: split.sleep_ms + ms}
  end

  defp timed_out(:rollback) do
    {:ok, 504,
     %{
       "error" =>
         "the instance did not confirm the rollback in time — it may still be flipping; " <>
           "check `bp cloud site status`"
     }}
  end

  defp timed_out(:teardown) do
    {:ok, 504,
     %{
       "error" =>
         "the instance did not confirm the teardown in time — it may still be tearing down; " <>
           "check `bp cloud site status`"
     }}
  end

  # WHERE THE SERVER-SIDE TIME WENT (rollback-latency c0). A live rollback measured
  # 1.4-3.4s server-side against an engine flip the charter measured at 25ms, and
  # nothing in the control plane could say which seam held it. Now every wait
  # reports its own arithmetic, so ONE live rollback attributes itself:
  #
  #   * `accept_ms`  — the CP->box POST round trip (the relay, one trip)
  #   * `poll_wire_ms` — the CP->box status reads (the relay, `polls` trips)
  #   * `sleep_ms`   — THIS loop's own 50ms quantisation (the control plane)
  #   * the box's own work is what forced `polls` above 1; with `polls: 1` the
  #     box was already done before the first read and the time is all relay.
  #
  # `total_ms` is the whole behaviour call, so `total_ms - accept_ms -
  # poll_wire_ms - sleep_ms` is the residue this module does not account for.
  defp attribute(mode, slug, started_at, wait) do
    accept_ms = System.monotonic_time(:millisecond) - started_at
    {reply, split} = wait.()
    total_ms = System.monotonic_time(:millisecond) - started_at

    Logger.info(fn ->
      "site #{mode} attribution slug=#{slug} total_ms=#{total_ms} " <>
        "accept_ms=#{accept_ms} polls=#{split.polls} " <>
        "poll_wire_ms=#{split.poll_wire_ms} sleep_ms=#{split.sleep_ms} " <>
        "box_min_ms=#{split.box_min_ms} box_max_ms=#{inspect(split.box_max_ms)}"
    end)

    # Hand the same numbers UP to the request-scoped accumulator, which owns the
    # two ends this module cannot see: the route work either side of the box
    # call. A no-op outside a route (a worker, a test calling the relay directly).
    RollbackAttribution.record_relay(%{
      relay_ms: total_ms,
      accept_ms: accept_ms,
      polls: split.polls,
      poll_wire_ms: split.poll_wire_ms,
      sleep_ms: split.sleep_ms,
      box_min_ms: split.box_min_ms,
      box_max_ms: split.box_max_ms
    })

    reply
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
