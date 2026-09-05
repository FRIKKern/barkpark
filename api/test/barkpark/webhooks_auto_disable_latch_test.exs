defmodule Barkpark.WebhooksAutoDisableLatchTest do
  @moduledoc """
  The webhook auto-disable latch used to be a SILENT, one-way stop: an endpoint
  crossed the consecutive-failure threshold, dropped out of `active_webhooks_for/4`,
  and the only witness was a `disable_reason` column nobody reads. A tenant's cache
  revalidation and downstream syncs stopped with no log line, no audit row, and no
  way back except a person noticing and clicking re-enable.

  These tests pin BOTH halves of the fix: the latch now ANNOUNCES itself exactly
  once at the threshold crossing, and it has an automatic exit (a rate-limited
  half-open probe) so a recovered receiver resumes without human action.
  """
  # async: false — these tests set the app-wide auto-disable threshold.
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Audit.Event
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Webhook

  @threshold 2

  setup do
    prev = Application.get_env(:barkpark, :webhook_auto_disable_threshold)
    Application.put_env(:barkpark, :webhook_auto_disable_threshold, @threshold)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:barkpark, :webhook_auto_disable_threshold),
        else: Application.put_env(:barkpark, :webhook_auto_disable_threshold, prev)
    end)

    :ok
  end

  defp hook(name \\ "Latch") do
    {:ok, wh} =
      Webhooks.create_webhook(%{
        "name" => name,
        "url" => "http://example.com/hook",
        "dataset" => "latchds",
        "events" => [],
        "types" => []
      })

    wh
  end

  defp reload(%Webhook{id: id}), do: Repo.get!(Webhook, id)

  # Drive the streak past the threshold the way the dispatcher does. Returns the
  # captured log so a test can assert on the latch's own announcement (and so
  # the tests that do NOT care about it stay quiet).
  defp latch(%Webhook{id: id}) do
    capture_log([level: :info], fn ->
      Enum.each(1..@threshold, fn _ -> Webhooks.record_endpoint_failure(id, "http 500") end)
    end)
  end

  # Rewind `auto_disabled_at` so the row's cooldown has demonstrably elapsed.
  defp age_by(%Webhook{id: id}, seconds) do
    from(w in Webhook, where: w.id == ^id)
    |> Repo.update_all(
      set: [
        auto_disabled_at:
          DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)
      ]
    )
  end

  defp latch_events(%Webhook{id: id}, action) do
    Repo.all(from(e in Event, where: e.subject == ^id and e.action == ^action))
  end

  defp candidates(dataset \\ "latchds"),
    do: Webhooks.active_webhooks_for(dataset, "create", "post") |> Enum.map(& &1.id)

  describe "the latch announces itself" do
    test "auto-disable emits a greppable log line AND a durable audit row" do
      wh = hook()

      log = latch(wh)

      assert log =~ "webhook_endpoint_auto_disabled",
             "the stop must reach an operator through a greppable code, not only a column"

      assert log =~ wh.id
      assert reload(wh).active == false

      events = latch_events(wh, "webhook_auto_disabled")

      assert length(events) == 1,
             "the stop must leave a durable RECORD, not just a log line that ages out"

      [event] = events

      assert event.category == "plugin_settings"
      assert event.metadata["consecutive_failures"] == @threshold
      assert event.metadata["dataset"] == "latchds"
      # Field hygiene: the signing secret never reaches the audit trail.
      refute Map.has_key?(event.metadata, "secret")
    end

    test "the signal fires ONCE at the crossing, not on every subsequent failure" do
      wh = hook()
      latch(wh)
      assert length(latch_events(wh, "webhook_auto_disabled")) == 1

      # Ten more terminal give-ups against the already-dark endpoint.
      Enum.each(1..10, fn _ -> Webhooks.record_endpoint_failure(wh.id, "http 500") end)

      assert length(latch_events(wh, "webhook_auto_disabled")) == 1,
             "a per-failure alert is noise; one line per dark interval is the signal"
    end
  end

  describe "the latch has an automatic exit" do
    test "a disabled endpoint is excluded until its cooldown elapses, then probed" do
      wh = hook()
      latch(wh)

      refute wh.id in candidates(),
             "a freshly-latched endpoint must not be probed immediately"

      age_by(wh, 120)

      assert wh.id in candidates(),
             "after the cooldown the endpoint rejoins the candidate set for ONE probe"
    end

    test "a successful probe re-enables the endpoint with no human action" do
      wh = hook()
      latch(wh)
      age_by(wh, 120)
      assert wh.id in candidates()

      # The probe delivers successfully — the dispatcher's success choke point.
      log = capture_log([level: :info], fn -> Webhooks.reset_endpoint_failures(wh.id) end)

      recovered = reload(wh)
      assert recovered.active == true, "a recovered receiver must resume on its own"
      assert recovered.consecutive_failures == 0
      assert recovered.auto_disabled_at == nil
      assert recovered.disable_reason == nil
      assert log =~ "webhook_endpoint_recovered"
      assert [_] = latch_events(wh, "webhook_auto_reenabled")
    end

    test "an endpoint a PERSON disabled is never probed" do
      wh = hook()
      {:ok, off} = Webhooks.update_webhook(wh, %{"active" => false})
      assert off.auto_disabled_at == nil

      age_by(wh, 100_000)
      # age_by only writes auto_disabled_at; re-assert the person-disabled shape.
      from(w in Webhook, where: w.id == ^wh.id)
      |> Repo.update_all(set: [auto_disabled_at: nil])

      refute wh.id in candidates(),
             "only the AUTOMATIC latch gets an automatic exit — a probe must never " <>
               "resurrect an endpoint an operator deliberately turned off"
    end
  end

  describe "the probe cannot become a retry storm" do
    test "a failed probe pushes the cooldown forward and backs off" do
      wh = hook()
      latch(wh)
      age_by(wh, 120)
      assert wh.id in candidates()

      before = reload(wh).auto_disabled_at

      # The probe fails: the dispatcher records another terminal give-up.
      Webhooks.record_endpoint_failure(wh.id, "http 500")

      after_probe = reload(wh)

      assert DateTime.compare(after_probe.auto_disabled_at, before) == :gt,
             "without re-stamping, every subsequent event is 'due' and the probe " <>
               "degenerates into the storm the latch exists to prevent"

      refute wh.id in candidates(),
             "the endpoint must drop back out of the candidate set immediately"
    end

    test "the cooldown grows with the number of failed probes" do
      wh = hook()
      latch(wh)
      first = Webhooks.next_probe_at(reload(wh))

      # Two more failed probes past the threshold.
      Webhooks.record_endpoint_failure(wh.id, "http 500")
      Webhooks.record_endpoint_failure(wh.id, "http 500")
      later = reload(wh)

      first_gap = DateTime.diff(first, Repo.get!(Webhook, wh.id).auto_disabled_at, :second)
      later_gap = DateTime.diff(Webhooks.next_probe_at(later), later.auto_disabled_at, :second)

      assert later_gap > first_gap,
             "a receiver down for a week must be probed ~24x/day, not on every event"
    end
  end
end
