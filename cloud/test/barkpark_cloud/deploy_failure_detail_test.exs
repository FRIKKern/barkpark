defmodule BarkparkCloud.DeployFailureDetailTest do
  @moduledoc """
  deploy-reliability (task-fb4fb869490b4213, criterion 5 of 7) — A FAILED
  DEPLOYMENT'S `detail` IS A CAUSE, NEVER A PROGRESS CAPTION AND NEVER BLANK.

  `deployments.detail` is the LATEST-WINS caption the site page renders under the
  status pill, written beat-by-beat by the off-box builder through
  `Registry.set_deployment_detail/2` ("Fetching your source…", "Building your
  site…", "Handing off to release…").

  `Sites.Deploy.fail/3` already rewrites it on its own terminal path
  (`detail: short_detail(reason)`). The two OTHER terminal writers do not:

    * `Registry.reap_stale_deployments/0` — four bare `Repo.update_all` passes
      that set `status: "failed"` + `failure_reason:` and never touch `detail`.
      `update_all` runs no changeset and no callback, so the row keeps whatever
      caption was last written. A `building` row reaped at the claim cap is
      therefore filed as a failure whose only human-readable text is "Building
      your site…", and a `pushing` row keeps "Handing off to release…". The two
      queued-row passes leave `detail` NULL — a failure that says nothing.

    * `Registry.create_failed_deployment/3` — a born-terminal row that stamps
      `failure_reason` only, so `detail` is NULL from birth.

  The epic measured both classes on the live control plane: 24 rows carrying a
  progress caption where a cause belongs, 7 carrying the empty string.

  These tests are scoped to their own fixture ids throughout — every assertion
  reads a row by the id this test created, never a table-wide query, so a peer
  agent's rows in the shared test database cannot colour the result.

  `async: true` is safe: every write is inside this test's Sandbox transaction.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Deployment

  ## Fixtures (mirror RegistryDeploymentReaperTest)

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp site_fixture(barkpark, attrs) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(barkpark, Map.merge(%{name: "S #{n}", slug: "s-#{n}"}, attrs))

    site
  end

  defp setup_site(attrs \\ %{}) do
    bp = team_fixture() |> barkpark_fixture()
    {bp, site_fixture(bp, attrs)}
  end

  defp backdate(deployment_id) do
    stale_at =
      DateTime.add(DateTime.utc_now(), -(Registry.deployment_stale_after_seconds() + 60), :second)
      |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(d in Deployment, where: d.id == ^deployment_id),
      set: [claimed_at: stale_at]
    )
  end

  defp pin_at_claim_budget(deployment_id) do
    Repo.update_all(
      from(d in Deployment, where: d.id == ^deployment_id),
      set: [claim_epoch: Registry.max_deploy_claims()]
    )
  end

  # The three captions the epic measured standing where a cause belongs. Any
  # `detail` on a FAILED row that is one of these is the defect, by definition.
  @progress_captions [
    "Fetching your source…",
    "Building your site…",
    "Handing off to release…"
  ]

  # The invariant, stated once and applied to every terminal row: a failed
  # deployment's `detail` is present, is not a progress caption, and agrees with
  # the `failure_reason` that names the cause.
  defp assert_detail_names_a_cause(%Deployment{} = row) do
    assert row.status == "failed"

    refute is_nil(row.detail),
           "a failed deployment's detail is NULL — the failure says nothing at all"

    refute String.trim(row.detail) == "",
           "a failed deployment's detail is blank — the failure says nothing at all"

    refute row.detail in @progress_captions,
           "a failed deployment's detail is the progress caption #{inspect(row.detail)} — " <>
             "a caption is not a cause"

    # The cause is the thing that was written, not merely SOMETHING. `detail` is
    # the clamped head of `failure_reason`, so the two can never disagree.
    assert String.starts_with?(row.failure_reason, String.trim_trailing(row.detail, "…")),
           "detail #{inspect(row.detail)} is not the head of failure_reason " <>
             "#{inspect(row.failure_reason)} — the caption and the cause have drifted"

    row
  end

  ## 1. Reaper pass (i): building → failed at the claim budget.
  ##    The row is carrying the builder's last progress caption.

  test "a stale building row reaped at the claim budget does not keep its progress caption" do
    {_bp, site} = setup_site()
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, claimed} = Registry.claim_next_deployment("builder-#{d.id}")
    assert claimed.status == "building"

    # The builder narrates, then dies. This is the last thing it wrote.
    {:ok, narrated} = Registry.set_deployment_detail(claimed.id, "Building your site…")
    assert narrated.detail == "Building your site…"

    pin_at_claim_budget(claimed.id)
    backdate(claimed.id)

    Registry.reap_stale_deployments()

    row = Repo.get(Deployment, claimed.id)
    assert row.failure_reason =~ "exceeded max deploy claim attempts"
    assert_detail_names_a_cause(row)
  end

  ## 2. Reaper pass (iii): pushing → failed at the claim budget.
  ##    Same defect one stage later, and the caption differs — so a fix that only
  ##    patched the building pass would still leave this row lying.

  test "a stale pushing row reaped at the claim budget does not keep its handoff caption" do
    {bp, site} = setup_site()
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, _} = Registry.transition_deployment(d, %{status: "pushing", image_tag: "img-1"})
    {:ok, claimed} = Registry.claim_pending_deployment_for_barkpark(bp, "agent-#{d.id}")

    {:ok, narrated} = Registry.set_deployment_detail(claimed.id, "Handing off to release…")
    assert narrated.detail == "Handing off to release…"

    pin_at_claim_budget(claimed.id)
    backdate(claimed.id)

    Registry.reap_stale_deployments()

    row = Repo.get(Deployment, claimed.id)
    assert row.failure_reason =~ "instance unreachable"
    assert_detail_names_a_cause(row)
  end

  ## 3. Reaper pass (0a): a container row with no build source is born un-buildable
  ##    and reaped straight out of `queued` — `detail` was never written at all.

  test "a container row failed for having no build source names the cause in detail" do
    {_bp, site} = setup_site(%{kind: "container"})
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})
    assert is_nil(Repo.get(Deployment, d.id).detail)

    Registry.reap_stale_deployments()

    row = Repo.get(Deployment, d.id)
    assert row.failure_reason =~ "no build source"
    assert_detail_names_a_cause(row)
  end

  ## 4. Reaper pass (0b): the static twin — no content binding, also reaped out of
  ##    `queued` with a NULL detail.

  test "a static row failed for having no content binding names the cause in detail" do
    {_bp, site} = setup_site(%{kind: "static", framework: "static"})
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})
    assert is_nil(Repo.get(Deployment, d.id).detail)

    Registry.reap_stale_deployments()

    row = Repo.get(Deployment, d.id)
    assert row.failure_reason =~ "no content binding"
    assert_detail_names_a_cause(row)
  end

  ## 5. `create_failed_deployment/3` — a row born terminal. There is no earlier
  ##    caption to inherit, so a NULL detail here is the pure blank class.

  test "a born-failed deployment carries its reason in detail, not a blank" do
    {_bp, site} = setup_site()
    reason = "no build source yet — connect the GitHub App or push with `bp deploy`"

    {:ok, failed} =
      Registry.create_failed_deployment(site, %{git_ref: "main"}, reason)

    row = Repo.get(Deployment, failed.id)
    assert row.failure_reason == reason
    assert_detail_names_a_cause(row)
  end

  ## 6. The clamp still holds. `detail` is the caption column and a reaper reason
  ##    plus a box's own words can run long; a terminal write that RAISED 22001
  ##    would lose the very failure it was recording. A born-failed row is the one
  ##    path whose reason is caller-supplied and unbounded.

  test "an over-long reason is clamped into detail rather than raising" do
    {_bp, site} = setup_site()
    reason = String.duplicate("x", 900)

    {:ok, failed} = Registry.create_failed_deployment(site, %{git_ref: "main"}, reason)

    row = Repo.get(Deployment, failed.id)
    # failure_reason is :text and holds the whole story, untruncated.
    assert row.failure_reason == reason
    assert String.length(row.detail) <= 255
    refute String.trim(row.detail) == ""
  end
end
