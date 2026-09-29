defmodule BarkparkCloud.Config.AzureTransportWiringTest do
  @moduledoc """
  task-2772b2cdd5001bfc — pins that the PROD runtime config actually wires a
  transport for the `BarkparkCloud.Azure` key, the one
  `BarkparkCloud.Azure.RealClient.request/1` resolves at call time.

  Before this wiring, that key was set in NO environment. RealClient fails
  closed with `{:error, :http_client_not_configured}` when it is absent, so in
  prod `Azure.verify/1` and `Azure.list_catalog/1` could never succeed:
  `GET /v1/providers/azure/overview` and `…/catalog` were a flat 502
  `catalog_unavailable` for every connected azure provider, and an azure service
  principal could not be verified at all. Nothing in the suite noticed, because
  dev/test select `Azure.FakeClient` at the module seam and never reach the key.

  So this test evaluates the REAL `config/runtime.exs` prod block via
  `Config.Reader` — exactly what a release boot does — instead of asserting that
  a code path exists. Delete the two runtime.exs lines and this file reds.

  `async: false` — the test mutates real OS environment variables.
  """
  use ExUnit.Case, async: false

  @touched ~w(
    DATABASE_URL REGISTRY_ENCRYPTION_KEY STRIPE_SECRET_KEY OAUTH_STATE_SECRET
    STRIPE_WEBHOOK_SECRET STRIPE_PRICE_SUPPORTER PLATFORM_ADMIN_EMAILS
  )

  setup do
    prior = Map.new(@touched, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- prior do
        if is_nil(value), do: System.delete_env(name), else: System.put_env(name, value)
      end
    end)

    System.put_env(%{
      "DATABASE_URL" => "ecto://user:pass@localhost/azure_transport_wiring_test",
      "REGISTRY_ENCRYPTION_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
      "STRIPE_SECRET_KEY" => "sk_test_azure_transport_wiring_test",
      "OAUTH_STATE_SECRET" => "azure-transport-wiring-test-state-secret",
      "STRIPE_WEBHOOK_SECRET" => "whsec_azure_transport_wiring_test",
      "STRIPE_PRICE_SUPPORTER" => "price_azure_transport_wiring_test"
    })

    :ok
  end

  defp runtime(env), do: Config.Reader.read!("config/runtime.exs", env: env, target: :host)
  defp transport(config, key), do: get_in(config, [:barkpark_cloud, key])[:http_client]

  describe "the credential Azure client's transport" do
    test "prod wires a 1-arity fun for the BarkparkCloud.Azure key" do
      client = transport(runtime(:prod), BarkparkCloud.Azure)

      assert is_function(client, 1),
             "BarkparkCloud.Azure[:http_client] is #{inspect(client)} in the prod " <>
               "runtime config — RealClient.request/1 needs a 1-arity fun or every " <>
               "ARM call returns {:error, :http_client_not_configured}"

      assert client == (&BarkparkCloud.Billing.HttpClient.request/1)
    end

    test "CONTROL: the sibling Pricing key is read the same way and is also wired" do
      # Proves the reader sees the real file and that the assertion above is not
      # vacuous — a per-key read that already finds a DIFFERENT configured Azure
      # transport is not a read that finds nothing.
      assert is_function(transport(runtime(:prod), BarkparkCloud.Azure.Pricing), 1)
    end

    test "CONTROL: the wiring is prod-only — dev/test get no runtime.exs transport" do
      # Discriminates the prod block from the config.exs default: if the arm
      # above were reading a key set for every environment, this would fail.
      for env <- [:dev, :test] do
        assert get_in(runtime(env), [:barkpark_cloud, BarkparkCloud.Azure]) == nil
      end
    end

    test "CONTROL: an unrelated config change leaves the azure transport alone" do
      # The regression arm is key-scoped, not a whole-file snapshot: moving an
      # unrelated prod config value must not red it.
      System.put_env("PLATFORM_ADMIN_EMAILS", "ops@example.com")
      before = transport(runtime(:prod), BarkparkCloud.Azure)

      System.put_env("PLATFORM_ADMIN_EMAILS", "someone-else@example.com, third@example.com")
      after_change = runtime(:prod)

      assert get_in(after_change, [:barkpark_cloud, :platform_admin_emails]) == [
               "someone-else@example.com",
               "third@example.com"
             ]

      assert transport(after_change, BarkparkCloud.Azure) == before
    end
  end

  describe "the non-prod defaults" do
    test "dev and test both select Azure.FakeClient at the module seam" do
      # The recorded decision for this row: azure.ex's moduledoc claimed dev
      # swapped in the fake; until task-2772b2cdd5001bfc only test.exs did.
      for env <- [:dev, :test] do
        config = Config.Reader.read!("config/config.exs", env: env, target: :host)

        assert get_in(config, [:barkpark_cloud, :azure_http_client]) ==
                 BarkparkCloud.Azure.FakeClient,
               "#{env} must resolve the in-memory Azure client — it has no tenant"
      end
    end

    test "the compile-time default for the credential key is nil (fail closed)" do
      config = Config.Reader.read!("config/config.exs", env: :test, target: :host)

      assert get_in(config, [:barkpark_cloud, BarkparkCloud.Azure]) == [http_client: nil]
    end
  end
end
