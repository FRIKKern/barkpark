defmodule Barkpark.Media.CdnSyncBlockTest do
  # async: false — mirrors cdn_test.exs: this module toggles the global
  # :media_cdn Application env, which Cdn reads straight from Application.get_env
  # (no test-scoped injection path), so concurrent tests would race the config.
  use ExUnit.Case, async: false

  alias Barkpark.Media.Delivery.Cdn
  alias Barkpark.Media.Storage.MediaFile

  # The stub's simulated round-trip. The old synchronous publish path blocked the
  # caller for ~this long; the async path returns in well under @return_budget_ms.
  @stub_delay_ms 2_000
  @return_budget_ms 500

  setup do
    original = Application.get_env(:barkpark, :media_cdn)

    # Restore by DELETING when the key was never set — put_env(..., nil) leaves a
    # literal nil that later crashes Cdn.base_url/0's Keyword.get (see cdn_test.exs).
    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, :media_cdn)
        val -> Application.put_env(:barkpark, :media_cdn, val)
      end
    end)

    :ok
  end

  test "publish returns promptly while the CDN edge purge fires in the background" do
    bypass = Bypass.open()
    test_pid = self()

    # A slow / hung third-party CDN: the purge endpoint sleeps before responding.
    # Capture the request into the test process (never assert inside the Bypass
    # handler — a raise there surfaces in the Cowboy process and races the test).
    Bypass.expect_once(bypass, "POST", "/purge", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Process.sleep(@stub_delay_ms)
      send(test_pid, {:purged, body})
      Plug.Conn.resp(conn, 204, "")
    end)

    Application.put_env(:barkpark, :media_cdn,
      base_url: "https://cdn.example.com",
      invalidation: [
        adapter: :http,
        url: "http://127.0.0.1:#{bypass.port}/purge",
        secret: "s"
      ]
    )

    file = %MediaFile{
      id: Ecto.UUID.generate(),
      path: "2026/05/pixel.png",
      mime_type: "image/png"
    }

    # doc: nil — the publish-path DB status patch is out of scope here; we measure
    # only the CDN round-trip's effect on the caller's wall-clock.
    {elapsed_us, result} = :timer.tc(fn -> Cdn.publish(file, nil) end)
    elapsed_ms = div(elapsed_us, 1000)

    assert result == :ok

    # FAIL-BEFORE: the old inline path blocked the caller for the full ~2s stub
    # round-trip (elapsed_ms ≈ @stub_delay_ms), tripping this bound. AFTER-FIX:
    # the purge is backgrounded on Barkpark.TaskSupervisor, so publish returns in
    # a few ms — comfortably under @return_budget_ms.
    assert elapsed_ms < @return_budget_ms,
           "expected Cdn.publish to return promptly (< #{@return_budget_ms}ms) once the " <>
             "purge is backgrounded, but it blocked #{elapsed_ms}ms — the ~#{@stub_delay_ms}ms " <>
             "stub round-trip is still running inline on the caller"

    # The purge is fire-and-forget, NOT dropped: the backgrounded task still
    # reaches the CDN. Give it the full stub delay plus slack to complete.
    assert_receive {:purged, body}, @stub_delay_ms + 2_000
    assert Jason.decode!(body)["paths"] != []

    # Let the backgrounded task finish READING the stub's 204 before this test's
    # on_exit stops Bypass. The {:purged, …} message is sent from the handler just
    # before it responds, so without this settle Bypass can be torn down while the
    # loopback response is still in flight — a benign but noisy GenServer.stop race
    # in Bypass's own teardown, not a defect in the code under test.
    Process.sleep(150)
  end
end
