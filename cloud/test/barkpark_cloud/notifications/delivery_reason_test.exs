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
      # WAVE 35 S3. These two rows USED to pin :tls_failure and :auth_rejected —
      # sentences naming a handshake and a credential rejection that never
      # happened. Correcting the module reds exactly these two of the eleven
      # rows above, which is the slice's fail-before proof.
      {"gen_smtp missing TLS requirement — the server never advertised STARTTLS",
       {:send, {:missing_requirement, host, :tls}}, :tls_not_offered},
      {"gen_smtp missing AUTH requirement — the server never offered a sign-in",
       {:send, {:missing_requirement, host, :auth}}, :auth_not_offered},
      {"gen_smtp option validation (no host in the term at all) — no socket was opened",
       :no_credentials, :not_configured},
      # cch-w35-followup. ONE ROW PER NEW ARM. Each is mutation-proved on its
      # own: reverting only its `classify/1` clause reds only this row, naming it.
      {"gen_smtp option validation: no relay host configured — no socket was opened", :no_relay,
       :relay_not_configured},
      {"gen_smtp option validation: the relay port is not a port — no socket was opened",
       :invalid_port, :relay_port_invalid},
      {"posix ehostdown — the destination host reported itself down, not unrouted",
       {:retries_exceeded, {:network_failure, host, {:error, :ehostdown}}}, :network_down},
      {"posix enetdown — the network reported itself down, not unrouted",
       {:no_more_hosts, {:network_failure, host, {:error, :enetdown}}}, :network_down},
      # NOBODY ANSWERED is not a refusal: the peer that refuses ANSWERS
      # (:econnrefused, above, is the unmoved control).
      {"gen_smtp host unreachable — no route, nobody answered",
       {:retries_exceeded, {:network_failure, host, {:error, :ehostunreach}}}, :unreachable},
      {"gen_smtp network unreachable — no route, nobody answered",
       {:no_more_hosts, {:network_failure, host, {:error, :enetunreach}}}, :unreachable},
      # The destination's OWN trouble, not a statement about our rate (421,
      # above, is the unmoved throttle control).
      {"gen_smtp temporary 450 mailbox busy",
       {:send, {:temporary_failure, host, "450 4.2.1 mailbox busy at #{@sentinel_host}"}},
       :destination_temporary_error},
      {"gen_smtp temporary 451 local error in processing",
       {:send,
        {:temporary_failure, host, "451 4.3.0 local error in processing for #{@sentinel_user}"}},
       :destination_temporary_error},
      {"gen_smtp temporary 452 insufficient system storage",
       {:send,
        {:temporary_failure, host, "452 4.3.1 insufficient system storage on #{@sentinel_host}"}},
       :destination_temporary_error},
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
            :unreachable,
            :connection_refused,
            :tls_failure,
            :tls_not_offered,
            :auth_rejected,
            :auth_not_offered,
            :not_configured,
            :relay_not_configured,
            :relay_port_invalid,
            :network_down,
            :rate_limited,
            :destination_temporary_error,
            :recipient_rejected,
            :timeout,
            :unknown
          ] do
        assert class in DeliveryReason.classes(), "missing class #{inspect(class)}"
      end
    end

    # WAVE 35 S3. `classes/0` is mapped through `label/1` by `Delivery`'s clamp,
    # by the backfill migration and by the tests, so it may only hold classes
    # whose label is a CONSTANT sentence. `:http_status` never was one:
    # `classify/1` only ever emits `{:http_status, code}`, so the bare arm was
    # a sentence nothing could produce and its removal is what takes the class
    # out of this list.
    test "holds only classes whose label is a constant — :http_status is parameterized, not a member" do
      refute :http_status in DeliveryReason.classes()

      assert DeliveryReason.classify({:http_status, 503}) == {:http_status, 503}

      # `apply/3`, not a direct call: a direct one is a compile-time type error
      # now that the arm is gone — which is itself the proof, but it would fail
      # the `--warnings-as-errors` compile rather than this assertion.
      assert_raise FunctionClauseError, fn -> apply(DeliveryReason, :label, [:http_status]) end
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

  ## ── WAVE 35 S3 — a label may only name what the code OBSERVED ────────────

  describe "the sentence names only what was observed" do
    # Each row is {term, the word the OLD sentence said and the code never
    # observed}. These red on a revert of `classify/1`, not merely on a reword:
    # the forbidden word is the one the reverted class's label carries.
    @miscause_terms [
      {:no_credentials, "rejected our credentials",
       "no socket is ever opened, so no destination rejected anything"},
      {{:missing_requirement, ~c"relay.invalid", :tls}, "handshake",
       "the throw happens after quit/1 because STARTTLS was never advertised"},
      {{:missing_requirement, ~c"relay.invalid", :auth}, "rejected our credentials",
       "the server never offered a sign-in, so it rejected no credential"},
      {:ehostunreach, "refused", "no route means nobody answered; a refusal is an answer"},
      {:enetunreach, "refused", "no route means nobody answered; a refusal is an answer"},
      {{:temporary_failure, ~c"relay.invalid", "451 4.3.0 local error in processing"},
       "rate-limiting", "451 is the destination's own processing error, not throttling"},
      {{:temporary_failure, ~c"relay.invalid", "452 4.3.1 insufficient system storage"},
       "rate-limiting", "452 is out of storage, not throttling"}
    ]

    test "no corrected arm still says the thing nothing observed" do
      for {term, forbidden, why} <- @miscause_terms do
        sentence = DeliveryReason.summarize(term)

        refute sentence =~ forbidden,
               "#{inspect(term)} still publishes #{inspect(forbidden)} — #{why}. " <>
                 "Sentence was #{inspect(sentence)}"
      end
    end

    # cch-w35-followup — the CRITERION, mechanical: each of the two option-
    # validation siblings must name ITS OWN missing configuration. Not the
    # generic :unknown sentence (which sends the reader to a server log for a
    # fault the console can fix), and not :not_configured's (which names the
    # username and password — the wrong missing setting for both).
    test "the validate_options siblings each name their own missing configuration" do
      relay = DeliveryReason.summarize(:no_relay)
      port = DeliveryReason.summarize(:invalid_port)

      for {atom, sentence} <- [no_relay: relay, invalid_port: port] do
        refute sentence == DeliveryReason.label(:unknown),
               "#{atom} still falls to the generic :unknown sentence: #{inspect(sentence)}"

        refute sentence == DeliveryReason.label(:not_configured),
               "#{atom} borrows the credentials sentence, which names the wrong missing " <>
                 "setting: #{inspect(sentence)}"

        assert sentence =~ "never started",
               "#{atom} no longer says the send never started: #{inspect(sentence)}"

        refute sentence =~ ~r/destination|rejected|refused|reach/,
               "#{atom} publishes a REMOTE verdict for a local option-validation fault, " <>
                 "which no socket was opened to observe: #{inspect(sentence)}"
      end

      assert relay =~ "relay host", "no_relay does not name the relay host: #{inspect(relay)}"
      assert port =~ "port", "invalid_port does not name the port: #{inspect(port)}"
      assert relay != port, "the two siblings publish one sentence for two settings"
    end

    # The two `down` reports are nobody-answered like ehostunreach/enetunreach,
    # but neither observed a ROUTE — and :unreachable's sentence names one. This
    # arm reds if a later pass folds them into it.
    test "a `down` report does not borrow :unreachable's route sentence" do
      for atom <- [:ehostdown, :enetdown] do
        sentence = DeliveryReason.summarize(atom)

        assert DeliveryReason.classify(atom) == :network_down

        refute sentence =~ "no route",
               "#{atom} publishes a routing mechanism nothing observed: #{inspect(sentence)}"

        refute sentence == DeliveryReason.label(:unknown),
               "#{atom} still falls to :unknown: #{inspect(sentence)}"
      end
    end

    # THE RULING, pinned so it stays a decision rather than a gap. `:eacces` is
    # OUR host refusing the socket (a local sandbox/firewall policy, or an
    # unprivileged bind). It names no destination behaviour and no console
    # setting, so every sentence in this vocabulary would claim something
    # nothing observed; :unknown points at the server log, where the raw term is.
    test "eacces is RULED OUT, not overlooked — it stays :unknown on purpose" do
      assert DeliveryReason.classify(:eacces) == :unknown

      assert DeliveryReason.summarize(:eacces) == DeliveryReason.label(:unknown),
             "eacces was given a sentence. If that is deliberate, the class must name what " <>
               "the code observed — a LOCAL permission denial — and this ruling must be " <>
               "rewritten, not deleted."
    end

    test "the controls keep their meaning — a refusal and a real throttle are answers" do
      assert DeliveryReason.summarize(:econnrefused) == DeliveryReason.label(:connection_refused)

      assert DeliveryReason.summarize(
               {:temporary_failure, ~c"relay.invalid", "421 4.7.0 too many connections"}
             ) == DeliveryReason.label(:rate_limited)
    end

    # The applied backfill (20260805210000) and every historical row key off
    # these exact bytes, so a REWORD is a data break the way a new class is not.
    test "the pre-existing sentences are frozen, byte for byte" do
      assert DeliveryReason.label(:dns_failure) ==
               "The destination host could not be resolved (DNS)."

      assert DeliveryReason.label(:connection_refused) ==
               "The destination refused the connection."

      assert DeliveryReason.label(:tls_failure) ==
               "The secure (TLS) handshake with the destination failed."

      assert DeliveryReason.label(:auth_rejected) == "The destination rejected our credentials."

      assert DeliveryReason.label(:rate_limited) ==
               "The destination is rate-limiting us — try again later."

      assert DeliveryReason.label(:recipient_rejected) ==
               "The destination rejected the recipient address."

      assert DeliveryReason.label(:timeout) == "The destination did not respond in time."

      assert DeliveryReason.label(:unknown) ==
               "The delivery failed — the server log has the transport detail."

      assert DeliveryReason.label({:http_status, 429}) ==
               "The channel rejected the message (HTTP 429)."
    end

    # THE INVERSE TRAP, and the reason a new class is never just a `label/1`
    # arm: `Delivery.changeset/2` clamps `last_error` to
    # `Enum.map(DeliveryReason.classes(), &DeliveryReason.label/1)` — DERIVED,
    # never hand-widened — so a sentence minted outside `classes/0` is rejected
    # and every Delivery insert carrying it becomes invalid.
    test "every class round-trips through the derived Delivery.changeset clamp" do
      for class <- DeliveryReason.classes() do
        changeset =
          Delivery.changeset(%Delivery{}, %{
            recipient: "census@example.com",
            event: "deployment_failed",
            status: "failed",
            last_error: DeliveryReason.label(class)
          })

        assert changeset.valid?,
               "#{inspect(class)} minted a sentence the clamp rejects: #{inspect(changeset.errors)}"
      end
    end

    test "a sentence outside the vocabulary is still rejected by that clamp" do
      changeset =
        Delivery.changeset(%Delivery{}, %{
          recipient: "census@example.com",
          event: "deployment_failed",
          status: "failed",
          last_error: "The destination did not offer a biscuit."
        })

      refute changeset.valid?
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
          "url" => "https://203.0.113.11/api/webhooks/1/abc"
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
