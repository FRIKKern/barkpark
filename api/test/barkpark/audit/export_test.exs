defmodule Barkpark.Audit.ExportTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Audit
  alias Barkpark.Audit.{Export, ExportSink}
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

  defp emit!(ws),
    do: {:ok, _} = Audit.emit(%{category: "auth", action: "login_succeeded", workspace_id: ws})

  describe "flush_sink/1 — tail shipping" do
    test "ships new events, advances the cursor, and stops when nothing is new" do
      emit!(@ws)
      emit!(@ws)
      {:ok, sink} = Export.create_sink(%{name: "s1", url: "https://siem.example.com/in"})

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
      emit!(@ws)
      emit!(@ws_b)
      emit!(@ws)

      {:ok, scoped} =
        Export.create_sink(%{name: "scoped", url: "https://a.example.com", workspace_id: @ws})

      {:ok, global} = Export.create_sink(%{name: "global", url: "https://b.example.com"})

      assert {:ok, {:shipped, 2}} = Export.flush_sink(scoped)
      assert {:ok, {:shipped, 3}} = Export.flush_sink(global)

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

  describe "flush/0" do
    test "is a no-op with no active sinks" do
      emit!(@ws)
      assert Export.flush() == []
      assert FakeHTTP.calls() == []
    end
  end

  describe "format_event/2 — stable schema" do
    test "renders the documented shape" do
      emit!(@ws)
      [event] = Repo.all(Barkpark.Audit.Event)
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
