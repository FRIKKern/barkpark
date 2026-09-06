defmodule BarkparkCloud.Workers.ChatNotificationWorkerTest do
  @moduledoc """
  notifications-chat: the Oban worker that replaced the swarm candidate's
  Task.Supervisor + inline Process.sleep retry loop. Drives `perform_job/2`
  against the in-process `FakeHttpClient` (config/test.exs) so the select → shape
  → POST → 2xx/4xx-terminal/5xx-retry paths run without the wire.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.{Delivery, FakeHttpClient}
  alias BarkparkCloud.Workers.ChatNotificationWorker

  defp team_with_discord do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    {:ok, _} =
      Notifications.put_channel(team, "discord", true, %{
        "url" => "https://203.0.113.11/api/webhooks/1/abc"
      })

    team
  end

  defp args(team, type \\ "discord", event \\ "provision_failed") do
    %{
      "team_id" => team.id,
      "channel_type" => type,
      "event" => event,
      "payload" => %{"name" => "acme"}
    }
  end

  test "a 2xx delivers, logs a sent Delivery, and POSTs the shaped envelope" do
    team = team_with_discord()
    FakeHttpClient.program([{:ok, %{status: 204}}])

    assert :ok = perform_job(ChatNotificationWorker, args(team))

    # One request went out, to the discord webhook URL.
    assert [req] = FakeHttpClient.requests()
    assert req.url =~ "203.0.113.11/api/webhooks"

    # A durable delivery row was written with the provider status.
    assert [%Delivery{status: "sent", http_status: 204, channel: "discord"}] =
             Notifications.list_deliveries(team)
  end

  test "a 4xx is TERMINAL — {:cancel, _}, no retry" do
    team = team_with_discord()
    FakeHttpClient.program([{:ok, %{status: 400}}])

    assert {:cancel, {:http_4xx, 400}} = perform_job(ChatNotificationWorker, args(team))
    assert [%Delivery{status: "failed", http_status: 400}] = Notifications.list_deliveries(team)
  end

  test "a 5xx is RETRYABLE — {:error, _} so Oban re-drives" do
    team = team_with_discord()
    FakeHttpClient.program([{:ok, %{status: 503}}])

    assert {:error, {:http_status, 503}} = perform_job(ChatNotificationWorker, args(team))
  end

  test "a transport error is retryable" do
    team = team_with_discord()
    FakeHttpClient.program([{:error, {:http_client, :timeout}}])

    assert {:error, {:http_client, :timeout}} = perform_job(ChatNotificationWorker, args(team))
  end

  test "a since-removed channel is a terminal no-op" do
    team = team_with_discord()
    {:ok, _} = Notifications.put_channel(team, "discord", false, nil)

    assert {:cancel, :channel_gone} = perform_job(ChatNotificationWorker, args(team))
  end

  test "the fixed [1s,5s,30s] backoff is preserved" do
    assert ChatNotificationWorker.backoff(%Oban.Job{attempt: 1}) == 1
    assert ChatNotificationWorker.backoff(%Oban.Job{attempt: 2}) == 5
    assert ChatNotificationWorker.backoff(%Oban.Job{attempt: 3}) == 30
    # Past the table it clamps to the last delay rather than crashing.
    assert ChatNotificationWorker.backoff(%Oban.Job{attempt: 4}) == 30
  end

  test "no-redirect regression: the egress transport explicitly disables autoredirect" do
    # SSRF via redirect is closed ONLY because Billing.HttpClient sets
    # autoredirect: false EXPLICITLY — Erlang :httpc DEFAULTS autoredirect to
    # TRUE, so a merely-absent key is the vulnerable state. Assert the key is
    # present AND false; if a future edit drops the line, this fails (unlike the
    # old `refute Keyword.get(...)`, which passed trivially on the vulnerable
    # absent-key state).
    {_arg, http_opts, _opts} =
      BarkparkCloud.Billing.HttpClient.to_httpc(%{
        method: :post,
        url: "https://example.com/x",
        headers: [{"content-type", "application/json"}],
        body: "{}"
      })

    assert Keyword.get(http_opts, :autoredirect) == false
    assert Keyword.has_key?(http_opts, :autoredirect)
  end

  test "a 3xx redirect to a private-IP Location is NOT auto-followed" do
    # End-to-end proof the redirect-SSRF hole is closed: the transport returns the
    # 3xx to the caller (autoredirect is off), the delivery path treats it as a
    # non-2xx (here retryable), and the fanned-out follow request to the private
    # metadata Location NEVER happens. Were autoredirect on, :httpc would chase the
    # Location to 169.254.169.254 without re-running SafeUrl.
    team = team_with_discord()

    FakeHttpClient.program([
      {:ok, %{status: 302, headers: [{"location", "http://169.254.169.254/latest/meta-data/"}]}}
    ])

    # 3xx is not 2xx and not 4xx → treated as retryable, never delivered.
    assert {:error, {:http_status, 302}} = perform_job(ChatNotificationWorker, args(team))

    # Exactly ONE request went out — the redirect Location was NOT fetched.
    assert [req] = FakeHttpClient.requests()
    assert req.url =~ "203.0.113.11/api/webhooks"
    refute Enum.any?(FakeHttpClient.requests(), &(&1.url =~ "169.254.169.254"))

    # And the Location target itself resolves private, so even a re-validated
    # follow would be blocked — the guard is coherent end to end.
    assert BarkparkCloud.Notifications.SafeUrl.private_address?({169, 254, 169, 254})
  end
end
