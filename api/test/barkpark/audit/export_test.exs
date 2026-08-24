defmodule Barkpark.Audit.ExportTest do
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Audit
  alias Barkpark.Audit.{Event, Export, ExportSink}
  alias Barkpark.Repo

  @ws Ecto.UUID.generate()
  @ws_b Ecto.UUID.generate()

  # A swappable HTTP adapter that records calls and can be told to fail.
  defmodule FakeHTTP do
    @name __MODULE__

    def start(fail? \\ false) do
      case Process.whereis(@name) do
        nil -> {:ok, _} = Agent.start_link(fn -> %{calls: [], fail?: fail?} end, name: @name)
        _ -> Agent.update(@name, fn _ -> %{calls: [], fail?: fail?} end)
      end

      :ok
    end

    def calls, do: Agent.get(@name, & &1.calls) |> Enum.reverse()

    def post(url, body, headers) do
      Agent.update(@name, fn s -> %{s | calls: [{url, body, headers} | s.calls]} end)
      if Agent.get(@name, & &1.fail?), do: {:error, :boom}, else: {:ok, 200, []}
    end
  end

  setup do
    prev = Application.get_env(:barkpark, :webhook_http_adapter)
    FakeHTTP.start()
    Application.put_env(:barkpark, :webhook_http_adapter, FakeHTTP)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:barkpark, :webhook_http_adapter)
        v -> Application.put_env(:barkpark, :webhook_http_adapter, v)
      end
    end)

    :ok
  end

  defp emit!(ws) do
    {:ok, event} =
      Audit.emit(%{category: "auth", action: "login_succeeded", workspace_id: ws})

    event
  end

  defp start_at_tail(sink, last_event_id) do
    Repo.update!(Ecto.Changeset.change(sink, last_exported_id: last_event_id))
  end

  describe "flush_sink/1 — tail shipping" do
    test "ships new events, advances the cursor, and stops when nothing is new" do
      last_event_id = Repo.aggregate(Event, :max, :id) || 0

      {:ok, sink} =
        Export.create_sink(%{
          name: "s1",
          url: "https://siem.example.com/in",
          workspace_id: @ws
        })

      sink = start_at_tail(sink, last_event_id)
      emit!(@ws)
      emit!(@ws)

      assert {:ok, {:shipped, 2}} = Export.flush_sink(sink)
      assert length(FakeHTTP.calls()) == 1
      sink = Repo.get(ExportSink, sink.id)
      assert sink.last_exported_id > 0

      # nothing new → no HTTP
      assert {:ok, :nothing_new} = Export.flush_sink(sink)
      assert length(FakeHTTP.calls()) == 1

      # a new event flushes again
      emit!(@ws)
      assert {:ok, {:shipped, 1}} = Export.flush_sink(Repo.get(ExportSink, sink.id))
      assert length(FakeHTTP.calls()) == 2
    end

    test "a workspace-scoped sink ships only its workspace's events; global ships all" do
      last_event_id = Repo.aggregate(Event, :max, :id) || 0

      {:ok, scoped} =
        Export.create_sink(%{name: "scoped", url: "https://a.example.com", workspace_id: @ws})

      {:ok, global} = Export.create_sink(%{name: "global", url: "https://b.example.com"})
      scoped = start_at_tail(scoped, last_event_id)
      global = start_at_tail(global, last_event_id)
      owned_events = [emit!(@ws), emit!(@ws_b), emit!(@ws)]

      assert {:ok, {:shipped, 2}} = Export.flush_sink(scoped)

      # Audit events are process-global and valid non-sandboxed producers may
      # append while this test runs. A global sink must include every event we
      # own; it does not promise that our three fixtures are the whole batch.
      assert {:ok, {:shipped, shipped}} = Export.flush_sink(global)
      assert shipped >= length(owned_events)

      {_url, body, _headers} = List.last(FakeHTTP.calls())
      shipped_ids = body |> Jason.decode!() |> get_in(["events", Access.all(), "id"])
      assert Enum.all?(owned_events, &(&1.id in shipped_ids))

      # scoped cursor still advanced past ALL examined events (so it won't re-ship)
      assert {:ok, :nothing_new} = Export.flush_sink(Repo.get(ExportSink, scoped.id))
    end

    test "signs the body with an HMAC header when a secret is set" do
      emit!(@ws)

      {:ok, sink} =
        Export.create_sink(%{name: "signed", url: "https://s.example.com", secret: "shh"})

      {:ok, _} = Export.flush_sink(sink)
      [{_url, _body, headers}] = FakeHTTP.calls()
      assert Enum.any?(headers, fn {k, v} -> k == "x-barkpark-signature" and v =~ "v1=" end)
    end
  end

  describe "auto-disable" do
    test "a failing sink increments failures and auto-disables at the threshold" do
      emit!(@ws)
      FakeHTTP.start(true)
      Application.put_env(:barkpark, :webhook_http_adapter, FakeHTTP)
      {:ok, sink} = Export.create_sink(%{name: "flaky", url: "https://down.example.com"})

      # flush repeatedly — the cursor never advances on failure, so the same
      # event re-fails and the streak climbs.
      for _ <- 1..15 do
        Export.flush_sink(Repo.get(ExportSink, sink.id))
      end

      disabled = Repo.get(ExportSink, sink.id)
      assert disabled.active == false
      assert disabled.consecutive_failures >= 15
      assert disabled.auto_disabled_at
    end
  end

  # -- The latch has an EXIT -------------------------------------------------
  #
  # Before this suite, `active` had exactly two writers -- the INSERT default and
  # the auto-disable -- so a 15-minute receiver outage ended a customer's audit
  # trail ingestion PERMANENTLY and SILENTLY. These tests pin both halves of the
  # remedy: the latch is loud exactly once, and it opens again by itself.

  # Drive a sink all the way to auto-disabled. Returns the reloaded row.
  defp latch!(name \\ "latchy") do
    emit!(@ws)
    FakeHTTP.start(true)
    Application.put_env(:barkpark, :webhook_http_adapter, FakeHTTP)
    {:ok, sink} = Export.create_sink(%{name: name, url: "https://down.example.com"})

    for _ <- 1..15, do: Export.flush_sink(Repo.get(ExportSink, sink.id))

    disabled = Repo.get(ExportSink, sink.id)
    assert disabled.active == false, "fixture failed to latch the sink"
    disabled
  end

  # Pretend the cooldown already elapsed by backdating the latch stamp.
  defp backdate(sink, seconds) do
    Repo.update!(
      Ecto.Changeset.change(sink,
        auto_disabled_at: DateTime.add(DateTime.utc_now(), -seconds, :second)
      )
    )
  end

  describe "half-open retry -- the automatic exit" do
    test "an auto-disabled sink is excluded until its cooldown elapses, then probed again" do
      sink = latch!("cooldown")

      # Still inside the cooldown: the flusher must NOT touch it.
      refute Enum.any?(Export.list_flush_candidates(), &(&1.id == sink.id))
      assert Export.flush() == []

      # Cooldown elapsed -> it rejoins the candidate set as a half-open probe.
      sink = backdate(sink, 3600)
      assert Enum.any?(Export.list_flush_candidates(), &(&1.id == sink.id))
    end

    test "a successful probe re-enables the sink and events flow again" do
      sink = latch!("recovers")

      # The receiver comes back up. `FakeHTTP.start/1` also RESETS the call log,
      # so every call counted below belongs to the recovery, not the outage.
      FakeHTTP.start(false)
      Application.put_env(:barkpark, :webhook_http_adapter, FakeHTTP)
      backdate(sink, 3600)

      # The ordinary once-a-minute tick -- no human verb anywhere -- heals it.
      assert [{:ok, {:shipped, n}}] = Export.flush()
      assert n >= 1

      healed = Repo.get(ExportSink, sink.id)
      assert healed.active == true, "the latch has no automatic exit"
      assert healed.consecutive_failures == 0
      assert healed.auto_disabled_at == nil
      assert healed.disable_reason == nil
      assert healed.last_exported_id > sink.last_exported_id

      # Events genuinely reached the SIEM, not just a flag flip.
      assert [{url, _body, _headers}] = FakeHTTP.calls()
      assert url == "https://down.example.com"

      # And it keeps shipping on subsequent ticks.
      emit!(@ws)
      assert [{:ok, {:shipped, again}}] = Export.flush()
      assert again >= 1
    end

    test "a failed probe backs off instead of retrying every tick" do
      sink = latch!("backoff")
      sink = backdate(sink, 3600)

      assert [{:error, _}] = Export.flush()

      after_probe = Repo.get(ExportSink, sink.id)
      assert after_probe.active == false
      # The streak grew AND the cooldown clock restarted...
      assert after_probe.consecutive_failures > sink.consecutive_failures
      assert DateTime.compare(after_probe.auto_disabled_at, sink.auto_disabled_at) == :gt
      # ...so the very next tick does not probe again.
      assert Export.flush() == []
    end
  end

  describe "the disabled interval leaves a person-facing trace" do
    test "the auto-disable logs a stable code exactly ONCE per latch, not once per failure" do
      emit!(@ws)
      FakeHTTP.start(true)
      Application.put_env(:barkpark, :webhook_http_adapter, FakeHTTP)
      {:ok, sink} = Export.create_sink(%{name: "loud", url: "https://down.example.com"})

      log =
        capture_log(fn ->
          # 20 failing flushes -- 5 of them past the threshold.
          for _ <- 1..20, do: Export.flush_sink(Repo.get(ExportSink, sink.id))
        end)

      assert log =~ "audit_export_sink_auto_disabled",
             "the SIEM went dark with no operator-visible signal"

      # One line per DARK INTERVAL. The 5 post-threshold failures must not each
      # re-announce the latch, or the signal drowns in its own repetition.
      latch_errors =
        for line <- String.split(log, "\n"),
            line =~ "[error]",
            line =~ "audit_export_sink_auto_disabled",
            do: line

      assert length(latch_errors) == 1

      assert Repo.get(ExportSink, sink.id).disable_reason =~ "auto-disabled after"
    end

    test "the recovery is announced too, so the incident can be closed" do
      sink = latch!("announced")
      FakeHTTP.start(false)
      Application.put_env(:barkpark, :webhook_http_adapter, FakeHTTP)
      backdate(sink, 3600)

      log = capture_log(fn -> Export.flush() end)
      assert log =~ "audit_export_sink_recovered"
    end

    test "sink_health/1 renders the dark sink as queryable status" do
      sink = latch!("visible")

      health = Enum.find(Export.sink_health(), &(&1.id == sink.id))

      assert health.status == :auto_disabled
      assert health.disable_reason =~ "auto-disabled after"
      assert health.consecutive_failures >= 15
      assert is_integer(health.dark_for_seconds)
      assert %DateTime{} = health.next_retry_at

      {:ok, _} = Export.reenable_sink(Repo.get(ExportSink, sink.id))
      assert Enum.find(Export.sink_health(), &(&1.id == sink.id)).status == :healthy
    end
  end

  describe "reenable_sink/1 -- the manual exit" do
    test "restores a latched sink to a clean shippable state and events flow again" do
      sink = latch!("manual")

      {:ok, cleared} = Export.reenable_sink(sink)

      assert cleared.active == true
      assert cleared.consecutive_failures == 0
      assert cleared.auto_disabled_at == nil
      assert cleared.disable_reason == nil

      FakeHTTP.start(false)
      Application.put_env(:barkpark, :webhook_http_adapter, FakeHTTP)
      emit!(@ws)
      assert [{:ok, {:shipped, _}}] = Export.flush()
    end

    test "is idempotent on an already-active sink and clears an in-progress streak" do
      emit!(@ws)
      FakeHTTP.start(true)
      Application.put_env(:barkpark, :webhook_http_adapter, FakeHTTP)
      {:ok, sink} = Export.create_sink(%{name: "streaky", url: "https://down.example.com"})

      for _ <- 1..3, do: Export.flush_sink(Repo.get(ExportSink, sink.id))
      assert Repo.get(ExportSink, sink.id).consecutive_failures == 3

      {:ok, cleared} = Export.reenable_sink(Repo.get(ExportSink, sink.id))
      assert cleared.active == true
      assert cleared.consecutive_failures == 0
    end
  end

  describe "candidate selection" do
    test "a sink a PERSON disabled is never probed -- only the automatic latch auto-exits" do
      {:ok, sink} =
        Export.create_sink(%{name: "off", url: "https://off.example.com", active: false})

      assert sink.active == false
      assert sink.auto_disabled_at == nil

      refute Enum.any?(Export.list_flush_candidates(), &(&1.id == sink.id))

      # Even long after any conceivable cooldown.
      future = DateTime.add(DateTime.utc_now(), 86_400, :second)
      refute Enum.any?(Export.list_flush_candidates(future), &(&1.id == sink.id))
    end
  end

  describe "flush/0" do
    test "is a no-op with no active sinks" do
      emit!(@ws)
      assert Export.flush() == []
      assert FakeHTTP.calls() == []
    end
  end

  describe "format_event/2 — stable schema" do
    test "renders the documented shape" do
      event = emit!(@ws)
      shape = Export.format_event(event, "generic")

      assert %{
               id: _,
               category: "auth",
               action: "login_succeeded",
               actor: %{type: _, id: _},
               workspace_id: @ws,
               hash: _,
               metadata: _
             } = shape
    end
  end
end
