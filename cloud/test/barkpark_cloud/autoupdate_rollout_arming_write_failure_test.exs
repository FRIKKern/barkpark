defmodule BarkparkCloud.AutoupdateRolloutArmingWriteFailureTest do
  @moduledoc """
  task-a207d875e61a2e02, residue 2 — the 503 branch's FALLBACK PAUSE.

  `AutoupdateRolloutWorker` answers a 503 from the self-update trigger with
  `Registry.record_apply_unarmed/1` (#13474). If that write fails, the code used
  to fall back to `Registry.pause_autoupdate/1` — and that is the one remaining
  place in the worker where the latch could still walk the WHOLE fleet: the 503
  branch never stamps `autoupdate_triggered_at`, so the serial-of-1 in-flight
  gate never slowed it. One box latched per 5-minute tick, for as long as the
  write kept failing, into a flag whose only `false` writer anywhere is the human
  PATCH on `/v1/barkparks/:id/autoupdate`.

  That is the exact shape #13474 removed from the line above it, surviving in the
  error arm.

  Under the worker's own call site the arming write cannot actually fail today
  (two hardcoded valid values through `Barkpark.update_status_changeset/2`), so
  this is a guard against a future validation change and against every DB-level
  reason a write fails — the same posture as `billing_reconcile_isolation_test`.
  To exercise it for real, this swaps in a fake registry via the `:registry`
  test-only config key `AutoupdateRolloutWorker.registry/0` reads, mirroring the
  `Billing.registry/0` seam.

  THE COUNT IS THE POINT. Three eligible boxes, three ticks, a write that fails
  every time: the old fallback paused one box per tick and left three boxes
  needing a human. The assertion is ZERO.
  """
  # async: false — the config swap below is ONE value for the whole node.
  # Ratchet: scripts/async_env_seam_scan.exs.
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, Vault}
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Workers.AutoupdateRolloutWorker

  @admin_token "instance-admin-token-plaintext"

  defmodule FailingArmingRegistry do
    @moduledoc """
    Delegates every call to the REAL `Registry` except `record_apply_unarmed/1`,
    which returns a genuine `{:error, %Ecto.Changeset{}}` without touching the DB
    — standing in for a persistent write failure on the arming columns.

    Scoped via the CALLING PROCESS's dictionary (not a global flag) so a process
    that never opted in always delegates, even while this module is configured.
    """
    def record_apply_unarmed(%Barkpark{} = bp) do
      if Process.get(:autoupdate_arming_write_always_fails) do
        {:error,
         bp
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:apply_arming, "forced failure for fleet-walk test")}
      else
        Registry.record_apply_unarmed(bp)
      end
    end
  end

  setup do
    previous = Application.get_env(:barkpark_cloud, AutoupdateRolloutWorker, [])

    Application.put_env(
      :barkpark_cloud,
      AutoupdateRolloutWorker,
      Keyword.put(previous, :registry, FailingArmingRegistry)
    )

    Process.put(:autoupdate_arming_write_always_fails, true)

    on_exit(fn ->
      Application.put_env(:barkpark_cloud, AutoupdateRolloutWorker, previous)
    end)

    :ok
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # A live, eligible, `behind` box. `checked_at` fixes the candidate ORDER
  # (`next_autoupdate_candidate/1` is `order_by: update_checked_at` ascending), so
  # the walk below is deterministic rather than insertion-ordered.
  defp live_behind(checked_at) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team_fixture(), %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(%{
      host: "203.0.113.#{rem(n, 250) + 1}",
      url: "https://bp-#{n}.barkpark.cloud",
      admin_token_encrypted: Vault.encrypt(@admin_token),
      update_state: "behind",
      update_checked_at: checked_at,
      autoupdate_enabled: true,
      autoupdate_paused: false
    })
    |> Repo.update!()
  end

  test "a persistent arming-write failure pauses NOTHING, however many ticks run" do
    base = DateTime.utc_now()
    boxes = for i <- 1..3, do: live_behind(DateTime.add(base, -60 * i, :second))

    # Every tick: the trigger POST draws the box's 503 `feature_not_configured`,
    # and the arming write that should absorb it fails.
    for _ <- 1..3 do
      StudioLinkFakeHttpClient.program([{:ok, %{status: 503, body: ~s({"error":{}})}}])
      AutoupdateRolloutWorker.perform(%Oban.Job{})
    end

    paused = Enum.count(boxes, &Registry.get_barkpark(&1.id).autoupdate_paused)

    assert paused == 0,
           "the fallback pause walked the fleet: a control-plane write failure must " <>
             "never latch a customer's box into a state only a human PATCH can leave " <>
             "(old behaviour paused one box per tick, so this read 3)"

    refute Enum.any?(boxes, &Registry.get_barkpark(&1.id).autoupdate_triggered_at),
           "a 503 never started a run, so nothing may be marked in flight"
  end

  test "the fallback could not have worked anyway: the pause writes the same row" do
    # WHY THE BRANCH IS DELETED RATHER THAN REPAIRED. `record_apply_unarmed/1` and
    # `pause_autoupdate/1` both write the SAME `barkparks` row through the SAME
    # `Repo.update/1` — the first two columns via `update_status_changeset/2`, the
    # second one via `autoupdate_changeset/2` in `set_autoupdate/2`. Any DB-level
    # reason the arming write fails (dead pool, read-only replica, lock timeout)
    # fails the pause identically, so the fallback bought containment in no world
    # it can actually reach while creating the fleet-walk in every world it can.
    bp = live_behind(DateTime.utc_now())

    assert {:error, %Ecto.Changeset{}} = FailingArmingRegistry.record_apply_unarmed(bp)

    # The real writer, on the same row, is a plain Repo.update — nothing about the
    # arming failure is specific to those columns.
    assert {:ok, %Barkpark{}} = Registry.pause_autoupdate(bp)

    # Restore, so this case leaves no latched row behind for a reader to puzzle over.
    {:ok, _} = Registry.set_autoupdate(Registry.get_barkpark(bp.id), %{autoupdate_paused: false})
  end
end
