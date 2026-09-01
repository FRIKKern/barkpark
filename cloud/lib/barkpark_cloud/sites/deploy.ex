defmodule BarkparkCloud.Sites.Deploy do
  @moduledoc """
  site-spawner D22/D30 — the control plane's STATIC deploy spine: mint a build,
  drive the box through `deploy/site-deploy.sh`'s six stages, narrate every
  transition onto the Deployment row, and flip the site live (or fail it honestly)
  at the end.

      PLAN → BUILD → STAGE → HEALTH → SWITCH → RETIRE

  ## Why the stages ride ALONGSIDE `status` (charter D3)

  The `Deployment.status` enum is deliberately NOT widened to six. Widening it
  would force migrating `@transitions`, every fenced CAS writer, and the stale
  reaper — high blast radius for cosmetic granularity. So the coarse lifecycle
  stays `queued → building → pushing → live | failed`, and the six VISIBLE stages
  ride the nullable `stage` column (which stage is in flight), `detail` (the
  latest-wins caption), and `console` (the append-only narration).

  Each stage transition appends ONE console entry that carries its stage identity:

      %{"line" => "HEALTH — probe returned 200 and the build markers matched",
        "at" => "2026-07-14T…Z", "stage" => "HEALTH", "status" => "done",
        "detail" => "…"}

  `stages/1` folds those back into the ordered six-stage list the CLI streams. The
  `console` array is already append-only, capped, and serialized — reusing it
  costs no migration and keeps ONE source of truth for "what happened", instead of
  a second stage table that could disagree with the narration.

  ## Crash safety (why this is NOT just a Task)

  The driver claims the row (`claim_worker` + `claimed_at` + `claim_epoch`) and
  heartbeats `claimed_at` on every stage CAS, exactly like the off-box container
  builder. That is deliberate: if the control plane restarts mid-build, the row is
  still visibly claimed and STALE, so the existing `StaleDeploymentReaper` sweeps
  it — requeue under budget, terminal failure over budget. An in-BEAM Task with no
  row liveness would be a brand-new crash-safety class (an eternal spinner nothing
  can see). `resume_orphaned/0` closes the loop: a requeued static row is picked
  back up and re-driven, because nothing else in the fleet claims static rows.

  ## Idempotency

  `build_id = hash(code_rev + content_rev + config)` names `releases/<build_id>/`
  on the box AND is the PLAN no-op key: the `(site_id, build_id)` partial unique
  index turns a re-deploy of unchanged code+content+config into a 200 no-op
  instead of a duplicate build. `content_rev` is read from the box (the only thing
  that can see the dataset); when it cannot be read the rev degrades to the EMPTY
  string — an honest "I don't know the content revision", which still forces a
  rebuild (the unknown rev folds a nonce into `build_id`, so a false cache hit can
  never serve stale content) but ships NO revision to the box, so HEALTH knows it
  has nothing to cross-check instead of asserting an invented value against itself.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.DeployLedger
  alias BarkparkCloud.FailureCopy
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.{Barkpark, Deployment, Site, SiteArtifact}
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Sites.AutoDeployWorker
  alias BarkparkCloud.Sites.BoxRelay
  alias BarkparkCloud.Sites.NodePortAllocator

  # The six visible stages, in order — the same list the CLI renders
  # (cloudclient.SpawnSiteStages). This is the canonical ordering `stages/1`
  # walks, so a lean box report still shows the full bar.
  @stages ~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE)

  # The stage at which the deploy stops being reversible-for-free and starts
  # touching what visitors see. Everything before SWITCH is `building`; SWITCH and
  # RETIRE are `pushing` (the coarse status the container pipeline already uses
  # for "on the box, going live"), and only then `live`.
  @switch_stage "SWITCH"

  # The `code_rev` a box that has reported NEITHER a git commit NOR a version
  # falls back to. It is a constant, so it freezes that half of `build_id` — see
  # `code_rev_known?/1`, which exists so a scheduled caller can SEE that.
  @unknown_code_rev "unknown"

  # The `content_rev` an UNREADABLE box degrades to (ssw8): the empty string, not
  # a fabricated marker. It is the wire value the box reads as "no CONTENT_REV
  # supplied", which is the only honest thing to say when the read failed — see
  # `content_rev/2`.
  @unknown_content_rev ""

  @doc "The six visible deploy stages, in order."
  @spec stages() :: [String.t()]
  def stages, do: @stages

  @doc """
  The display fold for ONE stage's `detail` — the single hop every channel that
  paints a stage detail to a person goes through (cch-w27-s2).

  Two arms, two separate obligations, deliberately not one:

    * **`failed` → `FailureCopy.humanize/1`.** `Sites.Deploy.fail/2` writes the
      identical reason to `failure_reason` AND `detail`, and
      `Web.Router.deployment_json/1` humanizes only the first. The rail a person
      is WATCHING (`.deploy-rail-fail`, fed from the failed stage's `detail`) and
      the settled row that replaces it seconds later therefore named two
      different causes off ONE string: the rail said `FATAL: 401 Unauthorized …`
      while the row spoke `FailureCopy`'s `@credential_rejected` arm — today
      "A credential was rejected. This capture doesn't say whose credential it
      was — the raw error line names it." Same event, same minute, two stories — the exact shape wave 26 S3 closed in the
      `provision_failed` email (charter D310).

      The RAW CAPTURE IS NOT DESTROYED, which is what D310's "both, not either"
      requires. It survives verbatim (scrubbed) one element away, in the SAME
      view: `console_entry/1` folds it into `line` ("BUILD failed — <detail>"),
      and `app.js` `deployConsoleHtml` renders `line` — the build console is
      open by default while a deploy is active, i.e. exactly when the rail is on
      screen. The class goes where a person LOOKS FIRST; the capture stays where
      they look NEXT. This is why `humanize/1` is right HERE and wrong on
      `merge_provision_steps` / `merge_provision_console`, where it would replace
      the only copy of the narration that exists.

    * **anything else → `FailureCopy.strip_ansi/1` THEN `FailureCopy.scrub/1`.**
      A stage detail is a REMOTE capture (an ssh stderr fold, a provider body, a
      build log line), so it is redacted at every display boundary. `broadcast_stage/2` shipped it RAW:
      driven on a detail carrying `Authorization: Bearer <token>`, the HTTP
      console entry returned `Bearer [redacted]` while the SSE frame for the
      same bytes carried the live credential. Same bytes, two channels, one
      redacted.

  `humanize/1` is `classify |> scrub`, so the `failed` arm is scrubbed too — the
  secret boundary is total across both arms, and neither arm weakens the other.
  Non-binary details (a stage the box narrated without one) pass through
  unchanged. The stored row keeps the raw bytes for ops, as always.
  """
  @spec stage_caption(term(), term()) :: term()
  def stage_caption("failed", detail), do: FailureCopy.humanize(detail)
  # `scrub/1` alone is not a redaction boundary on build-log bytes: a build tool
  # colourises its own output, so `api_key\e[0m=\e[33msk-live-…` puts ESC runs
  # INSIDE the shape the scrubber matches on and the secret walks out in
  # cleartext (with raw 0x1B bytes attached, which a console then interprets).
  # Strip first, then redact — the order is the fix (dr-w8-s2).
  def stage_caption(_status, detail),
    do: detail |> FailureCopy.strip_ansi() |> FailureCopy.scrub()

  ## ---------------------------------------------------------------------------
  ## Mint
  ## ---------------------------------------------------------------------------

  @doc """
  Mint a static Deployment for `site` — the 201 the CLI gets back INSTANTLY. The
  build itself runs on the box; this only computes the build identity and records
  the row so the deploy is visible (and reap-able) the moment it exists.

  Returns `{:ok, deployment}`, `{:duplicate, deployment}` when this exact
  code+content+config is already built (the `(site_id, build_id)` unique index —
  the PLAN no-op's DB backstop), or `{:error, changeset}`.
  """
  #
  # `force` (charter D36) mints a genuinely NEW build on UNCHANGED content: it
  # folds a nonce into `build_id`, so the `(site_id, build_id)` index no longer
  # collapses the re-deploy into a no-op and a fresh `releases/<build_id>/` is
  # cut. The default (`force = false`) path is byte-identical to before — the
  # idempotent no-op is the norm; force is the escape hatch for "re-run this
  # exact content" (a stuck/failed build, or two distinct builds for a rollback
  # proof).
  #
  # `trigger` (charter D49) is the deploy's PROVENANCE — "manual" (the default,
  # every `bp cloud site deploy`) or "content-auto" (the publish-to-live receiver
  # via AutoDeployWorker). It rides straight onto the Deployment row so the
  # deployment stream can show WHY the build ran (the wish's "observable" bar).
  #
  # `probed_rev` (stw9 residue 2a) lets a caller that ALREADY read the box's
  # content revision hand it in instead of paying a second analytics read.
  # `TemplateFreshnessWorker` probes with `content_rev_probe/2` before deciding
  # whether to enqueue at all, so without this the sweep costs TWO reads per site
  # per tick where one suffices. `nil` (the default, and every other call site)
  # keeps the pre-existing behaviour EXACTLY: read it here, fail-open included.
  # A handed-in rev is by construction the honest `{:ok, rev}` value, so the
  # fail-open is not bypassed — it simply already happened, or didn't need to.
  #
  # `source` (charter D86) is WHERE the bytes will come from: "box-build" (the
  # default and every pre-W9 call) or "prebuilt". A prebuilt mint is
  # NON-IDEMPOTENT BY CONSTRUCTION — see `maybe_prebuilt_nonce/2`.
  @spec enqueue(Site.t(), Barkpark.t(), boolean(), String.t(), String.t() | nil, String.t()) ::
          {:ok, Deployment.t()} | {:duplicate, Deployment.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(
        %Site{} = site,
        %Barkpark{} = bp,
        force \\ false,
        trigger \\ "manual",
        probed_rev \\ nil,
        source \\ "box-build"
      ) do
    content_rev = probed_rev || content_rev(site, bp)
    # An UNKNOWN revision must never dedupe (ssw8). The empty rev is a CONSTANT,
    # so on its own it would collapse every re-deploy of an unreadable box into
    # the `(site_id, build_id)` no-op and serve stale content forever — the exact
    # failure the old random `"u…"` marker existed to prevent. So the nonce that
    # `force` folds in is applied here too: the build is genuinely new, and the
    # revision shipped to the box stays honestly empty.
    build_id =
      build_id(site, bp, content_rev, force || content_rev == @unknown_content_rev, source)

    case Registry.create_deployment(site, %{
           build_id: build_id,
           content_rev: content_rev,
           trigger: trigger,
           source: source
         }) do
      {:ok, deployment} ->
        {:ok, deployment}

      {:error, %Ecto.Changeset{} = cs} ->
        recover_conflict(cs, site, build_id)
    end
  end

  # A unique conflict on create. TWO indexes can refuse this INSERT and Postgres
  # reports only ONE of them, in an order the app must not depend on — so both
  # recoveries are tried by LOOKUP, not by trusting which constraint name came
  # back:
  #
  #   * a repeat `build_id`: this exact build already exists. Recover it as a
  #     no-op — a re-deploy of unchanged content IS a no-op, and the script
  #     agrees (PLAN exits 0 when build_id is already live).
  #   * an ACTIVE build for this site (deploy-truth W1, charter D10): the re-keyed
  #     `(site_id, environment)` index refuses a second concurrent production
  #     build. Recover the row already in flight as the duplicate. The caller then
  #     coalesces onto it (a still-`queued` row will read the new content when it
  #     starts) or defers behind it (`AutoDeployWorker` re-fires the debounce), so
  #     the publish is never lost — and the box is never asked to run a second
  #     deploy it would only answer 409.
  defp recover_conflict(%Ecto.Changeset{} = cs, %Site{} = site, build_id) do
    case Registry.find_deployment_by_build_id(site.id, build_id) do
      %Deployment{} = existing ->
        {:duplicate, existing}

      nil ->
        case active_production_deployment(site.id) do
          %Deployment{} = active -> {:duplicate, active}
          nil -> {:error, cs}
        end
    end
  end

  @doc """
  The site's ONE active production deployment (`queued` / `building` / `pushing`),
  or nil — the row the re-keyed `deployments_active_site_env_index` (charter D10)
  now guarantees is unique. Public because the deferral path needs to name WHAT
  the new build is waiting behind.
  """
  @spec active_production_deployment(binary()) :: Deployment.t() | nil
  def active_production_deployment(site_id) when is_binary(site_id) do
    Repo.one(
      from(d in Deployment,
        where:
          d.site_id == ^site_id and d.environment == "production" and
            d.status in ["queued", "building", "pushing"],
        order_by: [desc: d.inserted_at],
        limit: 1
      )
    )
  end

  @doc """
  `build_id = hash(code_rev + content_rev + config)` (charter D2), truncated to 16
  lowercase hex chars — a valid `releases/<build_id>/` dir name under the script's
  `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` guard.

  `code_rev` is the box's own code revision (the adapter template ships with the
  instance, so the instance's commit IS the build's code identity); `config` is
  everything else that changes the output: framework, kind, the base path the site
  is served at, and the content binding.

  When `force` is true (charter D36) a `System.system_time()` nonce is folded
  into `config`, so an otherwise-identical build hashes to a DIFFERENT `build_id`
  — the `(site_id, build_id)` index then mints a new row instead of returning the
  cached duplicate, and a real `releases/<build_id>/` is cut on the box. With
  `force` false the config map is EXACTLY the pre-D36 shape, so the default
  build_id is unchanged and the idempotent no-op still fires.

  When `source` is `"prebuilt"` (charter D86) a SECOND, distinct nonce is folded
  in — see `maybe_prebuilt_nonce/2` for why it cannot share `force`'s key.
  """
  @spec build_id(Site.t(), Barkpark.t(), String.t(), boolean(), String.t()) :: String.t()
  def build_id(
        %Site{} = site,
        %Barkpark{} = bp,
        content_rev,
        force \\ false,
        source \\ "box-build"
      )
      when is_binary(content_rev) do
    config =
      %{
        framework: site.framework,
        kind: site.kind,
        base: base_path(site),
        workspace: site.bootstrap_workspace,
        project: site.bootstrap_project,
        dataset: site.bootstrap_dataset
      }
      |> maybe_force_nonce(force)
      |> maybe_prebuilt_nonce(source)
      |> Jason.encode!()

    :sha256
    |> :crypto.hash(Enum.join([code_rev(bp), content_rev, config], "|"))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # The force nonce (charter D36). `System.system_time()` is monotonic-enough for
  # a per-request nonce (two forced deploys of the same content in the same
  # nanosecond is not a case we owe distinctness). When force is false the map is
  # returned untouched, so the encoded config — and therefore the build_id — is
  # byte-identical to the pre-D36 default path.
  defp maybe_force_nonce(config, true), do: Map.put(config, :force_nonce, System.system_time())
  defp maybe_force_nonce(config, false), do: config

  # The PREBUILT nonce (charter D86) — and it is a SEPARATE key from `force`'s on
  # purpose, not a tidy-up candidate.
  #
  # A prebuilt mint MUST be non-idempotent, because the thing that varies is not
  # code, content, or config: it is the uploaded `dist/`, which does not exist
  # yet when the row is minted (site-deploy.sh bakes BARKPARK_BUILD_ID INTO the
  # bytes, so the id has to be handed to the builder BEFORE the build). Two
  # genuinely different dists of the same site therefore hash to the SAME
  # build_id under the pre-W9 config, trip the (site_id, build_id) partial unique
  # index, and are answered HTTP 200 with the OLD row — no build, no start, and
  # no audit row either (the audit lives only in the `{:ok, _}` arm), so a
  # swallowed upload leaves ZERO trace.
  #
  # Sharing `force`'s key would collapse two different meanings into one word:
  # force means "re-run this EXACT content" (D36), a deliberate override of a
  # correct no-op. Prebuilt means "the content is not knowable from here" — the
  # no-op was never correct in the first place. A future change that made `force`
  # idempotent again would silently take prebuilt with it.
  defp maybe_prebuilt_nonce(config, "prebuilt"),
    do: Map.put(config, :prebuilt_nonce, prebuilt_nonce())

  defp maybe_prebuilt_nonce(config, _source), do: config

  @doc """
  The prebuilt nonce VALUE — a wall clock, deliberately (clock-semantics class D).

  This is an identity token, not an elapsed duration: the only property it owes
  is "never repeats, never goes backwards ACROSS A RESTART". The obvious reflex —
  `System.unique_integer([:positive, :monotonic])` — is exactly wrong for that,
  because it is a node-global counter that RESTARTS FROM 1 on every BEAM boot (a
  separate sequence from bare `[:positive]`, so nothing else in the node consumes
  it: the Nth prebuilt mint since boot deterministically gets nonce N). Since
  `cloud/**` auto-deploys on merge, a control-plane restart is routine, so the
  overlap is guaranteed rather than improbable — and a repeated nonce means a
  repeated build_id, which the (site_id, build_id) partial unique index refuses,
  which `recover_conflict/3` answers `{:duplicate, existing}`, which the router
  answers HTTP 200 with the OLD row, while `record_audit` lives only in the
  `{:ok, _}` arm: the freshly uploaded dist is discarded with ZERO trace.

  `System.system_time()` is the idiom already used by `maybe_force_nonce/2` and
  it survives a restart. Three in-repo moduledocs state this same rule and reject
  `unique_integer` for this same fence (`Sheets.Session`, `StudioChat.FleetHub`,
  `Studio.SheetGrid`).

  SEVERITY, stated honestly: this is SILENT DATA LOSS on an AUTHENTICATED,
  opt-in-gated tenant path — `POST /v1/sites/:id/deploy` with
  `{"source":"prebuilt"}`, gated on `site.prebuilt_enabled` (422 otherwise) and
  reached through `with_team_site(conn, {:ability, "write"})`. It is NOT
  unauthenticated and NOT an authorization defect, no caller can influence the
  nonce, and it ranks BELOW any auth finding in this wave.

  Public only as a test seam: the nonce is otherwise invisible through
  `build_id/5` (which returns a hash) and no restart can be staged in `mix test`,
  so a difference assertion cannot fail on the unfixed code. The deciding proof
  is on the VALUE DOMAIN — see `sites_deploy_test.exs`.
  """
  @spec prebuilt_nonce() :: integer()
  def prebuilt_nonce, do: System.system_time()

  ## ---------------------------------------------------------------------------
  ## Prebuilt artifacts (charter D91)
  ## ---------------------------------------------------------------------------

  @doc """
  Store an uploaded tarball for `deployment` and record its digest ON the row,
  in ONE transaction.

  The ordering is the contract: the digest is committed BEFORE the caller may
  start the driver, so a deployment that reached the box can always name the
  exact bytes it was asked to serve. A crash between the two would otherwise
  leave a row that deploys artifact bytes while claiming it has none.

  `sha256` is computed from the bytes the control plane actually received —
  never taken from the client.

  Returns `{:ok, deployment}` with the digest stamped, or `{:error, changeset}`.
  """
  @spec store_artifact(Deployment.t(), binary(), String.t()) ::
          {:ok, Deployment.t()} | {:error, Ecto.Changeset.t()}
  def store_artifact(%Deployment{} = deployment, bytes, sha256)
      when is_binary(bytes) and is_binary(sha256) do
    artifact =
      SiteArtifact.changeset(%SiteArtifact{}, %{
        bytes: bytes,
        sha256: sha256,
        byte_size: byte_size(bytes),
        site_id: deployment.site_id,
        deployment_id: deployment.id
      })

    stamped = Deployment.changeset(deployment, %{artifact_sha256: sha256})

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:artifact, artifact)
    |> Ecto.Multi.update(:deployment, stamped)
    |> Repo.transaction()
    |> case do
      {:ok, %{deployment: updated}} -> {:ok, updated}
      {:error, _step, %Ecto.Changeset{} = cs, _changes} -> {:error, cs}
    end
  end

  # site-spawner W10: `store_site_artifact/3` is GONE. It inserted a SiteArtifact
  # with a site_id and no deployment_id — which `artifact_for/1` and
  # `drop_artifact/1` below both key on — so every row it wrote was unreadable and
  # unreapable, an unbounded leak on the control plane's only durable volume.
  # Artifact bytes are bound to a deployment at insert or they are not stored.

  @doc "The stored artifact for `deployment_id`, or nil."
  @spec artifact_for(binary()) :: SiteArtifact.t() | nil
  def artifact_for(deployment_id) when is_binary(deployment_id) do
    Repo.one(from a in SiteArtifact, where: a.deployment_id == ^deployment_id)
  end

  @doc """
  Drop a deployment's stored bytes. Called once the deployment is TERMINAL: the
  box has them by then, and a terminal Deployment is never re-driven, so keeping
  up to 32 MB per build would be a pure leak on the control plane's only durable
  volume. Best-effort — a failed delete never fails a deploy.
  """
  @spec drop_artifact(binary()) :: :ok
  def drop_artifact(deployment_id) when is_binary(deployment_id) do
    Repo.delete_all(from a in SiteArtifact, where: a.deployment_id == ^deployment_id)
    :ok
  end

  # The box's code revision. `git_commit` is the truth when the instance reports
  # it; `version` is the fallback; "unknown" only when the box has reported
  # neither (a fresh instance) — in which case content_rev still varies the hash,
  # so a build is never wrongly deduped.
  defp code_rev(%Barkpark{git_commit: c}) when is_binary(c) and c != "", do: c
  defp code_rev(%Barkpark{version: v}) when is_binary(v) and v != "", do: v
  defp code_rev(_bp), do: @unknown_code_rev

  @doc """
  Does this box report a REAL code revision, or is `build_id` riding the
  `"#{@unknown_code_rev}"` constant?

  stw9 residue 1: a box with neither `git_commit` nor `version` freezes the
  `code_rev` half of `build_id`, so `TemplateFreshnessWorker`'s unforced sweep
  can NEVER mint a new build for a code roll on that box — it returns
  `:duplicate` every tick, forever, indistinguishable from a healthy quiet
  fleet. The sweep counts this so an inert sweep is visible instead of silent.

  This is a SEAM, not a copy: `code_rev/1`'s three clauses stay the single owner
  of "what counts as a revision". Duplicating that predicate into the worker is
  exactly how two clause sets drift apart.
  """
  @spec code_rev_known?(Barkpark.t()) :: boolean()
  def code_rev_known?(%Barkpark{} = bp), do: code_rev(bp) != @unknown_code_rev

  # The content revision baked into the build (and into the `bp-content-rev`
  # marker HEALTH asserts). Only the box can see the dataset, so we ask it — over
  # the scoped analytics path, relayed with the INSTANCE ADMIN token
  # (`Registry.relay_admin/4`). NOT the site's own public-read token: that token
  # is the BUILD's credential and never leaves the deploy payload, so the probe
  # and the build read the dataset through two different credentials.
  #
  # FAIL-HONEST (ssw8): an unreadable revision degrades to the EMPTY string, and
  # `enqueue/5` folds a nonce into the build_id when it sees one — so the build is
  # still genuinely new (never a false cache hit that serves stale content), but
  # the box is told plainly that no revision was supplied. It was previously a
  # fresh random `"u" <> hex` marker: that value was stored on the row, exported
  # as CONTENT_REV, baked into `<meta name="bp-content-rev">` by the template, and
  # then asserted EQUAL by HEALTH — a green certified by comparing an invented
  # value to itself, with no detector anywhere in the repo that could tell it from
  # a real revision. An empty CONTENT_REV routes `deploy/site-deploy.sh` into its
  # existing honest branch instead ("no CONTENT_REV supplied — asserting
  # bp-content-rev is non-empty only"). Distrust vacuous green.
  defp content_rev(%Site{} = site, %Barkpark{} = bp) do
    case content_rev_probe(site, bp) do
      {:ok, rev} -> rev
      :error -> @unknown_content_rev
    end
  end

  @doc """
  READ the site's content revision from its box, WITHOUT the fail-open — the
  honest half of `content_rev/2`.

  `{:ok, rev}` when the box answered its scoped analytics read; `:error` when it
  did not (box down, no admin token, non-2xx, unbound triple).

  stw9 (charter D57): this exists so a SCHEDULED caller can tell "content
  unchanged" from "I could not look". `content_rev/2` degrades an unreadable
  revision to the empty string, and `enqueue/5` then nonces the build_id —
  correct for a human-triggered deploy (never serve stale content), but
  catastrophic on a timer: a sick box would mint a brand-new `build_id` on EVERY
  tick, so the idempotent no-op that makes an unforced sweep cheap never fires and
  the box builds forever. `TemplateFreshnessWorker` probes first and SKIPS the
  site on `:error`.

  ## What the revision is derived FROM (ssw8)

  NOT the whole analytics body. That body's `recent_activity` is the last 50
  mutation events for the DATASET — every type, drafts included — so hashing it
  moved the revision on activity the site does not publish: an unrelated task
  closing, or anyone saving a draft, minted a fresh `build_id` and a full rebuild
  of byte-identical output (~53/hour measured on a live dataset), and the
  idempotent no-op the `(site_id, build_id)` index exists to produce was dead.

  So the revision is derived from a PROJECTION of what this site actually
  publishes: the PUBLISHED document count for the site's bound `doc_type`, plus
  the published mutation events of that type still inside the activity window.
  Published-only and type-filtered on both halves — a draft edit or another type's
  churn cannot move it, while a real publish (a new document, or an edit to an
  existing published one of the bound type) does.
  """
  @spec content_rev_probe(Site.t(), Barkpark.t()) :: {:ok, String.t()} | :error
  def content_rev_probe(%Site{} = site, %Barkpark{} = bp) do
    with ws when is_binary(ws) <- site.bootstrap_workspace,
         proj when is_binary(proj) <- site.bootstrap_project,
         ds when is_binary(ds) <- site.bootstrap_dataset,
         # The projection is TYPE-SCOPED, so a site with no bound type has nothing
         # to project. `sites.doc_type` is `null: false default 'post'` in the
         # schema AND the migration, so this is unreachable from a stored row —
         # but an unbound type must degrade to :error (unknown ⇒ nonce ⇒ rebuild),
         # never raise a FunctionClauseError inside the deploy hot path.
         doc_type when is_binary(doc_type) <- site.doc_type,
         path <-
           "/w/#{URI.encode(ws)}/p/#{URI.encode(proj)}/v1/data/analytics/#{URI.encode(ds)}",
         {:ok, status, body} when status in 200..299 <- Registry.relay_admin(bp, :get, path, nil) do
      rev =
        :sha256
        |> :crypto.hash(Jason.encode!(content_projection(body, doc_type)))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 12)

      {:ok, rev}
    else
      _ -> :error
    end
  end

  # The published, type-scoped projection of an analytics body — a LIST, not a
  # map, so its JSON encoding is ordered and stable regardless of key traversal.
  defp content_projection(body, doc_type) when is_binary(doc_type) do
    [doc_type, published_count(body, doc_type), published_events(body, doc_type)]
  end

  # The published-document count for the bound type. The instance splits
  # `published` from `drafts` per type (`Barkpark.Content.Analytics.document_stats/2`);
  # an older box that reports only `total` falls back to it rather than to 0 —
  # a coarser signal, never a silently frozen one.
  defp published_count(%{"types" => types}, doc_type) when is_list(types) do
    Enum.find_value(types, 0, fn
      %{"type" => ^doc_type} = row -> row["published"] || row["total"] || 0
      _ -> false
    end)
  end

  defp published_count(_body, _doc_type), do: 0

  # The bound type's PUBLISHED events inside the activity window, projected to the
  # fields that identify a content change (which document, which mutation, when).
  # `id` is deliberately dropped: it is a per-event uuid that would make two
  # otherwise-identical windows differ. Drafts carry a `drafts.`-prefixed doc_id
  # (the instance's own published/draft discriminator) and are excluded.
  defp published_events(%{"recent_activity" => events}, doc_type) when is_list(events) do
    events
    |> Enum.filter(fn
      %{"type" => ^doc_type, "doc_id" => doc_id} when is_binary(doc_id) ->
        not String.starts_with?(doc_id, "drafts.")

      _ ->
        false
    end)
    |> Enum.map(&[&1["doc_id"], &1["mutation"], &1["timestamp"]])
  end

  defp published_events(_body, _doc_type), do: []

  ## ---------------------------------------------------------------------------
  ## Drive
  ## ---------------------------------------------------------------------------

  @doc """
  Kick the driver for a minted deployment, AND SAY WHAT HAPPENED (deploy-truth
  W1, charter D9).

  The spawn is a config seam (`:site_deploy_starter`) so tests can drive `run/1`
  synchronously and deterministically instead of racing a Task.

  The old seam was spec'd `:: :ok` and the production starter returned a LITERAL
  `:ok` after `Task.Supervisor.start_child` — it discarded the spawn result AND
  the run outcome, so `AutoDeployWorker` could only ever observe success. In
  three weeks that blindness recorded 11,868 completed `site_deploy` jobs and
  ZERO retryable/discarded ones while 8,830 deploys were refused by a busy box.

  Returns what actually happened, as far as the starter can know it:

    * `{:ok, :started}` — the supervised driver was spawned (production; the
      build's own outcome lands on the row, and a busy box is deferred + re-fired
      by `run/1` itself);
    * `{:ok, :live | :failed | :deferred}` — a SYNCHRONOUS starter drove the run
      to its settled state and is handing it back;
    * `{:error, reason}` — the driver never started (the supervisor refused the
      child, or the row could not be claimed). Nothing recorded the build, so the
      caller MUST NOT treat this as success.

  THIS IS THE ONLY SEAM. There used to be a fire-and-forget `start/1` beside it —
  spec'd `:: :ok`, it called this function, DISCARDED the `{:error, reason}` and
  returned a literal, so every `:ok = Deploy.start(row)` in the tree was a match
  that COULD NOT FAIL: the MatchError meant to signal a refused driver spawn was
  structurally unreachable. Four callers were blind through it — the manual deploy
  route, the prebuilt artifact-upload route, the hourly freshness sweep, and,
  worst, `resume_orphaned/0`, the reaper's own recovery pass, whose `resumed:`
  metric counted rows FOUND rather than rows restarted. It is deleted; a caller
  that cannot act on the outcome must at least SAY it did not happen.
  """
  @spec start_reported(Deployment.t()) ::
          {:ok, :started | :live | :failed | :deferred} | {:error, term()}
  def start_reported(%Deployment{id: id}), do: starter().start(id)

  @doc """
  Drive ONE deployment end to end, synchronously: claim the row, start the run on
  the box, poll it, CAS every stage transition onto the row, and settle it `live`
  (with the site's live pointer flipped in the SAME transaction) or `failed` (with
  the box's real reason — never an invented one).

  Returns `{:ok, :live}`, `{:ok, :failed}`, `{:ok, :deferred}` (the box was busy —
  this row is settled and a rebuild has been re-queued), or `{:error, reason}`
  when the row could not even be claimed (already claimed / gone). Never raises: a
  crash here would leave a claimed row, which the reaper sweeps — but an honest
  `failed` with the reason is strictly better, so every outbound error is mapped
  to one.
  """
  @spec run(binary()) :: {:ok, :live | :failed | :deferred} | {:error, term()}
  def run(deployment_id) when is_binary(deployment_id) do
    with %Deployment{} = deployment <- Registry.get_deployment(deployment_id),
         %Site{} = site <- Registry.get_site(deployment.site_id),
         %Barkpark{} = bp <- Registry.get_barkpark(site.barkpark_id),
         {:ok, claimed} <- Registry.claim_deployment(deployment_id, worker_id()) do
      drive(claimed, site, bp)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp drive(%Deployment{} = deployment, %Site{} = site, %Barkpark{} = bp) do
    ctx = %{
      id: deployment.id,
      worker: deployment.claim_worker,
      epoch: deployment.claim_epoch,
      site: site,
      bp: bp
    }

    # FAIL CLOSED on a missing/undecryptable read token (charter D37). The build
    # fetches content over the SCOPED route with this token; a nil token would
    # build UNAUTHENTICATED — empty content, an empty `bp-doc-id` marker, a
    # false-green "live" page with nothing on it. So the token is revealed HERE,
    # before the box is ever touched: anything but `{:ok, binary}` settles the
    # deployment `failed` with an honest reason and never starts a build.
    case Registry.reveal_site_read_token(site) do
      {:ok, read_token} when is_binary(read_token) ->
        start_on_box(ctx, deployment, site, bp, read_token)

      _ ->
        fail(ctx, "site read token missing or unreadable")
    end
  end

  defp start_on_box(
         ctx,
         %Deployment{} = deployment,
         %Site{} = site,
         %Barkpark{} = bp,
         read_token
       ),
       do: start_on_box(ctx, deployment, site, bp, read_token, start_retries())

  defp start_on_box(
         ctx,
         %Deployment{} = deployment,
         %Site{} = site,
         %Barkpark{} = bp,
         read_token,
         retries_left
       ) do
    case BoxRelay.start_deploy(bp, deploy_payload(deployment, site, bp, read_token)) do
      {:ok, status, body} when status in 200..299 ->
        case prebuilt_echo(deployment, body) do
          :ok -> poll(ctx, deployment.build_id, poll_max(), poll_grace())
          {:error, reason} -> fail(ctx, reason)
        end

      # THE BUSY BOX (deploy-truth W1, charter D9). 409 is the box's ONE
      # transient refusal: `SiteDeployController` answers it exactly when a run
      # for this slug is already in flight (`already_running`). Writing that
      # terminal-`failed` is what lost 8,830 publishes — the row was outside
      # every recovery pass and nothing re-enqueued. It becomes a COUNTED
      # `deferred` row plus a re-fired debounce instead.
      {:ok, 409, body} ->
        defer(ctx, deployment, box_refusal(409, body, :start))

      # THE POOL BLIP ON THE TRIGGER (deploy-truth W2). An UNTYPED 5xx is not the
      # box saying no — it is the door's own auth plug dying on a starved
      # Postgres pool and being rendered by the crash path (see
      # `transient_refusal?/1`). Retrying is safe BY CONSTRUCTION: if the blip
      # ate only the RESPONSE and the box did take the job, the retry meets a
      # slug already in flight and the box answers 409 `already_running` — which
      # the clause above already turns into a counted deferral plus a re-fired
      # debounce. So the worst case of a start retry is a DEFERRAL, never a
      # second build. A TYPED 5xx is the box stating a real fault about itself
      # and stays terminal on the first answer.
      {:ok, status, body} when status >= 500 ->
        if retries_left > 0 and transient_refusal?(body) do
          Process.sleep(poll_ms())
          start_on_box(ctx, deployment, site, bp, read_token, retries_left - 1)
        else
          fail(ctx, box_refusal(status, body, :start))
        end

      {:ok, status, body} ->
        fail(ctx, box_refusal(status, body, :start))

      {:error, reason} ->
        fail(ctx, unreachable(bp, reason))
    end
  end

  # THE PREBUILT HANDSHAKE (charter D91). The box's deploy-request decoder
  # silently DROPS unknown top-level params, so a control plane that speaks
  # prebuilt against an un-upgraded box would hand over the artifact, watch the
  # box ignore it, build from source on the very cores this wave exists to free,
  # and go green — a deploy labelled "prebuilt" in the ledger that was nothing of
  # the kind.
  #
  # So a prebuilt run is only allowed to proceed when the box ECHOES back that it
  # understood: `prebuilt: true` AND the digest it verified, matching the one the
  # control plane recorded. Anything else fails the deployment with the reason
  # stated plainly. A box-build never inspects the echo — its 202 is unchanged.
  defp prebuilt_echo(%Deployment{} = deployment, body) do
    cond do
      not Deployment.prebuilt?(deployment) ->
        :ok

      not is_map(body) or body["prebuilt"] != true ->
        {:error,
         "the box accepted the deploy but did not confirm the prebuilt artifact — it is running an older site-deploy that would build from source instead"}

      body["artifact_sha256"] != deployment.artifact_sha256 ->
        {:error,
         "the box confirmed a different artifact than the one uploaded (expected #{deployment.artifact_sha256 || "none"}, box reported #{body["artifact_sha256"] || "none"})"}

      true ->
        :ok
    end
  end

  # The box's argv: WHAT to build, and the scrubbed BARKPARK_* env it is allowed
  # to see (charter D7 — the box passes ONLY these into the build, so an ambient
  # BARKPARK_TOKEN on the instance can never shadow the site's own read token).
  # `read_token` is already proven to be a binary by `drive/3` (D37); it is never
  # logged.
  defp deploy_payload(%Deployment{} = deployment, %Site{} = site, %Barkpark{} = bp, read_token) do
    %{
      mode: "deploy",
      slug: site.slug,
      build_id: deployment.build_id,
      content_rev: deployment.content_rev,
      framework: site.framework,
      # site-spawner W7 (charter D63): WHICH runtime target the box drives this
      # build to. "static" = symlink-swap of a built dist/; "node" = boot the
      # per-site Node SSR process on the idle slot and flip the Caddy upstream to
      # it. Mapped straight from `kind` so the box never re-derives it.
      runtime_target: runtime_target(site),
      env: %{
        BARKPARK_API_URL: scoped_api_url(site, bp),
        BARKPARK_TOKEN: read_token,
        BARKPARK_DATASET: site.bootstrap_dataset,
        BARKPARK_WORKSPACE: site.bootstrap_workspace,
        BARKPARK_PROJECT: site.bootstrap_project,
        BARKPARK_SITE_BASE: base_path(site),
        # site-spawner W4 (charter D35): the content type the build's flagship
        # fetch reads. NOT NULL by column default, so this is always a binary.
        BARKPARK_DOC_TYPE: site.doc_type
      }
    }
    |> maybe_put_target_port(site)
    |> maybe_put_template(site)
    |> maybe_put_theme(site)
    |> maybe_put_artifact(deployment)
  end

  # site-spawner W9 (charter D91): a PREBUILT deploy ships the already-built
  # `dist/` down with the argv. `Registry.relay_admin/4` already `Jason.encode!`s
  # whatever map it is handed, so this is ZERO transport code — the binding
  # constraint is the relay's 15s timeout, not the box's 100 MB body parser.
  #
  # Base64 because the payload is JSON. It costs 33% on the wire against an
  # `dist/` measured at 12-16 KB (Astro) to 18 MB (Next standalone) — set against
  # the 137-148 MB of node_modules the box no longer installs, and the two
  # concurrent `astro build`s that put a 2-core box at load 9.65.
  #
  # A box-build carries NO artifact keys, so its payload is byte-identical to
  # pre-W9. A prebuilt row whose bytes are missing carries the digest alone: the
  # box then refuses the run rather than quietly building from source, and the
  # 202-echo check below turns that refusal into an honest failed deployment.
  defp maybe_put_artifact(payload, %Deployment{} = deployment) do
    if Deployment.prebuilt?(deployment) do
      payload
      |> Map.put(:source, "prebuilt")
      |> Map.put(:artifact_sha256, deployment.artifact_sha256)
      |> maybe_put_artifact_bytes(deployment)
    else
      payload
    end
  end

  defp maybe_put_artifact_bytes(payload, %Deployment{id: id}) do
    case artifact_for(id) do
      %SiteArtifact{bytes: bytes} -> Map.put(payload, :artifact_b64, Base.encode64(bytes))
      nil -> payload
    end
  end

  # search-template W6: the deploy-pinned palette rides the env ONLY when the
  # site row pins one — nil deploys byte-identical to pre-theme payloads. The
  # box engines already allow-list BARKPARK_THEME (BUILD_ALLOW + the API's
  # deploy-request env allow-list, W2).
  defp maybe_put_theme(payload, %Site{theme: nil}), do: payload

  defp maybe_put_theme(payload, %Site{theme: theme}) when is_binary(theme) do
    put_in(payload, [:env, :BARKPARK_THEME], theme)
  end

  # site-spawner W7 (charter D63): the runtime target the box switches to, mapped
  # from `kind` — node sites boot a process, everything else swaps a symlink.
  defp runtime_target(%Site{kind: "node"}), do: "node"
  defp runtime_target(_site), do: "static"

  # search-template charter D7: WHICH shipped starter tree the box provisions for
  # this site — the third deploy axis, forwarded on the payload so the box's
  # Provisioner selects it (DeployRequest validates it as a closed, path-indexing
  # slug — never an open string). Derived from `framework`: astro→astro-starter,
  # nextjs→next-starter. A framework with no shipped starter yet (nuxt/sveltekit/
  # hugo/static) carries NO template — the box then falls back to the
  # runtime_target default, byte-identical to the pre-template payload. W2
  # (charter D8): an EXPLICIT Site.template (set at create — the dashboard
  # picker / bp cloud site create --template) wins over the framework-derived
  # default, which remains the nil-template fallback.
  defp maybe_put_template(payload, %Site{template: explicit, framework: framework}) do
    case explicit || site_template(framework) do
      nil -> payload
      template -> Map.put(payload, :template, template)
    end
  end

  defp site_template("astro"), do: "astro-starter"
  defp site_template("nextjs"), do: "next-starter"
  defp site_template(_framework), do: nil

  # For a node deploy, carry down the IDLE slot's PORT — the port the box builds+
  # boots the new Node process on, health-gates, THEN flips the Caddy upstream to
  # (blue/green, zero-downtime). Non-node deploys carry no port (symlink swap).
  defp maybe_put_target_port(payload, %Site{kind: "node"} = site) do
    case NodePortAllocator.target_slot_port(site) do
      nil -> payload
      port -> Map.put(payload, :target_port, port)
    end
  end

  defp maybe_put_target_port(payload, _site), do: payload

  # The build fetches over the SCOPED route (charter D6): tenant-membership
  # isolation is what pins the token to ONE workspace — the flat route would let a
  # token's default workspace decide, which is not the same guarantee.
  defp scoped_api_url(%Site{} = site, %Barkpark{url: url}) when is_binary(url) do
    String.trim_trailing(url, "/") <>
      "/w/#{URI.encode(site.bootstrap_workspace || "")}/p/#{URI.encode(site.bootstrap_project || "")}"
  end

  defp scoped_api_url(_site, _bp), do: nil

  ## The poll loop: read the box, CAS what changed, repeat until terminal.
  ##
  ## Two INDEPENDENT budgets ride this loop (charter D-restart-grace):
  ##
  ##   * `left` — the BUILD budget. Every poll that actually reached the box and
  ##     saw the build still `running` (or a 404 not-yet-picked-up) spends one; at
  ##     zero the build genuinely stalled and the row fails "did not finish in time".
  ##
  ##   * `grace_left` — the RESTART budget. An `{:error, _}` poll means the box was
  ##     UNREACHABLE for this beat — and on this fleet that is almost never a dead
  ##     box, it is `barkpark.service` bouncing under an api/** auto-deploy while a
  ##     site build runs on it. Failing the row on the FIRST such blip (as the loop
  ##     used to) marks it `failed` ~2s in, and a failed Deployment row is
  ##     permanently unresurrectable — so the surviving on-box build could never
  ##     settle live (D35, proven). Instead we tolerate a BOUNDED run of consecutive
  ##     unreachable polls (~90s of default grace) WITHOUT spending build budget, so
  ##     the box finishes its restart and the control plane re-attaches.
  ##
  ## The two budgets never share a counter: `grace_left` RESETS to full on ANY poll
  ## that reached the box (a 2xx or a 404), so a restart mid-build costs nothing
  ## against a later, unrelated blip — only a GENUINELY dead box (grace consecutive
  ## errors with no reachable poll between) exhausts the grace and fails honestly,
  ## with the same `unreachable/2` reason the first-blip fail used to give.

  defp poll(ctx, _build_id, 0, _grace_left),
    do:
      fail(
        ctx,
        with_graced_note(
          ctx,
          "the build did not finish in time — the box is still working, or it stalled; deploy again to retry"
        )
      )

  defp poll(ctx, build_id, left, grace_left) do
    case BoxRelay.poll_deploy(ctx.bp, ctx.site.slug, build_id) do
      {:ok, status, body} when status in 200..299 ->
        report = normalize_report(body)
        ctx = ctx |> forget_graced_refusals() |> apply_stages(report.stages)

        case report.state do
          :succeeded -> settle_live(ctx, report)
          :failed -> fail(ctx, report.failure_reason || stage_failure_copy(report))
          # The box was reachable: spend one build beat and REFRESH the grace budget.
          :running -> sleep_then_poll(ctx, build_id, left - 1, poll_grace())
        end

      # The box has not started reporting yet (a 404 on a build id it hasn't
      # picked up) — keep waiting rather than inventing a failure. Reachable, so
      # the grace budget resets here too.
      {:ok, 404, _body} ->
        sleep_then_poll(ctx |> forget_graced_refusals(), build_id, left - 1, poll_grace())

      # THE POOL BLIP (deploy-truth W2). 91% of this door's 500s land HERE, and
      # none of them are the box refusing anything: they are
      # `DBConnection.ConnectionError` — a starved Postgres pool (SEARCH is the
      # dominant consumer) crashing the deploy door's OWN auth plug, rendered by
      # Phoenix's RenderErrors path (`ErrorJSON`, which never reaches
      # `action_fallback`) into the UNTYPED `internal_error / unknown error`
      # envelope. Terminating on the first one killed builds on beat 37 of 45 for
      # a defect the deploy path does not own — the exact grenade the `{:error, _}`
      # grace below already defuses for a transient SILENCE. A transient ANSWER
      # now buys the same bounded budget.
      #
      # It is DISCRIMINATING, not blanket: only the untyped crash envelope is
      # graced (`transient_refusal?/1`), so a TYPED 5xx (`runner_start_failed`,
      # the box stating a real fault about itself) is still terminal on the first
      # beat. And the swallowed refusals are RECORDED, so if the untyped 5xx
      # never clears, the failure that lands names the box's own last words and
      # how many were tolerated first — grace hides nothing, it only waits.
      {:ok, status, body} when status >= 500 and grace_left > 0 ->
        refusal = box_refusal(status, body, :poll)

        if transient_refusal?(body) do
          Process.sleep(poll_ms())
          poll(record_graced_refusal(ctx, refusal), build_id, left, grace_left - 1)
        else
          # A TYPED 5xx is terminal — but if untyped blips were tolerated on the
          # way here, the row still says so. "Grace never hides" has to hold on
          # every terminal exit, not only the ones that run out of budget.
          fail(ctx, with_graced_note(ctx, after_completed_build(ctx, refusal)))
        end

      {:ok, status, body} ->
        fail(
          ctx,
          with_graced_note(ctx, after_completed_build(ctx, box_refusal(status, body, :poll)))
        )

      # A restart-shaped blip: the box was unreachable this beat. Spend GRACE (not
      # build budget) and re-poll — `left` is untouched, so a long restart never
      # eats into "did the build finish in time". `grace_left` is proven > 0 here.
      {:error, _reason} when grace_left > 0 ->
        Process.sleep(poll_ms())
        poll(ctx, build_id, left, grace_left - 1)

      # Grace exhausted: this is not a blip, the box is really gone. Fail honestly
      # with the box's own unreachable reason — exactly the pre-grace behaviour,
      # now only after the restart window has closed.
      {:error, reason} ->
        fail(ctx, with_graced_note(ctx, unreachable(ctx.bp, reason)))
    end
  end

  # `failure_reason` is `:text` and holds the WHOLE story; `detail` is the
  # varchar(255) latest-wins caption the site page renders under the status pill.
  # A reason that carries the box's own words plus a request_id plus a graced
  # count can outgrow 255 — and an over-long `detail` does not truncate, it
  # RAISES (22001) inside the terminal transition, which would lose the very
  # failure it was trying to record. Clamped here, once, for both terminal
  # writers.
  defp short_detail(reason) when is_binary(reason) do
    if String.length(reason) > 255, do: String.slice(reason, 0, 254) <> "…", else: reason
  end

  defp short_detail(reason), do: reason

  # The graced-refusal ledger, carried on `ctx` (a plain map) so the loop's two
  # budgets keep their arities. It is CLEARED by any poll that reached the box —
  # the same reset rule `grace_left` follows, so an old blip never colours a
  # later, unrelated verdict.
  defp record_graced_refusal(ctx, caption) do
    ctx
    |> Map.update(:graced_refusals, 1, &(&1 + 1))
    |> Map.put(:last_graced_refusal, caption)
  end

  defp forget_graced_refusals(ctx), do: Map.drop(ctx, [:graced_refusals, :last_graced_refusal])

  # Grace waits; it never hides. Whatever finally fails the row says how many
  # transient 5xx were tolerated on the way and what the last one said.
  defp with_graced_note(ctx, reason) do
    case {Map.get(ctx, :graced_refusals), Map.get(ctx, :last_graced_refusal)} do
      {n, last} when is_integer(n) and is_binary(last) ->
        "#{reason} (after tolerating #{n} transient box 5xx; the last was: #{last})"

      _ ->
        reason
    end
  end

  defp sleep_then_poll(ctx, build_id, left, grace_left) do
    Process.sleep(poll_ms())
    poll(ctx, build_id, left, grace_left)
  end

  # CAS each NEW stage transition onto the row: `stage` (which stage is in
  # flight), `detail` (latest-wins caption), and ONE console entry per stage
  # carrying its identity. Already-recorded stages are skipped, so a poll that
  # re-reports the whole stream is idempotent.
  defp apply_stages(ctx, stages) do
    Enum.reduce(stages, ctx, fn stage, acc ->
      if recorded?(acc, stage.name, stage.status) do
        acc
      else
        record_stage(acc, stage)
      end
    end)
  end

  defp recorded?(ctx, name, status) do
    seen = Map.get(ctx, :seen, MapSet.new())
    MapSet.member?(seen, {name, status})
  end

  defp record_stage(ctx, stage) do
    deployment = Registry.get_deployment(ctx.id)
    entry = console_entry(stage)

    attrs = %{
      stage: stage.name,
      detail: stage.detail || stage_line(stage),
      # cch-w33-bl, NAMED CONSENT — this is the ONE console writer that does not
      # go through `Registry.cap_console/1`; the other three do
      # (`append_deployment_console/2`, `cancel_preview/2`, and the provision
      # twin). The bound holds by ARITHMETIC, not by enforcement: `apply_stages/2`
      # records a stage at most once per {name, status} pair (`recorded?/2`), and
      # six stages over three terminal statuses ceilings this at eighteen entries
      # against `@max_console_lines` 300.
      #
      # Latent is not harmless. Nothing here would notice the cap being lowered,
      # and if this writer ever appends onto a console another path already
      # capped, the row silently exceeds the cap and loses `cap_console/1`'s
      # `dropped_before` disclosure — a console that dropped its head would then
      # be indistinguishable from a complete one, which is the exact defect class
      # this epic exists to remove.
      #
      # CONSENTED RATHER THAN FIXED, deliberately: capping here means either
      # promoting `cap_console/1` to public in `registry.ex`, or re-deriving the
      # ring locally — and a local `Enum.take/2` would drop the head SILENTLY,
      # buying the bound by committing the very defect above. The honest fix is
      # to promote the one canonical implementation, which is a `registry.ex`
      # change and belongs with whoever holds that file.
      console: (deployment.console || []) ++ [entry],
      status: status_for_stage(deployment.status, stage),
      # Heartbeat: every stage CAS refreshes the lease so the reaper doesn't
      # mistake a long-but-healthy BUILD for an abandoned claim.
      claimed_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
    }

    case Registry.transition_deployment_fenced(ctx.id, ctx.worker, ctx.epoch, attrs) do
      {:ok, _updated} ->
        # site-spawner W4 (charter D15-D17): push this stage transition to the
        # console the instant it is CAS'd, so the dashboard's live six-stage rail
        # advances WITHOUT polling. The `deployments` tick only fires at the
        # terminal settle/fail; this fine-grained `site.deploy.stage` event is the
        # per-stage push — the SSE frame serializes the whole {type,payload}, and a
        # missed/duplicated event is harmless (the rail folds the whole set each
        # time). Only on a WON CAS: a stale epoch means we no longer own the row,
        # so we must not narrate over the worker that does.
        broadcast_stage(ctx, stage)

        Map.update(
          ctx,
          :seen,
          MapSet.new([{stage.name, stage.status}]),
          &MapSet.put(&1, {stage.name, stage.status})
        )

      {:error, reason} ->
        # A stale epoch means our lease was swept and someone else owns the row —
        # stop narrating over them. Telemetry is best-effort by design.
        Logger.warning("site deploy stage CAS failed (#{inspect(reason)}) for #{ctx.id}")

        Map.update(
          ctx,
          :seen,
          MapSet.new([{stage.name, stage.status}]),
          &MapSet.put(&1, {stage.name, stage.status})
        )
    end
  end

  # The coarse status a stage implies (charter D3). Everything up to HEALTH is
  # still `building` — nothing a visitor can see has moved. SWITCH/RETIRE are
  # `pushing`: the box is flipping the symlink. `live` is settled once, at the
  # end, together with the site pointer.
  defp status_for_stage(current, %{name: name}) do
    cond do
      current in ["pushing", "live", "failed", "cancelled"] -> current
      name in [@switch_stage, "RETIRE"] -> "pushing"
      true -> "building"
    end
  end

  defp console_entry(stage) do
    %{
      "line" => stage_line(stage),
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "stage" => stage.name,
      "status" => stage.status,
      "detail" => stage.detail
    }
  end

  # The per-stage push (charter D15-D17). Coarse-by-design like every Events
  # broadcast — the payload names WHICH deployment moved to WHICH stage, and the
  # dashboard reads the authoritative deployment on the next fetch; the rail folds
  # this signal in place. A nil/blank team is a no-op in Events.broadcast.
  #
  # cch-w27-s2: `detail` rides through `stage_caption/2` — the SAME display fold
  # `Web.Router.deployment_json/1` applies to the console entry this stage also
  # writes. Until now this payload shipped `stage.detail` RAW, which made this the
  # ONE channel that both (a) redacted nothing, so an ssh capture carrying a
  # bearer token reached the browser live while the HTTP twin of the same bytes
  # returned `Bearer [redacted]`, and (b) classified nothing, so the live rail and
  # the settled row named two different causes for one failure. `Events.broadcast`
  # forwards the payload verbatim to every SSE frame, so this call site is the
  # only place either could be fixed.
  defp broadcast_stage(ctx, stage) do
    BarkparkCloud.Events.broadcast(ctx.site.team_id, "site.deploy.stage", %{
      site_id: ctx.site.id,
      slug: ctx.site.slug,
      deployment_id: ctx.id,
      stage: stage.name,
      status: stage.status,
      detail: stage_caption(stage.status, stage.detail)
    })
  end

  defp stage_line(%{name: name, status: status, detail: detail}) do
    case detail do
      d when is_binary(d) and d != "" -> "#{name} #{status} — #{d}"
      _ -> "#{name} #{status}"
    end
  end

  ## Terminal states.

  # SWITCH has happened on the box: the release is serving. Flip the live pointer
  # and the deployment together, in ONE transaction — no window where the
  # deployment says `live` but the site still points at the previous build.
  defp settle_live(ctx, report) do
    attrs = %{
      status: "live",
      stage: List.last(@stages),
      became_live_at: DateTime.truncate(DateTime.utc_now(), :microsecond),
      detail: "live at #{report.url || site_url(ctx.site, ctx.bp)}"
    }

    case Registry.transition_deployment_with_site_update(ctx.id, ctx.worker, ctx.epoch, attrs, %{
           current_deployment_id: ctx.id
         }) do
      {:ok, _d} ->
        settled_live(ctx)

      {:error, reason} ->
        reconcile_serving(ctx, attrs, reason)
    end
  end

  # The cleanup + push a settled-live row earns, WHICHEVER write landed it — the
  # fenced one above or the reconcile below. The box is serving these bytes now;
  # the control plane's copy has done its job (charter D91). A terminal Deployment
  # is never re-driven (`live` has no outgoing edge in `Deployment.@transitions`),
  # so keeping the artifact would leak up to 32 MB per build onto cloud_pgdata.
  defp settled_live(ctx) do
    :ok = drop_artifact(ctx.id)
    BarkparkCloud.Events.broadcast(ctx.site.team_id, "deployments")
    {:ok, :live}
  end

  # THE DURABLE HALF OF W27 ARM B (dr-w27-arm-b-serving-build-durable-repair).
  #
  # THE WORST LOSS ON THIS PATH. SWITCH has already happened ON THE BOX — the
  # release IS serving — and the fenced write above is the one that tells the
  # control plane so. A refused fence used to leave the row non-live with the site
  # pointer unflipped, and because the row is still `building` with a lease nobody
  # renews, `StaleDeploymentReaper`'s over-budget pass then settled that SERVING
  # build `failed`, blaming "exceeded max deploy claim attempts (stale builder
  # lease)" — a terminal failure row, and a wrong cause, on a deploy serving
  # traffic. Reachable in prod: `deployment_stale_after_seconds` defaults to 15
  # minutes and `record_stage/2` only heartbeats on a stage TRANSITION, so a long
  # BUILD lets the reaper move the row under a driver that is still running.
  #
  # W27 made that OBSERVABLE (the log line below). This is the durable repair:
  # RE-SETTLE FROM THE BOX'S OWN REPORT. The fence was right to refuse — the
  # epoch moved, so this driver no longer owns the row — but the fence guards
  # AUTHORSHIP, not TRUTH, and the truth here came from the box: it answered
  # `succeeded` for this build id and is serving those bytes. So the write is
  # re-attempted OUTSIDE the fence, under a row lock, with three guards that keep
  # it from being the trampling the fence exists to stop:
  #
  #   1. STATUS. Only `building`/`pushing` reconcile — a row someone else already
  #      settled (`live`, `failed`, `cancelled`, `deferred`) is left exactly as it
  #      is. This never resurrects a terminal row.
  #   2. THE TRANSITION GRAPH. `building → live` is not an edge, so the walk goes
  #      through `pushing` with the SWITCH stage the box really ran, rather than
  #      taking a shortcut the fenced writers are forbidden.
  #   3. THE POINTER. `sites.current_deployment_id` moves only when it is nil, is
  #      already this row, or names an OLDER deployment — a zombie must never drag
  #      a site backwards onto a release the box has since replaced.
  #
  # NOT a reaper change and NOT a new column: the reaper's over-budget pass is
  # correct as written (a genuinely wedged `building` row SHOULD terminate), and
  # after this repair the ARM B row simply is not `building` when the sweep runs.
  # NOT a public Registry function either — an unfenced live-write is only safe in
  # the hand of a caller holding the box's own SUCCEEDED report, and this is the
  # one such caller.
  defp reconcile_serving(ctx, attrs, reason) do
    case reconcile_serving_write(ctx, attrs) do
      {:ok, _d} ->
        Logger.error(
          "site deploy settle-live for deployment #{ctx.id} (site #{ctx.site.slug}) " <>
            "could not be recorded (fenced write #{inspect(reason)}): the box is serving this build, " <>
            "so the row was RECONCILED live outside the fence from the box's own report — " <>
            "the row now says live and the site's live pointer names this deployment, and the " <>
            "stale-deployment reaper has no building row left to terminally fail"
        )

        settled_live(ctx)

      {:error, why} ->
        # THE RESIDUAL, and it keeps W27's original sentence verbatim because in
        # this arm every word of it is still true.
        Logger.error(
          "site deploy settle-live for deployment #{ctx.id} (site #{ctx.site.slug}) " <>
            "could not be recorded (fenced write #{inspect(reason)}) and could not be reconciled " <>
            "(#{inspect(why)}): the box is serving this build, " <>
            "but the row never went live and the site's live pointer was not flipped — " <>
            "the stale-deployment reaper will terminally report this serving build as failed, blaming the builder lease"
        )

        {:error, reason}
    end
  end

  # The only statuses a driver's OWN row can hold when its SWITCH landed on the
  # box. Everything else is somebody else's settled outcome.
  @reconcilable_statuses ~w(building pushing)

  defp reconcile_serving_write(ctx, attrs) do
    Repo.transaction(fn ->
      case Repo.one(from d in Deployment, where: d.id == ^ctx.id, lock: "FOR UPDATE") do
        nil ->
          Repo.rollback(:not_found)

        %Deployment{status: status} = d when status in @reconcilable_statuses ->
          with {:ok, d} <- walk_through_switch(d),
               {:ok, d} <- d |> Deployment.transition_changeset(attrs) |> Repo.update(),
               :ok <- point_site_at(ctx, d) do
            d
          else
            {:error, why} -> Repo.rollback(why)
          end

        %Deployment{status: status} ->
          Repo.rollback({:already_settled, status})
      end
    end)
  end

  # `Deployment.@transitions` has no `building → live` edge — the pipeline goes
  # through `pushing` — and skipping it would be exactly the shortcut the fenced
  # writers are refused. The box really did run SWITCH, so record that edge.
  defp walk_through_switch(%Deployment{status: "building"} = d) do
    d
    |> Deployment.transition_changeset(%{status: "pushing", stage: @switch_stage})
    |> Repo.update()
  end

  defp walk_through_switch(%Deployment{} = d), do: {:ok, d}

  defp point_site_at(ctx, %Deployment{} = d) do
    case Repo.one(from s in Site, where: s.id == ^ctx.site.id, lock: "FOR UPDATE") do
      nil ->
        {:error, :site_not_found}

      %Site{} = site ->
        if pointer_behind?(site, d) do
          case site |> Site.runtime_changeset(%{current_deployment_id: d.id}) |> Repo.update() do
            {:ok, _site} -> :ok
            {:error, cs} -> {:error, cs}
          end
        else
          # A NEWER build went live after this one: the box is serving THAT, and
          # dragging the pointer back would be this same mis-report in reverse.
          # The deployment row is still corrected; the pointer is left alone.
          :ok
        end
    end
  end

  defp pointer_behind?(%Site{current_deployment_id: nil}, _d), do: true
  defp pointer_behind?(%Site{current_deployment_id: id}, %Deployment{id: id}), do: true

  defp pointer_behind?(%Site{current_deployment_id: id}, %Deployment{} = d) do
    case Repo.get(Deployment, id) do
      nil -> true
      %Deployment{inserted_at: at} -> DateTime.compare(at, d.inserted_at) != :gt
    end
  end

  # How many CONSECUTIVE deferrals OF THE SAME CAUSE a site may collect before
  # the chain is called what it is. Each deferral costs one re-fired debounce job
  # (~60s apart) and one box call, and a normal build finishes in 2-4 minutes, so
  # a healthy trailing rebuild defers once or twice. A box that is still busy
  # with THIS SITE after this many rounds is not "busy" — it is stuck, and a
  # chain that re-fires forever would be a silent infinite loop wearing a counted
  # status. The last one FAILS, honestly and terminally, naming the box.
  @max_consecutive_deferrals 6

  # …but a CONCURRENT-BUILD CAP is a different animal, and sharing one bound with
  # the busy box loses publishes for no reason. The cap's whole job is to refuse
  # slots while the box is under pressure — six refusals in a row is what a busy
  # fleet LOOKS like, not evidence of a stuck runner — so a capacity chain gets a
  # longer leash before it is called terminal. It is still bounded: an instance
  # that has been at its cap for this many rounds has builds that are not
  # finishing, and that IS worth a human.
  @max_consecutive_capacity_deferrals 12

  # The head-of-stream scan must reach past the LONGEST bound, or the longest
  # chain could never be counted to its own limit.
  @deferral_scan_depth @max_consecutive_capacity_deferrals + 2

  # THE HARD CEILING ON THE DEFER BACKOFF (deploy-reliability W20, charter D352).
  # `AutoDeployWorker`'s `@unique [period: 300]` is compared against the job's
  # `inserted_at`, NOT its `scheduled_at` (Oban 2.23.0 `Basic.since_period/3`), so
  # a job scheduled further out than the period ages OUT of its own unique window
  # while still pending: the next enqueue sees no conflict and mints a SECOND
  # job — the fan-out this backoff exists to cut, reintroduced by the backoff.
  # 240 < 300 with headroom, and the alternative repair (`timestamp: :scheduled_at`
  # on the unique) is deliberately NOT taken: the cap is one number a test can
  # pin, the timestamp swap changes the coalescing semantics of every caller.
  @deferral_backoff_cap_seconds 240

  @doc """
  THE DEPTH-DERIVED DEFER WINDOW (deploy-reliability W20), in seconds.

  A refused deploy re-fires as a fresh debounced `AutoDeployWorker` job. Until
  now that job scheduled at the flat publish debounce (60s live —
  `AUTODEPLOY_DEBOUNCE_S` is unset on the control plane), which knows nothing
  about the build it is queueing behind: measured over 2,262 consecutive
  deferrals, p50 61.6s apart with 1,441 of them inside the 55-75s band and only 4
  below 55s. The clock, not the box, paced the chain — and 807 chains carried
  2,268 rows (mean 2.81, p90 5, max 11).

  The window is a MULTIPLE OF THE OPERATOR'S OWN DEBOUNCE, never an independent
  constant: `depth` 1 waits exactly as long as today, and each further round of
  the SAME chain waits one more window, capped at
  `#{@deferral_backoff_cap_seconds}s`. An operator who has already stretched the
  debounce past the cap keeps their own longer window (the cap must never make a
  deferral MORE eager than a plain publish).

  It does NOT make publishes go live faster — with one build slot per box the
  wait is set by the slot, not by this clock. What it removes is repetition:
  fewer permanent terminal `deferred` rows and fewer box POSTs per publish.
  """
  @spec deferral_backoff_seconds(pos_integer() | Site.t()) :: pos_integer()
  def deferral_backoff_seconds(depth) when is_integer(depth) and depth >= 1 do
    base = AutoDeployWorker.debounce_seconds()
    min(base * depth, max(base, @deferral_backoff_cap_seconds))
  end

  # The window for a site whose CHAIN DEPTH IS NOT IN HAND — `AutoDeployWorker`'s
  # `defer_behind_running_build/2`, which holds only the site and the in-flight
  # deployment, mints no row of its own, and therefore has no `cause` to count a
  # chain of. It reads the depth off the head of the site's own deployment stream
  # (the same head-of-stream scan `defer/3` counts with, keyed on whatever cause
  # that head row carries) and adds the round now being deferred.
  #
  # A site with no deferral at the head reads depth 1 — today's window, unchanged.
  def deferral_backoff_seconds(%Site{} = site) do
    deferral_backoff_seconds(current_deferral_depth(site) + 1)
  end

  # A BOX-BUSY DEFERRAL (charter D9). Not a failure, not a drop — a settled row
  # that says "this build did not happen, and here is the rebuild that will".
  #
  # Two things must both be true or this is worse than the terminal `failed` it
  # replaces: the row must be COUNTED (it is — `deferred` is a first-class status
  # the deployment stream prints), and the rebuild must actually RE-FIRE. The
  # re-fire is the debounced `AutoDeployWorker` job: it is the fleet's only
  # coalescing rebuild path, it re-reads the site's CURRENT content when it runs
  # (so it carries the publish that was refused, not a stale snapshot), and its
  # `site_id` unique collapses N deferrals of the same site onto ONE pending job.
  #
  # It is a NEW Oban job, deliberately NOT `{:snooze, n}` on the running one:
  # snooze increments `attempt` against `max_attempts: 3`, so three busy boxes
  # would DISCARD the job — the exact silent drop this wave exists to refuse.
  #
  # A PREBUILT deploy is never deferred: its bytes live on the control plane's
  # own row, the debounce path refuses prebuilt sites outright (it would rebuild
  # from source and overwrite bytes this fleet cannot reproduce), so promising a
  # rebuild we will not perform would be a lie. It fails honestly instead.
  defp defer(ctx, %Deployment{} = deployment, reason) do
    site = ctx.site
    cause = deferral_cause(deployment.stage, reason)
    prior = consecutive_deferrals(site, cause)

    cond do
      Deployment.prebuilt?(deployment) ->
        fail(ctx, reason <> " — re-run the upload once the in-flight deploy finishes")

      prior >= max_consecutive_deferrals(cause) - 1 ->
        # THE ABANDONMENT STAMPS ITS OWN COLUMNS (deploy-reliability W28, S6).
        # The terminal round of a chain is the one row an operator most needs to
        # find — it is the publish the fleet GAVE UP ON — and it was the only
        # deferral-chain row that carried NULL `deferral_depth` /
        # `deferral_bound` / `deferral_cause`, because `fail/2` wrote status,
        # failure_reason and detail and nothing else. Every abandonment on the
        # live control plane was therefore findable ONLY by
        # `failure_reason LIKE '%rebuilds in a row for this site%'` — a prose
        # scan over the very sentence a reword would silently break — while the
        # eleven DEFERRED rows beneath it were queryable as data.
        #
        # Nothing is computed here: `prior + 1`, the cause's bound and the cause
        # are the three values this call site is ALREADY holding to write the
        # sentence, so the columns and the prose come from one expression each
        # and cannot drift apart.
        #
        # THE DEPTH IS `prior + 1`, NOT `prior`, and not the deferred rows' max.
        # This branch fires at `prior >= bound - 1`, so the bound-th round is
        # written `failed` and never `deferred`: the highest depth a DEFERRED
        # row can carry is 11 (capacity) / 5 (busy), and the abandonment that
        # follows it is 12 / 6 — the same number the sentence interpolates.
        fail(ctx, abandonment_reason(reason, prior + 1, cause), %{
          deferral_depth: prior + 1,
          deferral_bound: max_consecutive_deferrals(cause),
          deferral_cause: cause
        })

      true ->
        # THE DEPTH TRAVELS (deploy-reliability charter D99, PR #9905). `prior`
        # was computed here, spent on the threshold above and interpolated into
        # the terminal string and the Logger line — and then DISCARDED, so the
        # operator-visible reason on refusal 1 and refusal 11 was byte-identical
        # and a chain eight rounds deep read exactly like a first blip. It rides
        # the EXISTING failure_reason/detail columns; no column was added.
        #
        # THE HONEST BOUND, and why the sentence says "zero-progress guard"
        # instead of counting down: `consecutive_deferrals/2` counts deferrals OF
        # THIS SAME CAUSE at the HEAD of the site's stream, scanned only
        # @deferral_scan_depth rows deep. It is NOT a lifetime total — one
        # successful deploy, or one deferral of a DIFFERENT cause, resets it to
        # zero — so a site that deferred 75 times in 12h can legitimately read 3
        # here, and did. A bare "3 of 12" would read as a countdown to a drop
        # that a merely-slow box may never reach.
        #
        # The bound comes from `max_consecutive_deferrals/1`, never a literal:
        # a capacity chain gets 12 and a busy/stuck chain gets 6, and a sentence
        # that hardcoded either would misstate the other cause's whole budget.
        bound = max_consecutive_deferrals(cause)

        # The depth sits EARLY, before the re-queue promise: `detail` is the
        # varchar(255) caption `short_detail/1` clamps, and a reason that carries
        # the box's own words can already be ~200 chars — so anything appended
        # last is the part the caption loses.
        detail =
          reason <>
            " — deferred: refusal #{prior + 1} of #{bound} in this site's current chain" <>
            " — a rebuild carrying this content has been re-queued and will run once the in-flight deploy finishes" <>
            " (the count is a zero-progress guard, not a countdown: only back-to-back refusals of this same cause count, and any successful deploy resets it to 0)"

        # THE PROMISE IS MADE FIRST, and the row only says `deferred` once it
        # holds. `deferred` is a TERMINAL status (`Deployment.@transitions` maps
        # it to `[]`), so a row settled deferred can never be corrected — writing
        # it before the re-queue is what made a broken re-queue unfixable and
        # left a lost publish wearing "re-queued, not lost". Enqueuing early is
        # safe: the debounced job is unique per site and schedules ~60s out, so a
        # rebuild that outlives a failed transition is the same coalesced job the
        # next publish would have fired anyway.
        # THE RE-FIRE STOPS BEING BLIND (W20): the depth already in hand above
        # picks the window, so round 4 of a chain no longer knocks on the same
        # busy box on the same 60s clock that round 1 did.
        case requeue_rebuild(site.id, deferral_backoff_seconds(prior + 1)) do
          {:ok, _job} ->
            deferral_write =
              Registry.transition_deployment_fenced(ctx.id, ctx.worker, ctx.epoch, %{
                status: "deferred",
                failure_reason: detail,
                detail: short_detail(detail),
                # THE CHAIN STOPS BEING PROSE (deploy-reliability W12, S6). The
                # SAME three facts the sentence above states in English, written
                # as data in the SAME write — one transition, one truth, so the
                # columns can never disagree with the sentence beside them.
                #
                # The sentence is NOT replaced. Vercel keeps `readyStateReason`
                # beside its `readyState` enum for the same reason: the prose is
                # the operator's (it explains that the counter is a zero-progress
                # guard, which no integer can), the columns are the aggregate's.
                # Before this, "how deep do capacity chains get" was a regex over
                # a sentence — `internal/cli/cloud_site_cmd.go`'s
                # `siteDeferralChainRe` reads the depth back out of English, and
                # one reworded clause would silently zero every such count.
                #
                # NOTHING READS THESE YET, on purpose: `DeployLedger` still
                # classifies off the reason string this wave. Write first, read
                # next wave — a reader flipped in the same change as its producer
                # cannot be proven to have been broken before.
                deferral_depth: prior + 1,
                deferral_bound: bound,
                deferral_cause: cause
              })

            # A COUNTING DEFECT, not merely a narration one (deploy-reliability
            # W27). The rebuild above really was enqueued, so the publish is not
            # lost — but if this write loses its fence, the row never becomes
            # `deferred` and `deferral_depth` / `deferral_bound` / `deferral_cause`
            # are never written, so the deferral is invisible to every deferral
            # census, to `consecutive_deferrals/2`'s chain scan, and to the
            # post-door rate this epic publishes. A defect that removes rows from
            # a numerator cannot be seen by reading the numerator.
            #
            # The narration rides the SAME branch: the pre-existing info line
            # states "deferred … N in a row", which is a count read off the very
            # write that just lost — true only when the CAS held.
            case deferral_write do
              {:ok, _updated} ->
                Logger.info(
                  "site deploy deferred for site #{site.id} (#{prior + 1} in a row, #{cause}): rebuild re-queued"
                )

              {:error, cas_error} ->
                Logger.error(
                  "site deploy deferral for deployment #{ctx.id} (site #{site.id}) " <>
                    "could not be recorded (fenced write #{inspect(cas_error)}): the rebuild WAS re-queued, " <>
                    "but the row never became deferred and deferral_depth / deferral_bound / deferral_cause " <>
                    "were never written — this deferral is invisible to every deferral census and to the post-door rate"
                )
            end

            BarkparkCloud.Events.broadcast(site.team_id, "deployments")
            {:ok, :deferred}

          {:error, enqueue_error} ->
            # THE PROMISE COULD NOT BE MADE, so this is not a deferral — it is
            # the lost publish this wave exists to refuse, and it is reported as
            # one WITH ITS STATUS, not merely in prose. `fail/2` settles it
            # `failed`, which puts it in the ledger's failure numerator; leaving
            # it `deferred` kept a terminally lost publish out of the numerator
            # while wearing the label "the rebuild was re-queued, not lost".
            #
            # Nothing retries this row, and the comment that used to sit here
            # said otherwise: it claimed "the OUTCOME is an error so the Oban job
            # retries", and cited a `defer_behind_running_build/2` that does not
            # exist. In production `Deploy.run/1` is called from exactly one
            # place — the `Task.Supervisor.start_child` body inside
            # `BarkparkCloud.Sites.Deploy.TaskStarter.start/1`, at the bottom of
            # THIS file — which returns the SPAWN result and throws the run's
            # return value away. There is no job outcome to fail and no retry to
            # wait for. The user's next publish IS the retry, which is what the
            # row now says.
            Logger.error(
              "site deploy deferral could not re-queue the rebuild for site #{site.id}: #{inspect(enqueue_error)}"
            )

            _ =
              fail(
                ctx,
                reason <> " — and the rebuild could NOT be re-queued; publish again to retry"
              )

            {:error, {:deferral_requeue_failed, enqueue_error}}
        end
    end
  end

  @doc """
  The terminal ABANDONMENT sentence: the box's own refusal plus the driver's
  admission that it has stopped retrying this publish.

  PUBLIC ON PURPOSE, and it is the only place this sentence is written.
  `DeployLedger.classify/2` has to recognise an abandoned row out of the RAW
  `failure_reason` column, and its only handle on one is this prose — so a reword
  here would silently degrade every abandoned row back to `BOX_BUSY_409`, whose
  label ("the box was already deploying") is affirmatively false for a capacity
  abandonment, with nothing failing anywhere. `deploy_ledger_test.exs` builds its
  fixtures through THIS function, so the classifier reds at edit time instead.
  """
  @spec abandonment_reason(String.t(), pos_integer(), String.t() | nil) :: String.t()
  def abandonment_reason(reason, rounds, cause) do
    reason <>
      " — and it has now refused #{rounds} rebuilds in a row for this site, #{terminal_verdict(cause)}"
  end

  # The deferral's NAMED cause, from the same classifier the ledger reports with —
  # one owner for the taxonomy, so a chain and a census can never disagree about
  # what a row is.
  defp deferral_cause(stage, reason) do
    DeployLedger.classify(%{status: "deferred", stage: stage, failure_reason: reason})
  end

  defp max_consecutive_deferrals("BOX_AT_CAPACITY_DEFERRED"),
    do: @max_consecutive_capacity_deferrals

  defp max_consecutive_deferrals(_cause), do: @max_consecutive_deferrals

  # What the terminal round actually ACCUSES the box of — derived from the cause,
  # because a capacity refusal is not a stuck runner and telling an operator to
  # go look at one sends them to the wrong place.
  defp terminal_verdict("BOX_AT_CAPACITY_DEFERRED"),
    do:
      "so the instance has been at its concurrent-build cap for that entire run; check for builds holding slots without finishing, or raise the cap"

  defp terminal_verdict("BOX_BUSY_DEFERRED"),
    do: "so the instance is not busy but stuck; check its deploy runner"

  defp terminal_verdict(_cause),
    do:
      "so the instance is refusing this site persistently for a cause the ledger cannot name; check its deploy runner"

  # The head-of-stream chain depth WITHOUT a cause in hand: take the cause from
  # the head deferral row itself, then count with the same scan `defer/3` uses.
  # Anything else at the head (a live build, a failure, nothing at all) is depth
  # 0 — there is no chain to back off from.
  defp current_deferral_depth(%Site{} = site) do
    site
    |> Registry.list_deployments(@deferral_scan_depth, environment: "production")
    |> Enum.drop_while(&(&1.status in ["queued", "building", "pushing"]))
    |> case do
      [%{status: "deferred"} = head | _] ->
        consecutive_deferrals(site, deferral_cause(head.stage, head.failure_reason))

      _ ->
        0
    end
  end

  # Deferrals of THE SAME CAUSE at the HEAD of this site's stream, i.e. how many
  # rounds the current chain has already run. Any other status — and any deferral
  # for a DIFFERENT cause — ends the count: a busy box and a full build queue are
  # two different stories, and counting them as one chain spends a site's whole
  # budget on causes that never repeated.
  defp consecutive_deferrals(%Site{} = site, cause) do
    site
    |> Registry.list_deployments(@deferral_scan_depth, environment: "production")
    |> Enum.drop_while(&(&1.status in ["queued", "building", "pushing"]))
    |> Enum.take_while(fn d ->
      d.status == "deferred" and deferral_cause(d.stage, d.failure_reason) == cause
    end)
    |> length()
  end

  # The re-queue seam. A PROCESS-LOCAL override wins over the real worker for the
  # same reason `starter/0` documents its own: under `Oban testing: :manual` an
  # insert ALWAYS succeeds, so the re-queue-failure arm above — the one that
  # decides whether a lost publish is counted — was unreachable in a test and had
  # never been exercised at all. A check that cannot fail proves nothing.
  # The window travels with the re-queue (W20): `defer/3` already holds `prior`,
  # so the depth is free here — it only had to be PLUMBED, since this arm is two
  # hops from Oban. The process-local override keeps its arity-1 contract: it
  # exists to make the re-queue FAILURE arm reachable under `testing: :manual`
  # (where an insert always succeeds), and it does not care about the window.
  defp requeue_rebuild(site_id, schedule_in) do
    case Process.get(:site_deploy_requeue) do
      fun when is_function(fun, 1) -> fun.(site_id)
      _ -> AutoDeployWorker.enqueue(site_id, schedule_in)
    end
  end

  # `extra` is the OPTIONAL structured half of a failure — columns the caller is
  # already holding, written in the SAME transition as the sentence so the two
  # can never disagree (W28, S6: the abandonment branch stamps its chain's depth,
  # bound and cause). It defaults to empty because the other nine `fail/…` call
  # sites have no chain to report, and a failure with no structure must keep
  # writing NULL rather than a zero that would read as "a chain of depth 0".
  defp fail(ctx, reason, extra \\ %{}) do
    # THE FAILURE'S ONLY CARRIER (deploy-reliability W27). This CAS is the whole
    # report: `Deploy.TaskStarter.start/1` returns the SPAWN result and throws
    # this function's return value away, so in production nothing downstream ever
    # sees `{:ok, :failed}`. When the fence refuses (our lease was swept and
    # re-claimed), the row is NOT `failed`, `failure_reason` stays nil — and no
    # alert fires either, because `maybe_dispatch_deployment_failed/2` lives
    # INSIDE the won-CAS branch of `transition_deployment_fenced/4`. A failed
    # build then has no carrier at all.
    #
    # The RETURN SHAPE IS DELIBERATELY UNCHANGED: `{:error, _}` from here would
    # route through `AutoDeployWorker.start_and_report/2`'s "could not start the
    # driver — retrying" arm — a NEW mis-report on a build that DID start, plus
    # an Oban retry of it. So the repair is speech: the line NAMES the deployment
    # and states both halves of what did not happen.
    # THE SENTENCE WINS THE MERGE. `extra` is written UNDER the three fields
    # this function exists to write, never over them: `fail/…` is the failure's
    # only carrier, so a caller that passed a stray `:status` or
    # `:failure_reason` key — by typo, or by reusing a map built for something
    # else — must not be able to turn an abandonment into a different row than
    # the one it just announced. Structure is additive here, by construction.
    attrs =
      Map.merge(
        extra,
        %{status: "failed", failure_reason: reason, detail: short_detail(reason)}
      )

    case Registry.transition_deployment_fenced(ctx.id, ctx.worker, ctx.epoch, attrs) do
      {:ok, _updated} ->
        :ok

      {:error, cas_error} ->
        Logger.error(
          "site deploy failure for deployment #{ctx.id} (site #{ctx.site.slug}) " <>
            "could not be recorded (fenced write #{inspect(cas_error)}): the row was NOT marked failed, " <>
            "failure_reason was not written, and no failure alert was dispatched " <>
            "(the alert only fires on a won CAS) — the reason that was lost is: #{reason}"
        )
    end

    # `failed` is terminal too — the row is never re-driven (the reaper only
    # requeues rows that are still `queued`), so its bytes are equally dead
    # weight. Dropping them here as well as on the happy path is why a run of
    # failed prebuilt deploys cannot fill the control plane's disk.
    :ok = drop_artifact(ctx.id)

    BarkparkCloud.Events.broadcast(ctx.site.team_id, "deployments")
    {:ok, :failed}
  end

  # A box that answered, but said no. Its own words travel — never a generic
  # "deploy failed".
  #
  # deploy-truth W2: the caption also names WHICH PHASE refused and carries the
  # box's `request_id`. Both were missing, and 2,544 rows paid for it: this
  # helper is called identically from the START arm and from every poll beat, so
  # "the instance refused the deploy (HTTP 500)" could not be told apart from
  # "…refused beat 37 of 45", and with no request_id no row could be joined to
  # the box journal that holds the actual stack trace. `failure_reason` is
  # `:text`, so both fold in with NO migration and no new column.
  defp box_refusal(status, body, phase) when is_map(body) do
    base =
      case phase do
        :start -> "the instance refused the deploy (HTTP #{status})"
        :poll -> "the instance refused the build poll (HTTP #{status})"
      end

    base =
      case refusal_detail(body) do
        d when is_binary(d) and d != "" -> "#{base}: #{d}"
        _ -> base
      end

    case request_id(body) do
      nil -> base
      rid -> "#{base} [box request_id: #{rid}]"
    end
  end

  # The box's own request id, as `Barkpark.Content.Errors.put_request_id/2`
  # stamps it from Logger metadata — nested inside the typed envelope, or flat on
  # the bodies `relay_with/5`'s fallback produces.
  defp request_id(body) when is_map(body) do
    nested =
      case body["error"] do
        %{} = err -> err["request_id"] || err["requestId"]
        _ -> nil
      end

    string_or_nil(nested || body["request_id"])
  end

  defp request_id(_), do: nil

  # THE REFUSAL CAPTION ON A BUILD THAT FINISHED (dr-bl-500-caption-lie).
  #
  # `box_refusal/3` names WHO refused and WHEN in the poll loop — but not what
  # the deploy had already ACHIEVED by then, and that is the half 1,322 rows
  # needed. Row b928fb2f-65b7-45ee-ab8b-80fa44cad42c walked PLAN done → BUILD
  # done (`npm ci && npm run build`) → STAGE done
  # (`standalone(+static+public) -> releases/2141dca9a5d58149 (39M)`) → HEALTH
  # running, and then the pool blip outlived the grace. The row it wrote —
  # "the instance refused the build poll (HTTP 500)" — is the caption of a box
  # that never took the job at all. A reader cannot tell the two apart, and they
  # want OPPOSITE responses: a start-phase refusal sends you to the runner flag,
  # this one sends you to the health probe on a build whose artifact really
  # exists on the box.
  #
  # So the caption LEADS with what happened and where, and the box's own words
  # follow it unchanged. It ADDS; it never replaces — the status, the code word
  # and the `request_id` journal join all still travel, and
  # `DeployLedger.classify/2` still reads them (its `@refusal` anchor carries
  # this clause as an optional prefix, and `sites_deploy_test.exs` asserts the
  # class off the row this function wrote, so a reword reds at edit time).
  defp after_completed_build(ctx, refusal) do
    case reached_after_stage(ctx) do
      nil -> refusal
      stage -> "the build completed and staged; the deploy then failed at #{stage} — #{refusal}"
    end
  end

  # The stage a deploy was AT when it died — but ONLY once the build genuinely
  # produced something: BUILD and STAGE both `done` is exactly "there is an
  # artifact staged on the box". Anything short of that has no completed build to
  # mis-report, so its refusal caption is left alone (a deploy that died during
  # BUILD really was refused mid-build and nothing else).
  #
  # "Where it was" is the stage AFTER the furthest completed one, which is what
  # the row's own `stage` column already says: the box reports HEALTH `running`
  # while it probes, and a poll that never comes back leaves that as the last
  # word. A fully-done walk yields nil (there is no seventh stage) — and it could
  # not reach here anyway, since a done RETIRE settles the row live.
  defp reached_after_stage(ctx) do
    seen = Map.get(ctx, :seen, MapSet.new())

    if MapSet.member?(seen, {"BUILD", "done"}) and MapSet.member?(seen, {"STAGE", "done"}) do
      done = Enum.filter(@stages, &MapSet.member?(seen, {&1, "done"}))
      idx = Enum.find_index(@stages, &(&1 == List.last(done)))
      Enum.at(@stages, idx + 1)
    end
  end

  # Is this 5xx the box refusing, or the DOOR dying?
  #
  # A refusal the box AUTHORED carries a code it chose (`runner_start_failed`,
  # `feature_not_configured`, …): it is a verdict about this build and repeating
  # the question cannot change it. The pool-starvation 500 has no author — the
  # crash path collapses every unhandled fault to the generic `internal_error`
  # constant with the message "unknown error". That, and only that, is what the
  # grace budget is for. An untyped body with no code at all counts too: the
  # bodies `relay_with/5` synthesises for an undecodable 5xx are equally
  # authorless.
  # `deploy_runner_unavailable` (dr-w8-s2) is the SECOND authorless shape. The
  # box's door emits it when its Runner did not answer the trigger inside the
  # call budget — a busy or wedged process, not a verdict about this build, and
  # repeating the question is exactly what can change the answer. It used to
  # arrive here wearing `feature_not_configured`, which is a TYPED refusal and
  # therefore terminal on the first beat: 207 rows in 24h spent a build on a box
  # that was merely slow. Naming it without grading it here would have kept the
  # loss and only renamed it, so the two land in the SAME change (charter D114).
  defp transient_refusal?(body) when is_map(body) do
    case refusal_code(body) do
      nil -> true
      "internal_error" -> true
      "deploy_runner_unavailable" -> true
      _ -> false
    end
  end

  defp transient_refusal?(_), do: false

  defp refusal_code(%{"error" => %{} = err}), do: string_or_nil(err["code"])
  defp refusal_code(body) when is_map(body), do: string_or_nil(body["code"])
  defp refusal_code(_), do: nil

  # site-spawner W10: the box renders its typed refusals NESTED —
  # `BarkparkWeb.SiteDeployController.bad_request/3` (and its
  # `feature_not_configured` / `build_id_mismatch` siblings) all answer
  # `%{error: %{code: …, message: …}}`, and `Registry.relay_with/5` decodes that
  # with STRING keys. The old flat `body["error"]` therefore bound a MAP, failed
  # the `is_binary` guard, and fell through to the bare "the instance refused the
  # deploy (HTTP 400)" — so every typed extraction refusal the prebuilt ingest
  # raises (`artifact_missing`, `artifact_digest_mismatch`, the symlink/absolute
  # /traversal path refusals, …) was invisible to the user, and the deploy that
  # names its cause most precisely was the one that named it least.
  #
  # The nested arm is tried FIRST and both halves travel: the code is what a user
  # greps or files a bug about, the message is what tells them what to fix.
  defp refusal_detail(%{"error" => %{} = err}) do
    code = string_or_nil(err["code"])
    message = string_or_nil(err["message"] || err["detail"] || err["reason"])

    case {code, message} do
      {nil, nil} -> nil
      {code, nil} -> code
      {nil, message} -> message
      {code, message} -> "#{code} — #{message}"
    end
  end

  # A flat body: the shape `relay_with/5`'s `%{}` fallback produces, plus any box
  # route that answers a bare string reason.
  defp refusal_detail(body),
    do: body["error"] || body["detail"] || body["reason"] || body["failure_reason"]

  defp string_or_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_or_nil(_), do: nil

  defp unreachable(%Barkpark{slug: slug}, :not_live),
    do: "instance #{slug} has no URL yet — it is still provisioning"

  defp unreachable(%Barkpark{slug: slug}, :no_admin_token),
    do:
      "instance #{slug} has no stored admin token — the control plane cannot drive a deploy on it"

  defp unreachable(%Barkpark{slug: slug}, :decrypt_failed),
    do: "instance #{slug}'s admin token could not be decrypted"

  # THE REFUSAL THAT IS NOT A REACHABILITY PROBLEM (cloud-console-hardening
  # D741/D757). `BoxRelay` refuses a WRITE to a box whose stored admin credential
  # the box itself answered 401 — nothing went on the wire, so calling it
  # "unreachable" would describe a network fault that did not happen. The sentence
  # ECHOES the one #11337 ships on the instance seam rather than minting a third
  # wording for one fact: the clause "the instance rejected our access credential"
  # is `usageUnavailableText("unauthorized")` byte for byte, and the second
  # sentence is that seam's verbatim. Only the opener is verb-neutral, because
  # this clause serves BOTH the rollback and the teardown mint.
  defp unreachable(%Barkpark{}, :identity_refused),
    do:
      "The request was never sent — the instance rejected our access credential. " <>
        "Barkpark Cloud stops asking a box that refused it; the hourly update " <>
        "check is what notices the credential working again."

  defp unreachable(%Barkpark{slug: slug}, _reason),
    do:
      "instance #{slug} is unreachable — the deploy could not be delivered; check instance health"

  # The box reported `failed` but named no reason: name the stage that failed, so
  # the user still learns WHERE it broke.
  defp stage_failure_copy(%{stages: stages}) do
    case Enum.find(stages, &(&1.status == "failed")) do
      %{name: name, detail: d} when is_binary(d) and d != "" -> "#{name} failed — #{d}"
      %{name: name} -> "#{name} failed on the box — see the deploy console"
      _ -> "the deploy failed on the box — see the deploy console"
    end
  end

  ## ---------------------------------------------------------------------------
  ## Rollback (charter D5) — a symlink repoint, BLOCKING on the real flip.
  ## ---------------------------------------------------------------------------

  @doc """
  Roll `site` back to its previous release: `site-deploy.sh --rollback` on the box
  — an atomic `current` symlink repoint, no rebuild.

  BLOCKS until the box confirms the flip, then repoints `sites.current_deployment_id`
  at the deployment that build belongs to. Returns
  `{:ok, %{deployment_id, previous_deployment_id, url}}`, or `{:error, status,
  reason}` when the box cannot roll back (no previous release, a deploy holding the
  lock, an unreachable box). The route answers non-2xx on every `:error` — the CLI
  gates success on the HTTP status ALONE, so a rollback that could not happen MUST
  NOT answer 200.
  """
  @spec rollback(Site.t(), Barkpark.t()) ::
          {:ok, map()}
          | {:error, non_neg_integer(), String.t()}
          | {:error, non_neg_integer(), String.t(), String.t()}
  def rollback(%Site{} = site, %Barkpark{} = bp) do
    was = site.current_deployment_id

    # Carry the runtime_target so the box dispatches to the RIGHT rollback engine
    # (charter D63/D71): a node site rolls back by flipping the Caddy port to its
    # warm previous slot (site-deploy-node.sh --rollback), NOT the static engine's
    # symlink swap — which has no `current` symlink for a node site and exits 22
    # "not_supported". The deploy payload already carries this; rollback must too.
    case BoxRelay.rollback(bp, %{
           mode: "rollback",
           slug: site.slug,
           runtime_target: runtime_target(site)
         }) do
      {:ok, status, body} when status in 200..299 ->
        target = body["build_id"] || body["target_build"] || body["current_build"]
        finish_rollback(site, bp, was, target)

      {:ok, 409, body} ->
        typed_rollback_error(
          409,
          body,
          "a deploy is running on the box — try again once it finishes"
        )

      {:ok, status, body} when status in 400..599 ->
        typed_rollback_error(
          422,
          body,
          "the instance could not roll this site back (HTTP #{status})"
        )

      {:ok, _status, body} ->
        typed_rollback_error(422, body, "the instance could not roll this site back")

      # THE REFUSED BOX (D741/D763). Nothing went on the wire, so this is a
      # CONFLICT with the box's own verdict about our credential, not a 502 about
      # the network — and it carries a TYPED code, because the console cannot
      # classify a status the route labels `rollback_failed` on every error.
      {:error, :identity_refused} ->
        {:error, 409, unreachable(bp, :identity_refused), "identity_refused"}

      {:error, reason} ->
        {:error, 502, unreachable(bp, reason)}
    end
  end

  @doc """
  Tear a site down on its box (the inverse of a spawn): stop the slots, disarm the
  Caddy route, delete the release tree. Carries `runtime_target` so the box picks
  the right engine (`site-deploy-node.sh` stops slots; `site-deploy.sh` doesn't).

  Returns `:ok` once the box confirms `TORN_DOWN=`, or `{:error, status, detail}`
  — the CALLER must only deregister the site row on `:ok`, or a still-serving box
  gets orphaned.
  """
  @spec teardown(Site.t(), Barkpark.t()) ::
          :ok
          | {:error, pos_integer(), String.t()}
          | {:error, pos_integer(), String.t(), String.t()}
  def teardown(%Site{} = site, %Barkpark{} = bp) do
    case BoxRelay.teardown(bp, %{
           mode: "teardown",
           slug: site.slug,
           runtime_target: runtime_target(site)
         }) do
      {:ok, status, _body} when status in 200..299 ->
        :ok

      {:ok, status, body} when status in 400..599 ->
        {:error, 422,
         teardown_refusal(body, "the instance could not tear this site down (HTTP #{status})")}

      {:ok, _status, body} ->
        {:error, 422, teardown_refusal(body, "the instance could not tear this site down")}

      # Same fence, same typed conflict (D741/D763): the teardown was refused by
      # the control plane before the wire, not lost on it.
      {:error, :identity_refused} ->
        {:error, 409, teardown_unreachable(bp, :identity_refused), "identity_refused"}

      {:error, reason} ->
        {:error, 502, teardown_unreachable(bp, reason)}
    end
  end

  # W68 (D814, Option A) — the DELETE receipt's OWN reachability copy. Two of
  # `unreachable/2`'s sentences narrate a DEPLOY ("cannot drive a deploy on it",
  # "the deploy could not be delivered"), and until this variant existed they
  # reached a user who pressed DELETE byte-unchanged. The shared mint stays
  # byte-frozen — `start_on_box/6`, `poll/4` and `rollback/2` still feed it, and
  # `DeployLedger.classify/2` keys on its "is unreachable" substring (preserved
  # here too) — so this variant is teardown-LOCAL: only `teardown/2`'s two
  # `{:error, _}` arms call it. The verb-free sentences delegate rather than
  # fork; `:identity_refused` in particular must stay byte-identical to the
  # instance-seam copy `unreachable/2` deliberately echoes (D741).
  defp teardown_unreachable(%Barkpark{slug: slug}, :no_admin_token),
    do:
      "instance #{slug} has no stored admin token — the control plane cannot drive a teardown on it"

  defp teardown_unreachable(%Barkpark{slug: slug}, reason)
       when reason not in [:not_live, :decrypt_failed, :identity_refused],
       do:
         "instance #{slug} is unreachable — the teardown could not be delivered; check instance health"

  defp teardown_unreachable(%Barkpark{} = bp, reason), do: unreachable(bp, reason)

  # The box has flipped. Point the site at the deployment that owns the now-live
  # build so `bp cloud site status` tells the truth immediately (no polling
  # window where the site claims the build it just rolled AWAY from).
  defp finish_rollback(site, bp, was, target) do
    now_live =
      case target do
        b when is_binary(b) and b != "" -> Registry.find_deployment_by_build_id(site.id, b)
        _ -> nil
      end

    _ =
      if now_live && now_live.id != was do
        Registry.set_site_current_deployment(site, now_live.id)
      end

    # THE WRITE THAT WAS NEVER ATTEMPTED (deploy-reliability W27). When the box
    # names a build the control plane has no Deployment row for, `now_live` is
    # nil, the pointer write above is SKIPPED — and this function still answers
    # `{:ok, …}`, which the route turns into a 200. The CLI gates success on the
    # HTTP status alone, so the user is told the rollback landed while
    # `sites.current_deployment_id` still names the build they rolled AWAY from,
    # upstream of the very transition fields the crown reads.
    #
    # This is the arm where the discarded result is the LEAST of it:
    # `sites.current_deployment_id` carries no FK, so that `Repo.update` is
    # near-unfailable. What is lost is the write that never ran.
    if is_nil(now_live) do
      Logger.error(
        "site rollback for site #{site.slug} (#{site.id}) could not repoint the live deployment: " <>
          "the box reports build #{inspect(target)} as now live, but the control plane has no Deployment row for it, " <>
          "so the site-pointer write was SKIPPED while the rollback still answered success — " <>
          "sites.current_deployment_id still names #{inspect(was)}"
      )
    end

    BarkparkCloud.Events.broadcast(site.team_id, "deployments")

    {:ok,
     %{
       deployment_id: (now_live && now_live.id) || nil,
       previous_deployment_id: was,
       url: site_url(site, bp)
     }}
  end

  # W70 (D847/D854) — MIGRATED onto `refusal_detail/1`, the extractor the deploy
  # path already trusts. The box's REAL pre-poll refusal transport is NESTED —
  # `SiteDeployController` answers every refusal `%{error: %{code, message}}`
  # and `BoxRelay.HTTP` relays a non-2xx verbatim before it ever polls — so the
  # old flat `body["error"] || body["detail"] || body["reason"]` chain bound a
  # MAP, failed the `is_binary` guard below, and the box's own sentence died
  # into the generic fallback. `refusal_detail/1` tries the nested arm first and
  # composes "code — message"; its flat arm is a strict superset of the old
  # chain (it also reads `failure_reason`), so every settle_* sentence and
  # await-timeout body still passes through unchanged.
  # cch-w62-bl — the box's three TYPED site-rollback refusals travel as a CODE
  # the console can classify, not only as prose inside `detail`. The router's
  # 4-tuple arm (cch-w63-s3 / D763) relays `{:error, status, detail, code}` as
  # flat `%{ok: false, error: code, detail: detail}`; before this, only
  # `identity_refused` used it and every box refusal collapsed into the constant
  # `rollback_failed`, so `siteRollbackRefusalTerminal(422, …)` was false for a
  # permanent no-previous-build refusal and the modal offered "Try again" into a
  # refusal that cannot change by clicking. ALLOWLISTED, not open-ended: only
  # the box's typed site-rollback exits are promoted; every other body —
  # including the nested `already_running` composite, whose wire shape the W70
  # flat-detail law test pins as `rollback_failed` — keeps the constant. The
  # code is read from the nested `%{"error" => %{"code" => …}}` envelope
  # (`refusal_code/1`, the box's real pre-poll transport) or from the flat
  # `%{"error" => token}` fixture shape; `detail` still carries
  # `rollback_refusal/2`'s prose either way, so nothing a human reads changed.
  @typed_rollback_codes ~w(no_previous not_supported lock_held)

  defp typed_rollback_error(status, body, fallback) do
    detail = rollback_refusal(body, fallback)

    case typed_rollback_code(body) do
      nil -> {:error, status, detail}
      code -> {:error, status, detail, code}
    end
  end

  defp typed_rollback_code(body) when is_map(body) do
    code =
      case refusal_code(body) do
        c when is_binary(c) -> c
        _ -> if is_binary(body["error"]), do: body["error"], else: nil
      end

    if code in @typed_rollback_codes, do: code, else: nil
  end

  defp typed_rollback_code(_body), do: nil

  defp rollback_refusal(body, fallback) when is_map(body) do
    case refusal_detail(body) do
      d when is_binary(d) and d != "" -> rollback_copy(d, fallback)
      _ -> fallback
    end
  end

  defp rollback_refusal(_body, fallback), do: fallback

  # W68 — a teardown refusal must never render ROLLBACK prose. The teardown 422
  # arms used to launder the box's body through `rollback_refusal/2`, whose typed
  # sentences narrate a rollback: a box answering `not_supported` to a teardown
  # told the user who pressed DELETE "this site has no live release yet — there
  # is nothing to roll back". Same extraction, teardown-safe rendering: the one
  # verb-neutral typed sentence (`lock_held`) keeps its plain words, and every
  # other detail — a box token like `not_supported`, or the transport's own
  # await-teardown timeout sentence — travels VERBATIM rather than being dressed
  # in another verb's prose.
  # W70 (D847/D854) — same migration as `rollback_refusal/2` above: the nested
  # envelope is the box's real pre-poll refusal transport, and `refusal_detail/1`
  # is the one extractor that reads it. The one verb-neutral typed sentence
  # (`lock_held`, an EXACT flat token) keeps its plain words; every other detail
  # — a nested "code — message" composite, a box token, or the transport's own
  # await-teardown timeout sentence — travels VERBATIM rather than being dressed
  # in another verb's prose (the W68 rollback-copy leak stays fixed).
  defp teardown_refusal(body, fallback) when is_map(body) do
    case refusal_detail(body) do
      "lock_held" -> "a deploy is running on the box — try again once it finishes"
      d when is_binary(d) and d != "" -> d
      _ -> fallback
    end
  end

  defp teardown_refusal(_body, fallback), do: fallback

  # site-deploy.sh's typed rollback exits, in plain words.
  #
  # TYPED-TOKEN FATE (W70, decided): these clauses match EXACT bare tokens, which
  # today's transports mint only as FLAT `%{"error" => token}` bodies — a shape
  # that is fixture-only on the current wire (settle_* mints failure_reason
  # sentences; pre-poll refusals are nested). They are KEPT as the friendly
  # rendering for that flat shape, and they deliberately do NOT fire on a nested
  # composite ("already_running — deploy already running for blog"): the box's
  # own message travels verbatim instead of being replaced by canned prose. If a
  # friendly sentence for a nested 409 is ever wanted, match `refusal_code/1` in
  # the caller's 409 arm — never widen these token clauses.
  defp rollback_copy("no_previous", _fallback),
    do: "there is no previous build to roll back to — this site has only ever had one release"

  defp rollback_copy("not_supported", _fallback),
    do: "this site has no live release yet — there is nothing to roll back"

  defp rollback_copy("lock_held", _fallback),
    do: "a deploy is running on the box — try again once it finishes"

  defp rollback_copy(other, _fallback), do: other

  ## ---------------------------------------------------------------------------
  ## Crash recovery
  ## ---------------------------------------------------------------------------

  @doc """
  Re-drive static deployments the reaper requeued — the other half of crash
  safety. The reaper can RECOVER an orphaned row (a control plane that restarted
  mid-build leaves a stale `building` claim, which it sweeps back to `queued`), but
  nothing in the fleet CLAIMS a static row: the off-box container builder is
  kind-scoped away from them, so a requeued static row would sit `queued` forever —
  the eternal spinner in a new costume.

  A row is an orphan (not a fresh mint) when it has been claimed before
  (`claim_epoch > 0`). Fresh rows are driven by the deploy route itself.

  Returns the number of rows ACTUALLY RE-DRIVEN — not the number found. This
  counts because the value IS the reaper's recovery metric:
  `StaleDeploymentReaper` puts it in the Oban job meta as `resumed`. It used to
  be `length(orphans)` over a fire-and-forget `start/1` that could not fail, so a
  sweep in which EVERY rescue was refused still reported `resumed: N` — the
  recovery mechanism failing looked exactly like the recovery mechanism working.
  A refusal is now counted out and logged; the rows it names stay `queued` for
  the next sweep.
  """
  @spec resume_orphaned() :: non_neg_integer()
  def resume_orphaned do
    Registry.list_orphaned_static_deployments()
    |> Enum.count(fn %Deployment{} = orphan ->
      case start_reported(orphan) do
        {:ok, _outcome} ->
          true

        {:error, reason} ->
          Logger.warning(
            "deploy resume could not re-drive orphaned deployment #{orphan.id} " <>
              "(site #{orphan.site_id}): #{inspect(reason)} — the row is left queued for the next sweep"
          )

          false
      end
    end)
  end

  ## ---------------------------------------------------------------------------
  ## Read model — the stage list the CLI streams
  ## ---------------------------------------------------------------------------

  @doc """
  The ordered six-stage list for a deployment, folded back out of its console
  narration. Every stage always appears (a lean payload still renders the full
  bar); a stage nothing has been recorded for is `pending`.

  Per-stage `status` is LITERALLY one of `done` | `failed` | `skipped` (plus
  `running`/`pending` for the ones still ahead) — the CLI's live stream prints
  NOTHING for any other word, so `ok`/`passed`/`complete` would silently blank the
  progress bar.
  """
  @spec stages(Deployment.t()) :: [map()]
  def stages(%Deployment{} = deployment) do
    recorded =
      (deployment.console || [])
      |> Enum.filter(&is_map/1)
      |> Enum.filter(&(&1["stage"] in @stages))
      |> Enum.reduce(%{}, fn entry, acc ->
        name = entry["stage"]

        Map.update(
          acc,
          name,
          %{
            name: name,
            status: normalize_status(entry["status"]),
            started_at: entry["at"],
            finished_at: finished_at(entry),
            detail: entry["detail"]
          },
          fn prev ->
            %{
              prev
              | status: normalize_status(entry["status"]),
                finished_at: finished_at(entry) || prev.finished_at,
                detail: entry["detail"] || prev.detail
            }
          end
        )
      end)

    Enum.map(@stages, fn name ->
      Map.get(recorded, name, %{
        name: name,
        status: pending_status(deployment, name),
        started_at: nil,
        finished_at: nil,
        detail: nil
      })
    end)
  end

  # A terminal deployment never gains another stage: an un-run stage of a FAILED
  # deploy is honestly `skipped` (the build died before it got there — and that is
  # exactly why visitors never saw it), not "pending" forever.
  defp pending_status(%Deployment{status: "failed"}, _name), do: "skipped"
  defp pending_status(_deployment, _name), do: "pending"

  defp finished_at(%{"status" => s, "at" => at}) when s in ["done", "failed", "skipped"], do: at
  defp finished_at(_), do: nil

  ## ---------------------------------------------------------------------------
  ## The box report — tolerant normalization
  ## ---------------------------------------------------------------------------

  @doc """
  Normalize whatever the box reported into `%{state, stages, url, failure_reason}`.

  Tolerant BY DESIGN: it reads a structured `stages` array when the instance
  supplies one, and otherwise parses the run's log lines — both the explicit
  `BPSTAGE <NAME> <status> [detail]` marker and `site-deploy.sh`'s own
  `[site-deploy hh:mm:ss] PLAN: …` narration. The instance-side surface is a
  sibling slice; a shape disagreement must degrade to "fewer stages narrated", never
  to a lost deploy.
  """
  @spec normalize_report(map()) :: %{
          state: :running | :succeeded | :failed,
          stages: [map()],
          url: String.t() | nil,
          failure_reason: String.t() | nil
        }
  def normalize_report(body) when is_map(body) do
    stages =
      cond do
        is_list(body["stages"]) ->
          Enum.map(body["stages"], &normalize_stage/1) |> Enum.filter(& &1)

        is_list(body["console"]) ->
          parse_lines(body["console"])

        is_binary(body["log"]) ->
          parse_lines(String.split(body["log"], "\n"))

        true ->
          []
      end

    %{
      state: normalize_state(body, stages),
      stages: stages,
      url: nonblank(body["url"]),
      failure_reason: nonblank(body["failure_reason"] || body["error"])
    }
  end

  def normalize_report(_), do: %{state: :running, stages: [], url: nil, failure_reason: nil}

  defp normalize_stage(%{} = s) do
    name = s["name"] || s["stage"]

    if name in @stages do
      %{
        name: name,
        status: normalize_status(s["status"]),
        detail: nonblank(s["detail"])
      }
    end
  end

  defp normalize_stage(_), do: nil

  # `BPSTAGE PLAN done — …` (the explicit marker) or `[site-deploy 09:12:03] BUILD
  # failed for 'blog' …` (the script's own log). Both name a stage and a verdict.
  defp parse_lines(lines) do
    lines
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&parse_line/1)
    |> Enum.filter(& &1)
  end

  # The engine's REAL marker is key=value —
  # `BPSTAGE name=BUILD status=failed build_id=b1 detail="…"` — so it is matched
  # first, and matched exactly (status and detail are read, never guessed from
  # prose). The looser prose form below is the genuine fallback: site-deploy.sh's
  # own `[site-deploy hh:mm:ss] BUILD: …` narration, where the verdict has to be
  # inferred from the words.
  defp parse_line(line) do
    stripped = Regex.replace(~r/^\[site-deploy [^\]]*\]\s*/, line, "")

    marker =
      Regex.run(
        ~r/^BPSTAGE\s+name=(PLAN|BUILD|STAGE|HEALTH|SWITCH|RETIRE)\s+status=([a-z]+)(?:\s+build_id=\S*)?(?:\s+detail="([^"]*)")?/,
        stripped,
        capture: :all_but_first
      )

    case marker do
      [name, status | rest] ->
        %{
          name: name,
          status: normalize_status(status),
          detail: rest |> List.first() |> nonblank()
        }

      _ ->
        parse_prose_line(stripped)
    end
  end

  defp parse_prose_line(stripped) do
    case Regex.run(~r/^(PLAN|BUILD|STAGE|HEALTH|SWITCH|RETIRE)\b[:\s]*(.*)$/, stripped) do
      [_, name, rest] ->
        %{name: name, status: line_status(rest), detail: nonblank(String.trim(rest))}

      _ ->
        nil
    end
  end

  defp line_status(rest) do
    down = String.downcase(rest)

    cond do
      String.contains?(down, "fail") or String.contains?(down, "abort") -> "failed"
      String.starts_with?(down, "skip") or String.contains?(down, "nothing to do") -> "skipped"
      String.starts_with?(down, "running") or String.starts_with?(down, "start") -> "running"
      true -> "done"
    end
  end

  # The CLI prints a stage ONLY for these exact words. `ok` / `passed` / `complete`
  # would blank the six-stage bar with no error anywhere — so they are mapped, not
  # trusted.
  defp normalize_status(s) when is_binary(s) do
    case String.downcase(String.trim(s)) do
      w
      when w in ["done", "ok", "passed", "pass", "success", "succeeded", "complete", "completed"] ->
        "done"

      w when w in ["failed", "fail", "error", "errored"] ->
        "failed"

      w when w in ["skipped", "skip", "noop", "no-op"] ->
        "skipped"

      w when w in ["running", "in_progress", "started", "start"] ->
        "running"

      _ ->
        "pending"
    end
  end

  defp normalize_status(_), do: "pending"

  # FAILURE SIGNALS BEAT THE LIFECYCLE WORD — this ordering is the whole
  # "a broken build never reaches a visitor" promise, so it is not cosmetic.
  #
  # The instance's `state` is a RUN LIFECYCLE (`idle` | `running` | `done`),
  # mirroring SelfUpdateController: `done` means "the process exited", NOT "the
  # deploy worked". The VERDICT lives in `exit_code` / `failure_reason`. Reading
  # `done` as success meant a build that died at BUILD or HEALTH (exit 12/14,
  # `state: "done"`) settled as `live` — the box correctly refused to switch, so
  # visitors kept the previous release, but the control plane flipped
  # `current_deployment_id`, marked the deployment live, and `bp cloud site`
  # printed a success line and a URL for a build that never shipped. A false
  # green is worse than a red.
  #
  # So: any failure signal wins, whatever the box calls its lifecycle.
  defp normalize_state(body, stages) when is_map(body) do
    lifecycle = (body["state"] || body["status"]) |> then(&(&1 && String.downcase(to_string(&1))))

    cond do
      failed?(body, stages) ->
        :failed

      lifecycle in ["succeeded", "success", "live", "ok", "complete", "completed", "done"] ->
        :succeeded

      lifecycle in ["failed", "fail", "error"] ->
        :failed

      true ->
        # No usable lifecycle word: infer from the stages — a done RETIRE is a
        # finished run, anything else is still going.
        if Enum.any?(stages, &(&1.name == "RETIRE" and &1.status == "done")),
          do: :succeeded,
          else: :running
    end
  end

  # A run is failed if the box said so in ANY of the three honest ways: a
  # non-zero exit code, a failure reason, or a stage that reported failed.
  defp failed?(body, stages) do
    exit_code = body["exit_code"]

    (is_integer(exit_code) and exit_code != 0) or
      nonblank(body["failure_reason"] || body["error"]) != nil or
      Enum.any?(stages, &(&1.status == "failed"))
  end

  defp nonblank(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp nonblank(_), do: nil

  ## ---------------------------------------------------------------------------
  ## URL + config
  ## ---------------------------------------------------------------------------

  @doc """
  The live URL of a spawned site: `https://<instance>/sites/<slug>/` (charter D4 —
  a PATH under the instance's existing FQDN, because no `*.barkpark.cloud`
  wildcard exists and no live box has ever run `on_demand_tls`). Nil while the
  instance has no URL yet.
  """
  @spec site_url(Site.t(), Barkpark.t() | nil) :: String.t() | nil
  def site_url(%Site{} = site, %Barkpark{url: url}) when is_binary(url) and url != "",
    do: String.trim_trailing(url, "/") <> base_path(site)

  def site_url(_site, _bp), do: nil

  @doc "The path a spawned site is served at, with both slashes: `/sites/<slug>/`."
  @spec base_path(Site.t()) :: String.t()
  def base_path(%Site{slug: slug}), do: "/sites/#{slug}/"

  ## Config seams.

  # The starter seam. A PROCESS-LOCAL override wins over the node-global app env
  # so an `async: true` test can drive the run synchronously (SyncStarter) without
  # swapping the starter out from under every other test running at that instant
  # — the same reasoning `NoopStarter` documents for its process-dictionary trace.
  defp starter do
    Process.get(:site_deploy_starter) ||
      Application.get_env(
        :barkpark_cloud,
        :site_deploy_starter,
        BarkparkCloud.Sites.Deploy.TaskStarter
      )
  end

  defp poll_ms, do: Application.get_env(:barkpark_cloud, :site_deploy_poll_ms, 2_000)
  defp poll_max, do: Application.get_env(:barkpark_cloud, :site_deploy_poll_max, 450)

  # The restart-grace budget (charter D-restart-grace): how many CONSECUTIVE
  # unreachable polls the loop tolerates before failing the row. 45 × the 2s
  # poll interval ≈ 90s — long enough for a `barkpark.service` bounce (nuke
  # `_build/prod` + recompile + restart) to complete mid-build, short enough that
  # a genuinely dead box still fails inside a couple of minutes. Config-defaulted
  # so tests can shrink it to a handful.
  defp poll_grace, do: Application.get_env(:barkpark_cloud, :site_deploy_poll_grace, 45)

  # How many times an UNTYPED 5xx on the START trigger is retried before the row
  # fails. Deliberately small: unlike a poll beat (where a finished build is on
  # the line), nothing has been built yet, and the retry's worst case is a 409
  # that becomes a counted deferral — so a handful of attempts across a pool blip
  # is enough, and a box that keeps crash-500ing still gets a verdict in seconds.
  defp start_retries,
    do: Application.get_env(:barkpark_cloud, :site_deploy_start_retries, 3)

  defp worker_id, do: "site-deploy-#{System.unique_integer([:positive])}@#{node()}"
end

defmodule BarkparkCloud.Sites.Deploy.Starter do
  @moduledoc """
  How a minted deployment's driver gets kicked off. One tiny behaviour with two
  implementations, because "spawn a Task" is exactly the kind of thing that makes a
  test race: prod spawns supervised (`TaskStarter`), test drives `Deploy.run/1`
  synchronously and asserts the settled row (`NoopStarter`).

  deploy-truth W1 (charter D9): the callback REPORTS. It used to be spec'd `:: :ok`
  and the production implementation returned a literal `:ok` after spawning, so a
  caller could not distinguish "the driver is running" from "the supervisor
  refused the child" from "the box said no". `{:ok, :started}` is the honest
  answer for an asynchronous starter; a synchronous one hands back the settled
  outcome; `{:error, reason}` means nothing is building and nothing recorded it.
  """
  @callback start(binary()) ::
              {:ok, :started | :live | :failed | :deferred} | {:error, term()}
end

defmodule BarkparkCloud.Sites.Deploy.TaskStarter do
  @moduledoc """
  The production starter: a supervised Task under `BarkparkCloud.SiteDeploySupervisor`.

  Crash-safety does NOT live here — it lives on the row (claim + epoch +
  heartbeat), so a Task that dies with the BEAM is recovered by the
  StaleDeploymentReaper + `Deploy.resume_orphaned/0`, not by this supervisor.
  """
  @behaviour BarkparkCloud.Sites.Deploy.Starter

  require Logger

  @impl true
  def start(deployment_id) do
    result =
      Task.Supervisor.start_child(BarkparkCloud.SiteDeploySupervisor, fn ->
        try do
          BarkparkCloud.Sites.Deploy.run(deployment_id)
        rescue
          e ->
            Logger.error(
              "site deploy driver crashed for #{deployment_id}: #{Exception.message(e)}"
            )
        end
      end)

    # deploy-truth W1: the SPAWN result travels. It used to be discarded and a
    # literal `:ok` returned, so a supervisor that refused the child (max_children,
    # a dead supervisor) left the row `queued` forever with every caller told the
    # build had started. The BUILD's own outcome still lands on the row — a
    # supervised Task cannot report it synchronously — and a busy box is deferred
    # and re-fired by `Deploy.run/1` itself.
    case result do
      {:ok, _pid} ->
        {:ok, :started}

      other ->
        Logger.error(
          "site deploy driver could not be spawned for #{deployment_id}: #{inspect(other)}"
        )

        {:error, other}
    end
  end
end

defmodule BarkparkCloud.Sites.Deploy.SyncStarter do
  @moduledoc """
  The SYNCHRONOUS starter: runs the driver in the calling process and hands back
  its settled outcome (`{:ok, :live | :failed | :deferred}` / `{:error, reason}`).

  It exists so a test can prove what a CALLER of `Deploy.start_reported/1`
  observes — the whole point of deploy-truth W1 is that `AutoDeployWorker` no
  longer flies blind, and a starter that spawns cannot demonstrate that. Select it
  per-process with `Process.put(:site_deploy_starter, __MODULE__)`; the seam is
  process-local so an `async: true` test never swaps it for another.
  """
  @behaviour BarkparkCloud.Sites.Deploy.Starter

  @impl true
  def start(deployment_id), do: BarkparkCloud.Sites.Deploy.run(deployment_id)
end

defmodule BarkparkCloud.Sites.Deploy.NoopStarter do
  @moduledoc """
  The test starter: spawns nothing. Route tests assert the 201 + the minted row
  deterministically; the driver itself is proven by calling `Deploy.run/1`
  directly against the in-memory fake box.

  site-spawner W9: it also leaves a PROCESS-LOCAL trace of WHAT THE ROW LOOKED
  LIKE at the instant the driver would have started — `Process.get({:deploy_started,
  id})` in the calling process. The prebuilt upload route must commit the
  artifact digest BEFORE handing the row over (otherwise a build can be in
  flight while the control plane cannot say which bytes it is serving), and that
  ordering is invisible to an after-the-fact read: both writes are done by then.

  Recorded in the CALLER's process dictionary rather than behind an
  `Application.put_env` swap, deliberately — app env is node-global, so an
  `async: true` module swapping it also swaps it for every test running at that
  instant. `start/1` is a plain synchronous call from the route, so the trace
  lands in the test's own process and nothing bleeds.
  """
  @behaviour BarkparkCloud.Sites.Deploy.Starter

  @impl true
  def start(deployment_id) do
    deployment = BarkparkCloud.Registry.get_deployment(deployment_id)

    Process.put({:deploy_started, deployment_id}, %{
      artifact_sha256: deployment && deployment.artifact_sha256,
      artifact_present: not is_nil(BarkparkCloud.Sites.Deploy.artifact_for(deployment_id))
    })

    # It stands in for the PRODUCTION spawn, so it reports what a successful spawn
    # reports: the driver is on its way, the outcome will land on the row.
    {:ok, :started}
  end
end
