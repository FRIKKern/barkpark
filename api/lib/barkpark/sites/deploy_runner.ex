defmodule Barkpark.Sites.DeployRunner do
  @moduledoc """
  Site-deploy EXECUTOR — the on-box process that actually runs
  `deploy/site-deploy.sh` for a content-bound site. This is the remote-exec seam
  the control plane reaches through `POST /v1/admin/site-deploy` (charter D22):
  an authenticated admin HTTP call on the instance's OWN API, turned into a real
  OS process here.

  ## Observer + finalizer, NOT a Port owner (search-template D29/D31/D32/D33)

  Guerrilla auto-deploys itself on every `api/**` merge, and the post-merge
  `barkpark.service` restart kills the BEAM. When this GenServer OWNED the build
  as a linked `Port`, that restart killed every in-flight site build with it — a
  grenade every few minutes on a busy day. Honest failure held (fail-closed, a
  CP retry hint, the reaper re-drove), but honest failure is not perfection.

  So on a systemd box the build no longer hangs off this process. `trigger/1`
  launches the WHOLE engine as a TRANSIENT systemd unit
  (`systemd-run --unit=bp-site-build-<slug>-<id>-<ts> …`) — a SIBLING cgroup,
  not a BEAM child. When `barkpark.service` restarts, that unit keeps running:
  its `npm ci`, its per-slug flock, its symlink swap all survive. This GenServer
  becomes an OBSERVER (it reads the unit's durable status + log files) and a
  FINALIZER (it force-stops a unit that outlives its deadline, and reconstructs
  a terminal `:done` once the unit is gone). On `init/1` it SCANS the run-state
  dir and RE-ATTACHES to every unit still `systemctl is-active` — re-arming the
  deadline and re-claiming the per-slug single-flight slot so a same-slug
  re-trigger still 409s across a restart.

  When `systemd-run` is absent (dev, macOS, CI) it FALLS BACK to the classic
  in-process `Port` path below, so local tests exercise the same lifecycle
  without systemd.

  ## Why this is NOT `Barkpark.SelfUpdate.Runner` (charter D23)

  The self-update Runner is the right SHAPE (supervised GenServer, fail-closed
  behind an apply flag, bounded log, deadline watchdog) but the wrong ENGINE for
  a site deploy, on three counts that each break a live deploy rather than
  merely offend taste:

    * **Compile-time command.** Its command comes from `config` — it can never
      carry a per-request `build_id`. Every site deploy names a different build.
    * **One GLOBAL run slot.** Self-update + rollback share it, and guerrilla
      auto-deploys on every merge — a site deploy racing the box's own
      post-merge self-update would get a bare `already_running` for a run that
      has nothing to do with it. Here the single-flight slot is **per slug**:
      two different sites deploy concurrently; the same site twice is a 409.
    * **A 500-line log ring that evicts the oldest.** A real `npm ci` prints far
      more than 500 lines, so the early `PLAN:`/`BUILD:` lines are gone before
      an orchestrator ever polls. Hence `stages` — parsed out of the engine's
      `BPSTAGE` lines and retained **separately from, and immune to,** the log
      ring. The raw log stays a bounded tail; the six stages never evict.

  ## The child's environment (charter D24)

  In BOTH paths the master encryption keys and stale ambient build vars are kept
  OUT of the build, and the per-site content binding comes only from the
  request. The mechanism differs:

    * **systemd unit.** A transient unit starts from a CLEAN environment — it
      does NOT inherit the BEAM's env, so `BARKPARK_KEK`/`BARKPARK_CLOAK_KEY`
      never reach it in the first place. The build's env is supplied by a
      per-run **0600 `EnvironmentFile`** (never `--setenv`/argv, so no secret
      lands on a `ps`-visible command line): every `BUILD_ALLOW` key SET from
      the request or simply omitted, plus `PATH` (asdf's `npm` shims) and the
      status/log file paths. The file is unlinked once the run finalizes.
    * **`Port` fallback.** `Port.open` with no `env:` gives the child the BEAM's
      FULL environment. Erlang's `env` option only ADDS/OVERRIDES; the ONLY way
      to REMOVE a var is `{~c"NAME", false}`. So `BARKPARK_KEK`/
      `BARKPARK_CLOAK_KEY` are removed with the `false` form and every
      `BUILD_ALLOW` var is set-from-request-or-removed. `PATH` is preserved.

  Both derive their KEY→value decision from the SAME `resolved_build_vars/1`
  (the allow-list is never forked).

  ## Prebuilt artifacts (charter D86/D87 — the build leaves the serving box)

  A request carrying `artifact_b64` + `artifact_sha256` is INGESTED before
  anything else runs: `Barkpark.Sites.PrebuiltArtifact` digest-verifies and
  hardened-extracts it into `<run_state_dir>/<slug>.prebuilt`, and only then is
  the site provisioned and the engine launched. A refused artifact costs
  nothing (no provision, no unit) and returns `{:error, {:artifact_rejected,
  code, message}}` — it NEVER degrades to a box build, because a box build
  passes HEALTH on genuine markers while serving bytes the caller never asked
  for. The staged dir reaches the engine as `PREBUILT_DIR` + `PREBUILT_SHA256`
  on BOTH env sinks (`resolved_prebuilt_vars/1`), and both are persisted in the
  run manifest so a re-attach after a BEAM restart still knows the run was
  prebuilt.

  ## The durable per-BUILD record (deploy-reliability D21/D22)

  The run-state files used to be keyed on the SLUG alone
  (`<slug>.log`/`.status`/`.env`), and `fresh_run_files/1` truncates them at
  every launch — so the SECOND deploy of a slug destroyed the FIRST one's build
  log. Observed live: build `caf056f10a8b6837` wrote 33,227 bytes at 23:36 and
  the same path was 0 bytes at 23:39. A site that failed 25 times kept zero of
  its 25 failures. So the log/status/env triple is now keyed on the RUN TAG —
  `<slug>-<build_id>.log` for a deploy, `<slug>-<mode>-<ms>.log` for a
  rollback/teardown (which name no build) — and a new build gets a NEW path, so
  truncating its own fresh path can never reach a sibling's. The MANIFEST stays
  `<slug>.manifest.json` on purpose: it is the "current run for this slug"
  pointer the re-attach seam and `status/1` resolve by slug, and it carries the
  per-build paths.

  A manifest is a POINTER, not a record — it has no exit code, no failure
  reason, no finished_at — so it cannot answer "what happened to build X" once
  it is overwritten or pruned. At FINALIZE (`cache_and_cleanup/4`, where the
  reconstructed render exists) a **terminal record** is written next to the log:
  `<slug>-<tag>.terminal.json`, carrying exit_code, failure_reason, the stage
  fold, `unit_name` (so a journald fallback is addressable by EXACT unit name —
  measured 0.16s, against 121s for a globbed query) and the log's path + byte
  count. It is ~1 KB and OUTLIVES the log.

  That is what makes eviction honest: `build_record/2` (and `status/1`'s
  `:log_state`) answers `:available`, `:evicted` or `:never_recorded` as three
  DIFFERENT answers. Before this, a pruned deployment and a slug that had never
  deployed returned byte-identical maps. Retention is bounded three ways —
  total bytes, count, and age, each configurable — whichever bites first, and
  `retention_sweep/0` REPORTS which cap was effective.

  ## The run-state dir census (dr-w23)

  Retention here is SUFFIX-keyed: `.manifest.json`, `.log` and `.terminal.json`
  each have a sweep that can name their records from the directory listing
  alone. Everything else a run leaves behind — `<slug>-<tag>.status`,
  `<slug>-<tag>.env`, `<slug>.prebuilt/` and a crashed extraction's
  `<slug>.prebuilt.staging-N/` — is named ONLY inside a manifest, and the
  manifest is slug-keyed while those files are tag-keyed, so the next deploy of
  the same slug overwrote the only pointer to them and nothing could ever
  delete them again. `prune_orphan_run_files/1` bounds exactly that set (no
  manifest names it, and it has sat longer than `orphan_grace_ms`), and the
  full record-by-record census with each record's stated bound sits above that
  function. `serving-memory.json` is the one record ruled intentionally
  unswept: it has a FIXED name, so it is bounded at one by construction.

  This slice keeps the record on the BOX. No raw log bytes are exposed over
  HTTP here: the build env file carries `BARKPARK_TOKEN=` in plaintext and the
  display scrubber does not yet know that shape, so the read path ships after
  the scrubber does.

  ## Fail-closed

  Always supervised (an idle GenServer is free), but every trigger is gated by
  `enabled?/0`, which ships OFF in config.exs and is only flipped on in prod by
  `BARKPARK_SITE_DEPLOY_APPLY=1`. With the defaults this process can execute
  nothing at all, and the admin endpoint degrades to a clean 503.

  Never-crash contract: `trigger/1` and `status/1` never raise — a dead or
  unanswering process degrades to `{:error, :runner_unavailable}` (its OWN
  value: a wedged Runner is not an unset flag, and the door must never say it
  is) / an idle status map, and a command that
  cannot start, dies abnormally, or outlives the deadline lands as a `:done`
  state with a non-zero exit code and an honest `failure_reason`.
  """

  use GenServer

  require Logger

  alias Barkpark.Sites.DeployRequest
  alias Barkpark.Sites.PrebuiltArtifact
  alias Barkpark.Sites.Provisioner

  @default_command {"bash", ["deploy/site-deploy.sh"]}
  @default_rollback_command {"bash", ["deploy/site-deploy.sh", "--rollback"]}
  # The node-slot SSR runtime target (charter D63): the SAME 6-stage state
  # machine, but the artifact is a long-running node process, so it drives a
  # SEPARATE engine script (`deploy/site-deploy-node.sh`) that boots + health-
  # probes + Caddy-upstream-flips a node port instead of swapping a symlink.
  @default_node_command {"bash", ["deploy/site-deploy-node.sh"]}
  @default_node_rollback_command {"bash", ["deploy/site-deploy-node.sh", "--rollback"]}
  # Teardown (the inverse of a spawn): disarm the Caddy route + delete the tree
  # (node also stops the slots). The engine emits no BPSTAGE — success is a
  # `TORN_DOWN=<slug>` line in the durable log, finalized like a rollback.
  @default_teardown_command {"bash", ["deploy/site-deploy.sh", "--teardown"]}
  @default_node_teardown_command {"bash", ["deploy/site-deploy-node.sh", "--teardown"]}

  # The transient-unit launcher + the status/liveness probes. All config-
  # injectable so a test on a systemd-less host can stub the whole path.
  @default_systemd_run {"systemd-run", []}
  @default_is_active {"systemctl", ["is-active"]}
  @default_systemctl_stop {"systemctl", ["stop"]}
  # Per-unit resource caps on the SIBLING cgroup (the inner `systemd-run --scope`
  # build cap is retired — stw6-engine-file-contract; the OUTER unit carries it).
  @default_memory_max "1500M"
  @default_cpu_quota "150%"

  @default_max_log_lines 500
  # 30 min — an `npm ci` + build on a small box, with headroom. A run that
  # outlives it is force-closed so a wedged unit/port can't hold the slug's slot
  # until the next BEAM restart.
  @default_run_deadline_ms 1_800_000

  # Hard deadline for a SYNCHRONOUS control-plane `System.cmd` (systemd-run,
  # `systemctl is-active`, `systemctl stop`). These run INSIDE the singleton
  # GenServer — a hung systemd/systemctl (a wedged unit, a stuck D-Bus) would
  # freeze {:trigger}/{:status} for every slug, and the {:unit_deadline}
  # watchdog's own stop cannot be rescued by safe_call. 15s is generous for a
  # local systemctl round-trip; a call that outlives it is force-killed and its
  # caller degrades (never crashes). Distinct from @default_run_deadline_ms,
  # which bounds the BUILD, not the ctl call that launches/reaps it.
  @default_ctl_cmd_timeout_ms 15_000

  # How long a caller waits for the DOOR to answer `{:trigger, req}`.
  #
  # This used to be `GenServer.call/2`'s unstated 5_000ms default, which is
  # indefensible next to @default_ctl_cmd_timeout_ms above: the trigger's own
  # critical section may run a systemctl round-trip that is ALLOWED to take 15s,
  # so the caller's budget was shorter than the work it was waiting for. When it
  # blew, `safe_call/3` converted the exit into `{:error, :disabled}` and the
  # endpoint told the operator to set a flag that was already set — while the
  # build it had just accepted ran to completion behind the lie (dr-w8-s2).
  #
  # 30s is ctl timeout + spawn grace + slack: a trigger that outlives THIS is a
  # wedged Runner, not a slow one, and now says so in its own words.
  @trigger_call_timeout_ms 30_000

  # How long a caller waits for the door to answer `{:status, slug}`.
  #
  # Same defect class as the trigger's old 5_000ms, on the read the operator
  # trusts MOST: `{:status, slug}` may run a `systemctl is-active` round-trip
  # that is ALLOWED to take @default_ctl_cmd_timeout_ms (15s), so a 5_000ms
  # caller budget was shorter than the work it waited for — and `safe_call/3`
  # then served `idle_status/1`, i.e. a wedged Runner reported `state: :idle`,
  # byte-identical to "this slug has never run". A false NEGATIVE on the exact
  # read a control plane polls to decide a deploy finished.
  #
  # 20s is the ctl budget plus slack: a status that outlives THIS is a wedged
  # Runner, and `unreachable_status/1` now says `:unknown` instead of `:idle`.
  @status_call_timeout_ms 20_000

  # After a launch, systemd may report the unit `inactive` for a beat before it
  # transitions to `active`. Do NOT serve `:done` off an empty fold inside this
  # grace — an observer that flickers to done between spawn and start would race
  # the CP into a false failure.
  @spawn_grace_ms 3_000

  # Finished runs stay queryable (the orchestrator polls AFTER the exit), but not
  # forever — keep the newest N slugs, evicting finished ones first.
  #
  # NOTE this counts SLUGS, not deployments: manifests are `<slug>.manifest.json`
  # (one per slug, overwritten), so on a 16-site box `length(manifests) > 32` is
  # unreachable and this cap has never evicted anything in production. The caps
  # that actually bound the box are the three BUILD-LOG caps below, which count
  # DEPLOYMENTS.
  @max_tracked_runs 32

  # ── durable per-build log retention (deploy-reliability D21/D23) ───────────
  #
  # Three INDEPENDENT caps, whichever bites first, each config-injectable:
  # bytes, count, age. Sized against this box's real rate (9,495 distinct build
  # units in 8.74 days ≈ 1,000 builds/day) and a real Next build log (the one
  # recovered off the box is 30,993 bytes): 1,000/day × ~30 KB ≈ 30 MB/day, so
  # 256 MiB / 2,000 logs / 7 days all land in the same neighbourhood — no single
  # cap silently does all the work, and whichever one bites is REPORTED.
  @default_max_build_log_bytes 268_435_456
  @default_max_build_logs 2_000
  @default_max_build_log_age_ms 604_800_000

  # Terminal records are ~1 KB and must OUTLIVE the logs they describe — that is
  # the whole point of a tombstone — so they are bounded far more loosely, by
  # count only.
  @default_max_terminal_records 10_000

  # How long an UNREFERENCED run-state entry must sit before the orphan sweep
  # takes it. The window exists because a launch writes its files BEFORE it
  # writes the manifest that names them (`launch_unit/2`): a sweep racing that
  # gap must not delete the run it is about to be told about. An hour is ~14,000
  # times that gap and still bounds a 1,000-builds/day dir.
  @default_orphan_grace_ms 3_600_000

  @typedoc """
  Why a build's raw log can (or cannot) be read — four DIFFERENT answers where
  there used to be one. `:available` the bytes are on the box; `:evicted`
  retention removed them and a terminal record survives to say so; `:missing` a
  record exists but its log never appeared (the unit died before writing);
  `:never_recorded` nothing was ever written for this deployment at all;
  `:unknown` NOTHING WAS READ — the Runner did not answer, so this says nothing
  about the bytes either way (see `status/1`'s degraded answer).
  """
  @type log_state :: :available | :evicted | :missing | :never_recorded | :unknown
  # How many trailing meaningful lines a failure_reason carries. The engine's own
  # "BUILD failed …" line is usually last; the REAL cause (npm's 401, the HEALTH
  # marker miss) is the line or two above it.
  @reason_lines 3

  # `BPSTAGE name=<STAGE> status=<STATUS> build_id=<ID> [detail="…"]` — emitted by
  # the engine at every state-machine boundary, to stdout AND (when the transient
  # unit sets it) appended to the durable status file. Both fields are whitelisted
  # below; a line that does not match is just log.
  #
  # `detail` is the REASON and it is load-bearing: the engine hangs npm's real
  # error (`FATAL: 401 Unauthorized …`) and HEALTH's marker miss off the terminal
  # stage line, and the control plane + `bp cloud site` render it as the failed
  # stage's message. Dropping it here does not fail loudly — it silently degrades
  # every failure to a canned "the build failed", which is precisely the dishonest
  # status this seam exists to prevent. build_id is `\S*` (not `\S+`) because the
  # engine emits `build_id=` empty on a PLAN that has not resolved one yet; `\S+`
  # would refuse the empty value and then swallow the detail with it.
  @stage_re ~r/\bBPSTAGE\s+name=([A-Za-z_]+)\s+status=([a-z]+)(?:\s+build_id=(\S*))?(?:\s+detail="([^"]*)")?/
  @stage_names ~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE)
  @stage_statuses ~w(started ok skipped noop failed)

  # THE SERVED-SLOT MARKER (site-spawner: node slot truth). The node engine
  # emits, AFTER its Caddy flip has committed and reloaded, one report-only line
  #
  #     BPSTAGE name=SERVED status=ok build_id=<id> detail="port=<n|none> slot=<a|b|none>"
  #
  # whose values it READ BACK out of the Caddyfile marker block — i.e. what Caddy
  # is actually proxying, not the TARGET_SLOT the run intended. SERVED is not in
  # @stage_names above, so `parse_stage_line/2` skips it and it can never reach
  # `stage_exit_code/1`: it is a measurement, never a verdict.
  #
  # Its own regex rather than a widened @stage_re, for exactly that separation —
  # and `none` is matched as a VALUE, not treated as a parse failure, because
  # "Caddy names no upstream for this site" is a thing the box learned, not a
  # thing it failed to say.
  @served_re ~r/\bBPSTAGE\s+name=SERVED\s+status=ok(?:\s+build_id=\S*)?\s+detail="port=([^\s"]+)\s+slot=([^\s"]+)"/

  # The two node slot names the engine uses for a site's blue/green pair. Anything
  # else (including the literal `none` the engine emits when the Caddy read
  # matched neither of this site's ports) is reported as nil — an honest "not
  # known", never a guess at which half is serving.
  @served_slots ~w(a b)

  # systemctl is-active states that mean the build is STILL running. Everything
  # else (inactive / failed / deactivating / unknown / "") is terminal or gone.
  @active_states ~w(active activating reloading)

  # ── the box's build-slot door ────────────────────────────────────────────
  #
  # The engine serializes BUILDS across the whole box on ONE fleet build slot
  # (`BUILD_GATE_SLOTS=1` in deploy/lib/site-deploy-common.sh, forced by the
  # unit's CPUQuota=150% / MemoryMax=1500M). Until this door existed the box
  # answered every trigger 202 and the engine only met that gate LATER, inside
  # the unit — so a second site's unit sat `active running` parked in
  # `flock -w 900`, burning its 30-minute deadline while it waited, and an
  # operator read a queue as a hang.
  #
  # This is an EARLY HONEST REFUSAL, never the barrier. `build_gate_acquire`
  # FAILS OPEN in three named cases (no flock(1), an undeletable lock dir, an
  # unopenable lock file) and in every one of them nothing is written to
  # /proc/locks, so a door that trusted the lock alone would read "free"
  # forever. The in-engine flock — including its 900s wait — stays exactly as
  # it is, as the last-resort correctness barrier.
  @build_slot_capacity 1

  # ── the door's census (deploy-reliability D8) ────────────────────────────
  #
  # `@build_slot_capacity` is a CONSTANT: it has no ignorance to report and no
  # worse value to reach, so a box that renders only it can never say the door
  # is saturated, or that it refused anybody. The one real measurement in this
  # module — `length(building_slugs(state))` — was computed at the refusal site
  # and thrown into an English log line. This table keeps it.
  #
  # It is an ETS table and NOT a `GenServer.call` on purpose. The reader is
  # `GET /v1/instance/site-deploy`, whose entire justification is that it still
  # answers when the Runner is WEDGED (D113) — a census that called the Runner
  # would re-import the bug it exists to report. The Runner is the only writer;
  # readers take no lock and cannot block.
  #
  # The table is owned by the Runner process, so a Runner crash takes the
  # counters with it and the next `init/1` mints a FRESH `refusals_since`. That
  # is why the count is never rendered bare: a total without its window is a
  # number nobody can check.
  @census_table :barkpark_site_deploy_door_census

  # How often the census is refreshed on its own, on top of the writes at every
  # trigger and every run completion. The backstop exists for the state changes
  # this BEAM does not get a message for: a transient systemd unit that finishes
  # outside the Runner's view stays counted as in-flight until something looks.
  @default_census_interval_ms 10_000

  # The lock the engine actually takes. NOT /run/lock. `build_gate_acquire`
  # resolves it as $BARKPARK_BUILD_GATE_LOCK, else this path, else
  # ${TMPDIR:-/tmp}/barkpark-site-build.lock when the lock dir cannot be made —
  # so the door reads EVERY path the engine could have picked. Keying on one
  # hardcoded path would miss a box whose /var/lock is unwritable, which is
  # precisely the box that needs the door most.
  @default_build_gate_lock "/var/lock/barkpark-site-build.lock"
  @build_gate_lock_basename "barkpark-site-build.lock"
  @default_proc_locks "/proc/locks"

  # The box's master encryption keys — REMOVED from the Port child (see moduledoc).
  @scrub_env ~w(BARKPARK_KEK BARKPARK_CLOAK_KEY)
  # Set-from-request-or-remove. Superset of DeployRequest.allowed_env_keys/0: the
  # engine derives BARKPARK_BUILD_ID / BARKPARK_CONTENT_REV itself from BUILD_ID /
  # CONTENT_REV, but they are in its BUILD_ALLOW list, so an ambient value could
  # still shadow — remove them too and let the engine set them.
  @build_env_keys DeployRequest.allowed_env_keys() ++
                    ~w(BARKPARK_BUILD_ID BARKPARK_CONTENT_REV)

  # ── public API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Whether site deploys may execute on this instance. Fail-closed: config.exs
  ships `enabled: false`; prod's runtime.exs flips it on only when
  `BARKPARK_SITE_DEPLOY_APPLY=1`.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false) == true

  @doc "The `Barkpark.Sites.DeployRunner` config keyword list (see config.exs)."
  @spec config() :: keyword()
  def config, do: Application.get_env(:barkpark, __MODULE__, [])

  @doc """
  Start a site deploy (or rollback) for a VALIDATED request. Single-flight PER
  SLUG — a second run for the same slug while one is in flight returns
  `{:error, :already_running}`. Never raises.

  A DIFFERENT slug proceeds only while the box still has a free fleet build
  slot: `mode: :deploy` is refused with `{:error, :box_at_capacity}` when a
  build is already in flight (see `build_slot_capacity/0`), because the engine
  would otherwise queue that build inside its unit for up to 900s and read as a
  hang. `:rollback` and `:teardown` never touch the build gate and are never
  refused by it.

  The refusal atom carries no detail — WHICH slug holds the slot, and whether
  the holder is a peer build or a foreign one, are recorded at the refusal site
  and read back through `last_refusal/0`.
  """
  @spec trigger(DeployRequest.t()) ::
          {:ok, :started}
          | {:error,
             :already_running | :box_at_capacity | :disabled | :runner_unavailable | :start_failed}
          | {:error, {:artifact_rejected, String.t(), String.t()}}
          | {:error, {:provision_failed, String.t()}}
  def trigger(%DeployRequest{} = req),
    do:
      safe_call({:trigger, req}, {:error, :runner_unavailable},
        timeout: trigger_call_timeout_ms()
      )

  @doc """
  The DURABLE per-deployment record for one build — the answer to "what
  happened to build X", readable long after the slug has deployed again.

  Reads the box's run-state dir directly (no GenServer call, so a wedged Runner
  cannot hide a finished build's outcome) and NEVER raises. `build_id` is the
  deploy's own id; pass `nil` for the newest record of that slug.

  `:log_state` is the honest part (see `t:log_state/0`): a deployment whose log
  was EVICTED by retention answers `:evicted` and still carries its exit_code,
  failure_reason, stage fold and `unit_name`; a deployment that was never
  recorded answers `:never_recorded` and carries nothing. Those used to be the
  same map.

  `:log_path` is a path ON THE BOX. The bytes are deliberately NOT returned —
  they carry the build env's plaintext `BARKPARK_TOKEN` and no scrubber on this
  box is trusted with that shape yet.
  """
  @spec build_record(String.t(), String.t() | nil) :: map()
  def build_record(slug, build_id \\ nil) when is_binary(slug) do
    case find_terminal_record(slug, build_id) do
      nil -> absent_record(slug, build_id)
      record -> render_terminal_record(record)
    end
  rescue
    _ -> absent_record(slug, build_id)
  end

  @doc """
  Every durable build record on this box, newest finish first, optionally
  narrowed to one slug. Never raises.
  """
  @spec build_records(String.t() | nil) :: [map()]
  def build_records(slug \\ nil) do
    run_state_dir()
    |> list_terminal_records()
    |> Enum.filter(&(is_nil(slug) or &1["slug"] == slug))
    |> Enum.sort_by(& &1["finished_at"], :desc)
    |> Enum.map(&render_terminal_record/1)
  rescue
    _ -> []
  end

  @doc """
  Enforce the three retention caps on the durable build logs NOW and report the
  result — which cap was EFFECTIVE (`:bytes` | `:count` | `:age` | `:none`),
  how many logs each cap condemned, what survives, and the caps themselves.

  Every evicted log leaves a tombstone behind: an existing terminal record is
  marked `log_state: :evicted`, and a log with no record at all gets a minimal
  one, so an evicted deployment can never read back as "never recorded".
  Called on every launch and on re-attach; public so ops (and the eviction
  tests, which must drive PAST each cap) can fire it deliberately.

  Also runs the ORPHAN sweep and reports it under `:orphans` — see the run-state
  census on `prune_orphan_run_files/1`. The three suffix sweeps
  (`.manifest.json` / `.log` / `.terminal.json`) each bound a record they can
  NAME; the orphan sweep is what bounds the per-run files whose only name lived
  in a manifest that has since been overwritten.
  """
  @spec retention_sweep() :: map()
  def retention_sweep do
    dir = run_state_dir()
    dir |> prune_build_logs() |> Map.put(:orphans, prune_orphan_run_files(dir))
  end

  @doc "The three configured build-log retention caps."
  @spec retention_caps() :: map()
  def retention_caps do
    %{
      max_bytes: Keyword.get(config(), :max_build_log_bytes, @default_max_build_log_bytes),
      max_logs: Keyword.get(config(), :max_build_logs, @default_max_build_logs),
      max_age_ms: Keyword.get(config(), :max_build_log_age_ms, @default_max_build_log_age_ms),
      max_terminal_records:
        Keyword.get(config(), :max_terminal_records, @default_max_terminal_records),
      orphan_grace_ms: Keyword.get(config(), :orphan_grace_ms, @default_orphan_grace_ms)
    }
  end

  @doc """
  The run status for `slug`: `state` (`:idle` | `:running` | `:done` |
  `:unknown`), the parsed
  `stages` (never evicted), `exit_code`, an honest `failure_reason`, the bounded
  `log` tail (oldest line first), and timestamps. A slug that has never run
  reports `:idle`. On a systemd box the status is RECONSTRUCTED from the transient
  unit's durable status + log files, so it survives a BEAM restart. Never raises.

  A Runner that does not answer inside `status_call_timeout_ms/0` does NOT get
  reported as idle — the degraded answer is `state: :unknown` with a
  `failure_reason` naming the unanswered call (`unreachable_status/1`). "I could
  not read this" and "this slug has never run" used to be the same map.
  """
  @spec status(String.t()) :: map()
  def status(slug) when is_binary(slug),
    do: safe_call({:status, slug}, unreachable_status(slug), timeout: status_call_timeout_ms())

  @doc "Whether a run for `slug` is currently in flight."
  @spec running?(String.t()) :: boolean()
  def running?(slug) when is_binary(slug), do: match?(%{state: :running}, status(slug))

  # `fallback` is what a caller gets when the Runner cannot answer at all —
  # never crashed into, never confused with an answer the Runner GAVE.
  #
  # `:timeout` is MANDATORY (dr-w15-s1): there is no implicit budget any more.
  # The silent 5_000ms default this used to carry is what let `status/1` serve
  # `idle_status/1` for a Runner that was merely wedged, so the number is now a
  # decision each caller has to make and a test can pin.
  defp safe_call(msg, fallback, opts) do
    timeout = Keyword.fetch!(opts, :timeout)

    case Process.whereis(__MODULE__) do
      nil ->
        fallback

      pid ->
        try do
          GenServer.call(pid, msg, timeout)
        catch
          # Runner died between whereis and call (or timed out) — degrade, never
          # propagate the exit to the caller.
          :exit, _reason -> fallback
        end
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Ports (fallback path) are linked to this process; trap so an abnormal port
    # death becomes a :done run instead of taking the Runner (and every other
    # slug) down.
    Process.flag(:trap_exit, true)
    ensure_census_table()
    schedule_census_tick()
    state = %{runs: %{}, ports: %{}, units: %{}, timers: %{}}
    {:ok, publish_census(reattach_units(state))}
  end

  @impl true
  def handle_call({:trigger, %DeployRequest{} = req}, _from, state) do
    # The census is republished on EVERY reply — including the refusals — so the
    # numbers the door reports move at the moment the door moves, not one tick
    # later.
    {:reply, reply, state} =
      cond do
        not enabled?() ->
          {:reply, {:error, :disabled}, state}

        true ->
          state = drop_stale(state, req.slug)

          cond do
            running_slug?(state, req.slug) ->
              {:reply, {:error, :already_running}, state}

            # THE DOOR. This is one serialized GenServer critical section:
            # drop_stale → running_slug? → box_at_capacity? → start_run all run
            # without interleaving, so two concurrent triggers can NEVER both
            # observe a free slot. The census touches no lock, so — unlike a
            # `flock -n` probe — it cannot steal one from a unit already blocked
            # in `flock -w 900`, and it cannot leak an inherited fd that would
            # hold the box's only build slot with no reaper.
            #
            # It sits BEFORE start_run/2 deliberately (charter D86/D87): a
            # refused deploy must cost nothing, and start_run's first act is
            # ingest_prebuilt/1, which extracts the caller's artifact to disk.
            box_at_capacity?(state, req) ->
              {:reply, {:error, :box_at_capacity}, state}

            true ->
              start_run(state, req)
          end
      end

    {:reply, reply, publish_census(state)}
  end

  # A SYNCHRONOUS census refresh — for a caller that needs the numbers as of NOW
  # rather than as of the last door event or tick. The HTTP reader deliberately
  # does NOT use this; see `door_census/0`.
  def handle_call(:refresh_door_census, _from, state) do
    state = publish_census(state)
    {:reply, door_census(), state}
  end

  def handle_call({:status, slug}, _from, state) do
    cond do
      # A live Port-mode run, or a cached finalized systemd render.
      Map.has_key?(state.runs, slug) ->
        {:reply, render_run(Map.fetch!(state.runs, slug)), state}

      # A tracked in-flight unit — reconstruct from its durable files.
      Map.has_key?(state.units, slug) ->
        observe_unit(state, slug)

      # No live tracking, but a manifest may survive on disk (a terminal run, or
      # one this process never launched — e.g. straight after a restart).
      manifest = load_manifest_for(slug) ->
        finalize_from_disk(state, manifest)

      # The manifest is gone (retention pruned it, or a newer slug-keyed one was
      # overwritten) but a TERMINAL RECORD survives. Answering `:idle` here is
      # the lie this slice removes: the deployment DID happen and we know how it
      # ended. Serve the record — `:done`, its exit code, its reason, and a
      # `log_state` that says whether the bytes still exist.
      record = load_latest_terminal_record(slug) ->
        {:reply, status_from_record(record), state}

      true ->
        {:reply, idle_status(slug), state}
    end
  end

  # ── Port-mode async messages (fallback path only) ────────────────────────

  @impl true
  def handle_info({port, {:data, {_eol_or_noeol, line}}}, state) do
    {:noreply, update_run(state, port, &ingest_line(&1, line))}
  end

  def handle_info({port, {:exit_status, code}}, state) do
    {:noreply,
     state
     |> update_run(port, &finish_run(&1, code))
     |> release_port(port)
     |> publish_census()}
  end

  # Abnormal port death without an exit_status — record a failure, never crash.
  def handle_info({:EXIT, port, reason}, state) when is_port(port) do
    if Map.has_key?(state.ports, port) do
      {:noreply,
       state
       |> update_run(port, fn run ->
         run
         |> ingest_line("[runner] deploy port closed: #{inspect(reason)}")
         |> finish_run(-1)
       end)
       |> release_port(port)
       |> publish_census()}
    else
      {:noreply, state}
    end
  end

  # Deadline watchdog for a Port-mode run that is STILL live on this port. A stale
  # deadline from an already-finished run finds no port entry and falls through.
  def handle_info({:run_deadline, port}, state) do
    if Map.has_key?(state.ports, port) do
      _ = close_port(port)
      ms = run_deadline_ms()

      {:noreply,
       state
       |> update_run(port, fn run ->
         run
         |> ingest_line("[runner] run exceeded #{ms}ms deadline — force-closed")
         |> finish_run(-2)
       end)
       |> release_port(port)
       |> publish_census()}
    else
      {:noreply, state}
    end
  end

  # Deadline watchdog for a systemd transient unit. If the unit is still alive,
  # stop it and finalize a `:done` run with the deadline reason so the slug's slot
  # can never wedge until the next restart.
  def handle_info({:unit_deadline, slug}, state) do
    case Map.fetch(state.units, slug) do
      {:ok, manifest} ->
        _ = systemctl_stop(manifest.unit_name)
        ms = run_deadline_ms()

        render =
          manifest
          |> reconstruct(:terminal)
          |> Map.merge(%{
            state: :done,
            exit_code: -2,
            failure_reason: exit_label(-2) <> " (#{ms}ms)"
          })

        {:noreply, publish_census(cache_and_cleanup(state, slug, manifest, render))}

      :error ->
        {:noreply, state}
    end
  end

  # The census backstop. Every door event republishes synchronously; this tick
  # covers the state changes nothing sends this BEAM a message about — chiefly a
  # transient systemd unit that finished outside the Runner's view, which would
  # otherwise read as in-flight until the next trigger.
  def handle_info(:census_tick, state) do
    schedule_census_tick()
    {:noreply, publish_census(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── run lifecycle ───────────────────────────────────────────────────────

  # Per-slug single-flight. Port mode: a live in-memory run. systemd mode: a
  # tracked unit that `systemctl is-active` still reports running.
  defp running_slug?(state, slug) do
    cond do
      match?({:ok, %{state: :running}}, Map.fetch(state.runs, slug)) -> true
      match?({:ok, _}, Map.fetch(state.units, slug)) -> unit_running?(state, slug)
      true -> false
    end
  end

  defp unit_running?(state, slug) do
    case Map.fetch(state.units, slug) do
      {:ok, manifest} -> is_active(manifest.unit_name) in @active_states
      :error -> false
    end
  end

  # A finished/terminal record for this slug must not block a fresh trigger: drop
  # any cached render, and drop a tracked unit that is no longer active (freeing
  # the single-flight slot + its deadline timer + its secret env file).
  defp drop_stale(state, slug) do
    state =
      case Map.fetch(state.runs, slug) do
        {:ok, %{state: :running}} -> state
        {:ok, _finished} -> %{state | runs: Map.delete(state.runs, slug)}
        :error -> state
      end

    case Map.fetch(state.units, slug) do
      {:ok, manifest} ->
        if is_active(manifest.unit_name) in @active_states do
          state
        else
          _ = unlink_env(manifest)
          cancel_timer(state, slug) |> Map.update!(:units, &Map.delete(&1, slug))
        end

      :error ->
        state
    end
  end

  # ── the box's build-slot door (see the @build_slot_capacity note) ────────

  @doc """
  How many builds this box will run at once — the DOOR's mirror of the engine's
  `BUILD_GATE_SLOTS`, which is forced to 1 by the build unit's CPUQuota=150% /
  MemoryMax=1500M. Deliberately not operator-tunable from a control-plane
  deploy: raising it here without raising the unit's resource caps is how a box
  swaps itself to death.
  """
  @spec build_slot_capacity() :: pos_integer()
  def build_slot_capacity, do: @build_slot_capacity

  @typedoc """
  What the door knows about itself. `capacity` is the CONSTANT
  `@build_slot_capacity`; everything else is a MEASUREMENT, and every
  measurement can be `nil` — which means NOTHING WAS READ (the Runner has never
  booted in this BEAM, or it crashed and took its table with it), never "zero".
  """
  @type door_census :: %{
          capacity: pos_integer(),
          observed_in_flight: non_neg_integer() | nil,
          in_flight_slugs: [String.t()] | nil,
          refusals_total: non_neg_integer() | nil,
          refusals_since: DateTime.t() | nil,
          door_open_admissions_total: non_neg_integer() | nil,
          door_open_admissions: %{String.t() => non_neg_integer()} | nil,
          measured_at: DateTime.t() | nil
        }

  @typedoc """
  WHY the last refusal happened, kept beside the count so a 409 can name the
  holder instead of saying "another site". `holder` is `:peer` (a build THIS
  instance launched and tracks — normal contention) or `:foreign` (an FLOCK
  entry on the fleet build lock that this instance did not launch — a hand-run
  engine, or a unit that outlived a previous BEAM, and operator-actionable).
  `slug` is the slug that was REFUSED, so a reader can tell whether the record
  is about its own request or a newer one that overwrote it.
  """
  @type refusal_detail :: %{
          slug: String.t(),
          holder: :peer | :foreign,
          in_flight_slugs: [String.t()],
          slots_in_use: non_neg_integer(),
          capacity: pos_integer(),
          holder_lock: String.t() | nil,
          at: DateTime.t()
        }

  @doc """
  What the box's build-slot door is actually doing — as opposed to
  `build_slot_capacity/0`, which is a compile-time constant and therefore
  cannot report saturation, refusals, or its own ignorance.

  Five facts, each a real measurement:

    * `observed_in_flight` / `in_flight_slugs` — `building_slugs(state)`, the
      SAME census `box_at_capacity?/2` admits or refuses on. Before this it was
      computed at the refusal site and interpolated into an English log line;
      nothing kept it.
    * `refusals_total` — how many deploys this door has turned away, counted at
      the refusal itself. Guerrilla's door refused 1,810 times in ~34h and the
      box could not state that number about itself.
    * `refusals_since` — when that counter started, i.e. the current Runner's
      start. The count is USELESS without it and must never be rendered alone:
      the table is owned by the Runner, so a crash resets both together and a
      reader that saw only a small total would misread a fresh window as a quiet
      door.
    * `door_open_admissions_total` / `door_open_admissions` — the OTHER half of
      the door's story: builds it let through WITHOUT a second opinion because
      its evidence was missing (no `/proc/locks`, an unreadable `/proc/locks`, a
      lock file it could not stat). The door fails open on purpose; before this
      it failed open SILENTLY, so the one number that bounds the leak did not
      exist. Keyed by reason so the dev-box case (`no_proc_locks`, expected and
      uninteresting) never hides the operator case.

  Reads take NO lock and make NO `GenServer.call`. That is the point: the one
  HTTP reader of this exists to describe a box whose Runner may be WEDGED
  (D113), and a census that called the Runner would hang exactly when it
  mattered. The cost is staleness, which is why `measured_at` is rendered too —
  every value here is "as of" that instant, not "as of now".
  """
  @spec door_census() :: door_census()
  def door_census do
    %{
      capacity: build_slot_capacity(),
      observed_in_flight: census_get(:observed_in_flight),
      in_flight_slugs: census_get(:in_flight_slugs),
      refusals_total: census_get(:refusals_total),
      refusals_since: census_get(:refusals_since),
      door_open_admissions_total: census_get(:door_open_admissions_total),
      door_open_admissions: census_get(:door_open_admissions),
      measured_at: census_get(:measured_at)
    }
  end

  @doc """
  The LAST refusal this door made, or `nil` when it has never refused in this
  BEAM (or its table is gone).

  This exists because `trigger/1` answers `{:error, :box_at_capacity}` — a bare
  atom that cannot carry WHICH slug holds the slot, and cannot separate a peer
  build from a foreign one. Both facts are known at the refusal site and were
  previously interpolated into a log line and dropped. The record is keyed by
  the REFUSED slug on purpose: a reader that does not recognise the slug has
  been overtaken by a newer refusal and must fall back to the generic message
  rather than name the wrong site.
  """
  @spec last_refusal() :: refusal_detail() | nil
  def last_refusal, do: census_get(:last_refusal)

  @doc """
  Recompute the census SYNCHRONOUSLY inside the Runner and return it. Degrades
  to the ETS reading (never blocks past `timeout`) when the Runner cannot
  answer, on the same `safe_call/3` seam as `status/1`.
  """
  @spec refresh_door_census(keyword()) :: door_census()
  def refresh_door_census(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1_000)
    safe_call(:refresh_door_census, door_census(), timeout: timeout)
  end

  # Owned by the Runner process, so its lifetime IS the counter's window — see
  # `refusals_since`. `:public` because the writer is the Runner and the readers
  # are web request processes.
  defp ensure_census_table do
    case :ets.whereis(@census_table) do
      :undefined ->
        :ets.new(@census_table, [:named_table, :public, :set, read_concurrency: true])
        :ets.insert(@census_table, {:refusals_total, 0})
        :ets.insert(@census_table, {:refusals_since, DateTime.utc_now()})
        :ets.insert(@census_table, {:door_open_admissions_total, 0})
        :ets.insert(@census_table, {:door_open_admissions, %{}})
        :ok

      _tid ->
        # A previous Runner in this BEAM already owns it (test restarts). Keep
        # its window rather than silently resetting the count to zero.
        :ok
    end
  end

  defp schedule_census_tick do
    Process.send_after(self(), :census_tick, census_interval_ms())
  end

  defp census_interval_ms do
    case Keyword.get(config(), :census_interval_ms, @default_census_interval_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_census_interval_ms
    end
  end

  # The ONE place the real concurrency number is kept instead of being thrown
  # into a log line.
  defp publish_census(state) do
    in_flight = Enum.sort(building_slugs(state))

    census_write([
      {:observed_in_flight, length(in_flight)},
      {:in_flight_slugs, in_flight},
      {:measured_at, DateTime.utc_now()}
    ])

    state
  end

  # Counted AT the refusal, in the same breath as the log line that announces
  # it — so the count cannot drift from the thing it counts.
  defp note_refusal(%{} = detail) do
    census_write([{:last_refusal, detail}])

    try do
      :ets.update_counter(@census_table, :refusals_total, 1)
    rescue
      # No table (no Runner in this BEAM) — nothing to count on, and a refusal
      # is never worth crashing the door over.
      ArgumentError -> :no_table
    end
  end

  # An ADMISSION the door could not justify. The door fails OPEN by design (a
  # box with no /proc/locks, an unreadable /proc/locks, a lock file that cannot
  # be stat'd) — every one of those is a build that got in WITHOUT a second
  # opinion, and until now none of them left a trace. Counted by reason, beside
  # `refusals_total`, so the leak the refusals hide is measurable at last.
  defp note_door_open(reason) when is_atom(reason) do
    key = Atom.to_string(reason)

    try do
      total = :ets.update_counter(@census_table, :door_open_admissions_total, 1)

      by_reason =
        case :ets.lookup(@census_table, :door_open_admissions) do
          [{:door_open_admissions, %{} = map}] -> map
          _ -> %{}
        end

      :ets.insert(
        @census_table,
        {:door_open_admissions, Map.update(by_reason, key, 1, &(&1 + 1))}
      )

      total
    rescue
      ArgumentError -> :no_table
    end
  end

  defp census_write(rows) do
    try do
      :ets.insert(@census_table, rows)
    rescue
      ArgumentError -> false
    end
  end

  defp census_get(key) do
    case :ets.lookup(@census_table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Every path the engine's `build_gate_acquire` could have resolved the fleet
  build lock to, in its own order: `$BARKPARK_BUILD_GATE_LOCK`, else
  `/var/lock/barkpark-site-build.lock`, else the `${TMPDIR:-/tmp}` fallback it
  falls back to when the lock dir cannot be created. The door reads ALL of them
  — on the box whose /var/lock is unwritable, the tmp path IS the real lock.
  """
  @spec build_gate_lock_candidates() :: [String.t()]
  def build_gate_lock_candidates do
    primary =
      env_or_nil("BARKPARK_BUILD_GATE_LOCK") ||
        Keyword.get(config(), :build_gate_lock) ||
        @default_build_gate_lock

    tmp_dir = env_or_nil("TMPDIR") || "/tmp"

    Enum.uniq([primary, Path.join(tmp_dir, @build_gate_lock_basename)])
  end

  @doc """
  The `MAJ:MIN:INO` triple `/proc/locks` prints for a file — hex major, hex
  minor (both `%02x`, the kernel's own format), decimal inode — derived from
  `File.stat/2`'s `st_dev` + inode. `:error` when the file cannot be stat'd,
  which INCLUDES the ordinary "no build has ever run on this box" case.

  Pure enough to unit-test: the door's whole foreign-holder read is this plus
  `flock_held?/2`.
  """
  @spec lock_triple(String.t()) :: {:ok, String.t()} | :error
  def lock_triple(path) do
    case lock_triple_status(path) do
      {:ok, triple} -> {:ok, triple}
      _ -> :error
    end
  end

  # `lock_triple/1` with the two `:error` cases KEPT APART: `:absent` is
  # conclusive (no file, so nothing holds this gate) while `{:unreadable, _}` is
  # ignorance — the door admits on it, and that admission is counted.
  @spec lock_triple_status(String.t()) ::
          {:ok, String.t()} | :absent | {:unreadable, File.posix()}
  defp lock_triple_status(path) do
    case File.stat(path) do
      {:ok, %File.Stat{major_device: dev, inode: inode}} ->
        # Userspace st_dev encoding (glibc gnu_dev_major/minor); the kernel
        # prints MAJOR()/MINOR() of the same device, so the numbers agree.
        major = Bitwise.bsr(Bitwise.band(dev, 0x000F_FF00), 8)

        minor =
          Bitwise.bor(Bitwise.band(dev, 0xFF), Bitwise.band(Bitwise.bsr(dev, 12), 0xFFFF_FF00))

        {:ok, "#{hex2(major)}:#{hex2(minor)}:#{inode}"}

      {:error, :enoent} ->
        # The lock file does not exist — nothing has ever taken this gate.
        :absent

      {:error, reason} ->
        Logger.warning(
          "[site-deploy] the build-slot door could not stat #{path} (#{inspect(reason)}) — " <>
            "no second opinion on foreign builds; ADMITTING, the engine's own flock still serializes"
        )

        {:unreadable, reason}
    end
  end

  @doc """
  Does a `/proc/locks` body carry an FLOCK entry for this `MAJ:MIN:INO` triple?

  Keyed on the ENTRY'S PRESENCE and NEVER on its PID: a live build showed
  /proc/locks naming a pid that `ps` could not find, because the lock's fd had
  been inherited and lived on in a child. The read itself is non-destructive —
  five world-readable lines, one `File.read` — which is the whole reason
  `flock -n` is not used here: on a FREE lock `flock -n` ACQUIRES, and flock
  wakeups are unordered, so a probe can take the slot from a unit that was
  already queued for it.
  """
  @spec flock_held?(String.t(), String.t()) :: boolean()
  def flock_held?(locks_body, triple) do
    locks_body
    |> String.split("\n")
    |> Enum.any?(fn line ->
      fields = String.split(line)
      "FLOCK" in fields and triple in fields
    end)
  end

  # Is the box's ONE build slot already spoken for? Two signals, in order:
  #
  #   1. PRIMARY — the in-BEAM census, above, race-free by construction.
  #   2. SECOND OPINION — /proc/locks, covering the census's blind spot: a
  #      build this BEAM did not launch (a human running site-deploy.sh by
  #      hand, or a unit that outlived a previous BEAM).
  #
  # Neither is complete, and the door does not pretend otherwise: the node and
  # static engines share ONE lock but are two command families here; a
  # hand-run engine answers to neither; and the node engine RELEASES the slot
  # before HEALTH boots the site's own process, so one slot does not bound
  # concurrent memory on node sites. Every uncertain case ADMITS.
  defp box_at_capacity?(state, %DeployRequest{} = req) do
    if takes_build_slot?(req) do
      case building_slugs(state) do
        [_ | _] = in_flight ->
          _ =
            note_refusal(%{
              slug: req.slug,
              holder: :peer,
              in_flight_slugs: Enum.sort(in_flight),
              slots_in_use: length(in_flight),
              capacity: build_slot_capacity(),
              holder_lock: nil,
              at: DateTime.utc_now()
            })

          Logger.info(
            "[site-deploy] REFUSED #{inspect(req.slug)} at the door: the box's build slot is " <>
              "in use (#{length(in_flight)} of #{build_slot_capacity()}, in flight: " <>
              "#{Enum.join(in_flight, ", ")})"
          )

          true

        [] ->
          foreign_build_in_flight?(req)
      end
    else
      # A rollback is a symlink repoint and a teardown removes a site — neither
      # ever acquires the build gate, so neither may be refused by it.
      false
    end
  end

  defp takes_build_slot?(%DeployRequest{mode: :deploy}), do: true
  defp takes_build_slot?(%DeployRequest{}), do: false

  # Slugs this BEAM knows are BUILDING right now — a live Port-mode run, or a
  # tracked unit systemd still reports active. Rollbacks/teardowns are excluded:
  # they hold no build slot. A run whose shape is unexpected is simply not
  # counted (the door fails OPEN, never closed).
  defp building_slugs(state) do
    port_slugs = for {slug, %{state: :running, mode: :deploy}} <- state.runs, do: slug

    unit_slugs =
      for {slug, %{mode: :deploy} = manifest} <- state.units,
          is_active(manifest.unit_name) in @active_states,
          do: slug

    Enum.uniq(port_slugs ++ unit_slugs)
  end

  # Reachability: `path` is always `proc_locks_path()` — `Keyword.get(config(),
  # :proc_locks_path, @default_proc_locks)`, i.e. application config with a
  # compile-time default of "/proc/locks". It is never a request value, never a
  # slug, and no caller passes a path in: `foreign_build_in_flight?/1` takes a
  # `%DeployRequest{}` and reads nothing path-shaped off it.
  # sobelow_skip ["Traversal.FileModule"]
  defp foreign_build_in_flight?(%DeployRequest{} = req) do
    path = proc_locks_path()

    case File.read(path) do
      {:ok, body} ->
        statuses =
          Enum.map(build_gate_lock_candidates(), fn lock -> {lock, lock_triple_status(lock)} end)

        held =
          Enum.find_value(statuses, fn
            {lock, {:ok, triple}} -> if flock_held?(body, triple), do: lock
            {_lock, _} -> nil
          end)

        cond do
          held ->
            # Also a refusal at this door, and counted here for the same reason:
            # a total that omitted foreign-lock refusals would understate exactly
            # the case an operator cannot see from the BEAM.
            _ =
              note_refusal(%{
                slug: req.slug,
                holder: :foreign,
                in_flight_slugs: [],
                slots_in_use: build_slot_capacity(),
                capacity: build_slot_capacity(),
                holder_lock: held,
                at: DateTime.utc_now()
              })

            Logger.info(
              "[site-deploy] REFUSED #{inspect(req.slug)} at the door: the box's build lock #{held} " <>
                "is held by a build this instance did not launch (#{build_slot_capacity()} of " <>
                "#{build_slot_capacity()} slots in use)"
            )

            true

          # /proc/locks read fine, but at least one candidate lock could not be
          # stat'd for a reason OTHER than "it does not exist" — so an FLOCK
          # entry for it would have been invisible to the scan above. We admit,
          # and we say so.
          Enum.any?(statuses, &match?({_lock, {:unreadable, _reason}}, &1)) ->
            _ = note_door_open(:lock_unstattable)
            false

          true ->
            false
        end

      {:error, :enoent} ->
        # No /proc/locks — this box is not Linux (dev, macOS, CI). There is no
        # second opinion to be had; ADMIT and let the engine's flock decide.
        _ = note_door_open(:no_proc_locks)
        false

      {:error, reason} ->
        Logger.warning(
          "[site-deploy] the build-slot door could not read #{path} (#{inspect(reason)}) — " <>
            "ADMITTING #{inspect(req.slug)} unrefused; the engine's own flock still serializes it"
        )

        _ = note_door_open(:proc_locks_unreadable)
        false
    end
  end

  defp proc_locks_path, do: Keyword.get(config(), :proc_locks_path, @default_proc_locks)

  defp env_or_nil(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp hex2(n), do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")

  defp start_run(state, %DeployRequest{} = req) do
    # INGEST FIRST when the request carries prebuilt bytes (charter D86/D87): a
    # refused artifact must cost nothing — no provision, no unit, no run — and
    # must NEVER degrade to a box build, because a box build of the template
    # would pass HEALTH on genuine markers while serving bytes the caller never
    # asked for. The refusal is typed and reaches the caller as a 400.
    case ingest_prebuilt(req) do
      :ok -> provision_and_spawn(state, req)
      {:error, code, message} -> {:reply, {:error, {:artifact_rejected, code, message}}, state}
    end
  end

  # No artifact: unchanged box-build path.
  defp ingest_prebuilt(%DeployRequest{artifact_b64: nil}), do: :ok

  defp ingest_prebuilt(%DeployRequest{} = req) do
    dir = prebuilt_dir(req.slug)

    case PrebuiltArtifact.stage(req.artifact_b64, req.artifact_sha256, dir) do
      {:ok, %{entries: entries, bytes: bytes}} ->
        Logger.info(
          "[site-deploy] staged prebuilt artifact for #{inspect(req.slug)} " <>
            "(#{entries} entries, #{bytes} bytes, sha256 #{req.artifact_sha256})"
        )

        :ok

      {:error, code, message} ->
        Logger.warning(
          "[site-deploy] prebuilt artifact REFUSED for #{inspect(req.slug)}: #{code} — #{message}"
        )

        {:error, code, message}
    end
  end

  # Where a staged artifact lives: a deterministic per-slug path under the same
  # run-state dir as the 0600 env file. Deterministic ON PURPOSE — it is how
  # BOTH env sinks (child_env/1 and write_env_file/4) resolve PREBUILT_DIR from
  # the request alone, with no third source of truth to drift.
  defp prebuilt_dir(slug), do: Path.join(ensure_run_state_dir(), "#{slug}.prebuilt")

  # The manifest is what a re-attach after a BEAM restart reads back, so a
  # prebuilt run must be recognizable as one from disk alone.
  defp prebuilt_manifest_dir(%DeployRequest{artifact_b64: nil}), do: nil
  defp prebuilt_manifest_dir(%DeployRequest{} = req), do: prebuilt_dir(req.slug)

  defp provision_and_spawn(state, %DeployRequest{} = req) do
    # PROVISION FIRST (charter D33/D34): a content-bound site has no repo to check
    # out, so its source must be materialized from the shipped template BEFORE the
    # build starts — otherwise the engine walks PLAN and dies at BUILD with `no
    # site source dir …/src` (exit 10). Deploy only; a rollback is a symlink
    # repoint whose source is already there (Provisioner no-ops it). Fail-closed:
    # a provision failure short-circuits EXACTLY like a spawn failure — no build,
    # no run recorded.
    #
    # It is NOT, however, the same ANSWER (deploy-reliability D26). This arm used
    # to be a bare `Logger.warning` + `{:error, :start_failed}`: no row, no
    # BPSTAGE, no failure class, so the `%File.Error{}` that explains 63% of this
    # fleet's failures went to journald and nowhere else, and 25 consecutive
    # attempts on one site never once said WHY. It is now a NAMED typed refusal
    # carrying a scrubbed, human-readable reason (the File.Error's action AND
    # path survive into it — that pair IS the diagnosis) which the controller
    # renders as its own 500 code.
    #
    # site-spawner D34 still holds: PROVISION is a SILENT pre-BUILD step, not a
    # visible 7th stage. A typed refusal code is not a stage — @stages and
    # @stage_names are untouched.
    case Provisioner.provision(req) do
      :ok ->
        spawn_run(state, req)

      {:error, {:provision_failed, reason}} ->
        described = describe_provision_reason(reason)

        Logger.warning(
          "[site-deploy] provision failed for #{inspect(req.slug)} — deploy not started: #{described}"
        )

        {:reply, {:error, {:provision_failed, described}}, state}
    end
  end

  # The provision reason, rendered for an operator and SCRUBBED. Deliberately a
  # local, explicit redactor rather than the display-boundary `scrub/1`: this
  # string crosses an HTTP boundary as a 500 body, and the measured leak rate
  # of the shared scrubber against this box's own `bppat_` token shape is
  # 95.1%. What
  # must SURVIVE is the diagnosis — a File.Error's action and path, an errno's
  # meaning — because "enoent" alone is what made 25 failures unreadable.
  #
  # PUBLIC (`@doc false`) purely so the operator sentences can be asserted
  # directly. Neither of the two shapes below can be induced end-to-end from a
  # test: `:global.trans/2` retries forever rather than returning `:aborted`,
  # and making `rename(2)` fail with anything but `:enoent` needs a
  # platform-specific trick (an immutable flag, a mount point) that would red on
  # someone else's box. An unassertable sentence is one nobody notices breaking.
  @doc false
  @spec describe_provision_reason(term()) :: String.t()
  def describe_provision_reason(%File.Error{reason: reason, path: path, action: action}),
    do: redact("could not #{action} #{path}: #{format_posix(reason)}")

  def describe_provision_reason(%File.CopyError{reason: reason, source: src, destination: dst}),
    do: redact("could not copy #{src} to #{dst}: #{format_posix(reason)}")

  def describe_provision_reason({:template_not_found, path}),
    do: redact("site template not found: #{path}")

  def describe_provision_reason({:rename_failed, reason}),
    do: redact("could not rename the staged site source: #{format_posix(reason)}")

  # The two shapes the provisioner's swap produces (provisioner.ex:202/:240).
  # They live HERE, beside their producers: without their own clauses they fall
  # to `inspect/1` and reach the operator as Elixir tuple jargon, which is the
  # exact narrowing this arm exists to end.
  def describe_provision_reason({:swap_aside_failed, reason}),
    do:
      redact(
        "could not move the live site source aside before swapping in the new one: " <>
          format_posix(reason)
      )

  def describe_provision_reason({:lock_aborted, slug}),
    do: redact("another deploy of #{slug} holds the provision lock and it could not be acquired")

  def describe_provision_reason(reason) when is_binary(reason), do: redact(reason)

  def describe_provision_reason(%{__exception__: true} = error),
    do: redact(Exception.message(error))

  def describe_provision_reason(reason) when is_atom(reason), do: format_posix(reason)

  def describe_provision_reason(reason), do: redact(inspect(reason))

  defp format_posix(reason) when is_atom(reason) do
    described = reason |> :file.format_error() |> to_string()

    # `:file.format_error/1` answers "unknown POSIX error: <atom>" for anything
    # that is not an errno — in that case the atom itself is the better answer.
    if String.starts_with?(described, "unknown POSIX error"),
      do: to_string(reason),
      else: described
  rescue
    _ -> inspect(reason)
  end

  defp format_posix(reason), do: inspect(reason)

  # Redact the two secret shapes that can plausibly ride a provision reason: this
  # product's own token prefix, and any `KEY=value` whose key names a credential.
  @token_re ~r/bppat_[A-Za-z0-9_\-]+/
  @assigned_secret_re ~r/\b([A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|KEK|APIKEY|API_KEY))=\S+/i

  defp redact(text) when is_binary(text) do
    text
    |> String.replace(@token_re, "bppat_[REDACTED]")
    |> String.replace(@assigned_secret_re, "\\1=[REDACTED]")
    |> String.slice(0, 500)
  end

  defp redact(other), do: redact(inspect(other))

  # The launch fork: a systemd box gets a SURVIVING transient unit; anywhere
  # `systemd-run` is absent falls back to the in-process Port.
  defp spawn_run(state, %DeployRequest{} = req) do
    case runner_mode() do
      :systemd -> launch_unit(state, req)
      :port -> open_port_and_record(state, req)
    end
  end

  # `:auto` (the default) resolves to `:systemd` only when `systemd-run` is
  # actually on the box; test/dev pins `:port` (config/test.exs) so the classic
  # Port lifecycle is exercised without systemd. An explicit `:systemd`/`:port`
  # is honored verbatim (tests stub the launcher + probes).
  defp runner_mode do
    case Keyword.get(config(), :runner_mode, :auto) do
      :systemd -> :systemd
      :port -> :port
      _auto -> if systemd_run_exe(), do: :systemd, else: :port
    end
  end

  defp systemd_run_exe do
    {exe, _prefix} = Keyword.get(config(), :systemd_run_command, @default_systemd_run)
    System.find_executable(exe)
  end

  # ── systemd transient-unit path (observer + finalizer) ────────────────────

  defp launch_unit(state, %DeployRequest{} = req) do
    dir = ensure_run_state_dir()
    unit = unit_name(req)
    # THE KEYING IS THE BUG (deploy-reliability D21). These three used to be
    # `<slug>.log`/`.status`/`.env`, and fresh_run_files/1 truncates them at
    # every launch — so deploy #2 of a slug erased deploy #1's build log. Keyed
    # on the run tag, a new build gets a NEW path and can only ever truncate its
    # OWN. The manifest deliberately stays slug-keyed (see run_tag/1).
    tag = run_tag(req)
    status_file = Path.join(dir, "#{req.slug}-#{tag}.status")
    log_file = Path.join(dir, "#{req.slug}-#{tag}.log")
    env_file = Path.join(dir, "#{req.slug}-#{tag}.env")

    manifest = %{
      slug: req.slug,
      run_tag: tag,
      build_id: req.build_id,
      content_rev: req.content_rev,
      mode: req.mode,
      runtime_target: req.runtime_target,
      unit_name: unit,
      status_file: status_file,
      log_file: log_file,
      build_env_file: env_file,
      prebuilt_dir: prebuilt_manifest_dir(req),
      prebuilt_sha256: req.artifact_sha256,
      started_at: DateTime.utc_now()
    }

    with :ok <- write_env_file(env_file, req, status_file, log_file),
         :ok <- fresh_run_files([status_file, log_file]),
         :ok <- write_manifest(dir, manifest),
         :ok <- systemd_run(req, unit, env_file) do
      state =
        state
        |> Map.update!(:units, &Map.put(&1, req.slug, manifest))
        |> Map.update!(:runs, &(&1 |> Map.delete(req.slug) |> prune_runs()))
        |> arm_unit_deadline(req.slug, run_deadline_ms())

      _ = prune_run_state_dir(dir)
      {:reply, {:ok, :started}, state}
    else
      {:error, reason} ->
        Logger.warning(
          "[site-deploy] unit launch failed for #{inspect(req.slug)}: #{inspect(reason)}"
        )

        _ = unlink_env(manifest)
        {:reply, {:error, :start_failed}, state}
    end
  end

  # The per-DEPLOYMENT key for the run-state files. A deploy is named by its
  # build_id (charset-validated upstream: `[A-Za-z0-9._-]`, so it is a safe path
  # component) — that is the id a caller polls with and the id it must be able
  # to read its log back by. A rollback/teardown names NO build, so it takes
  # `<mode>-<ms>`, which is still unique per launch and still cannot clobber a
  # sibling.
  #
  # The MANIFEST is not tagged: it stays `<slug>.manifest.json` because it is the
  # "current run for this slug" pointer that `load_manifest_for/1` and the
  # re-attach scan resolve BY SLUG, and it carries these tagged paths. The
  # durable per-deployment record is the terminal record, not the manifest.
  defp run_tag(%DeployRequest{build_id: id}) when is_binary(id) and id != "", do: id

  defp run_tag(%DeployRequest{mode: mode}),
    do: "#{mode}-#{System.system_time(:millisecond)}"

  # A manifest written before this change (or by a prior BEAM) carries no
  # run_tag — derive it from its log file name so its terminal record still
  # lands beside its log.
  defp manifest_tag(%{run_tag: tag}) when is_binary(tag) and tag != "", do: tag

  defp manifest_tag(%{slug: slug, log_file: log}) when is_binary(log) do
    case Path.basename(log, ".log") do
      ^slug -> "legacy"
      <<_::binary>> = base -> String.replace_prefix(base, "#{slug}-", "")
    end
  end

  defp manifest_tag(_), do: "legacy"

  # A unique, valid systemd unit name. The `.service` suffix pins the type so an
  # internal `.` in a build_id can never be read AS the type; the millisecond
  # stamp keeps a same-build_id redeploy from colliding with a `--collect`-swept
  # predecessor mid-GC. slug + build_id are already charset-validated upstream.
  defp unit_name(%DeployRequest{} = req) do
    tag = req.build_id || "rollback"
    ts = System.system_time(:millisecond)
    "bp-site-build-#{req.slug}-#{tag}-#{ts}.service"
  end

  # The launch itself. `systemd-run` REGISTERS the transient unit and returns
  # immediately — the build runs detached in its own cgroup, so a barkpark.service
  # restart cannot reach it. Every knob is a `--property=` (not argv), the secrets
  # ride the 0600 EnvironmentFile (never `--setenv`), and `--collect` GCs the unit
  # after it exits so a re-run of the same slug never trips "unit already exists".
  defp systemd_run(%DeployRequest{} = req, unit, env_file) do
    {launcher, prefix} = Keyword.get(config(), :systemd_run_command, @default_systemd_run)
    {engine_exe, engine_args} = command_for(req.mode, req.runtime_target)

    case System.find_executable(engine_exe) do
      nil ->
        {:error, {:executable_not_found, engine_exe}}

      engine_path ->
        args =
          prefix ++
            [
              "--unit=#{unit}",
              "--property=WorkingDirectory=#{run_cd()}",
              "--property=EnvironmentFile=#{env_file}",
              "--property=MemoryMax=#{memory_max()}",
              "--property=CPUQuota=#{cpu_quota()}",
              "--collect",
              engine_path
            ] ++ engine_args

        # Bounded: `systemd-run` REGISTERS-and-returns fast, but a wedged D-Bus /
        # a hung systemd would otherwise freeze this synchronous {:trigger} call.
        # A timeout or crash degrades to a start failure — the with-chain in
        # launch_unit maps every {:error, _} to {:error, :start_failed}.
        case bounded_cmd(launcher, args, cd: run_cd(), stderr_to_stdout: true) do
          {:ok, {_out, 0}} -> :ok
          {:ok, {out, code}} -> {:error, {:systemd_run_exit, code, String.slice(out, 0, 500)}}
          :timeout -> {:error, {:systemd_run_timeout, ctl_cmd_timeout_ms()}}
          {:crashed, reason} -> {:error, {:systemd_run_crashed, reason}}
        end
    end
  end

  # Reconstruct + advance an in-flight unit. Reads the durable status fold; if the
  # unit is still active it is `:running`; once it is gone the run is finalized,
  # cached, and its secret env file unlinked (single-flight freed).
  defp observe_unit(state, slug) do
    manifest = Map.fetch!(state.units, slug)

    case is_active(manifest.unit_name) do
      active when active in @active_states ->
        {:reply, reconstruct(manifest, :running), state}

      _terminal ->
        # Grace: right after launch systemd may report `inactive` for a beat
        # before the unit goes active. Do not serve a false `:done` off NO output
        # yet — keep it `:running` until the run shows something or the grace
        # elapses. A DEPLOY announces itself with its first BPSTAGE (the fold); a
        # ROLLBACK emits no BPSTAGE ever (its output is the log), so gating its
        # grace on an empty FOLD would hold every FINISHED rollback `:running`
        # for the whole grace and then mislabel it. `no_output_yet?` is mode-aware.
        if no_output_yet?(manifest) and within_spawn_grace?(manifest) do
          {:reply, reconstruct(manifest, :running), state}
        else
          render = reconstruct(manifest, :terminal)
          {:reply, render, cache_and_cleanup(state, slug, manifest, render)}
        end
    end
  end

  # A manifest found on disk with no live tracking (post-restart terminal, or a
  # unit another process launched). Reconstruct terminal and cache it.
  defp finalize_from_disk(state, manifest) do
    render = reconstruct(manifest, :terminal)
    {:reply, render, cache_and_cleanup(state, manifest.slug, manifest, render)}
  end

  defp cache_and_cleanup(state, slug, manifest, render) do
    # THE terminal record is written HERE and nowhere else: this is the one
    # place where the reconstructed render (exit_code, failure_reason, the stage
    # fold, finished_at) exists at the same time as the manifest (unit_name, the
    # log path). A tombstone written at PRUNE time could not say why anything
    # failed — the manifest carries none of that.
    _ = write_terminal_record(manifest, render)
    _ = unlink_env(manifest)

    state
    |> cancel_timer(slug)
    |> Map.update!(:units, &Map.delete(&1, slug))
    |> Map.update!(:runs, &(&1 |> Map.put(slug, render) |> prune_runs()))
  end

  # ── re-attach on boot (search-template D32) ───────────────────────────────

  # Scan the run-state dir; for every manifest whose unit is STILL active,
  # re-attach as `:running`, re-arm the (remaining) deadline, and re-claim the
  # single-flight slot. A unit that is gone/terminal is left on disk (so a later
  # `status/1` reconstructs its outcome) but its secret env file is unlinked.
  defp reattach_units(state) do
    if runner_mode() == :systemd do
      dir = run_state_dir()

      state =
        dir
        |> list_manifests()
        |> Enum.reduce(state, fn manifest, acc ->
          if is_active(manifest.unit_name) in @active_states do
            remaining = remaining_deadline_ms(manifest)

            acc
            |> Map.update!(:units, &Map.put(&1, manifest.slug, manifest))
            |> arm_unit_deadline(manifest.slug, remaining)
          else
            _ = unlink_env(manifest)
            acc
          end
        end)

      _ = prune_run_state_dir(dir)
      state
    else
      state
    end
  rescue
    # Never let a malformed run dir take down the boot — degrade to a fresh state.
    error ->
      Logger.warning("[site-deploy] unit re-attach skipped: #{inspect(error)}")
      state
  end

  defp remaining_deadline_ms(manifest) do
    elapsed = DateTime.diff(DateTime.utc_now(), manifest.started_at, :millisecond)
    max(run_deadline_ms() - elapsed, 0)
  end

  # ── status-file / log-file reconstruction ─────────────────────────────────

  # Build the status map from the manifest + the unit's durable files. `phase`
  # is `:running` (unit still active) or `:terminal` (unit gone). The stage fold
  # keeps RAW tokens (never pre-normalized — the CP maps `ok`→`done`), first-seen
  # ORDER, latest-wins. build_id is preserved from the manifest (slice 3 needs it).
  defp reconstruct(manifest, phase) do
    log = read_log_tail(manifest.log_file)
    stages = fold_status_file(manifest.status_file, manifest.build_id)
    {served_port, served_slot} = fold_served_file(manifest.status_file)

    base = %{
      slug: manifest.slug,
      build_id: manifest.build_id,
      content_rev: manifest.content_rev,
      mode: manifest.mode,
      runtime_target: manifest.runtime_target,
      stages: stages,
      served_port: served_port,
      served_slot: served_slot,
      log: log,
      log_state: disk_log_state(manifest.log_file),
      log_path: manifest.log_file,
      unit_name: manifest.unit_name,
      started_at: manifest.started_at
    }

    case phase do
      :running ->
        Map.merge(base, %{state: :running, exit_code: nil, failure_reason: nil, finished_at: nil})

      :terminal ->
        {code, reason} = terminal_outcome(manifest.mode, stages, log)

        Map.merge(base, %{
          state: :done,
          exit_code: code,
          failure_reason: reason,
          build_id: terminal_build_id(manifest, code, log),
          finished_at: file_mtime(manifest.status_file) || DateTime.utc_now()
        })
    end
  end

  # Fold the durable status file (one BPSTAGE line per state boundary) into the
  # stage list, using the SAME upsert as the Port stream so both paths agree.
  # Reachability: `path` is always `manifest.status_file` — built here at :459
  # from `run_state_dir()` + a charset-validated slug, never from request data.
  # sobelow_skip ["Traversal.FileModule"]
  defp fold_status_file(path, default_build_id) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reduce([], fn line, stages ->
          case parse_stage_line(line, default_build_id) do
            {:ok, stage} -> upsert_stage(stages, stage)
            :skip -> stages
          end
        end)

      {:error, _} ->
        []
    end
  end

  # The SERVED marker's twin of `fold_status_file/2`: latest-wins over the same
  # durable file, so a systemd run that this process never streamed still reports
  # the slot Caddy ended up on. `{nil, nil}` when the engine emitted no marker
  # (every static deploy, and any node build that died before SWITCH) — which is
  # the honest answer, not a zero.
  # Reachability: `path` is always `manifest.status_file` (run_state_dir + a
  # charset-validated slug), never request data.
  # sobelow_skip ["Traversal.FileModule"]
  defp fold_served_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reduce({nil, nil}, fn line, acc ->
          case parse_served_line(line) do
            {:ok, port, slot} -> {port, slot}
            :skip -> acc
          end
        end)

      {:error, _} ->
        {nil, nil}
    end
  end

  # Reachability: `path` is always `manifest.log_file` — same provenance as the
  # status file (run_state_dir + validated slug), never a caller-supplied path.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_log_tail(path) do
    max = Keyword.get(config(), :max_log_lines, @default_max_log_lines)

    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.take(-max)

      {:error, _} ->
        []
    end
  end

  defp empty_fold?(manifest),
    do: fold_status_file(manifest.status_file, manifest.build_id) == []

  # "No durable output yet" — the signal that a unit reporting `inactive` may just
  # be in the post-launch beat rather than genuinely finished. A DEPLOY announces
  # itself with its first BPSTAGE (the fold); a ROLLBACK emits no BPSTAGE, so for
  # it the signal is an empty LOG. Mode-aware so the deploy grace is byte-unchanged.
  defp no_output_yet?(%{mode: :rollback} = manifest), do: empty_log?(manifest)
  defp no_output_yet?(%{mode: :teardown} = manifest), do: empty_log?(manifest)
  defp no_output_yet?(manifest), do: empty_fold?(manifest)

  defp empty_log?(manifest), do: read_log_tail(manifest.log_file) == []

  defp within_spawn_grace?(manifest),
    do: DateTime.diff(DateTime.utc_now(), manifest.started_at, :millisecond) < @spawn_grace_ms

  # A terminal unit exposes no exit code (`--collect` sweeps it), so the outcome is
  # derived from the durable signals the child left behind. The signal set differs
  # by MODE, and conflating them is the rollback-finalizer bug: a DEPLOY reads its
  # BPSTAGE fold + log tail; a ROLLBACK emits NO BPSTAGE (it is a pointer flip, not
  # a deploy — see `deploy/site-deploy.sh` header: the machine contract is the
  # TARGET_BUILD= line + the typed exits, NOT BPSTAGE), so folding its empty stages
  # through the deploy path mislabels every SUCCESSFUL rollback as `stages == []`
  # → `-1` abnormal death, which the CP then reports as `rollback_failed`.
  defp terminal_outcome(:rollback, _stages, log), do: rollback_outcome(log)
  defp terminal_outcome(:teardown, _stages, log), do: teardown_outcome(log)
  defp terminal_outcome(_deploy, stages, log), do: deploy_outcome(stages, log)

  # TEARDOWN: like a rollback it emits no BPSTAGE, but the engine DOES speak a
  # typed-failure vocabulary (an earlier comment here claimed it did not —
  # refuted by `deploy/site-deploy.sh` itself): success prints `TORN_DOWN=<slug>`;
  # `teardown_failed()` prints `TEARDOWN_FAILED=<slug> detail="…"` and exits 25;
  # the per-site lock refusal logs `… (lock_held)` and exits 23. A terminal unit
  # exposes no exit code (`--collect` sweeps it), so the typed exit is recovered
  # FROM those log markers; anything else is an abnormal end (-1) — voiced as a
  # teardown, never as a deploy.
  defp teardown_outcome(log) do
    cond do
      Enum.any?(log, &String.contains?(&1, "TORN_DOWN=")) ->
        {0, nil}

      Enum.any?(log, &String.contains?(&1, "TEARDOWN_FAILED=")) ->
        {25, teardown_reason(25, teardown_failed_detail(log), log)}

      Enum.any?(log, &String.contains?(&1, "(lock_held)")) ->
        {23, teardown_reason(23, nil, log)}

      true ->
        {-1, teardown_reason(-1, nil, log)}
    end
  end

  # The engine's own words, parsed from its `TEARDOWN_FAILED=<slug> detail="…"`
  # line — the operator reads what the script diagnosed, not a generic label.
  defp teardown_failed_detail(log) do
    Enum.find_value(log, fn line ->
      case Regex.run(~r/TEARDOWN_FAILED=\S+ detail="([^"]*)"/, line) do
        [_, detail] -> blank_to_nil(detail)
        _ -> nil
      end
    end)
  end

  # DEPLOY: a `failed` stage names its typed exit + carries its detail; a clean run
  # that reached SWITCH/RETIRE ok is exit 0; a unit that vanished without emitting a
  # stage is an abnormal death.
  defp deploy_outcome(stages, log) do
    failed = stages |> Enum.reverse() |> Enum.find(&(&1.status == "failed"))

    cond do
      failed ->
        {stage_exit_code(failed.name), terminal_reason(stage_exit_code(failed.name), failed, log)}

      Enum.any?(stages, &(&1.name in ~w(SWITCH RETIRE) and &1.status == "ok")) ->
        {0, nil}

      stages == [] ->
        {-1, terminal_reason(-1, nil, log)}

      true ->
        # Reached some stages but never a terminal failure or a clean switch —
        # the unit is gone; treat as an abnormal end with the log's own tail.
        {-1, terminal_reason(-1, nil, log)}
    end
  end

  # ROLLBACK: no stages exist, so the verdict comes from the log the engine typed.
  # A recognized typed failure wins first (`(no_previous)` → 21, `(not_supported)`
  # → 22). Otherwise a success marker (`ROLLED BACK` / `TARGET_BUILD=`, emitted by
  # both the real flip AND the "previous == current, nothing to do" path) is exit 0.
  # Neither — including a flip failure (24), which logs no distinct marker — falls
  # through to an abnormal death: still non-zero, still fail-closed, so the CP renders
  # a 422 refusal, never a false `rolled_back`.
  defp rollback_outcome(log) do
    case rollback_failure_code(log) do
      nil ->
        if rollback_succeeded?(log),
          do: {0, nil},
          else: {-1, terminal_reason(-1, nil, log)}

      code ->
        {code, terminal_reason(code, nil, log)}
    end
  end

  # The typed rollback failures name themselves in the log with a parenthetical
  # marker (`deploy/site-deploy.sh`): "(no_previous)" → 21, "(not_supported)" → 22.
  defp rollback_failure_code(log) do
    text = Enum.join(log, "\n")

    cond do
      String.contains?(text, "(no_previous)") -> 21
      String.contains?(text, "(not_supported)") -> 22
      true -> nil
    end
  end

  defp rollback_succeeded?(log) do
    Enum.any?(log, fn line ->
      String.contains?(line, "ROLLED BACK") or target_build_line?(line)
    end)
  end

  defp target_build_line?(line), do: Regex.match?(~r/^\s*TARGET_BUILD=\S/, line)

  # The build a deploy went live on is its manifest build_id; a SUCCESSFUL rollback
  # flips to a DIFFERENT build (its manifest build_id is empty — a rollback names no
  # build), so the now-live build is parsed from the engine's `TARGET_BUILD=<id>`
  # line, reusing the CP's parse (box_relay.target_build/1). Everything else keeps
  # the manifest build_id verbatim.
  defp terminal_build_id(%{mode: :rollback, build_id: fallback}, 0, log),
    do: parse_target_build(log) || fallback

  defp terminal_build_id(%{build_id: build_id}, _code, _log), do: build_id

  defp parse_target_build(log) do
    Enum.find_value(log, fn line ->
      case Regex.run(~r/^TARGET_BUILD=(\S+)/, String.trim(to_string(line))) do
        [_, id] -> id
        _ -> nil
      end
    end)
  end

  defp terminal_reason(code, failed_stage, log) do
    detail = failed_stage && failed_stage.detail
    tail = log_reason_tail(log)

    cond do
      is_binary(detail) and detail != "" -> "#{exit_label(code)}: #{detail}"
      tail != "" -> "#{exit_label(code)}: #{tail}"
      true -> exit_label(code)
    end
  end

  # Teardown-voiced twin of `terminal_reason/3` — a failed teardown must never
  # open by saying a DEPLOY died. `exit_label/1` stays byte-frozen (deploy-
  # reliability's classifier starts_with-matches its -1 bytes,
  # cloud/lib/barkpark_cloud/deploy_ledger.ex); only :teardown outcomes route here.
  defp teardown_reason(code, detail, log) do
    tail = log_reason_tail(log)

    cond do
      is_binary(detail) and detail != "" -> "#{teardown_exit_label(code)}: #{detail}"
      tail != "" -> "#{teardown_exit_label(code)}: #{tail}"
      true -> teardown_exit_label(code)
    end
  end

  # site-deploy.sh's typed non-deploy-mode exits, in teardown voice. 23 reuses
  # the CP's own lock_held copy (cloud/sites/deploy.ex renders the same sentence
  # for the box's synchronous 409 refusal) so both refusal surfaces speak
  # identically. 25 is `teardown_failed()` — no TORN_DOWN= was printed, so the
  # site was NOT torn down (the release tree is deliberately kept on disk).
  defp teardown_exit_label(23),
    do: "a deploy is running on the box — try again once it finishes (exit 23)"

  defp teardown_exit_label(25), do: "teardown failed — the site was not torn down (exit 25)"
  defp teardown_exit_label(-1), do: "the teardown did not complete — its process died abnormally"
  defp teardown_exit_label(-2), do: "the teardown exceeded its deadline and was force-closed"
  defp teardown_exit_label(code), do: "teardown failed (exit #{code})"

  # The trailing meaningful lines of the child's raw log (BPSTAGE lines + blanks
  # are structure, not diagnosis). `log` is oldest-first, so take the last N.
  defp log_reason_tail(log) do
    log
    |> Enum.reject(&noise_line?/1)
    |> Enum.take(-@reason_lines)
    |> Enum.map_join(" | ", &String.trim/1)
  end

  # A `failed` stage's typed exit — the reverse of exit_label's mapping.
  defp stage_exit_code("PLAN"), do: 11
  defp stage_exit_code("BUILD"), do: 12
  defp stage_exit_code("STAGE"), do: 13
  defp stage_exit_code("HEALTH"), do: 14
  defp stage_exit_code("SWITCH"), do: 16
  defp stage_exit_code(_other), do: -1

  # ── the child's environment ───────────────────────────────────────────────

  # Configured working dir, or the repo root: the BEAM's cwd is api/ under both
  # `mix phx.server` and start.sh, so the parent is /opt/barkpark on a real box —
  # exactly where `bash deploy/site-deploy.sh` resolves.
  defp run_cd, do: Keyword.get(config(), :cd) || Path.dirname(File.cwd!())

  # The KEY→value decision, ONCE, shared by both sinks (the allow-list is never
  # forked): a request-supplied non-empty value, else `nil` (Port mode removes it
  # with `false`; a systemd EnvironmentFile omits the line — a transient unit
  # starts clean, so an omitted var is simply absent, never inherited).
  defp resolved_build_vars(%DeployRequest{} = req) do
    for key <- @build_env_keys do
      case Map.get(req.env, key) do
        value when is_binary(value) and value != "" -> {key, value}
        _absent -> {key, nil}
      end
    end
  end

  # The PREBUILT pair, resolved ONCE for both sinks exactly like
  # `resolved_build_vars/1` — because the failure mode of forking them is
  # invisible: a prebuilt deploy that reaches the Port path (dev, macOS) but not
  # the systemd EnvironmentFile works interactively and then silently degrades
  # to a full on-box `npm ci && npm run build` under the real runner, i.e. the
  # exact cost this whole wave exists to remove, with a GREEN deploy on top.
  # An absent artifact yields NO lines at all, so the box-build path is byte-for-
  # byte what it was.
  defp resolved_prebuilt_vars(%DeployRequest{artifact_b64: nil}), do: []

  defp resolved_prebuilt_vars(%DeployRequest{} = req) do
    [
      {"PREBUILT_DIR", prebuilt_dir(req.slug)},
      {"PREBUILT_SHA256", req.artifact_sha256}
    ]
  end

  # The Port child's environment (fallback path). See the moduledoc: `false`
  # REMOVES, everything else is set explicitly, and PATH is untouched (inherited).
  defp child_env(%DeployRequest{} = req) do
    scrub = for key <- @scrub_env, do: {to_charlist(key), false}

    build =
      for {key, value} <- resolved_build_vars(req) do
        case value do
          v when is_binary(v) -> {to_charlist(key), to_charlist(v)}
          nil -> {to_charlist(key), false}
        end
      end

    engine = [
      {~c"SITE_SLUG", to_charlist(req.slug)},
      {~c"BUILD_ID", charlist_or_false(req.build_id)},
      {~c"CONTENT_REV", charlist_or_false(req.content_rev)}
    ]

    prebuilt =
      for {key, value} <- resolved_prebuilt_vars(req),
          do: {to_charlist(key), charlist_or_false(value)}

    scrub ++ build ++ engine ++ prebuilt
  end

  defp charlist_or_false(value) when is_binary(value) and value != "", do: to_charlist(value)
  defp charlist_or_false(_value), do: false

  # The transient unit's EnvironmentFile (0600): the SAME set-or-omit decision as
  # child_env, rendered as `KEY=VALUE` lines. NO secret ever lands on argv, and
  # PATH is carried explicitly (a systemd unit's default PATH lacks asdf's `npm`
  # shims). The engine reads SITE_SLUG/BUILD_ID/CONTENT_REV and the status/log
  # file paths from here.
  # Reachability: `path` is the env file this module names itself (:462) under
  # `run_state_dir()` from a slug matching ^[a-z0-9][a-z0-9-]{0,62}$ (no `/`,
  # no `.`) — DeployRequest.validate_slug/1 rejects everything else upstream.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_env_file(path, %DeployRequest{} = req, status_file, log_file) do
    build_lines =
      for {key, value} <- resolved_build_vars(req), is_binary(value), do: "#{key}=#{value}"

    engine_lines =
      [{"SITE_SLUG", req.slug}, {"BUILD_ID", req.build_id}, {"CONTENT_REV", req.content_rev}] ++
        resolved_prebuilt_vars(req)

    engine_lines =
      engine_lines
      |> Enum.filter(fn {_k, v} -> is_binary(v) and v != "" end)
      |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)

    lines =
      ["PATH=#{System.get_env("PATH") || ""}"] ++
        build_lines ++
        engine_lines ++
        [
          "BARKPARK_SITE_STATUS_FILE=#{status_file}",
          "BARKPARK_SITE_LOG_FILE=#{log_file}"
        ]

    with :ok <- File.write(path, Enum.join(lines, "\n") <> "\n"),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  rescue
    error -> {:error, error}
  end

  # Reachability: `build_env_file` is only ever the path write_env_file/4 just
  # created; the annotation binds THIS clause only (charter D141b).
  # sobelow_skip ["Traversal.FileModule"]
  defp unlink_env(%{build_env_file: path}) when is_binary(path), do: File.rm(path)
  defp unlink_env(_), do: :ok

  # Each {mode, runtime_target} cell resolves its own injectable command (tests
  # stub these). The engine takes slug/build_id/content_rev from the ENVIRONMENT,
  # so argv carries only the MODE (`--rollback` or nothing); the RUNTIME TARGET
  # (charter D63) picks which engine script runs. runtime_target is a CLOSED enum
  # validated upstream, so these four clauses are total.
  defp command_for(:rollback, :node),
    do: Keyword.get(config(), :node_rollback_command, @default_node_rollback_command)

  defp command_for(:rollback, _static),
    do: Keyword.get(config(), :rollback_command, @default_rollback_command)

  defp command_for(:teardown, :node),
    do: Keyword.get(config(), :node_teardown_command, @default_node_teardown_command)

  defp command_for(:teardown, _static),
    do: Keyword.get(config(), :teardown_command, @default_teardown_command)

  defp command_for(_deploy, :node),
    do: Keyword.get(config(), :node_command, @default_node_command)

  defp command_for(_deploy, _static),
    do: Keyword.get(config(), :command, @default_command)

  # ── Port fallback (dev / macOS / CI) ──────────────────────────────────────

  defp open_port_and_record(state, %DeployRequest{} = req) do
    case open_port(req) do
      {:ok, port} ->
        schedule_run_deadline(port)

        run = %{
          slug: req.slug,
          build_id: req.build_id,
          content_rev: req.content_rev,
          mode: req.mode,
          runtime_target: req.runtime_target,
          state: :running,
          port: port,
          stages: [],
          # The node engine's SERVED marker fills these once its Caddy flip has
          # committed; nil until then, and nil forever on a static deploy (a
          # symlink swap has no slot). Never seeded from the request's intent.
          served_port: nil,
          served_slot: nil,
          log: [],
          exit_code: nil,
          failure_reason: nil,
          started_at: DateTime.utc_now(),
          finished_at: nil
        }

        state = %{
          state
          | runs: state.runs |> Map.put(req.slug, run) |> prune_runs(),
            ports: Map.put(state.ports, port, req.slug)
        }

        {:reply, {:ok, :started}, state}

      {:error, _reason} ->
        {:reply, {:error, :start_failed}, state}
    end
  end

  defp open_port(%DeployRequest{} = req) do
    {exe, args} = command_for(req.mode, req.runtime_target)

    case System.find_executable(exe) do
      nil ->
        {:error, {:executable_not_found, exe}}

      path ->
        port =
          Port.open(
            {:spawn_executable, path},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              {:line, 4096},
              args: args,
              cd: run_cd(),
              env: child_env(req)
            ]
          )

        {:ok, port}
    end
  rescue
    # Port.open raises on e.g. a missing cd — degrade to a start failure so the
    # controller can answer 500 runner_start_failed instead of crashing.
    error -> {:error, error}
  end

  defp schedule_run_deadline(port) do
    Process.send_after(self(), {:run_deadline, port}, run_deadline_ms())
  end

  # Closing a `{:spawn_executable, _}` port closes the pipe fds and sends the child
  # NO signal — it terminates only a program that exits on stdin EOF or dies to
  # SIGPIPE (GH #6681: the Codex runtime orphaned a child that did neither, which
  # `Session.reap_port/1` now SIGKILLs after the close). A deploy child that
  # ignores EOF survives this watchdog the same way; reaping here is filed, not
  # done. Tolerate an already-closed port so the watchdog never crashes the Runner.
  defp close_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Apply `fun` to the run this port belongs to; a port we do not know (a stale
  # message from a finished run) is ignored.
  defp update_run(state, port, fun) do
    with {:ok, slug} <- Map.fetch(state.ports, port),
         {:ok, run} <- Map.fetch(state.runs, slug) do
      %{state | runs: Map.put(state.runs, slug, fun.(run))}
    else
      :error -> state
    end
  end

  defp release_port(state, port) do
    %{state | ports: Map.delete(state.ports, port)}
  end

  # Every line goes into the bounded log tail; a BPSTAGE line ALSO upserts the
  # stage list, which is never evicted.
  defp ingest_line(run, line) do
    run
    |> push_log(line)
    |> parse_stage(line)
    |> parse_served(line)
  end

  defp finish_run(run, code) do
    %{
      run
      | state: :done,
        port: nil,
        exit_code: code,
        failure_reason: failure_reason(code, run),
        finished_at: DateTime.utc_now()
    }
  end

  # Bounded log: newest-first internally, oldest dropped beyond the cap.
  defp push_log(run, line) do
    max = Keyword.get(config(), :max_log_lines, @default_max_log_lines)
    %{run | log: Enum.take([line | run.log], max)}
  end

  # ── stages ──────────────────────────────────────────────────────────────

  # Port-stream variant: parse one line, upsert into the run's stage list.
  defp parse_stage(run, line) do
    case parse_stage_line(line, run.build_id) do
      {:ok, stage} -> %{run | stages: upsert_stage(run.stages, stage)}
      :skip -> run
    end
  end

  # Port-stream variant of the SERVED marker: latest-wins onto the run. A line
  # that is not a SERVED marker leaves the run untouched, so this is safe to run
  # over every line of a 900-line `npm ci`.
  defp parse_served(run, line) do
    case parse_served_line(line) do
      {:ok, port, slot} -> %{run | served_port: port, served_slot: slot}
      :skip -> run
    end
  end

  @doc """
  Parse the engine's report-only `SERVED` marker into `{:ok, port, slot}`, or
  `:skip` for any other line.

  Both halves are INDEPENDENTLY nullable, and neither is ever invented: a `none`
  port (Caddy names no upstream for this site) yields `nil` while the slot may
  still be known, and a slot outside `a`/`b` yields `nil` while the port stands.
  The port is the stronger fact — it is the literal the Caddyfile carries — so a
  reader that only trusts one should trust that one.
  """
  @spec parse_served_line(String.t()) :: {:ok, pos_integer() | nil, String.t() | nil} | :skip
  def parse_served_line(line) when is_binary(line) do
    case Regex.run(@served_re, line, capture: :all_but_first) do
      [port, slot] -> {:ok, served_port(port), served_slot(slot)}
      _no_match -> :skip
    end
  end

  def parse_served_line(_), do: :skip

  defp served_port(raw) do
    case Integer.parse(raw) do
      {port, ""} when port > 0 -> port
      _ -> nil
    end
  end

  defp served_slot(raw) when raw in @served_slots, do: raw
  defp served_slot(_), do: nil

  @doc """
  The HEALTH stage's exit code, or `nil` when HEALTH was never MEASURED.

  NULLABLE ON PURPOSE, and the nil is the whole point: `0` is the SUCCESS code,
  so a health field that defaulted to zero would render "the health stage never
  ran" as "the health stage passed" — a build that died in BUILD would read as
  health-certified. Three answers, three values:

    * HEALTH `ok`     -> `0`  — it ran and the probe passed.
    * HEALTH `failed` -> `14` — the engine's cross-engine HEALTH-failed exit code
      (`stage_exit_code("HEALTH")`, so this cannot drift from the verdict path).
    * anything else (`started` with no verdict yet, `skipped`, `noop`, or no
      HEALTH stage in the fold at all) -> `nil`.

  Derived from the stage fold rather than persisted, so it is available from
  EVERY status shape — the live Port run, the reconstructed systemd render, and
  the durable terminal record all carry `stages`.
  """
  @spec health_exit_code([map()]) :: non_neg_integer() | nil
  def health_exit_code(stages) when is_list(stages) do
    case Enum.find(stages, &(stage_name(&1) == "HEALTH")) do
      nil -> nil
      stage -> health_code_for(stage_status(stage))
    end
  end

  def health_exit_code(_), do: nil

  defp health_code_for("ok"), do: 0
  defp health_code_for("failed"), do: stage_exit_code("HEALTH")
  defp health_code_for(_other), do: nil

  # A stage arrives atom-keyed from the live paths and string-keyed from a
  # decoded terminal record. Both are read, because a health code that silently
  # vanished once the run went terminal would be exactly the "not measured"
  # answer for something that WAS measured.
  defp stage_name(%{name: name}), do: name
  defp stage_name(%{"name" => name}), do: name
  defp stage_name(_), do: nil

  defp stage_status(%{status: status}), do: status
  defp stage_status(%{"status" => status}), do: status
  defp stage_status(_), do: nil

  # The ONE stage parser both sinks share. Returns `{:ok, stage}` for a
  # well-formed, whitelisted BPSTAGE line, else `:skip`. RAW tokens (no
  # normalization). build_id falls back to the run/manifest's own when the line
  # emits it empty.
  defp parse_stage_line(line, default_build_id) do
    case Regex.run(@stage_re, line, capture: :all_but_first) do
      [name, status | rest] when name in @stage_names and status in @stage_statuses ->
        {build_id, detail} = stage_rest(rest)

        {:ok,
         %{
           name: name,
           status: status,
           build_id: blank_to_nil(build_id) || default_build_id,
           detail: blank_to_nil(detail),
           at: DateTime.utc_now()
         }}

      _no_match ->
        :skip
    end
  end

  # Trailing optional groups that never participated are dropped by Regex.run; a
  # skipped MIDDLE group comes back as "". Both shapes mean "absent".
  defp stage_rest([]), do: {nil, nil}
  defp stage_rest([build_id]), do: {build_id, nil}
  defp stage_rest([build_id, detail | _]), do: {build_id, detail}

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s

  # Upsert by stage name, preserving first-seen order: `started` is later
  # overwritten by `ok`/`failed` for the same stage rather than appended.
  defp upsert_stage(stages, stage) do
    if Enum.any?(stages, &(&1.name == stage.name)) do
      Enum.map(stages, fn existing ->
        if existing.name == stage.name, do: stage, else: existing
      end)
    else
      stages ++ [stage]
    end
  end

  # ── failure reasons (Port stream) ─────────────────────────────────────────

  defp failure_reason(0, _run), do: nil

  # The Port fallback is where the typed non-deploy exits arrive AS exit codes
  # (a transient unit's code is swept by `--collect`; a Port delivers it). A
  # teardown run must speak teardown here too — never `exit_label/1`'s
  # deploy/rollback voice. Deploy and rollback runs keep the arm below verbatim.
  defp failure_reason(code, %{mode: :teardown} = run) do
    case reason_tail(run) do
      "" -> teardown_exit_label(code)
      tail -> "#{teardown_exit_label(code)}: #{tail}"
    end
  end

  defp failure_reason(code, run) do
    case reason_tail(run) do
      "" -> exit_label(code)
      tail -> "#{exit_label(code)}: #{tail}"
    end
  end

  # The REAL reason, not a generic message: the trailing meaningful lines of the
  # child's own stream. `run.log` is newest-first internally.
  defp reason_tail(run) do
    run.log
    |> Enum.reject(&noise_line?/1)
    |> Enum.take(@reason_lines)
    |> Enum.reverse()
    |> Enum.map_join(" | ", &String.trim/1)
  end

  defp noise_line?(line) do
    String.trim(line) == "" or Regex.match?(@stage_re, line)
  end

  # site-deploy.sh's typed exit codes (its header block is the contract).
  defp exit_label(2), do: "usage error (exit 2)"
  defp exit_label(10), do: "missing site source dir (exit 10)"
  defp exit_label(11), do: "missing or invalid required input (exit 11)"
  defp exit_label(12), do: "BUILD failed (exit 12)"
  defp exit_label(13), do: "STAGE failed — no dist/ (exit 13)"
  defp exit_label(14), do: "HEALTH gate failed — not switched (exit 14)"
  # Exit 15 has TWO producers in the engine and the label may not pick one: the
  # per-slug deploy lock (`flock -w 1200`) AND the box's fleet build gate
  # (`flock -w 900`, site-deploy-common.sh). Naming only the first sent an
  # operator to the wrong lock — the box-wide queue is the far likelier cause,
  # and it is the one the door above now refuses up front.
  defp exit_label(15),
    do:
      "gave up waiting for a deploy lock — the box's fleet build slot (900s) " <>
        "or this site's own deploy lock (1200s) (exit 15)"

  defp exit_label(16), do: "SWITCH failed (exit 16)"
  defp exit_label(21), do: "rollback: no previous release (exit 21)"
  defp exit_label(22), do: "rollback: not supported on this site (exit 22)"
  defp exit_label(23), do: "rollback: a deploy is in flight (exit 23)"
  defp exit_label(24), do: "rollback failed (exit 24)"
  defp exit_label(-1), do: "deploy process died abnormally"
  defp exit_label(-2), do: "deploy exceeded its deadline and was force-closed"
  defp exit_label(code), do: "deploy failed (exit #{code})"

  # ── deadline timers (systemd path) ────────────────────────────────────────

  defp arm_unit_deadline(state, slug, remaining_ms) do
    state = cancel_timer(state, slug)

    if remaining_ms <= 0 do
      # Already over the deadline (e.g. a long build re-attached after a slow
      # restart): fire immediately so the finalizer stops + finalizes it.
      send(self(), {:unit_deadline, slug})
      state
    else
      ref = Process.send_after(self(), {:unit_deadline, slug}, remaining_ms)
      Map.update!(state, :timers, &Map.put(&1, slug, ref))
    end
  end

  defp cancel_timer(state, slug) do
    case Map.fetch(state.timers, slug) do
      {:ok, ref} ->
        _ = Process.cancel_timer(ref)
        Map.update!(state, :timers, &Map.delete(&1, slug))

      :error ->
        state
    end
  end

  # ── manifests + run-state dir ─────────────────────────────────────────────

  @doc """
  A config-injectable dir under which every run's manifest + status + log + env
  files live. Must SURVIVE a BEAM restart (it is how `init/1` re-attaches), so
  it defaults under the repo root, not a per-boot tmp.

  Public because that survival property is the reason
  `Barkpark.Sites.ServingMemory` sites its record here rather than in journald:
  the dir is bounded by COUNT only (`@default_max_terminal_records`, no age
  term) and is not wiped, whereas journald is age- and volume-bounded.
  """
  @spec run_state_dir() :: String.t()
  def run_state_dir do
    Keyword.get(config(), :run_state_dir) || Path.join(run_cd(), ".bp-site-deploy-runs")
  end

  # Reachability: the argument is `run_state_dir()` — a config constant or a
  # repo-root join, with no caller-supplied component at all.
  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_run_state_dir do
    dir = run_state_dir()
    File.mkdir_p!(dir)
    dir
  end

  defp manifest_path(dir, slug), do: Path.join(dir, "#{slug}.manifest.json")

  # Reachability: `manifest_path/2` joins `run_state_dir()` with a validated
  # slug and a fixed `.manifest.json` suffix — no traversable component.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_manifest(dir, manifest) do
    File.write(manifest_path(dir, manifest.slug), Jason.encode!(encode_manifest(manifest)))
  rescue
    error -> {:error, error}
  end

  defp load_manifest_for(slug) do
    case runner_mode() do
      :systemd -> read_manifest(manifest_path(run_state_dir(), slug))
      :port -> nil
    end
  end

  # Reachability: callers pass either `manifest_path/2` (validated slug) or a
  # `File.ls(run_state_dir())` entry filtered to `*.manifest.json` — both are
  # names this module wrote itself into a dir it owns.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_manifest(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, json} <- Jason.decode(raw) do
      decode_manifest(json)
    else
      _ -> nil
    end
  end

  defp list_manifests(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".manifest.json"))
        |> Enum.map(&read_manifest(Path.join(dir, &1)))
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp encode_manifest(m) do
    %{
      "slug" => m.slug,
      "run_tag" => manifest_tag(m),
      "build_id" => m.build_id,
      "content_rev" => m.content_rev,
      "mode" => Atom.to_string(m.mode),
      "runtime_target" => Atom.to_string(m.runtime_target),
      "unit_name" => m.unit_name,
      "status_file" => m.status_file,
      "log_file" => m.log_file,
      "build_env_file" => m.build_env_file,
      "prebuilt_dir" => Map.get(m, :prebuilt_dir),
      "prebuilt_sha256" => Map.get(m, :prebuilt_sha256),
      "started_at" => DateTime.to_iso8601(m.started_at)
    }
  end

  defp decode_manifest(%{"slug" => slug, "unit_name" => unit} = j)
       when is_binary(slug) and is_binary(unit) do
    %{
      slug: slug,
      run_tag: j["run_tag"],
      build_id: j["build_id"],
      content_rev: j["content_rev"],
      mode: safe_atom(j["mode"], [:deploy, :rollback, :teardown], :deploy),
      runtime_target: safe_atom(j["runtime_target"], [:static, :node], :static),
      unit_name: unit,
      status_file: j["status_file"],
      log_file: j["log_file"],
      build_env_file: j["build_env_file"],
      prebuilt_dir: j["prebuilt_dir"],
      prebuilt_sha256: j["prebuilt_sha256"],
      started_at: parse_dt(j["started_at"])
    }
  end

  defp decode_manifest(_), do: nil

  # Never String.to_atom on file data — map only the closed enum, else default.
  defp safe_atom(value, allowed, default) do
    Enum.find(allowed, default, &(Atom.to_string(&1) == value))
  end

  defp parse_dt(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_dt(_), do: DateTime.utc_now()

  # Start a fresh status + log so a redeploy of the same slug never folds a
  # previous run's stages.
  # Reachability: the only call site (:477) passes `[status_file, log_file]`,
  # both just built from run_state_dir + a validated slug.
  # sobelow_skip ["Traversal.FileModule"]
  defp fresh_run_files(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.write(path, "") do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: secs}} -> DateTime.from_unix!(secs)
      _ -> nil
    end
  end

  # Keep the run-state dir bounded: newest @max_tracked_runs manifests survive;
  # for each evicted one, sweep its manifest/status/log/env quartet. A unit still
  # active is NEVER evicted (its files are load-bearing for re-attach).
  # Reachability: every swept path comes from a manifest this module wrote into
  # `run_state_dir()`; the sweep is confined to that dir and never takes input.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune_run_state_dir(dir) do
    manifests = list_manifests(dir)

    if length(manifests) > @max_tracked_runs do
      {active, idle} =
        Enum.split_with(manifests, &(is_active(&1.unit_name) in @active_states))

      keep =
        idle
        |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
        |> Enum.take(max(@max_tracked_runs - length(active), 0))

      keep_slugs = MapSet.new(active ++ keep, & &1.slug)

      for m <- manifests, not MapSet.member?(keep_slugs, m.slug) do
        _ = File.rm(manifest_path(dir, m.slug))
        _ = sweep_path(dir, m.status_file, &File.rm/1)
        # Through evict_build_log/2, never a bare File.rm: a removed log MUST
        # leave a tombstone, or the deployment reads back as never-recorded.
        _ = sweep_path(dir, m.log_file, &evict_build_log(&1, :count))
        # The staged prebuilt tree is the BIGGEST thing a run leaves behind (up
        # to the 64 MiB extraction cap, against a 3.8 GB box), so it is swept
        # with the rest of the quartet rather than living forever after a
        # one-shot slug.
        _ = sweep_path(dir, m.prebuilt_dir, &File.rm_rf/1)
        _ = sweep_path(dir, m.build_env_file, &File.rm/1)
      end
    end

    # The manifest cap above counts SLUGS and has never fired on this box. The
    # caps that actually bound a 1,000-builds/day dir count DEPLOYMENTS.
    _ = prune_build_logs(dir)
    _ = prune_orphan_run_files(dir)
    :ok
  rescue
    _ -> :ok
  end

  # Reachability: `dir` is `run_state_dir()`; `path` came back OUT of a manifest
  # on disk, which is exactly why it is checked before it is followed.
  # sobelow_skip ["Traversal.FileModule"]
  defp sweep_path(dir, path, fun) when is_binary(path) do
    if inside_run_state_dir?(dir, path) do
      fun.(path)
    else
      # A manifest naming a path outside the dir it lives in is corrupt or
      # planted; either way the sweep REFUSES rather than follows. The sweep is
      # the one path in this module that deletes at scale, and `status_file` /
      # `log_file` / `build_env_file` / `prebuilt_dir` are JSON strings read back
      # from disk — containment is what keeps a bounded dir from becoming an
      # arbitrary `rm`.
      Logger.warning(
        "[site-deploy] retention refused to follow #{inspect(path)} — a manifest in " <>
          "#{dir} named a path outside it"
      )

      :refused
    end
  end

  defp sweep_path(_dir, _path, _fun), do: :noop

  defp inside_run_state_dir?(dir, path) do
    root = Path.expand(dir)
    String.starts_with?(Path.expand(path), root <> "/")
  end

  @orphan_staging_rx ~r/\.staging-\d+\z/

  # An entry the ORPHAN sweep may consider. The three suffix sweeps each own a
  # record they can name from the directory alone; these are the ones whose only
  # name lives inside a manifest — so once that manifest is overwritten (it is
  # slug-keyed, the files are tag-keyed) nothing can name them again.
  defp orphan_candidate?(name) do
    String.ends_with?(name, ".status") or String.ends_with?(name, ".env") or
      String.ends_with?(name, ".prebuilt") or Regex.match?(@orphan_staging_rx, name)
  end

  # ── the run-state dir census (dr-w23) ─────────────────────────────────────
  #
  # Every durable thing this module (and ServingMemory) sites in the run-state
  # dir, and the bound that holds it. A record with no bound is a leak, and this
  # list is the place a later auditor checks that claim against the writers.
  #
  #   <slug>.manifest.json      1 per SLUG (overwritten)  @max_tracked_runs = 32
  #   <slug>-<tag>.log          1 per DEPLOYMENT          prune_build_logs/1:
  #                                                       age 7d / count 2,000 /
  #                                                       bytes 256 MiB
  #   <slug>-<tag>.terminal.json 1 per DEPLOYMENT         prune_terminal_records/2
  #                                                       count 10,000
  #   <slug>-<tag>.status       1 per DEPLOYMENT          THIS SWEEP (was: only
  #                                                       via the manifest that
  #                                                       names it, which the
  #                                                       next deploy of the same
  #                                                       slug overwrites)
  #   <slug>-<tag>.env          1 per DEPLOYMENT          unlinked at finalize;
  #                                                       THIS SWEEP catches the
  #                                                       ones a crash stranded
  #                                                       (they carry
  #                                                       BARKPARK_TOKEN= in
  #                                                       plaintext at 0600)
  #   <slug>.prebuilt/          1 per SLUG (replaced)     quartet sweep on
  #                                                       eviction + THIS SWEEP
  #                                                       once no manifest names
  #                                                       it
  #   <slug>.prebuilt.staging-N transient                 removed by
  #                                                       PrebuiltArtifact on
  #                                                       both exits; THIS SWEEP
  #                                                       catches a crash's
  #                                                       remains
  #   serving-memory.json(.tmp) 1, FIXED NAME             bounded at 1 by the
  #                                                       name: every write
  #                                                       replaces it. RULED
  #                                                       intentionally unswept —
  #                                                       it is the record whose
  #                                                       whole value is
  #                                                       surviving.
  #
  # Growth rate the sweep is sized against (ESTIMATED — no prod access; from
  # `@default_max_build_logs = 2_000` and the module's own 1,000-builds/day
  # note): ~1,000 `.status` files/day at a few hundred bytes each, i.e. the
  # unswept case was ~0.4 M files and ~0.1 GB/year against a 3.8 GB box.
  #
  # Sweeps every candidate the dir holds that NO manifest names and that has sat
  # longer than `orphan_grace_ms`. Returns how many it took.
  # Reachability: every path is `run_state_dir()` + an entry of its own listing.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune_orphan_run_files(dir) do
    referenced =
      for m <- list_manifests(dir),
          path <- [m.status_file, m.log_file, m.build_env_file, m.prebuilt_dir],
          is_binary(path),
          into: MapSet.new(),
          do: path

    grace = retention_caps().orphan_grace_ms
    now = DateTime.utc_now()

    entries =
      case File.ls(dir) do
        {:ok, names} -> for name <- names, orphan_candidate?(name), do: Path.join(dir, name)
        {:error, _} -> []
      end

    swept =
      for path <- entries,
          not MapSet.member?(referenced, path),
          mtime = entry_mtime(path),
          mtime != nil,
          DateTime.diff(now, mtime, :millisecond) > grace,
          reduce: 0 do
        taken ->
          _ = File.rm_rf(path)
          taken + 1
      end

    if swept > 0 do
      Logger.info(
        "[site-deploy] run-state orphan sweep removed #{swept} unreferenced entr(ies) " <>
          "older than #{grace}ms"
      )
    end

    swept
  rescue
    error ->
      Logger.warning("[site-deploy] run-state orphan sweep skipped: #{inspect(error)}")
      0
  end

  # `log_stat/1`'s twin for entries that are NOT regular files: a stranded
  # staging tree is a directory, and a sweep that only stats regular files would
  # report the biggest orphan as absent.
  # sobelow_skip ["Traversal.FileModule"]
  defp entry_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> DateTime.from_unix!(mtime)
      _ -> nil
    end
  end

  # ── durable per-build record (the tombstone) ──────────────────────────────

  defp terminal_record_path(dir, slug, tag),
    do: Path.join(dir, "#{slug}-#{tag}.terminal.json")

  # Derive a log's record path from the log itself — the two are named from the
  # SAME `<slug>-<tag>` stem, so an eviction can always find the record to mark
  # without re-reading a manifest that may already be gone.
  defp record_path_for_log(log_path),
    do: String.replace_suffix(log_path, ".log", ".terminal.json")

  # Written ONCE per deployment, at finalize. ~1 KB, and it outlives the log.
  # Reachability: the path is `run_state_dir()` + a validated slug + a
  # charset-validated build_id (or a server-generated `<mode>-<ms>` tag).
  # sobelow_skip ["Traversal.FileModule"]
  defp write_terminal_record(manifest, render) do
    dir = run_state_dir()
    tag = manifest_tag(manifest)
    log_file = manifest.log_file

    payload = %{
      "slug" => manifest.slug,
      "run_tag" => tag,
      "build_id" => Map.get(render, :build_id) || manifest.build_id,
      "content_rev" => manifest.content_rev,
      "mode" => to_string(manifest.mode),
      "runtime_target" => to_string(manifest.runtime_target),
      # The EXACT unit name, persisted so a journald fallback is addressable by
      # name (measured 0.16s) instead of by glob (measured 121s). The manifest
      # carried it but the manifest is a slug-keyed pointer that gets
      # overwritten; the record is per deployment and durable.
      "unit_name" => manifest.unit_name,
      "journal_command" => journal_command(manifest.unit_name),
      "exit_code" => Map.get(render, :exit_code),
      "failure_reason" => Map.get(render, :failure_reason),
      "stages" => Enum.map(Map.get(render, :stages) || [], &encode_record_stage/1),
      # The served slot outlives the unit. Persisted rather than re-derived,
      # because the Caddyfile it was read out of has moved on by the time anyone
      # asks a terminal record what THIS build ended up serving.
      "served_port" => Map.get(render, :served_port),
      "served_slot" => Map.get(render, :served_slot),
      "log_file" => log_file,
      "log_bytes" => file_size(log_file),
      "log_state" => Atom.to_string(live_log_state(log_file)),
      "evicted_at" => nil,
      "started_at" => iso_or_nil(manifest.started_at),
      "finished_at" => iso_or_nil(Map.get(render, :finished_at) || DateTime.utc_now())
    }

    # The record is named from the LOG's own stem whenever a log path exists, so
    # `record_path_for_log/1` — the only name an eviction has to work from once
    # the manifest is gone — always resolves to the record this call wrote. For a
    # tagged run the two names are identical; for a PRE-CHANGE manifest (log
    # `<slug>.log`, tag "legacy") they diverge, and deriving from the log is what
    # keeps that run's eviction honest instead of orphan-tombstoning it.
    record_path =
      if is_binary(log_file),
        do: record_path_for_log(log_file),
        else: terminal_record_path(dir, manifest.slug, tag)

    File.write(record_path, Jason.encode!(payload))
  rescue
    error ->
      Logger.warning("[site-deploy] could not write the terminal record: #{inspect(error)}")
      :ok
  end

  defp encode_record_stage(stage) do
    %{
      "name" => Map.get(stage, :name),
      "status" => Map.get(stage, :status),
      "detail" => Map.get(stage, :detail)
    }
  end

  # The EXACT-name journald query. A glob (`bp-site-build-<slug>-*`) has to walk
  # every journal file on the box; a `_SYSTEMD_UNIT=` match is indexed.
  defp journal_command(unit) when is_binary(unit),
    do: "journalctl --no-pager -u #{unit}"

  defp journal_command(_), do: nil

  defp iso_or_nil(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso_or_nil(_), do: nil

  # Reachability: only ever a path this module wrote into run_state_dir().
  # sobelow_skip ["Traversal.FileModule"]
  defp file_size(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp file_size(_), do: nil

  # Is the log ON THE BOX right now? `:available` / `:missing` only — `:evicted`
  # is a CLAIM about history that only a tombstone can make.
  defp live_log_state(path) when is_binary(path) do
    if File.regular?(path), do: :available, else: :missing
  end

  defp live_log_state(_), do: :missing

  # The same question, but allowed to consult history: a log that is gone AND
  # tombstoned was EVICTED; one that is gone with no tombstone never arrived.
  defp disk_log_state(path) when is_binary(path) do
    case live_log_state(path) do
      :available ->
        :available

      :missing ->
        case read_terminal_record(record_path_for_log(path)) do
          %{"log_state" => "evicted"} -> :evicted
          _ -> :missing
        end
    end
  end

  defp disk_log_state(_), do: :missing

  # Reachability: `run_state_dir()` + a validated slug + a validated tag.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_terminal_record(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"slug" => slug} = json} when is_binary(slug) <- Jason.decode(raw) do
      json
    else
      _ -> nil
    end
  end

  defp list_terminal_records(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".terminal.json"))
        |> Enum.map(&read_terminal_record(Path.join(dir, &1)))
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  # The record for ONE deployment. A build_id addresses its own build directly
  # (that is the whole point); `nil` means "the newest record for this slug".
  defp find_terminal_record(slug, nil), do: newest_record(records_for(slug))

  defp find_terminal_record(slug, build_id) when is_binary(build_id) do
    dir = run_state_dir()

    case read_terminal_record(terminal_record_path(dir, slug, build_id)) do
      nil ->
        slug
        |> records_for()
        |> Enum.filter(&(&1["build_id"] == build_id))
        |> newest_record()

      record ->
        record
    end
  end

  defp records_for(slug) do
    run_state_dir()
    |> list_terminal_records()
    |> Enum.filter(&(&1["slug"] == slug))
  end

  defp newest_record([]), do: nil
  defp newest_record(records), do: Enum.max_by(records, &to_string(&1["finished_at"]))

  defp load_latest_terminal_record(slug) do
    case runner_mode() do
      :systemd -> find_terminal_record(slug, nil)
      :port -> nil
    end
  end

  # A deployment nobody has any record of. The DIFFERENT answer.
  defp absent_record(slug, build_id) do
    %{
      slug: slug,
      build_id: build_id,
      record: :none,
      log_state: :never_recorded,
      log_path: nil,
      log_bytes: nil,
      exit_code: nil,
      failure_reason: nil,
      stages: [],
      unit_name: nil,
      journal_command: nil,
      mode: nil,
      runtime_target: nil,
      started_at: nil,
      finished_at: nil,
      evicted_at: nil
    }
  end

  defp render_terminal_record(record) do
    log_path = record["log_file"]

    %{
      slug: record["slug"],
      build_id: record["build_id"],
      run_tag: record["run_tag"],
      record: :terminal,
      # Re-derived from the FILESYSTEM, not trusted from the record: a log that
      # is gone but was never tombstoned is `:missing`, not a phantom
      # `:available`. The tombstone's `:evicted` wins when the bytes are gone.
      log_state: resolved_log_state(record, log_path),
      log_path: log_path,
      log_bytes: record["log_bytes"],
      exit_code: record["exit_code"],
      failure_reason: record["failure_reason"],
      stages: record["stages"] || [],
      served_port: record["served_port"],
      served_slot: record["served_slot"],
      unit_name: record["unit_name"],
      journal_command: record["journal_command"] || journal_command(record["unit_name"]),
      mode: record["mode"],
      runtime_target: record["runtime_target"],
      started_at: record["started_at"],
      finished_at: record["finished_at"],
      evicted_at: record["evicted_at"]
    }
  end

  defp resolved_log_state(record, log_path) do
    case live_log_state(log_path) do
      :available -> :available
      :missing -> if record["log_state"] == "evicted", do: :evicted, else: :missing
    end
  end

  # A status/1 answer built from the record alone (the manifest is gone). Same
  # shape as every other status map — plus the honest `log_state`.
  defp status_from_record(record) do
    rendered = render_terminal_record(record)

    %{
      state: :done,
      slug: rendered.slug,
      build_id: rendered.build_id,
      content_rev: record["content_rev"],
      mode: safe_atom(record["mode"], [:deploy, :rollback, :teardown], :deploy),
      runtime_target: safe_atom(record["runtime_target"], [:static, :node], :static),
      stages: Enum.map(rendered.stages, &decode_record_stage/1),
      served_port: rendered.served_port,
      served_slot: rendered.served_slot,
      exit_code: rendered.exit_code,
      failure_reason: rendered.failure_reason,
      # The BYTES are not served here — the record survived, the log may not
      # have, and either way this slice does not put raw build output on a
      # response. `log_state` says which it is.
      log: [],
      log_state: rendered.log_state,
      log_path: rendered.log_path,
      unit_name: rendered.unit_name,
      started_at: parse_dt_or_nil(record["started_at"]),
      finished_at: parse_dt_or_nil(record["finished_at"])
    }
  end

  defp decode_record_stage(stage) do
    %{
      name: stage["name"],
      status: stage["status"],
      build_id: nil,
      detail: stage["detail"],
      at: nil
    }
  end

  defp parse_dt_or_nil(iso) when is_binary(iso), do: parse_dt(iso)
  defp parse_dt_or_nil(_), do: nil

  # ── build-log retention: bytes AND count AND age ──────────────────────────

  # Enforce all three caps and REPORT which one was effective. Ordered
  # age → count → bytes, and `bound` names the tightest: a cap that condemned
  # logs INSIDE the set the previous cap already allowed is the one actually
  # holding the line.
  # Reachability: `dir` is `run_state_dir()`; every candidate is a `*.log` entry
  # inside it, never a caller-supplied path.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune_build_logs(dir) do
    caps = retention_caps()
    protected = active_log_paths(dir)

    {aged, fresh} =
      dir
      |> build_log_entries()
      |> Enum.reject(&MapSet.member?(protected, &1.path))
      |> order_newest_first()
      |> Enum.split_with(&older_than?(&1, caps.max_age_ms))

    {within_count, over_count} = Enum.split(fresh, caps.max_logs)
    {keep, over_bytes} = split_at_byte_cap(within_count, caps.max_bytes)

    for entry <- aged, do: evict_build_log(entry.path, :age)
    for entry <- over_count, do: evict_build_log(entry.path, :count)
    for entry <- over_bytes, do: evict_build_log(entry.path, :bytes)

    _ = prune_terminal_records(dir, caps.max_terminal_records)

    report = %{
      bound: effective_bound(aged, over_count, over_bytes),
      evicted: length(aged) + length(over_count) + length(over_bytes),
      evicted_by: %{age: length(aged), count: length(over_count), bytes: length(over_bytes)},
      kept: length(keep),
      kept_bytes: Enum.reduce(keep, 0, &(&1.size + &2)),
      protected: MapSet.size(protected),
      caps: caps
    }

    if report.evicted > 0 do
      Logger.info(
        "[site-deploy] build-log retention evicted #{report.evicted} log(s) " <>
          "(age #{report.evicted_by.age}, count #{report.evicted_by.count}, " <>
          "bytes #{report.evicted_by.bytes}); effective bound=#{report.bound}; " <>
          "kept #{report.kept} log(s) / #{report.kept_bytes} bytes"
      )
    end

    report
  rescue
    error ->
      Logger.warning("[site-deploy] build-log retention skipped: #{inspect(error)}")
      %{bound: :error, evicted: 0, evicted_by: %{age: 0, count: 0, bytes: 0}, kept: 0}
  end

  defp effective_bound(aged, over_count, over_bytes) do
    cond do
      over_bytes != [] -> :bytes
      over_count != [] -> :count
      aged != [] -> :age
      true -> :none
    end
  end

  defp build_log_entries(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        for name <- entries,
            String.ends_with?(name, ".log"),
            path = Path.join(dir, name),
            stat = log_stat(path),
            stat != nil,
            do: stat

      {:error, _} ->
        []
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp log_stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{type: :regular, size: size, mtime: mtime}} ->
        %{path: path, size: size, mtime: DateTime.from_unix!(mtime)}

      _ ->
        nil
    end
  end

  # A log whose unit is STILL RUNNING is never a retention candidate — evicting
  # it would delete the file the engine is actively teeing into.
  defp active_log_paths(dir) do
    for m <- list_manifests(dir),
        is_binary(m.log_file),
        is_active(m.unit_name) in @active_states,
        into: MapSet.new(),
        do: m.log_file
  end

  defp older_than?(entry, max_age_ms),
    do: DateTime.diff(DateTime.utc_now(), entry.mtime, :millisecond) > max_age_ms

  # Newest-first ordering, and it must be TOTAL. `File.stat/2` reports mtime at
  # one-second resolution, so builds of the same slug that finish inside the same
  # second tie — and a tie left to `Enum.sort_by/3`'s stable sort falls through to
  # `File.ls/1`'s arbitrary directory order, which would let the OS pick which
  # build log the byte and count caps delete. Tie-breaking on the path makes that
  # choice deterministic: the same directory always evicts the same files, so a
  # sweep is reproducible and "which build lost its log" is answerable.
  #
  # The path is a TIE-BREAK, not a recency claim — within one second the
  # filesystem does not know which build finished last, and neither do we. The
  # sort key is the mtime as a unix integer rather than the %DateTime{}: a tuple
  # sorts by Erlang term order, under which structs compare as maps (by size,
  # then keys, then values) and NOT chronologically.
  defp recency_key(entry), do: {DateTime.to_unix(entry.mtime), entry.path}

  # Newest-first: keep taking until the running total would exceed the cap; the
  # remainder is condemned. The newest log is ALWAYS kept even if it alone is
  # over the cap — a bound that deletes the build you are reading is not a bound,
  # it is a bug.
  defp split_at_byte_cap(entries, max_bytes) do
    {keep, over, _total} =
      Enum.reduce(entries, {[], [], 0}, fn entry, {keep, over, total} ->
        cond do
          keep == [] -> {[entry], over, entry.size}
          total + entry.size > max_bytes -> {keep, [entry | over], total}
          true -> {[entry | keep], over, total + entry.size}
        end
      end)

    {Enum.reverse(keep), Enum.reverse(over)}
  end

  # Remove a build log AND leave a tombstone. This is the ONLY way a log may be
  # deleted: without the tombstone, an evicted deployment reads back identically
  # to one that never happened, which is precisely the dishonesty D22 forbids.
  # Reachability: `path` is a `*.log` entry inside run_state_dir(), or a
  # manifest's own log_file — never caller data.
  # sobelow_skip ["Traversal.FileModule"]
  defp evict_build_log(path, cap) when is_binary(path) do
    if File.regular?(path) do
      _ = File.rm(path)
      _ = tombstone(path, cap)
      :evicted
    else
      :noop
    end
  rescue
    _ -> :noop
  end

  defp evict_build_log(_path, _cap), do: :noop

  # Mark the deployment's record evicted. When there is no record (a run that
  # never finalized — the BEAM died, the unit vanished) write a MINIMAL one, so
  # even then "evicted" and "never recorded" stay different answers.
  # sobelow_skip ["Traversal.FileModule"]
  defp tombstone(log_path, cap) do
    record_path = record_path_for_log(log_path)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    payload =
      case read_terminal_record(record_path) do
        nil -> orphan_tombstone(log_path, cap)
        record -> record
      end
      |> Map.merge(%{
        "log_state" => "evicted",
        "evicted_at" => now,
        "evicted_by" => Atom.to_string(cap)
      })

    File.write(record_path, Jason.encode!(payload))
  rescue
    _ -> :ok
  end

  # A log with no terminal record: the run never reached finalize, so there is no
  # exit code to report and saying so IS the honest answer.
  defp orphan_tombstone(log_path, _cap) do
    stem = Path.basename(log_path, ".log")

    %{
      "slug" => stem |> String.split("-") |> List.first(),
      "run_tag" => stem,
      "build_id" => nil,
      "unit_name" => nil,
      "exit_code" => nil,
      "failure_reason" =>
        "the build log was evicted by retention before this run was finalized — " <>
          "no exit code was ever recorded",
      "stages" => [],
      "log_file" => log_path,
      "log_bytes" => nil,
      "started_at" => nil,
      "finished_at" => nil
    }
  end

  # Records are the tombstones — they must outlive their logs — so they are
  # bounded only by COUNT, and generously.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune_terminal_records(dir, max_records) do
    case File.ls(dir) do
      {:ok, entries} ->
        records =
          for name <- entries,
              String.ends_with?(name, ".terminal.json"),
              path = Path.join(dir, name),
              stat = log_stat(path),
              stat != nil,
              do: stat

        # Same total ordering as the log sweep, and for a sharper reason: these
        # tombstones are what make an evicted deploy read as `:evicted` instead
        # of `:never_recorded`. Sorting on mtime alone left ties to `File.ls/1`'s
        # arbitrary order, so the OS decided which deployment lost its record.
        # The decision itself lives in `terminal_records_to_evict/2` so it can be
        # observed apart from the directory that produced the entries.
        records
        |> terminal_records_to_evict(max_records)
        |> Enum.each(&File.rm(&1.path))

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Which terminal records a sweep condemns, given the stat entries and the count
  cap — the eviction decision with the filesystem taken back out of it.

  PUBLIC and pure so a test can hand it the entries in an ADVERSARIAL order. The
  whole hazard here is invisible from a directory: `File.stat/2` reports mtime at
  one-second resolution, tombstones written inside the same second tie on it, and
  a tie left to `Enum.sort_by/3`'s stable sort silently inherits whatever order
  `File.ls/1` returned. A test that can only ever see the order the filesystem
  happened to hand back cannot tell a total order from a lucky one — on one host
  the arbitrary order agrees with the intended answer and the bug reads as fixed.
  Feeding this function an order that DISAGREES with the answer is what makes the
  collapse observable everywhere rather than only where the OS is unkind.
  """
  @spec terminal_records_to_evict([map()], non_neg_integer()) :: [map()]
  def terminal_records_to_evict(entries, max_records) do
    entries
    |> order_newest_first()
    |> Enum.drop(max_records)
  end

  @doc """
  Retention's newest-first ordering over stat entries, as a TOTAL order — the one
  answer to "which of these is newer" that every sweep in this module uses, so the
  log cap and the tombstone cap cannot disagree about it.

  Ties on the one-second mtime break on the path, descending; see `recency_key/1`
  for why the key is the unix integer and not the `%DateTime{}`. PUBLIC for the
  same reason as `terminal_records_to_evict/2`: the order has to be observable
  independently of the directory listing that fed it.
  """
  @spec order_newest_first([map()]) :: [map()]
  def order_newest_first(entries), do: Enum.sort_by(entries, &recency_key/1, :desc)

  # ── config knobs ──────────────────────────────────────────────────────────

  defp run_deadline_ms, do: Keyword.get(config(), :run_deadline_ms, @default_run_deadline_ms)
  defp memory_max, do: Keyword.get(config(), :memory_max, @default_memory_max)
  defp cpu_quota, do: Keyword.get(config(), :cpu_quota, @default_cpu_quota)

  defp ctl_cmd_timeout_ms,
    do: Keyword.get(config(), :ctl_cmd_timeout_ms, @default_ctl_cmd_timeout_ms)

  @doc """
  How long `trigger/1` waits for the door to answer, in ms — the DEFAULT is
  `#{@trigger_call_timeout_ms}` and must stay longer than the ctl round-trip the
  trigger's critical section is allowed to make (a shorter budget is the dr-w8-s2
  defect: 265 rows of `feature_not_configured` for builds that ran fine).

  PUBLIC so the default can be OBSERVED by a test without overriding it — this
  is the same expression `trigger/1` passes to `safe_call/3`, so a pin on it
  cannot pass while the door uses a different number. Overridable via config
  `:trigger_call_timeout_ms` so a test can shrink the budget below the work the
  door actually does and observe the unanswered-trigger path for real.
  """
  @spec trigger_call_timeout_ms() :: pos_integer()
  def trigger_call_timeout_ms,
    do: Keyword.get(config(), :trigger_call_timeout_ms, @trigger_call_timeout_ms)

  @doc """
  How long `status/1` waits for the door to answer, in ms — default
  `#{@status_call_timeout_ms}`. Same public-for-observation contract as
  `trigger_call_timeout_ms/0`, and the same invariant: longer than the ctl
  round-trip `{:status, slug}` may make, or a slow box reads as `:unknown` when
  it is merely busy.
  """
  @spec status_call_timeout_ms() :: pos_integer()
  def status_call_timeout_ms,
    do: Keyword.get(config(), :status_call_timeout_ms, @status_call_timeout_ms)

  # Run a control-plane `System.cmd` under a hard deadline on a SUPERVISED,
  # UNLINKED task so a hung external process cannot wedge the singleton Runner.
  # async_nolink (never linked Task.async) so a crash inside the child degrades
  # to a tuple instead of taking the GenServer down; Task.yield ||
  # Task.shutdown(:brutal_kill) is the same per-site pattern as
  # `studio_chat/probe.ex` + `onixedit/export/validator.ex`. Returns:
  #   {:ok, {out, code}} — the command completed inside the deadline;
  #   :timeout           — the deadline fired (task brutal-killed);
  #   {:crashed, reason} — `System.cmd` raised inside the task.
  # Each caller degrades these three per the never-crash contract.
  #
  # Sobelow CI.System is a false-positive here: every caller resolves `path` via
  # `System.find_executable/1` (a fixed binary name or a test-only config
  # override, never request data) and passes a fixed token list + the
  # server-generated unit name — no shell string, no client input. This inline
  # skip replaces the line-anchored `.sobelow-skips` fingerprints
  # (`deploy_runner.ex:526/:1351/:1368`) that the deadline wrapper moved
  # System.cmd off of.
  # sobelow_skip ["CI.System"]
  defp bounded_cmd(path, args, opts) do
    task =
      Task.Supervisor.async_nolink(Barkpark.TaskSupervisor, fn ->
        System.cmd(path, args, opts)
      end)

    case Task.yield(task, ctl_cmd_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, code}} -> {:ok, {out, code}}
      {:exit, reason} -> {:crashed, reason}
      nil -> :timeout
    end
  end

  # `systemctl is-active <unit>` → the trimmed state word ("active", "inactive",
  # "failed", …). A missing systemctl / a swept unit is terminal ("unknown").
  # Injectable so a systemd-less test can drive re-attach + finalize.
  defp is_active(unit_name) do
    {exe, prefix} = Keyword.get(config(), :is_active_cmd, @default_is_active)

    case System.find_executable(exe) do
      nil ->
        "unknown"

      path ->
        # Bounded: a hung `systemctl is-active` would freeze the {:status} call
        # (and prune_run_state_dir). A timeout or crash degrades to "unknown" —
        # a terminal state (not in @active_states) that finalizes the run rather
        # than pinning it :running forever.
        case bounded_cmd(path, prefix ++ [unit_name], stderr_to_stdout: true) do
          {:ok, {out, _code}} ->
            out |> String.trim() |> String.split("\n") |> List.first() |> to_string()

          _timeout_or_crash ->
            "unknown"
        end
    end
  end

  defp systemctl_stop(unit_name) do
    {exe, prefix} = Keyword.get(config(), :systemctl_stop_cmd, @default_systemctl_stop)

    case System.find_executable(exe) do
      nil ->
        :ok

      path ->
        # Bounded: this is the {:unit_deadline} watchdog's OWN kill, running in a
        # handle_info that safe_call cannot rescue — a hung `systemctl stop` here
        # would wedge the Runner exactly where it must stay live to force-close a
        # wedged unit. On timeout/crash we WARN and still return :ok so the
        # watchdog finalizes the run (:done / exit -2) regardless.
        case bounded_cmd(path, prefix ++ [unit_name], stderr_to_stdout: true) do
          {:ok, _} ->
            :ok

          other ->
            Logger.warning(
              "[site-deploy] systemctl stop did not complete in #{ctl_cmd_timeout_ms()}ms " <>
                "for #{inspect(unit_name)} (#{inspect(other)}) — finalizing the run anyway"
            )

            :ok
        end
    end
  end

  # ── rendering ───────────────────────────────────────────────────────────

  # Keep the newest @max_tracked_runs slugs. Running (Port) runs are NEVER
  # evicted; among finished ones the oldest goes first. A systemd finalized cache
  # (no `:port`, always `:done`) is treated as finished.
  defp prune_runs(runs) when map_size(runs) <= @max_tracked_runs, do: runs

  defp prune_runs(runs) do
    {running, finished} =
      runs |> Map.values() |> Enum.split_with(&(&1.state == :running))

    keep =
      finished
      |> Enum.sort_by(&run_finished_at/1, {:desc, DateTime})
      |> Enum.take(max(@max_tracked_runs - length(running), 0))

    Map.new(running ++ keep, &{&1.slug, &1})
  end

  defp run_finished_at(%{finished_at: %DateTime{} = dt}), do: dt
  defp run_finished_at(_), do: ~U[1970-01-01 00:00:00Z]

  # The answer when the door could not be READ at all — the Runner is gone or
  # did not reply inside `status_call_timeout_ms/0`. Deliberately NOT
  # `idle_status/1`: an unread status is not an empty one, and a control plane
  # polling for a build's outcome must be able to tell "nothing here" from "I
  # cannot see". Same keys as every other status map (callers pattern-match the
  # shape), with `state: :unknown` and a `failure_reason` that names the cause.
  defp unreachable_status(slug) do
    %{
      idle_status(slug)
      | state: :unknown,
        log_state: :unknown,
        failure_reason:
          "deploy runner unreachable — it is not registered, or it did not " <>
            "answer {:status, #{slug}} within #{status_call_timeout_ms()}ms; " <>
            "status unknown (NOT idle)"
    }
  end

  defp idle_status(slug) do
    %{
      state: :idle,
      slug: slug,
      build_id: nil,
      content_rev: nil,
      mode: nil,
      runtime_target: nil,
      stages: [],
      served_port: nil,
      served_slot: nil,
      exit_code: nil,
      failure_reason: nil,
      log: [],
      # NOTHING was ever recorded for this slug — distinct from a deployment
      # whose log retention evicted, which reports :evicted with its outcome.
      log_state: :never_recorded,
      log_path: nil,
      unit_name: nil,
      started_at: nil,
      finished_at: nil
    }
  end

  # Whitelist-render — the configured COMMAND is never exposed, only its output.
  # A Port run holds its log newest-first (reverse it); a reconstructed systemd
  # render already carries an oldest-first log + a `:done`/`:running` state.
  defp render_run(%{port: _} = run) do
    %{
      state: run.state,
      slug: run.slug,
      build_id: run.build_id,
      content_rev: run.content_rev,
      mode: run.mode,
      runtime_target: run.runtime_target,
      stages: run.stages,
      served_port: run.served_port,
      served_slot: run.served_slot,
      exit_code: run.exit_code,
      failure_reason: run.failure_reason,
      log: Enum.reverse(run.log),
      # The Port fallback holds its log IN MEMORY for the life of the run — there
      # is no durable file to evict, so it is available for exactly as long as
      # the render is.
      log_state: :available,
      log_path: nil,
      unit_name: nil,
      started_at: run.started_at,
      finished_at: run.finished_at
    }
  end

  # A CACHED systemd render outlives the file it was reconstructed from —
  # retention can evict the log between the finalize and the next poll — so its
  # log_state is re-derived from disk on every read. A cached `:available` for
  # bytes that are gone is exactly the stale-by-one-cache dishonesty this slice
  # exists to remove.
  defp render_run(reconstructed), do: refresh_log_state(reconstructed)

  defp refresh_log_state(%{log_path: path} = render) when is_binary(path),
    do: %{render | log_state: disk_log_state(path)}

  defp refresh_log_state(render), do: render
end
