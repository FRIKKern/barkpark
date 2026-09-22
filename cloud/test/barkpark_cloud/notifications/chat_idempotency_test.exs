defmodule BarkparkCloud.Notifications.ChatIdempotencyTest do
  @moduledoc """
  ccpca-bl-chat-webhook-idempotency-key — the two halves of the receipt-accuracy
  gap on the chat egress path.

  HALF ONE, the wire: `ChatNotificationWorker` is `max_attempts: 4` and the only
  per-send value any envelope carried was `Channels.Webhook`'s
  `DateTime.utc_now()`, minted INSIDE `shape/4` and therefore different on every
  attempt. A receiver could not tell attempt 2 of one notification from a second
  notification. Now every shaper carries a STABLE `Idempotency-Key` minted at
  enqueue.

  HALF TWO, the receipt: `post_chat/6`'s transport-error arm stamped `"failed"`
  for a request that was written and never answered — a verdict about a receiver
  that arm never heard from. It stamps `"unconfirmed"` for that one case now.

  THE CHANNEL SET IS DERIVED, NOT LISTED. `channel_shapers/0` reads the modules
  out of `lib/barkpark_cloud/notifications/channels/`, so a sixth channel added
  later arrives in these tests by existing — it does not have to be remembered.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  import Ecto.Query

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.Channels
  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.Notifications.FakeHttpClient
  alias BarkparkCloud.Workers.ChatNotificationWorker

  @channels_dir "lib/barkpark_cloud/notifications/channels"

  # NOT the shaper — this module is the id itself, and has no `shape/4`.
  @not_a_shaper ["idempotency.ex"]

  # Per-channel credentials, keyed by the DERIVED module. A channel whose file
  # exists with no entry here reds `every derived shaper is covered` below with
  # its own name, which is the point: the list that can go stale is the FIXTURE,
  # and a stale fixture must fail loudly rather than quietly skip a sibling.
  defp creds_for(Channels.Discord), do: %{"url" => "https://203.0.113.21/hook"}
  defp creds_for(Channels.Slack), do: %{"url" => "https://203.0.113.22/hook"}
  defp creds_for(Channels.Telegram), do: %{"token" => "bot-token", "chat_id" => "42"}
  defp creds_for(Channels.Pushover), do: %{"user_key" => "u", "api_token" => "t"}
  defp creds_for(Channels.Webhook), do: %{"url" => "https://1.1.1.1/hook"}
  defp creds_for(_other), do: nil

  # The DERIVATION: one module per file under channels/, minus the id module.
  # Not a hand-kept list of five names.
  defp channel_shapers do
    @channels_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Kernel.--(@not_a_shaper)
    |> Enum.map(fn file ->
      mod =
        file
        |> Path.rootname()
        |> Macro.camelize()
        |> then(&Module.concat(Channels, &1))

      {file, mod}
    end)
    |> Enum.sort()
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp deliveries(team) do
    Repo.all(from d in Delivery, where: d.team_id == ^team.id, order_by: d.inserted_at)
  end

  describe "the delivery id is on EVERY derived channel shape" do
    test "the channel set is derived from the tree, and every derived shaper has a fixture" do
      shapers = channel_shapers()

      assert shapers != [], "derived the empty channel set — the derivation itself is broken"

      missing = for {file, mod} <- shapers, is_nil(creds_for(mod)), do: file

      assert missing == [],
             "a channel module exists with no credentials fixture in this test: #{inspect(missing)} — " <>
               "add it, do not skip it"

      for {file, mod} <- shapers do
        # `Code.ensure_loaded?/1` FIRST: `function_exported?/3` answers false for
        # a module that simply has not been loaded yet, so without this the
        # assertion passes or fails by which other test module ran first. It did
        # exactly that — green alone, red inside the 590-test run.
        assert Code.ensure_loaded?(mod), "#{file} does not compile to #{inspect(mod)}"

        assert function_exported?(mod, :shape, 4),
               "#{file} does not export shape/4 — it cannot be handed a delivery id"
      end
    end

    test "every derived shaper carries the id in Idempotency-Key AND X-Barkpark-Delivery-Id" do
      id = "11111111-2222-3333-4444-555555555555"

      for {file, mod} <- channel_shapers() do
        assert {:ok, _url, _body, headers} =
                 mod.shape(creds_for(mod), "test", %{}, delivery_id: id),
               "#{file} refused to shape"

        assert header(headers, "idempotency-key") == id, "#{file} lost the Idempotency-Key"

        assert header(headers, "x-barkpark-delivery-id") == id,
               "#{file} lost the X-Barkpark-Delivery-Id"
      end
    end

    test "a nil id appends NOTHING — an empty key is worse than an absent one" do
      for {file, mod} <- channel_shapers() do
        assert {:ok, _url, _body, headers} = mod.shape(creds_for(mod), "test", %{}, [])
        assert header(headers, "idempotency-key") == nil, "#{file} emitted a blank key"
      end
    end

    test "the webhook BODY carries delivery_id; the provider bodies deliberately do not" do
      id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

      {:ok, _url, body, _h} = Channels.Webhook.shape(creds_for(Channels.Webhook), "test", %{}, delivery_id: id)

      assert Jason.decode!(body)["delivery_id"] == id,
             "webhook is the one envelope Barkpark owns — its body must carry the key"

      # The EXCEPTION, asserted rather than left implicit: these four post to a
      # provider whose request schema we do not own, so the id rides headers only.
      for mod <- [Channels.Discord, Channels.Slack, Channels.Telegram, Channels.Pushover] do
        {:ok, _url, body, _h} = mod.shape(creds_for(mod), "test", %{}, delivery_id: id)
        refute to_string(body) =~ id, "#{inspect(mod)} put the id in a provider-owned body"
      end
    end
  end

  describe "the id is STABLE across attempts — the whole point" do
    test "two attempts of one job present one key, while the webhook timestamp moves" do
      team = team_fixture()

      {:ok, _} =
        Notifications.put_channel(team, "webhook", true, %{"url" => "https://1.1.1.1/hook"})

      {:ok, 1} = Notifications.send_test_chat(team)

      [%{args: args}] = all_enqueued(worker: ChatNotificationWorker)

      assert is_binary(args["delivery_id"]),
             "the id must be minted at ENQUEUE and live in the job args, not in the attempt"

      # Attempt 1 fails retryably, attempt 2 succeeds — Oban re-runs the SAME
      # args, which is what this drives by hand.
      FakeHttpClient.program([{:ok, %{status: 503}}, {:ok, %{status: 200}}])

      assert {:error, _} = ChatNotificationWorker.perform(%Oban.Job{args: args})
      assert :ok = ChatNotificationWorker.perform(%Oban.Job{args: args})

      assert [r1, r2] = FakeHttpClient.requests()

      k1 = header(r1.headers, "idempotency-key")
      k2 = header(r2.headers, "idempotency-key")

      assert k1 == args["delivery_id"]
      assert k1 == k2, "the key moved between attempts — it dedupes nothing"

      # THE CONTROL ARM. `timestamp` is the per-attempt value that was already
      # there and is NOT a dedupe key. If this assertion ever fails, the two
      # attempts were not actually distinct sends and the equality above proved
      # nothing.
      t1 = Jason.decode!(r1.body)["timestamp"]
      t2 = Jason.decode!(r2.body)["timestamp"]
      assert is_binary(t1) and is_binary(t2)

      refute t1 == t2,
             "the per-attempt timestamp did not move — this rig is not making two distinct sends, " <>
               "so the stable-key assertion above is vacuous"

      assert Jason.decode!(r1.body)["delivery_id"] == Jason.decode!(r2.body)["delivery_id"]
    end

    test "args with no delivery_id still deliver — and carry no key" do
      team = team_fixture()

      {:ok, _} =
        Notifications.put_channel(team, "webhook", true, %{"url" => "https://1.1.1.1/hook"})

      {:ok, 1} = Notifications.send_test_chat(team)
      [%{args: args}] = all_enqueued(worker: ChatNotificationWorker)

      legacy = Map.delete(args, "delivery_id")

      FakeHttpClient.program([{:ok, %{status: 200}}])
      assert :ok = ChatNotificationWorker.perform(%Oban.Job{args: legacy})

      [req] = FakeHttpClient.requests()
      assert header(req.headers, "idempotency-key") == nil
    end
  end

  describe "the receipt for a LOST RESPONSE is not a plain failed" do
    setup do
      team = team_fixture()

      {:ok, _} =
        Notifications.put_channel(team, "webhook", true, %{"url" => "https://1.1.1.1/hook"})

      {:ok, team: team}
    end

    test "a request timeout records unconfirmed, and still retries", %{team: team} do
      FakeHttpClient.program([{:error, :timeout}])

      assert {:error, :timeout} = Notifications.deliver_chat(team.id, "webhook", "test", %{}),
             "the RETURN must be unchanged — only the receipt got more accurate"

      assert [%Delivery{status: status}] = deliveries(team)
      assert status == "unconfirmed"

      meaning = Delivery.status_meaning("unconfirmed")
      assert meaning =~ "do not know"

      refute meaning =~ ~r/\bdelivered to\b/,
             "unconfirmed must not claim delivery — that is the lie failed was replacing"
    end

    # THE CONTROL ARM for half two. Every one of these DID read a verdict, so
    # every one must stay `failed`. A rig that stamped `unconfirmed` everywhere
    # would pass the test above and fail here.
    test "a verdict that WAS read off the wire stays failed", %{team: team} do
      connect_timeout =
        {:failed_connect, [{:to_address, {~c"1.1.1.1", 443}}, {:inet, [:inet], :etimedout}]}

      for reason <- [:econnrefused, :nxdomain, connect_timeout] do
        FakeHttpClient.program([{:error, reason}])
        assert {:error, ^reason} = Notifications.deliver_chat(team.id, "webhook", "test", %{})
      end

      FakeHttpClient.program([{:ok, %{status: 500}}])
      assert {:error, _} = Notifications.deliver_chat(team.id, "webhook", "test", %{})

      statuses = deliveries(team) |> Enum.map(& &1.status)

      assert statuses == ["failed", "failed", "failed", "failed"],
             "a reason that named a verdict was recorded as unconfirmed: #{inspect(statuses)}"
    end

    test "unconfirmed is a known status word with its own sentence" do
      assert "unconfirmed" in Delivery.statuses()

      refute Delivery.status_meaning("unconfirmed") =~ "Not a status this version",
             "the word shipped without its sentence"
    end
  end
end
