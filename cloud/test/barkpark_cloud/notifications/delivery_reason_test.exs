defmodule BarkparkCloud.Notifications.DeliveryReasonTest do
  @moduledoc """
  wave 31 S1 — `Delivery.last_error` is PUBLISHED (`Web.Router.delivery_json/1` →
  `app.js` renders it verbatim to every team admin), so it may only ever carry a
  label from `DeliveryReason`'s closed vocabulary.

  The centrepiece is the CENSUS: a table of REAL transport error terms — the
  gen_smtp `host_failure()` shapes (which name `smtp_host()` in every arm) and
  the `:httpc` `failed_connect` shape (which names host AND port) — driven
  through the actual send paths, asserting the persisted `last_error` contains
  NONE of the seeded sentinels and IS one of the vocabulary's constant
  sentences. A test that only asserts the happy label is green by construction;
  this one reds the moment a write site publishes a raw capture again (proven by
  mutation: restoring `inspect(why)` in `record_delivery/5` fails the census
  naming the leaked sentinel).

  `async: false` — the email arm swaps the module-global Mailer adapter and the
  chat arm swaps the module-global notifications HTTP client (both restored via
  `on_exit`).
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.Notifications.DeliveryReason
  alias BarkparkCloud.Repo

  # Secrets seeded into every error term the census drives. The relay HOST is the
  # one the system already treats as a secret (`settings_view/1` masks it to
  # "********" even for the owner; the column is Vault-sealed with redact: true).
  # The username and port ride along as the adjacent values a raw `inspect/1`
  # would also publish once a term happens to carry them.
  @sentinel_host "top-secret-relay-3204.invalid"
  @sentinel_user "smtp-user-7781"
  @sentinel_port "2525"
  @sentinels [@sentinel_host, @sentinel_user, @sentinel_port]

  # Every sentence the closed vocabulary can produce. `last_error` must be one of
  # these, exactly — anything else means a raw capture reached the column.
  defp allowed_labels do
    Enum.map(DeliveryReason.classes(), &DeliveryReason.label/1) ++
      Enum.map(
        [200, 400, 401, 403, 404, 429, 500, 502, 503],
        &DeliveryReason.label({:http_status, &1})
      )
  end

  # {description, raw transport term, expected class}
  defp census_terms do
    host = String.to_charlist(@sentinel_host)

    [
      {"gen_smtp DNS failure (the shape a live run actually produced)",
       {:retries_exceeded, {:network_failure, host, {:error, :nxdomain}}}, :dns_failure},
      {"gen_smtp connection refused",
       {:retries_exceeded, {:network_failure, host, {:error, :econnrefused}}},
       :connection_refused},
      {"gen_smtp connect timeout",
       {:retries_exceeded, {:network_failure, host, {:error, :timeout}}}, :timeout},
      {"gen_smtp permanent 550 naming the mailbox",
       {:no_more_hosts, {:permanent_failure, host, "550 5.1.1 <#{@sentinel_user}> unknown user"}},
       :recipient_rejected},
      {"gen_smtp temporary 421 throttle quoting the relay",
       {:send,
        {:temporary_failure, host, "421 4.7.0 too many connections from #{@sentinel_host}"}},
       :rate_limited},
      {"gen_smtp auth rejected", {:no_more_hosts, {:permanent_failure, host, :auth_failed}},
       :auth_rejected},
      {"gen_smtp TLS handshake failure", {:send, {:temporary_failure, host, :tls_failed}},
       :tls_failure},
      {"gen_smtp missing TLS requirement", {:send, {:missing_requirement, host, :tls}},
       :tls_failure},
      {"gen_smtp option validation (no host in the term at all)", :no_credentials,
       :auth_rejected},
      {"httpc failed_connect naming host AND port",
       {:failed_connect,
        [{:to_address, {host, String.to_integer(@sentinel_port)}}, {:inet, [:inet], :nxdomain}]},
       :dns_failure},
      {"an unmapped term keeps nothing of itself",
       {:relay_down, %{host: @sentinel_host, port: @sentinel_port, user: @sentinel_user}},
       :unknown}
    ]
  end

  ## ── The vocabulary itself ────────────────────────────────────────────────

  describe "classes/0 — the exported closed vocabulary" do
    test "covers every class the wave's surfaces name (slice 7 imports this list)" do
      for class <- [
            :dns_failure,
            :connection_refused,
            :tls_failure,
            :auth_rejected,
            :rate_limited,
            :recipient_rejected,
            :timeout,
            :http_status,
            :unknown
          ] do
        assert class in DeliveryReason.classes(), "missing class #{inspect(class)}"
      end
    end

    test "every class has a person-facing label and no class leaks jargon" do
      for class <- DeliveryReason.classes() do
        label = DeliveryReason.label(class)
        assert is_binary(label) and label != ""
        assert String.ends_with?(label, "."), "#{class} label is not a sentence: #{label}"
        refute label =~ ~r/[{}]|:[a-z_]+_failure|inspect/
      end
    end
  end

  describe "classify/1" do
    test "maps every census term to its expected class" do
      for {what, term, expected} <- census_terms() do
        assert DeliveryReason.classify(term) == expected,
               "#{what}: expected #{inspect(expected)}, got #{inspect(DeliveryReason.classify(term))}"
      end
    end

    test "an HTTP status keeps only its integer" do
      assert DeliveryReason.classify({:http_status, 503}) == {:http_status, 503}
      assert DeliveryReason.classify({:http_4xx, 429}) == {:http_status, 429}
      assert DeliveryReason.label({:http_status, 429}) =~ "429"
    end

    test "is total — an arbitrary term is :unknown, never a crash" do
      assert DeliveryReason.classify(%{"anything" => [1, 2, 3]}) == :unknown
      assert DeliveryReason.classify(self()) == :unknown
      assert DeliveryReason.classify({:a, :b, :c, :d}) == :unknown
    end

    test "summarize/1 passes nil through so a success path can pipe it" do
      assert DeliveryReason.summarize(nil) == nil
      assert DeliveryReason.summarize(:nxdomain) == DeliveryReason.label(:dns_failure)
    end
  end

  ## ── THE CENSUS — the email path ──────────────────────────────────────────

  defmodule ScriptedFailingAdapter do
    @moduledoc "A Swoosh adapter that fails with whatever term the census scripted."
    use Swoosh.Adapter

    @impl true
    def deliver(_email, _config),
      do: {:error, Application.get_env(:barkpark_cloud, :__delivery_reason_census_term__)}
  end

  describe "census: a failed EMAIL send never publishes the relay host" do
    setup do
      prev = Application.get_env(:barkpark_cloud, BarkparkCloud.Mailer)
      Application.put_env(:barkpark_cloud, BarkparkCloud.Mailer, adapter: ScriptedFailingAdapter)

      on_exit(fn ->
        Application.put_env(:barkpark_cloud, BarkparkCloud.Mailer, prev)
        Application.delete_env(:barkpark_cloud, :__delivery_reason_census_term__)
      end)

      :ok
    end

    test "no seeded sentinel survives into Delivery.last_error, for any transport term" do
      for {what, term, expected} <- census_terms() do
        Repo.delete_all(Delivery)
        Application.put_env(:barkpark_cloud, :__delivery_reason_census_term__, term)

        assert {:error, _} =
                 Notifications.deliver_password_reset(
                   "census@example.com",
                   "https://barkpark.cloud/reset/xyz"
                 )

        assert [%Delivery{status: "failed"} = d] = Repo.all(Delivery)

        for sentinel <- @sentinels do
          refute d.last_error =~ sentinel,
                 "#{what}: last_error PUBLISHED the secret #{inspect(sentinel)} — " <>
                   "stored value was #{inspect(d.last_error)}"
        end

        assert d.last_error in allowed_labels(),
               "#{what}: last_error is not a closed-vocabulary label — #{inspect(d.last_error)}"

        assert d.last_error == DeliveryReason.label(expected), "#{what}: wrong class published"
      end
    end
  end

  ## ── THE CENSUS — the chat path ───────────────────────────────────────────

  defmodule ScriptedChatClient do
    @moduledoc "A chat HTTP client that returns whatever the census scripted."
    def request(_req),
      do: Application.get_env(:barkpark_cloud, :__delivery_reason_census_http__)
  end

  describe "census: a failed CHAT send never publishes the destination host or port" do
    setup do
      prev = Application.get_env(:barkpark_cloud, :notifications_http_client)
      Application.put_env(:barkpark_cloud, :notifications_http_client, ScriptedChatClient)

      on_exit(fn ->
        if prev do
          Application.put_env(:barkpark_cloud, :notifications_http_client, prev)
        else
          Application.delete_env(:barkpark_cloud, :notifications_http_client)
        end

        Application.delete_env(:barkpark_cloud, :__delivery_reason_census_http__)
      end)

      n = System.unique_integer([:positive])
      {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

      {:ok, _} =
        Notifications.put_channel(team, "discord", true, %{
          "url" => "https://discord.com/api/webhooks/1/abc"
        })

      {:ok, team: team}
    end

    test "a transport error is classified, not inspected", %{team: team} do
      host = String.to_charlist(@sentinel_host)

      failures = [
        {{:error,
          {:failed_connect,
           [
             {:to_address, {host, String.to_integer(@sentinel_port)}},
             {:inet, [:inet], :nxdomain}
           ]}}, :dns_failure},
        {{:error,
          {:failed_connect, [{:to_address, {host, 443}}, {:inet, [:inet], :econnrefused}]}},
         :connection_refused},
        {{:error, :timeout}, :timeout}
      ]

      for {response, expected} <- failures do
        Repo.delete_all(Delivery)
        Application.put_env(:barkpark_cloud, :__delivery_reason_census_http__, response)

        assert {:error, _} = Notifications.deliver_chat(team.id, "discord", "test", %{})

        assert [%Delivery{status: "failed", channel: "discord"} = d] = Repo.all(Delivery)

        for sentinel <- @sentinels do
          refute d.last_error =~ sentinel,
                 "chat #{inspect(response)}: last_error PUBLISHED the secret " <>
                   "#{inspect(sentinel)} — stored value was #{inspect(d.last_error)}"
        end

        assert d.last_error == DeliveryReason.label(expected)
      end
    end

    test "an HTTP rejection keeps the status and nothing else", %{team: team} do
      Application.put_env(
        :barkpark_cloud,
        :__delivery_reason_census_http__,
        {:ok, %{status: 429}}
      )

      # A 4xx is terminal, so the send path CANCELS rather than retrying — the
      # delivery row is written either way.
      assert {:cancel, {:http_4xx, 429}} =
               Notifications.deliver_chat(team.id, "discord", "test", %{})

      assert [%Delivery{status: "failed", http_status: 429} = d] = Repo.all(Delivery)
      assert d.last_error == DeliveryReason.label({:http_status, 429})
      assert d.last_error =~ "429"
      assert d.last_error in allowed_labels()
    end

    test "a successful send still records no error", %{team: team} do
      Application.put_env(
        :barkpark_cloud,
        :__delivery_reason_census_http__,
        {:ok, %{status: 204}}
      )

      assert :ok = Notifications.deliver_chat(team.id, "discord", "test", %{})
      assert [%Delivery{status: "sent", last_error: nil}] = Repo.all(Delivery)
    end
  end
end
