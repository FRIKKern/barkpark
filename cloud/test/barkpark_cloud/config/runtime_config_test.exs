defmodule BarkparkCloud.Config.RuntimeConfigTest do
  @moduledoc """
  isu-w5 — pins that the PROD runtime config actually wires the
  `:platform_admin_emails` allowlist from PLATFORM_ADMIN_EMAILS. Before this
  wiring existed, a release-built prod control plane had a permanently-empty
  allowlist (the config.exs default) and the daily fleet digest was a no-op
  FOREVER, no matter what an operator set — so this test evaluates the real
  `config/runtime.exs` prod block (via `Config.Reader`, exactly what a release
  boot does) rather than duplicating the parse logic.

  `async: false` — the test mutates real OS environment variables.
  """
  use ExUnit.Case, async: false

  # Every env var the test touches: the four hard-raise prod requirements, the
  # two that silence the partial-billing IO.warn, and the var under test.
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
      "DATABASE_URL" => "ecto://user:pass@localhost/runtime_config_test",
      "REGISTRY_ENCRYPTION_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
      "STRIPE_SECRET_KEY" => "sk_test_runtime_config_test",
      "OAUTH_STATE_SECRET" => "runtime-config-test-state-secret",
      "STRIPE_WEBHOOK_SECRET" => "whsec_runtime_config_test",
      "STRIPE_PRICE_SUPPORTER" => "price_runtime_config_test"
    })

    :ok
  end

  defp read_prod_admin_emails do
    "config/runtime.exs"
    |> Config.Reader.read!(env: :prod, target: :host)
    |> get_in([:barkpark_cloud, :platform_admin_emails])
  end

  test "PLATFORM_ADMIN_EMAILS is comma-split, trimmed, and blank-rejected" do
    System.put_env("PLATFORM_ADMIN_EMAILS", " ops@example.com, admin@example.com ,,")

    assert read_prod_admin_emails() == ["ops@example.com", "admin@example.com"]
  end

  test "an unset PLATFORM_ADMIN_EMAILS keeps the honest [] no-op" do
    System.delete_env("PLATFORM_ADMIN_EMAILS")

    assert read_prod_admin_emails() == []
  end
end
