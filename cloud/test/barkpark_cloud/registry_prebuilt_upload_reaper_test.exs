defmodule BarkparkCloud.RegistryPrebuiltUploadReaperTest do
  @moduledoc """
  ssw9-bl-stale-reaper-prebuilt-mint — what the stale-deployment reaper does to a
  PREBUILT deployment that was MINTED and never UPLOADED.

  Charter D86's mint-then-upload lane mints a `queued` Deployment and starts NO
  driver (`Web.Router`'s `start_box_build(true, _)` returns `:ok` without
  spawning one): the client must build off-box with the minted `build_id` baked
  in, then PUT the tarball to the artifact route, which is what starts the
  driver. Until that upload lands the row wears `claim_epoch == 0`, `claimed_at`
  nil and `artifact_sha256` nil — the EXACT shape a REFUSED DRIVER SPAWN leaves
  behind.

  DERIVED BY RUNNING, not by reading (criterion 0). On `origin/main` @ 9a837ed38
  this suite's first test was run against the unmodified reaper and the row
  landed:

      status:         "failed"
      failure_reason: "exceeded max deploy start attempts — the deploy driver was
                       never spawned (the control plane refused the child), so
                       this build was never claimed; deploy again to retry"
      claim_epoch:    0

  Both halves of that sentence are false for this row: nothing refused a spawn
  (this lane starts none), and the cure it names — deploy again, i.e. go look at
  the control plane's build capacity — is not the missing thing. The missing
  thing is the client's own upload. `list_orphaned_static_deployments/0` made it
  worse: it FOUND the row at the lease horizon (15 min) and `resume_orphaned/0`
  re-drove it, shipping a prebuilt run with no artifact — which the box refuses,
  killing a client's build 15 minutes into a legitimate upload window.

  So: (0a) and (0c) now EXCLUDE a prebuilt row awaiting its bytes, the orphan
  sweep does too, and pass (0d) owns it on
  `Registry.prebuilt_upload_grace_seconds/0` — a CLIENT-sized window, not a
  fleet lease — with a reason that names the missing upload.

  `async: true` is safe: Oban runs in `:manual` mode (config/test.exs) and no
  test here mutates application env.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.{Accounts, FailureCopy, Registry}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Workers.StaleDeploymentReaper

  ## Fixtures (mirror registry_deployment_reaper_test.exs)

  defp barkpark_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp static_site_fixture(barkpark, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(
        barkpark,
        Enum.into(attrs, %{
          name: "S #{n}",
          slug: "s-#{n}",
          kind: "static",
          framework: "astro",
          bootstrap_workspace: "acme",
          bootstrap_project: "blog",
          bootstrap_dataset: "production"
        })
      )

    site
  end

  # A CONTAINER site with neither an artifact_url nor a connected repo — the
  # shape pass (0a) terminates on sight. `prebuilt_enabled` carries no kind guard
  # on the deploy route, so this row is reachable.
  defp container_site_fixture(barkpark) do
    n = System.unique_integer([:positive])
    {:ok, site} = Registry.create_site(barkpark, %{name: "C #{n}", slug: "c-#{n}"})
    site
  end

  # `inserted_at` is the ONLY clock a never-claimed row has — `claimed_at` is nil
  # for it by construction, which is exactly why every claimed_at-gated pass is
  # blind to it.
  defp backdate_mint(deployment_id, seconds) do
    minted_at =
      DateTime.utc_now()
      |> DateTime.add(-seconds, :second)
      |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(d in Deployment, where: d.id == ^deployment_id),
      set: [inserted_at: minted_at]
    )
  end

  defp mint_prebuilt(site, tag) do
    {:ok, d} =
      Registry.create_deployment(site, %{
        build_id: tag,
        content_rev: tag,
        source: "prebuilt"
      })

    # The shape mint-then-upload leaves behind, ASSERTED rather than assumed —
    # it is what makes this row indistinguishable from a refused spawn.
    assert d.status == "queued"
    assert d.source == "prebuilt"
    assert d.claim_epoch == 0
    assert is_nil(d.claimed_at)
    assert is_nil(d.artifact_sha256)

    d
  end

  defp grace, do: Registry.prebuilt_upload_grace_seconds()
  defp lease_horizon, do: Registry.deployment_stale_after_seconds()
  defp spawn_budget, do: Registry.max_deploy_claims() * Registry.deployment_stale_after_seconds()

  ## 1. Criterion 2 — a legitimate slow upload INSIDE the window is not reaped;
  ##    criterion 1 — one PAST it dies naming the missing upload.
  ##
  ##    The two backdates are 120 seconds apart around the SAME boundary, which
  ##    is what makes this a window test and not a "reaps eventually" test: a
  ##    window widened past `grace() + 60` reds the second half, and one narrowed
  ##    below `grace() - 60` reds the first.
  test "a prebuilt mint survives its whole upload window, then dies naming the missing upload" do
    site = static_site_fixture(barkpark_fixture())
    d = mint_prebuilt(site, "pb1")

    ## FRESH — the client just got its 201 and is building. Untouched.
    assert {:ok, %{upload_missing_failed: 0, spawn_failed: 0, no_source_failed: 0, resumed: 0}} =
             perform_job(StaleDeploymentReaper, %{})

    assert %{status: "queued", failure_reason: nil} = Repo.get(Deployment, d.id)

    ## PAST THE FLEET'S LEASE HORIZON (15 min) — a cold CI build is routinely
    ## still running here. It must be neither reaped NOR re-driven: re-driving
    ## ships a prebuilt run with no artifact, which the box refuses, so a
    ## "rescue" here KILLS the build the client is still uploading.
    backdate_mint(d.id, lease_horizon() + 60)

    assert [] == Registry.list_orphaned_static_deployments()

    assert {:ok, %{upload_missing_failed: 0, spawn_failed: 0, resumed: 0}} =
             perform_job(StaleDeploymentReaper, %{})

    assert %{status: "queued", failure_reason: nil, claim_epoch: 0} =
             Repo.get(Deployment, d.id)

    ## PAST THE FLEET'S CLAIM BUDGET (75 min) is ALSO inside nothing — but the
    ## grace window (60 min) is what governs here, and one second before it the
    ## row is still the client's. Sit just INSIDE it.
    backdate_mint(d.id, grace() - 60)

    assert {:ok, %{upload_missing_failed: 0, spawn_failed: 0}} =
             perform_job(StaleDeploymentReaper, %{})

    assert %{status: "queued", failure_reason: nil} = Repo.get(Deployment, d.id)

    ## PAST IT. The client is gone; the row is told the truth.
    backdate_mint(d.id, grace() + 60)

    assert {:ok, %{upload_missing_failed: 1, spawn_failed: 0, no_source_failed: 0}} =
             perform_job(StaleDeploymentReaper, %{})

    reaped = Repo.get(Deployment, d.id)
    assert reaped.status == "failed"
    assert reaped.failure_reason =~ "prebuilt artifact was never uploaded"
    assert reaped.failure_reason =~ "--prebuilt"

    # The LIE, named, in both of the shapes that could produce it. A row this
    # pass stops owning falls straight back into one of them.
    refute reaped.failure_reason =~ "never spawned"
    refute reaped.failure_reason =~ "exceeded max"
    refute reaped.failure_reason =~ "no build source"

    # And the caption under the status pill is the cause, not a stale progress
    # line — the reaper's terminal-writer contract.
    assert reaped.detail == FailureCopy.caption(reaped.failure_reason)
  end

  ## 2. The reason is CLASSIFIED, not passed through raw. `FailureCopy` is the
  ##    boundary every read surface (dashboard + `bp sites`) goes through, so an
  ##    unmapped reaper reason reaches a person as internal jargon.
  test "the missing-upload reason routes through the failure_copy classifier" do
    site = static_site_fixture(barkpark_fixture())
    d = mint_prebuilt(site, "pb2")
    backdate_mint(d.id, grace() + 60)

    assert {:ok, %{upload_missing_failed: 1}} = perform_job(StaleDeploymentReaper, %{})

    raw = Repo.get(Deployment, d.id).failure_reason
    human = FailureCopy.humanize(raw)

    # It classified: the human copy is NOT the raw string...
    refute human == raw
    # ...it names the missing upload and the command that supplies it...
    assert human =~ "never arrived"
    assert human =~ "--prebuilt"
    # ...and it does not land in a neighbouring reaper class.
    refute human =~ "no build source"
    refute human =~ "several attempts"

    # Idempotent under a second pass, like every other clause in that module.
    assert FailureCopy.humanize(human) == human
  end

  ## 3. THE DIFFERENTIAL. Excluding prebuilt mints from (0a)/(0c) must not blind
  ##    those passes to the rows they were built for — a scope narrowed one
  ##    predicate too far is silent, and looks exactly like a fixed bug.
  test "a BOX-BUILD never-claimed row past the spawn budget still gets the refused-spawn reason" do
    site = static_site_fixture(barkpark_fixture())
    {:ok, d} = Registry.create_deployment(site, %{build_id: "bb1", content_rev: "bb1"})

    assert d.source == "box-build"
    backdate_mint(d.id, spawn_budget() + 60)

    assert {:ok, %{spawn_failed: 1, upload_missing_failed: 0}} =
             perform_job(StaleDeploymentReaper, %{})

    reaped = Repo.get(Deployment, d.id)
    assert reaped.status == "failed"
    assert reaped.failure_reason =~ "never spawned"
  end

  ## 4. The other half of the differential: a prebuilt row whose upload DID
  ##    arrive is out of (0d)'s scope on the ARTIFACT, not on the clock. Same
  ##    backdate as test 1's terminal half (`grace() + 60`), where a row with no
  ##    artifact dies — so the only thing separating the two outcomes is the
  ##    `artifact_sha256` conjunct. Without it this row would be failed under the
  ##    client while its driver builds.
  ##
  ##    And past the FLEET's spawn budget it is (0c)'s, honestly: once the bytes
  ##    landed the artifact route DID start a driver, so a row still `queued` at
  ##    `claim_epoch == 0` 75 minutes later is a spawn that really was refused.
  ##    (0d) handing it back is the point — the mint→upload exemption ends at the
  ##    upload, it is not a permanent immunity for anything tagged "prebuilt".
  test "a prebuilt row whose artifact ARRIVED is out of the upload pass, and falls back to (0c)" do
    site = static_site_fixture(barkpark_fixture())
    d = mint_prebuilt(site, "pb3")

    # What the artifact route stamps before it starts the driver.
    Repo.update_all(
      from(x in Deployment, where: x.id == ^d.id),
      set: [artifact_sha256: String.duplicate("a", 64)]
    )

    # Inside the fleet's spawn budget (75m) but PAST the upload grace (60m):
    # the clock alone would reap it, the artifact is what saves it.
    assert grace() + 60 < spawn_budget()
    backdate_mint(d.id, grace() + 60)

    assert {:ok, %{upload_missing_failed: 0, spawn_failed: 0}} =
             perform_job(StaleDeploymentReaper, %{})

    assert %{status: "queued", failure_reason: nil} = Repo.get(Deployment, d.id)

    # Past the spawn budget it is a refused spawn, and is told so — never the
    # missing-upload reason, whose cure (upload again) already happened.
    backdate_mint(d.id, spawn_budget() + 60)

    assert {:ok, %{upload_missing_failed: 0, spawn_failed: 1}} =
             perform_job(StaleDeploymentReaper, %{})

    reaped = Repo.get(Deployment, d.id)
    assert reaped.status == "failed"
    assert reaped.failure_reason =~ "never spawned"
    refute reaped.failure_reason =~ "never uploaded"
  end

  ## 5. A CONTAINER prebuilt mint. `prebuilt_enabled` is per-SITE with no kind
  ##    guard on the deploy route, and a container row carries no `artifact_url`
  ##    and (here) no connected repo — the exact predicate pass (0a) terminates
  ##    ON SIGHT, un-gated by any clock. So before this fix a container prebuilt
  ##    mint was dead within 60 seconds, told it had "no build source" while its
  ##    owner was still building the source it was about to upload.
  test "a CONTAINER prebuilt mint is not insta-failed as source-less, and dies honestly past the window" do
    site = container_site_fixture(barkpark_fixture())
    d = mint_prebuilt(site, "pb4")

    assert {:ok, %{no_source_failed: 0, upload_missing_failed: 0}} =
             perform_job(StaleDeploymentReaper, %{})

    assert %{status: "queued", failure_reason: nil} = Repo.get(Deployment, d.id)

    backdate_mint(d.id, grace() + 60)

    assert {:ok, %{upload_missing_failed: 1, no_source_failed: 0}} =
             perform_job(StaleDeploymentReaper, %{})

    reaped = Repo.get(Deployment, d.id)
    assert reaped.status == "failed"
    assert reaped.failure_reason =~ "prebuilt artifact was never uploaded"
  end

  ## 6. A HUMAN-CANCELLED prebuilt mint is neither resurrected nor re-terminated
  ##    — pass (0d)'s `status == "queued"` guard, asserted rather than assumed.
  test "pass (0d) leaves a cancelled prebuilt row alone" do
    site = static_site_fixture(barkpark_fixture())
    d = mint_prebuilt(site, "pb5")

    Repo.update_all(from(x in Deployment, where: x.id == ^d.id), set: [status: "cancelled"])
    backdate_mint(d.id, grace() + 3600)

    assert {:ok, %{upload_missing_failed: 0}} = perform_job(StaleDeploymentReaper, %{})
    assert %{status: "cancelled", failure_reason: nil} = Repo.get(Deployment, d.id)
  end
end
