defmodule BarkparkCloud.Config.InternalAllowedCidrsRuntimeTest do
  @moduledoc """
  dr-w24-bl-internal-write-route-is-publicly-reachable — the BOOT, driven.

  `internal_perimeter_test.exs` unit-tests `InternalPerimeter.load!/2`. This file
  proves the wiring around it: that the REAL `config/runtime.exs`, evaluated
  through `Config.Reader` exactly as a release boot does, refuses a prod boot
  when `INTERNAL_ALLOWED_CIDRS` was never declared, and lands the parsed ranges
  under `:internal_allowed_cidrs` when it was.

  Without this the fail-closed claim would rest on a `raise` nobody ever ran: a
  variable that never reaches the config file is exactly how the original defect
  shipped (see `runtime_config_test.exs`'s moduledoc — a prod control plane whose
  allowlist was permanently empty because the wiring did not exist).

  What this does NOT prove: that the variable reaches the CONTAINER. That is
  `cloud/docker-compose.yml`'s bare passthrough list, which no Elixir test can
  observe — it is called out as an owner step on the PR.

  `async: false` — it mutates real OS environment variables.
  """
  use ExUnit.Case, async: false

  # The prod block's hard-raise requirements, the two that silence the
  # partial-billing IO.warn, and the variable under test.
  @touched ~w(
    DATABASE_URL REGISTRY_ENCRYPTION_KEY STRIPE_SECRET_KEY OAUTH_STATE_SECRET
    STRIPE_WEBHOOK_SECRET STRIPE_PRICE_SUPPORTER INTERNAL_ALLOWED_CIDRS
  )

  setup do
    prior = Map.new(@touched, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- prior do
        if is_nil(value), do: System.delete_env(name), else: System.put_env(name, value)
      end
    end)

    System.put_env(%{
      "DATABASE_URL" => "ecto://user:pass@localhost/internal_cidrs_runtime_test",
      "REGISTRY_ENCRYPTION_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
      "STRIPE_SECRET_KEY" => "sk_test_internal_cidrs_runtime_test",
      "OAUTH_STATE_SECRET" => "internal-cidrs-runtime-test-state-secret",
      "STRIPE_WEBHOOK_SECRET" => "whsec_internal_cidrs_runtime_test",
      "STRIPE_PRICE_SUPPORTER" => "price_internal_cidrs_runtime_test"
    })

    :ok
  end

  defp read_prod do
    "config/runtime.exs"
    |> Config.Reader.read!(env: :prod, target: :host)
    |> get_in([:barkpark_cloud, :internal_allowed_cidrs])
  end

  test "a prod boot with the ranges declared carries them into config" do
    System.put_env("INTERNAL_ALLOWED_CIDRS", "203.0.113.7/32, 10.20.0.0/16")

    assert read_prod() == [{{203, 0, 113, 7}, 32}, {{10, 20, 0, 0}, 16}]
  end

  test "an UNDECLARED variable refuses the prod boot — it does not fall open" do
    System.delete_env("INTERNAL_ALLOWED_CIDRS")

    error = assert_raise(RuntimeError, fn -> read_prod() end)
    assert error.message =~ "INTERNAL_ALLOWED_CIDRS is missing"
  end

  test "the named opt-out is honoured, so an operator can decline the factor deliberately" do
    System.put_env("INTERNAL_ALLOWED_CIDRS", "any")

    assert read_prod() == :any
  end

  test "a malformed declaration refuses the boot rather than shrinking the fence" do
    System.put_env("INTERNAL_ALLOWED_CIDRS", "203.0.113.7/32,not-an-ip")

    assert_raise RuntimeError, ~r/not a valid IP address/, fn -> read_prod() end
  end

  test "control — this harness really is reading the prod block" do
    # If Config.Reader silently returned an empty keyword list (a moved file, a
    # renamed key), every assertion above would be vacuous. DATABASE_URL is a
    # value only the prod block writes.
    System.put_env("INTERNAL_ALLOWED_CIDRS", "any")

    repo =
      "config/runtime.exs"
      |> Config.Reader.read!(env: :prod, target: :host)
      |> get_in([:barkpark_cloud, BarkparkCloud.Repo])

    assert repo[:url] == "ecto://user:pass@localhost/internal_cidrs_runtime_test"
  end
end
