defmodule BarkparkCloud.Notifications.DigestRunDurabilityTest do
  @moduledoc """
  dr-w27 — THE COUNTED LOSS MUST OUTLIVE THE CONTAINER THAT COUNTED IT.

  ## The defect

  dr-w18-s3 gave `deliver_fleet_digest/1` a counted loss so it could not succeed
  at sending nothing unobserved. The count was correct and its SINK was a
  `Logger` line — nothing else. The control plane is a docker container on the
  `json-file` log driver, and `deploy/cp-deploy.sh`'s `compose_up_repair`
  recreates it on any image or config change; json-file state lives under
  `/var/lib/docker/containers/<id>/` and is deleted with the container.

  Measured 2026-08-09: the digest DID deliver at 06:00Z — four
  `notification_deliveries` rows survived to prove it — and the accounting grep
  the code told an operator to run returned ZERO lines, over every container on
  the host, because a recreate at 07:31/07:33 had taken the logs. The rows lived;
  the accounting did not. The read affordance the code named
  (`journalctl -u barkpark-cloud`) was fictional on top of that: no such systemd
  unit has ever existed on that box.

  ## What "survives a recreate" means IN A TEST, stated rather than mimed

  No Elixir test can destroy a container. What it can do is pin WHICH SINK the
  accounting lands in, because that is the whole difference between the two
  outcomes above: the delivery rows survived precisely by being rows in
  `cloud-db-1`'s volume-backed Postgres, and the log line died precisely by being
  container-local state. So §1 asserts the record is readable back OUT OF
  POSTGRES — by a context function AND by raw SQL against `digest_runs`, which is
  a statement about storage and not about any in-memory value. A record in that
  database is in the same place the 2026-08-09 delivery rows were when the
  container was destroyed around them.

  §3 is the other half and it is the one that would have caught the original
  defect: it proves the Logger line ALONE is not the record, by keeping the
  record readable with the log discarded entirely.
  """
  use BarkparkCloud.DataCase, async: false

  import ExUnit.CaptureLog

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.Notifications.DigestRun
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Repo

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "correct horse staple"})
    u
  end

  defp team(user) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    team
  end

  defp instance(team, name, slug, attrs) do
    {:ok, bp} = Registry.register_barkpark(team, %{name: name, slug: slug})

    bp
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp swap_mailer_adapter(adapter) do
    prior = Application.get_env(:barkpark_cloud, BarkparkCloud.Mailer, [])

    Application.put_env(
      :barkpark_cloud,
      BarkparkCloud.Mailer,
      Keyword.put(prior, :adapter, adapter)
    )

    on_exit(fn -> Application.put_env(:barkpark_cloud, BarkparkCloud.Mailer, prior) end)
  end

  # Refuses every recipient whose local part starts with "fail" and hands the
  # rest to the ordinary Test adapter — the same shape
  # `daily_digest_worker_test.exs` uses for its partial-send arm.
  defmodule HalfDeadAdapter do
    use Swoosh.Adapter

    @impl true
    def deliver(%Swoosh.Email{to: [{_name, address} | _]} = email, config) do
      if String.starts_with?(address, "fail") do
        {:error, {:temporary_failure, "450 4.2.1 mailbox busy"}}
      else
        Swoosh.Adapters.Test.deliver(email, config)
      end
    end
  end

  ## 1. A REAL send writes a DURABLE accounting record, readable through a real
  ##    read path.

  test "deliver_fleet_digest/1 writes a digest_runs ROW with the same measurements as the log line" do
    # `config/test.exs` pins the logger at :warning, and a WON run logs at INFO.
    prior_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prior_level) end)

    n = System.unique_integer([:positive])
    owner = user("op-#{n}@example.com")
    t = team(owner)
    bp = instance(t, "Prod", "prod-#{n}", %{update_state: "behind"})

    log =
      capture_log(fn ->
        assert {:ok, %{sent: 1, recipients: [_]}} = Notifications.deliver_fleet_digest([bp])
      end)

    # The log line is still emitted — the row REPLACES nothing, it outlives it.
    assert log =~ "fleet_digest phase=settled recipients=1 sent=1"

    # THE READ PATH. A context function, not a hand-rolled query: the affordance
    # a stranger is pointed at has to be the one that is tested.
    assert [run] = Notifications.list_digest_runs()
    assert run.event == "fleet_digest"
    assert run.phase == "settled"
    assert run.recipients == 1
    assert run.sent == 1
    assert run.instances == 1
    assert run.covered == 1
    assert run.reason == nil
    refute DigestRun.lost?(run)

    # AND IT IS IN POSTGRES, which is the entire durability claim. The 2026-08-09
    # delivery rows survived the 07:31 container recreate by living exactly here;
    # the log line describing them did not, by living in the container's
    # json-file state. Raw SQL rather than the schema, so what passes is a
    # statement about the TABLE and not about an in-memory struct.
    assert %{rows: [[recipients, sent, instances, covered]]} =
             Repo.query!(
               "SELECT recipients, sent, instances, covered FROM digest_runs WHERE event = $1",
               ["fleet_digest"]
             )

    assert [recipients, sent, instances, covered] == [1, 1, 1, 1]
  end

  ## 2. SUPPRESSED DELIVERY — the loss is still on the durable record.
  ##
  ##    Two suppressions, because they lose in different directions and the
  ##    original defect was invisible on both: nobody was mailable at all, and
  ##    somebody was mailable and the transport refused them.

  test "a zero-recipient digest leaves a durable LOSS row, where the receipts table cannot" do
    _registered = user("bystander-#{System.unique_integer([:positive])}@example.com")

    log =
      capture_log(fn ->
        assert {:ok, :no_admins} = Notifications.deliver_fleet_digest([])
      end)

    assert log =~ "[warning]"

    assert [run] = Notifications.list_digest_runs()
    assert run.recipients == 0
    assert run.sent == 0
    assert run.reason == "no_team_recipients"

    # `Withhold.record/4`'s consented zero, carried onto the row. NOT nil: the
    # column's NULL means "this branch never funnelled through the withhold
    # vocabulary", and this branch did.
    assert run.withheld == 0
    assert DigestRun.lost?(run)

    # WHY THIS TABLE HAD TO EXIST. The receipts log cannot show this run at all:
    # `Delivery.changeset/2` requires a recipient and charter D362 forbids
    # inventing one, so a digest that mailed nobody produces no receipt. Before
    # this row, the only trace of the worst outcome the digest has was a log line
    # in a container a deploy deletes.
    assert Notifications.list_fleet_deliveries() == []
    assert Repo.all(Delivery) == []
  end

  test "a partial send leaves a durable LOSS row: sent=1 of recipients=2" do
    n = System.unique_integer([:positive])
    good = user("op-good-#{n}@example.com")
    bad = user("fail-op-#{n}@example.com")
    t = team(good)
    {:ok, _} = Accounts.add_member(t, bad, "admin")
    bp = instance(t, "Prod", "prod-#{n}", %{update_state: "behind"})

    swap_mailer_adapter(HalfDeadAdapter)

    capture_log(fn ->
      assert {:ok, %{sent: 1, recipients: recipients}} = Notifications.deliver_fleet_digest([bp])
      assert length(recipients) == 2
    end)

    assert [run] = Notifications.list_digest_runs()
    assert run.recipients == 2
    assert run.sent == 1
    assert run.reason == "partial_send"
    assert DigestRun.lost?(run)

    # The counter on the row disagrees with the recipient count — the assertion a
    # record that stored `sent = length(recipients)` could not satisfy.
    assert run.sent < run.recipients
  end

  ## 3. THE RECORD IS NOT THE LOG.
  ##
  ##    This is the arm that would have caught dr-w18-s3's sink. Discard the
  ##    Logger output entirely — the state of affairs after a container recreate,
  ##    for every purpose an operator has — and ask the question again. Before
  ##    this slice the answer was nothing at all.

  test "with the log discarded, the loss is still answerable through the durable record" do
    prior_level = Logger.level()
    Logger.configure(level: :none)
    on_exit(fn -> Logger.configure(level: prior_level) end)

    assert {:ok, :no_admins} = Notifications.deliver_fleet_digest([])

    assert [run] = Notifications.list_digest_runs()
    assert DigestRun.lost?(run)
    assert run.recipients == 0
    assert run.reason == "no_team_recipients"
  end

  ## 4. Accounting NEVER breaks the send it is counting.

  test "an unwritable accounting row loses the record, never the digest" do
    n = System.unique_integer([:positive])
    owner = user("op-safe-#{n}@example.com")
    t = team(owner)
    bp = instance(t, "Prod", "prod-#{n}", %{update_state: "behind"})

    # Drop the table under the writer. `safely/1` must swallow the insert
    # failure: this is a best-effort operator email and the accounting is a side
    # path on it.
    Repo.query!("DROP TABLE digest_runs")

    capture_log(fn ->
      assert {:ok, %{sent: 1}} = Notifications.deliver_fleet_digest([bp])
    end)
  end
end
