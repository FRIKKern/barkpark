defmodule Barkpark.Webhooks.DispatcherTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Dispatcher

  test "build_payload creates correct structure" do
    payload = Dispatcher.build_payload("create", "post", "p1", %{"_id" => "p1"}, "production")

    assert payload.event == "create"
    assert payload.type == "post"
    assert payload.doc_id == "p1"
    assert payload.dataset == "production"
    assert payload.document == %{"_id" => "p1"}
    assert is_binary(payload.timestamp)
  end

  test "sign_payload generates HMAC" do
    payload = %{event: "create", doc_id: "p1"}
    sig = Dispatcher.sign_payload(Jason.encode!(payload), "mysecret")
    assert String.starts_with?(sig, "sha256=")
    # sha256= (7 chars) + 64 hex chars = 71
    assert String.length(sig) == 71
  end

  test "dispatch_async spawns tasks for matching webhooks" do
    {:ok, _wh} =
      Webhooks.create_webhook(%{
        "name" => "Test",
        "url" => "http://localhost:1/noop",
        "dataset" => "test",
        "events" => ["create"],
        "types" => []
      })

    # Should not raise; tasks will fail silently (connection refused)
    Dispatcher.dispatch_async("test", "create", "post", "p1", %{"_id" => "p1"})
    Process.sleep(50)
  end
end
