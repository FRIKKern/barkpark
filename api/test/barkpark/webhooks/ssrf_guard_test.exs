defmodule Barkpark.Webhooks.SsrfGuardTest do
  @moduledoc """
  Adapter-level SSRF guard behaviour: the real `Dispatcher.ReqAdapter` (and the
  full `deliver/3` terminal-failure wiring) refuse internal targets with no
  network call, and `redirect: false` is enforced so a 302-to-internal is not
  followed.
  """
  use Barkpark.DataCase, async: false
  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Dispatcher
  alias Barkpark.Webhooks.Dispatcher.ReqAdapter

  setup do
    prev_flag = Application.get_env(:barkpark, :allow_private_outbound)
    prev_adapter = Application.get_env(:barkpark, :webhook_http_adapter)
    # Force the real ReqAdapter (some sibling test may have swapped it) so the
    # guard actually runs.
    Application.delete_env(:barkpark, :webhook_http_adapter)

    on_exit(fn ->
      restore(:allow_private_outbound, prev_flag)
      restore(:webhook_http_adapter, prev_adapter)
    end)

    :ok
  end

  test "ReqAdapter refuses a 127.0.0.1 target with :ssrf_blocked and no HTTP attempt" do
    Application.put_env(:barkpark, :allow_private_outbound, false)

    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/hook", fn conn ->
      send(test_pid, :hit)
      Plug.Conn.resp(conn, 200, "")
    end)

    assert {:error, {:ssrf_blocked, {:blocked_address, {127, 0, 0, 1}}}} =
             ReqAdapter.post("http://127.0.0.1:#{bypass.port}/hook", "{}", [])

    refute_receive :hit, 200
  end

  test "deliver/3 marks the delivery terminally failed (no retry) on an SSRF block" do
    Application.put_env(:barkpark, :allow_private_outbound, false)

    {:ok, wh} =
      Webhooks.create_webhook(%{
        "name" => "internal",
        "url" => "http://169.254.169.254/latest/meta-data/",
        "dataset" => "test",
        "secret" => "sek",
        "events" => ["publish"]
      })

    event_id = new_event_id()

    assert {:error, :ssrf_blocked, 1} = Dispatcher.deliver(wh, "{}", event_id)

    d = Webhooks.get_delivery(wh.id, event_id)
    assert d.status == "failed_giveup"
    assert d.attempts == 1
    assert d.last_error_text =~ "ssrf_blocked"
  end

  test "redirect: false — a 302 response is not followed to a second request" do
    Application.put_env(:barkpark, :allow_private_outbound, true)

    bypass = Bypass.open()
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://127.0.0.1:#{bypass.port}/second")
      |> Plug.Conn.resp(302, "")
    end)

    Bypass.stub(bypass, "POST", "/second", fn conn ->
      send(test_pid, :followed)
      Plug.Conn.resp(conn, 200, "")
    end)

    assert {:ok, 302} = ReqAdapter.post("http://127.0.0.1:#{bypass.port}/hook", "{}", [])
    refute_receive :followed, 200
  end

  # A real mutation_events row is required — webhook_deliveries.event_id has an
  # FK to it. Mirrors DispatcherTest's helper.
  defp new_event_id do
    Content.upsert_schema(
      %{"name" => "widget", "title" => "W", "visibility" => "public", "fields" => []},
      "test"
    )

    id = "e-" <> (Ecto.UUID.generate() |> binary_part(0, 8))
    {:ok, doc} = Content.create_document("widget", %{"_id" => id, "title" => "t"}, "test")

    [ev | _] =
      Barkpark.Repo.all(
        from(e in Barkpark.Content.MutationEvent,
          where: e.doc_id == ^doc.doc_id,
          order_by: [desc: e.id]
        )
      )

    ev.id
  end

  defp restore(k, nil), do: Application.delete_env(:barkpark, k)
  defp restore(k, v), do: Application.put_env(:barkpark, k, v)
end
