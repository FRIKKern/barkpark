defmodule BarkparkWeb.SiteDeployController do
  @moduledoc """
  Admin-only trigger + status for a content-bound STATIC site deploy
  (`/v1/admin/site-deploy`, backed by `Barkpark.Sites.DeployRunner`).

  This is the remote-exec seam (charter D22): the control plane already knows
  how to make an authenticated admin POST to an instance's own API with the
  per-instance Vault-stored admin token — that is exactly how self-update runs
  today — so a site deploy rides the SAME door. No SSH, no agent channel, no
  new auth: the routes sit in the existing `/v1/admin` scope
  (`pipe_through [:api, :require_admin]`), so an un-authenticated caller gets
  401 and a non-admin 403 before this module is ever reached.

  Status contract, mirroring `SelfUpdateController`:

    * **503** `feature_not_configured` — the box has not CONSENTED to run
      third-party site build code. Fail-closed default, and a decision rather
      than a misconfiguration: the message names the consent boundary and the
      preflight that checks the per-box prerequisites, never an env var to set
      (D593). `BARKPARK_SITE_DEPLOY_APPLY=1` is still what records the consent
      on the box; it is deliberately absent from the wire message.
    * **400** `invalid_slug` / `invalid_build_id` / `invalid_content_rev` /
      `invalid_deploy_mode` / `invalid_env` / `invalid_artifact` /
      `invalid_artifact_digest` / `artifact_too_large` — nothing reaches argv or
      the child's env until `Barkpark.Sites.DeployRequest` has validated it.
    * **400** `E_DIGEST_MISMATCH` / `E_NOT_GZIP` / `E_NOT_BASE64` /
      `E_MALFORMED` / `E_PATH_TRAVERSAL` / `E_ABSOLUTE_PATH` / `E_SYMLINK` /
      `E_HARDLINK` / `E_SPECIAL_FILE` / `E_UNKNOWN_TYPE` / `E_MODE_BITS` /
      `E_BAD_NAME` / `E_UNSAFE_PARENT` / `E_ENTRY_TOO_LARGE` /
      `E_TOTAL_TOO_LARGE` / `E_COMPRESSION_RATIO` / `E_TOO_MANY_ENTRIES` /
      `E_NO_INDEX` — the 18 typed refusals a PREBUILT artifact can draw from the
      box (`Barkpark.Sites.PrebuiltArtifact`). These are 400s, not 500s: the
      bytes are the caller's, and the box never falls back to building the site
      itself when it refuses them. `E_MALFORMED` covers framing as well as
      corruption — a stream with no end-of-archive marker, or a gzip member that
      never terminates, is a truncated upload; `E_NO_INDEX` is the archive that
      arrived WHOLE and still has nothing to serve.
    * **409** `already_running` — a run for THAT SLUG is in flight. A different
      slug (or an unrelated self-update) never collides.
    * **409** `box_at_capacity` — a DIFFERENT slug is building and the box's
      fleet build slot is taken (`BUILD_GATE_SLOTS=1`). The refusal happens at
      the door, before the artifact is even unpacked, because the alternative
      is what the box used to do: answer 202 and let the engine queue inside
      its own unit for up to 900s, where an operator reads a queue as a hang.
      Only `mode: "deploy"` can draw it — a rollback or teardown never touches
      the build gate. Retry when the in-flight build finishes.

      The body NAMES THE HOLDER. `code` and the message's capacity clause are
      byte-stable (the control plane's deferral taxonomy matches the literal
      code, and the CLI keys its exit code on it), so the holder rides in ADDED
      FIELDS: `holder` (`"peer"` — a build this instance launched and tracks,
      ordinary contention; `"foreign"` — an FLOCK entry on the fleet build lock
      this instance did NOT launch, which a retry may never clear and an
      operator should look at; `"unknown"` — a newer refusal overwrote the
      detail before this process read it, so we decline to name a site rather
      than name the wrong one), `holding_slugs`, `build_slots_in_use`,
      `build_slot_capacity`, and `holder_lock` on the foreign case only. This
      refusal is the single highest-volume event in the deploy pipeline; it
      used to say "another site is building" and never which.
    * **202** `started` — with the fresh run status.
    * **500** `runner_start_failed` — the feature IS enabled but the command
      could not spawn (missing script, bad cd). Distinct from 503: telling an
      admin to set an env var they already set would be actively wrong.
    * **500** `site_provision_failed` — the site's SOURCE could not be
      materialized, so the build never started. Carries a scrubbed `reason`
      (the failed action + path). Distinct from `runner_start_failed`, which it
      used to be silently folded into: the two have different operators and
      different fixes.

  `GET /v1/admin/site-deploy?slug=<slug>` returns the run status for one slug:
  state, the six parsed `stages` (retained separately from the log ring, so a
  900-line `npm ci` cannot evict PLAN/BUILD), `exit_code`, an honest
  `failure_reason` carrying the real lines from the child's stream, and the
  bounded log tail. The configured command is never exposed — only its output.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Sites.DeployRequest
  alias Barkpark.Sites.DeployRunner

  @doc """
  Start a site deploy (`mode: "deploy"`, the default) or an instant rollback
  (`mode: "rollback"` — a symlink repoint, no rebuild) for one slug.
  """
  def trigger(conn, params) do
    # Fail-closed FIRST: a box that cannot execute site deploys says so before
    # it says anything about the shape of the request.
    if DeployRunner.enabled?() do
      do_trigger(conn, params)
    else
      feature_not_configured(conn)
    end
  end

  defp do_trigger(conn, params) do
    case DeployRequest.new(params) do
      {:ok, req} -> start(conn, req)
      {:error, code, message} -> bad_request(conn, code, message)
    end
  end

  defp start(conn, %DeployRequest{} = req) do
    case DeployRunner.trigger(req) do
      {:ok, :started} ->
        conn
        |> put_status(:accepted)
        |> json(
          Map.merge(
            %{ok: true, status: render_status(DeployRunner.status(req.slug))},
            prebuilt_echo(req)
          )
        )

      {:error, :already_running} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: %{
            code: "already_running",
            message: "a deploy for site '#{req.slug}' is already running"
          }
        })

      {:error, :box_at_capacity} ->
        # The box is BUILDING something else. `code` is exactly
        # "box_at_capacity" (lowercase snake, no prefix) and `message` is
        # NON-EMPTY on purpose: the control plane renders a refusal as
        # "<code> — <message>" and classifies on the head of that split, so a
        # code with an empty message collides with the request-id stamp the
        # relay appends and the deferral lands unclassified.
        #
        # The code and the message's leading clause are BYTE-STABLE on purpose
        # — the control plane's deferral taxonomy matches the literal
        # `box_at_capacity` and the CLI's exit-code map keys on it, so the
        # holder is carried in ADDED FIELDS and in the message's TAIL, never in
        # a second code.
        conn
        |> put_status(:conflict)
        |> json(%{error: box_at_capacity_error(req.slug)})

      {:error, :disabled} ->
        # The apply flag flipped off between the guard and the call — still
        # fail-closed, and still the operator's flag to set. This arm is ONLY
        # the Runner's own considered `:disabled` reply now; a Runner that
        # could not answer lands below.
        feature_not_configured(conn)

      {:error, :runner_unavailable} ->
        # The Runner did not answer inside the call budget, or was not alive to
        # answer. This used to arrive here as `{:error, :disabled}` and render
        # `feature_not_configured` — telling an operator to set
        # BARKPARK_SITE_DEPLOY_APPLY=1 on a box that had carried it for 75
        # minutes, at 5039ms, WHILE the build the door had just accepted ran to
        # completion behind the answer. 207 rows in 24h, 24.5% of the fleet's
        # failure numerator, wrong about the cause AND about the outcome.
        #
        # Its own typed code now, and the message never names the flag. Same
        # 503 as before ON PURPOSE (charter D115): the control plane keys its
        # refusal class on the STATUS, so moving this would refile the rows into
        # the very class this wave is emptying. The CODE is what changed, and
        # `transient_refusal?/1` in the control plane graces it in the SAME PR —
        # so this now BUYS a start retry and 45 poll-grace beats where it used
        # to spend a build.
        runner_unavailable(conn)

      {:error, {:artifact_rejected, code, message}} ->
        # The box REFUSED the caller's prebuilt bytes. 400 with the extractor's
        # own typed code — the control plane must be able to tell "your tarball
        # has a symlink in it" from "the box is broken", and must never read a
        # refusal as a licence to let the box build the site instead.
        bad_request(conn, code, message)

      {:error, {:provision_failed, reason}} ->
        # The site's SOURCE could not be materialized, so the build never
        # started. This used to collapse into `runner_start_failed` after a bare
        # Logger.warning — which is why a `%File.Error{}` that explained 63% of
        # this fleet's failures reached journald and nothing else, across 25
        # consecutive attempts on one site. It is now its own code carrying the
        # scrubbed reason (the failed action AND path), so a caller can tell
        # "your box cannot write the sites dir" from "the runner would not
        # spawn". It is NOT a stage: site-spawner D34 keeps PROVISION a silent
        # pre-BUILD step, and the six stage names are untouched.
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: %{
            code: "site_provision_failed",
            message: "site source could not be provisioned — the deploy never started",
            reason: reason
          }
        })

      {:error, :start_failed} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: %{
            code: "runner_start_failed",
            message: "site-deploy runner failed to start — check the server logs"
          }
        })
    end
  end

  @doc """
  The run status for one slug (`?slug=<slug>`). A slug that has never deployed
  reports `state: "idle"` — an honest empty state, not a 404.

  `build_id` is a first-class match key (charter D34). BoxRelay already sends
  the build_id it is polling for; when it is present AND non-empty AND does not
  match the run currently served for that slug (which includes the idle case,
  where the run's build_id is `nil`), this responds **404**. The control plane
  treats 404 as keep-waiting, so a superseded run — or one that has not started
  yet — times out honestly instead of silently adopting another same-slug run's
  stages and its eventual success. An empty (`""`, rollback await-flip) or
  absent (legacy caller) build_id falls back to slug-only match — backward
  compatible. The decision is `resolve_status_match/2`, a pure function.
  """
  def status(conn, params) do
    case DeployRequest.validate_slug(Map.get(params, "slug")) do
      {:ok, slug} ->
        requested_build_id = Map.get(params, "build_id")

        if record_requested?(params) do
          json(conn, render_build_record(DeployRunner.build_record(slug, requested_build_id)))
        else
          status = DeployRunner.status(slug)

          case resolve_status_match(status, requested_build_id) do
            :serve -> json(conn, render_status(status))
            :not_found -> build_id_mismatch(conn, slug, requested_build_id)
          end
        end

      {:error, code, message} ->
        bad_request(conn, code, message)
    end
  end

  # OPT-IN ONLY, and the opt-in is the design. BoxRelay polls this same route and
  # its 404-means-keep-waiting contract is load-bearing (charter D34), so the
  # durable record must never arrive by changing what an existing caller already
  # receives. A caller that does not ask for it sees byte-identical behaviour,
  # and a typo (`record=yes-please`, `record=0`) degrades to the live status
  # rather than silently switching response shapes.
  defp record_requested?(params) do
    Map.get(params, "record") in ["1", "true", "yes", "on"]
  end

  @doc """
  Decide whether a served status matches the polled `build_id` — pure, so it is
  unit-testable with no GenServer or filesystem. `:serve` means the slug-only or
  build_id-matched run is the one the caller wants; `:not_found` means the caller
  is polling for a build that this slug is not currently serving.

    * absent (`nil`) or empty (`""`) requested build_id → `:serve` (slug-only,
      backward compatible: legacy callers and rollback await-flip)
    * non-empty and equal to the run's build_id → `:serve`
    * non-empty and different (including idle, where the run build_id is `nil`)
      → `:not_found`
  """
  @spec resolve_status_match(map(), String.t() | nil) :: :serve | :not_found
  def resolve_status_match(status_payload, requested_build_id) do
    case requested_build_id do
      nil -> :serve
      "" -> :serve
      id when is_binary(id) -> if id == status_payload.build_id, do: :serve, else: :not_found
      _ -> :serve
    end
  end

  # The 202 says WHICH KIND of deploy started. A prebuilt run echoes the digest
  # the box actually verified — not the one the caller sent, though a mismatch
  # never reaches here — so the control plane can record what it deployed
  # instead of assuming. A box build carries NEITHER key: an absent field is an
  # honest "this was built here", where `prebuilt: false` would invite a caller
  # to read a pre-upgrade box's silence as a considered answer.
  defp prebuilt_echo(%DeployRequest{} = req) do
    if DeployRequest.prebuilt?(req) do
      %{prebuilt: true, artifact_sha256: req.artifact_sha256}
    else
      %{}
    end
  end

  # THE REFUSAL NAMES THE CONSENT BOUNDARY, NOT A FLAG TO FLIP (deploy charter
  # D593). The old message ended `(set BARKPARK_SITE_DEPLOY_APPLY=1)` — an
  # INSTRUCTION, issued to an operator who may have every reason not to follow
  # it. A site build is not a self-update: it runs `npm ci` + `npm run build`
  # over the SITE's own dependency tree, which executes third-party postinstall
  # code on this box, and `runtime.exs` gates it separately in exactly those
  # words. A box that has not opted in has not FAILED to be configured; it has
  # DECLINED, and a spawned box declines by construction because nothing in the
  # provisioning path may consent on its owner's behalf (`instance-deploy.sh`
  # PRESERVES the flag and never SETS it — D38).
  #
  # The status and the code word are UNCHANGED on purpose (charter D115): the
  # control plane keys `BOX_DEPLOY_DISABLED_503` on `feature_not_configured`
  # through `DeployLedger.refusal_class/2`, so re-wording the prose reclassifies
  # nothing and no historical row moves. What changed is what the sentence asks
  # of the reader — a decision to make, and where the per-box prerequisites for
  # making it are actually CHECKED, rather than an env var to export.
  # The 409 body for a full box. Everything past `code` and the capacity clause
  # is the part this endpoint used to throw away: the door KNOWS which slug is
  # building and whether the holder is a peer build or a foreign one, said so in
  # a log line, and then answered "another site is building".
  #
  # `holder`:
  #   * `"peer"`    — a build THIS instance launched and tracks. Ordinary
  #                   contention; `holding_slugs` names it and a retry works.
  #   * `"foreign"` — an FLOCK entry on the fleet build lock that this instance
  #                   did not launch (a hand-run engine, or a unit that outlived
  #                   a previous BEAM). `holder_lock` names the lock file. A
  #                   retry may never work; this one wants an operator.
  #   * `"unknown"` — the door refused but its detail record was overwritten by
  #                   a newer refusal before this process read it. We degrade to
  #                   the old generic prose rather than name the wrong site.
  defp box_at_capacity_error(slug) do
    slots = DeployRunner.build_slot_capacity()

    base = %{
      code: "box_at_capacity",
      build_slot_capacity: slots
    }

    case DeployRunner.last_refusal() do
      %{slug: ^slug, holder: :peer, in_flight_slugs: [_ | _] = held} = detail ->
        Map.merge(base, %{
          holder: "peer",
          holding_slugs: held,
          build_slots_in_use: detail.slots_in_use,
          message: capacity_message(detail.slots_in_use, slots, peer_tail(held))
        })

      %{slug: ^slug, holder: :foreign} = detail ->
        Map.merge(base, %{
          holder: "foreign",
          holding_slugs: [],
          holder_lock: detail.holder_lock,
          build_slots_in_use: detail.slots_in_use,
          message:
            capacity_message(
              detail.slots_in_use,
              slots,
              "a build this instance did not launch holds the build lock " <>
                "#{detail.holder_lock}; it is not tracked here, so a retry may not " <>
                "clear it — an operator should check the box"
            )
        })

      _ ->
        Map.merge(base, %{
          holder: "unknown",
          holding_slugs: [],
          build_slots_in_use: slots,
          message:
            capacity_message(slots, slots, "another site is building; retry when it finishes")
        })
    end
  end

  # The leading clause is byte-identical to what the control plane has been
  # parsing since D179 — only the tail after the second em dash is new.
  defp capacity_message(in_use, slots, tail) do
    "the box is at its build capacity (#{in_use} of #{slots} build slots in use) — " <> tail
  end

  defp peer_tail([one]), do: "site '#{one}' is building; retry when it finishes"

  defp peer_tail(many) do
    "sites #{Enum.map_join(many, ", ", &"'#{&1}'")} are building; retry when one finishes"
  end

  defp feature_not_configured(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      error: %{
        code: "feature_not_configured",
        message:
          "this instance has not consented to run third-party site build code " <>
            "— a site deploy executes the site's own npm dependency tree " <>
            "(postinstall scripts included) on this box, so opting in is the " <>
            "box owner's decision, not a retry; the per-box prerequisites are " <>
            "checked by `deploy/instance-deploy.sh --site-deploy-preflight`"
      }
    })
  end

  # The door is CONFIGURED and the Runner is supervised — it just did not answer
  # in time. Deliberately says nothing about the apply flag: this refusal is not
  # about configuration, and the operator who "fixes" it by setting a flag that
  # is already set has been sent to the wrong place.
  #
  # It is also honest about the outcome it does not know: a trigger that outran
  # the call budget may ALREADY be running on the box, in which case the retry
  # this refusal invites meets a 409 `already_running` (which the control plane
  # turns into a counted deferral, never a second build).
  @runner_unavailable_retry_after_s 15

  defp runner_unavailable(conn) do
    conn
    |> put_status(:service_unavailable)
    |> put_resp_header("retry-after", Integer.to_string(@runner_unavailable_retry_after_s))
    |> json(%{
      error: %{
        code: "deploy_runner_unavailable",
        message:
          "the deploy runner did not answer in time — the box is busy or wedged, " <>
            "not unconfigured; retry in #{@runner_unavailable_retry_after_s}s " <>
            "(if the trigger did land, the retry answers already_running)"
      }
    })
  end

  defp bad_request(conn, code, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: code, message: message}})
  end

  # The polled build_id is not the run this slug is currently serving — it was
  # superseded by a newer same-slug build, or has not started yet. 404 (not 200)
  # so the control plane keeps waiting instead of adopting the wrong run's stages.
  defp build_id_mismatch(conn, slug, build_id) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: %{
        code: "build_id_mismatch",
        message:
          "no run for site '#{slug}' matches build_id '#{build_id}' — " <>
            "it was superseded by a newer build or has not started yet"
      }
    })
  end

  # Whitelist-render: the runner's status map, JSON-shaped (atoms → strings,
  # DateTime → ISO8601). Never the command.
  # The DURABLE per-build record, for a run the Runner has long forgotten.
  #
  # WHY THIS EXISTS: `render_status/1` above answers about the run the Runner is
  # holding IN MEMORY. Once a build finishes and the slug goes idle, the only
  # thing that still knows what happened is `<slug>-<tag>.terminal.json` on the
  # box — and nothing called `build_record/2`, so the answer to "why did build X
  # fail" was an SSH session. This is that answer over the existing admin door.
  #
  # RAW LOG BYTES ARE DELIBERATELY NOT SERVED, AND THIS IS NOT A SIZE DECISION.
  # The build env file carries `BARKPARK_TOKEN=` in plaintext, and the measured
  # leak rate of the shared scrubber against this box's own `bppat_` token shape
  # is 95.1% (DeployRunner :1153-1155). DeployRunner :404-406 refuses the bytes
  # for exactly that reason. So this ships the STRUCTURED record — which is
  # strictly more diagnostic than the one-line failure_reason and carries no
  # credential surface — and `log_path` + `log_bytes` + `journal_command` tell an
  # operator where the bytes are without moving them.
  #
  # THE FIELD LIST IS EXPLICIT, NEVER A PASS-THROUGH. `build_record/2` is free to
  # grow a field; if this rendered its map wholesale, the day someone adds a
  # `log_tail` for an internal caller is the day this endpoint starts serving
  # credentials. Naming each key means a new upstream field is invisible here
  # until a human adds it on purpose.
  # THE CAPS ARE ENFORCED HERE, not inherited. Upstream already bounds both —
  # `failure_reason` carries @reason_lines (3) trailing lines and the BPSTAGE
  # fold has six members by construction — but an invariant held somewhere else
  # is exactly what this endpoint must not rely on. If a future change lets a
  # 4 MB reason through, the door truncates it instead of serving it, and the
  # test pins that with input an order of magnitude over the cap.
  @max_reason_bytes 4_000
  @max_stages 32

  defp render_build_record(record) do
    %{
      slug: record.slug,
      build_id: record.build_id,
      record: Atom.to_string(record.record),
      # FOUR states, not three: `available`, `evicted`, `never_recorded`, and
      # `missing` — a log gone from disk but never tombstoned. Collapsing
      # `missing` into `evicted` would claim retention did something it did not,
      # and collapsing either into `never_recorded` is the exact lie this record
      # was built to stop: a pruned deployment and a slug that never deployed
      # used to return byte-identical maps.
      log_state: Atom.to_string(record.log_state),
      log_path: record.log_path,
      log_bytes: record.log_bytes,
      exit_code: record.exit_code,
      failure_reason: cap_reason(record.failure_reason),
      # The BPSTAGE fold. Retained separately from the 500-line log ring and
      # IMMUNE to it, so these survive after the log itself is evicted — which
      # is what makes this record useful at the end of a retention window
      # rather than only while the bytes are still there.
      stages: Enum.take(record.stages || [], @max_stages),
      unit_name: record.unit_name,
      journal_command: record.journal_command,
      mode: atom_or_nil(record.mode),
      runtime_target: atom_or_nil(record.runtime_target),
      started_at: record_iso(record.started_at),
      finished_at: record_iso(record.finished_at),
      evicted_at: record_iso(record.evicted_at)
    }
  end

  # Truncation is VISIBLE, never silent: a caller that sees the marker knows the
  # reason was longer, and one that does not is looking at the whole thing. A
  # quiet slice would make a truncated diagnosis indistinguishable from a
  # complete one, which is the same class of lie as an evicted log answering
  # like one that never existed.
  # The terminal record is READ BACK FROM JSON, so its timestamps arrive as ISO
  # STRINGS — not the %DateTime{} structs `iso/1` renders for the live status.
  # Kept as its own function rather than widening `iso/1`: that one serves the
  # live path, where a binary timestamp would mean something upstream had
  # already gone wrong and should still crash rather than pass through.
  defp record_iso(nil), do: nil
  defp record_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp record_iso(value) when is_binary(value), do: value
  defp record_iso(_other), do: nil

  defp cap_reason(nil), do: nil

  defp cap_reason(reason) when is_binary(reason) do
    if byte_size(reason) > @max_reason_bytes do
      binary_part(reason, 0, @max_reason_bytes) <> "… [truncated at #{@max_reason_bytes} bytes]"
    else
      reason
    end
  end

  defp cap_reason(other), do: other

  defp render_status(status) do
    %{
      state: Atom.to_string(status.state),
      slug: status.slug,
      build_id: status.build_id,
      content_rev: status.content_rev,
      mode: atom_or_nil(status.mode),
      stages: Enum.map(status.stages, &render_stage/1),
      exit_code: status.exit_code,
      failure_reason: status.failure_reason,
      log: status.log,
      # THE SLOT CADDY IS ACTUALLY SERVING (site-spawner: node slot truth), read
      # back out of the Caddyfile by the node engine AFTER its flip committed —
      # never the slot the run intended. `null` on every static deploy (a symlink
      # swap has no slot) and on any node build that died before SWITCH.
      #
      # `Map.get/2`, not dot access: `status/1` answers in five shapes (a live
      # Port run, a reconstructed systemd render, a cached one, a terminal record
      # and `:idle`), and a status map from a pre-upgrade cached render must not
      # crash this door.
      served_port: Map.get(status, :served_port),
      served_slot: Map.get(status, :served_slot),
      started_at: iso(status.started_at),
      finished_at: iso(status.finished_at)
    }
    |> put_health_exit_code(status)
  end

  # THE HEALTH CODE IS OMITTED WHEN IT WAS NEVER MEASURED, and that omission is
  # the contract — the same discipline `prebuilt_echo/1` above states for the
  # 202: an absent field is an honest "nobody measured this", where a present one
  # invites the caller to read it as a considered answer.
  #
  # It matters more here than anywhere else on this door, because the value that
  # would be invented is ZERO and zero is SUCCESS. A `health_exit_code: 0` on a
  # build that died in BUILD says the health gate passed. So: present and `0`
  # when HEALTH really ran and passed, present and `14` when it ran and failed,
  # and ABSENT when there is no HEALTH verdict in the fold at all.
  defp put_health_exit_code(payload, status) do
    case DeployRunner.health_exit_code(Map.get(status, :stages) || []) do
      nil -> payload
      code -> Map.put(payload, :health_exit_code, code)
    end
  end

  # `detail` is the failed stage's REAL reason (npm's 401, HEALTH's marker miss).
  # The control plane reads it straight off this key and `bp cloud site` prints
  # it; omitting it degrades every failure to a canned line, silently.
  defp render_stage(stage) do
    %{
      name: stage.name,
      status: stage.status,
      build_id: stage.build_id,
      detail: Map.get(stage, :detail),
      at: iso(stage.at)
    }
  end

  defp atom_or_nil(nil), do: nil
  defp atom_or_nil(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
