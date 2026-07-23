defmodule BarkparkCloud.Push.PushDeliveryWorkerTest do
  @moduledoc """
  Push-relay spike (mobile charter D15d) — one delivery's execution on
  `ChatNotificationWorker`'s exact verdict contract, through the swappable
  `:push_adapter` seam (the process-local `PushFakeAdapter`):

    * accepted → `:ok`, `last_used_at` stamped, and the notification encodes the
      BOUND deep-link ruling (D15c/D59h): session-level `deep_link`, `data` =
      exactly the 5 wire fields, no widening;
    * platform-dead token (`:unregistered` / `:invalid_token`) →
      `{:cancel, _}` TERMINAL and the row is REVOKED (the delivery path
      self-heals the registry);
    * no credentials (`:not_configured`, today's honest default) →
      `{:cancel, :not_configured}` — never retried, never faked;
    * revoked/gone row → `{:cancel, _}` without ever calling the adapter;
    * transport error → `{:error, _}` (Oban retries on the fixed [1s, 5s, 30s]
      backoff, 4 attempts total).
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.{Accounts, Push, Repo}
  alias BarkparkCloud.Push.DevicePushToken
  alias BarkparkCloud.PushFakeAdapter
  alias BarkparkCloud.Workers.PushDeliveryWorker

  @payload %{
    "session_id" => "sess-42",
    "title" => "Deploy the docs site?",
    "workspace_id" => "ws-acme",
    "blocked_since" => "2026-07-24T10:00:00Z",
    "ask_role" => "approver"
  }

  defp device_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, device} =
      Push.register_device_token(user, %{
        "platform" => "apns",
        "token" => "device-token-#{System.unique_integer([:positive])}"
      })

    device
  end

  defp perform(device_id) do
    perform_job(PushDeliveryWorker, %{
      "device_push_token_id" => device_id,
      "event" => "chat_blocked",
      "payload" => @payload
    })
  end

  test "accepted send → :ok, last_used_at stamped, deep-link ruling encoded" do
    device = device_fixture()
    assert is_nil(device.last_used_at)

    assert :ok = perform(device.id)

    assert %DateTime{} = Repo.get!(DevicePushToken, device.id).last_used_at

    assert [{sent_device, notification}] = PushFakeAdapter.sent()
    assert sent_device.id == device.id

    # The bound D15c/D59h ruling: deep-link to the SESSION (the app
    # follow-up-fetches pending asks on tap); data is the 5 fields VERBATIM.
    assert notification["deep_link"] == "barkpark://sessions/sess-42?workspace_id=ws-acme"
    assert notification["data"] == @payload
    assert notification["body"] == "Deploy the docs site?"
  end

  test "platform reports the token UNREGISTERED → terminal cancel + row revoked" do
    device = device_fixture()
    PushFakeAdapter.program({:error, :unregistered})

    assert {:cancel, :unregistered} = perform(device.id)
    assert %DateTime{} = Repo.get!(DevicePushToken, device.id).revoked_at
  end

  test "platform reports the token INVALID → terminal cancel + row revoked" do
    device = device_fixture()
    PushFakeAdapter.program({:error, :invalid_token})

    assert {:cancel, :invalid_token} = perform(device.id)
    assert %DateTime{} = Repo.get!(DevicePushToken, device.id).revoked_at
  end

  test "no APNs/FCM credentials configured → honest terminal cancel (never faked)" do
    device = device_fixture()
    PushFakeAdapter.program({:error, :not_configured})

    assert {:cancel, :not_configured} = perform(device.id)
    # NOT a platform verdict about the token — the row stays live for wave 2.
    assert is_nil(Repo.get!(DevicePushToken, device.id).revoked_at)
  end

  test "a row revoked between enqueue and perform → cancel WITHOUT calling the adapter" do
    device = device_fixture()
    device |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update!()

    assert {:cancel, :token_revoked} = perform(device.id)
    assert PushFakeAdapter.sent() == []
  end

  test "a deleted row → cancel without calling the adapter" do
    assert {:cancel, :token_gone} = perform(Ecto.UUID.generate())
    assert PushFakeAdapter.sent() == []
  end

  test "a transport error → {:error, _} (retryable — Oban re-drives)" do
    device = device_fixture()
    PushFakeAdapter.program({:error, :timeout})

    assert {:error, :timeout} = perform(device.id)
    # Transport trouble says nothing about the token: never revoke on it.
    assert is_nil(Repo.get!(DevicePushToken, device.id).revoked_at)
  end

  test "ChatNotificationWorker's contract: queue :default, 4 attempts, [1s, 5s, 30s] backoff" do
    job = PushDeliveryWorker.new(%{})
    assert job.changes[:queue] == "default"
    assert job.changes[:max_attempts] == 4

    assert PushDeliveryWorker.backoff(%Oban.Job{attempt: 1}) == 1
    assert PushDeliveryWorker.backoff(%Oban.Job{attempt: 2}) == 5
    assert PushDeliveryWorker.backoff(%Oban.Job{attempt: 3}) == 30
    assert PushDeliveryWorker.backoff(%Oban.Job{attempt: 4}) == 30
  end
end
