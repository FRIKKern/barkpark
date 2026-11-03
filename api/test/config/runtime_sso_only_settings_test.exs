defmodule Barkpark.Config.RuntimeSsoOnlySettingsTest do
  # NOT async: mutates the process-global env vars config/runtime.exs reads.
  use ExUnit.Case, async: false

  @runtime_exs Path.join(File.cwd!(), "config/runtime.exs")
  @keys ~w(BARKPARK_SIGNUP BARKPARK_MICROSOFT_TENANT)

  setup do
    prev = Map.new(@keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@keys, &System.delete_env/1)
    :ok
  end

  defp barkpark(env) do
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)
    @runtime_exs |> Config.Reader.read!(env: :test) |> Keyword.get(:barkpark, [])
  end

  test "signup stays open unless BARKPARK_SIGNUP is a false value" do
    refute Keyword.has_key?(barkpark(%{}), :signup)
    refute Keyword.has_key?(barkpark(%{"BARKPARK_SIGNUP" => "on"}), :signup)
    assert Keyword.get(barkpark(%{"BARKPARK_SIGNUP" => "off"}), :signup) == false
  end

  test "BARKPARK_MICROSOFT_TENANT sets the tenant; unset or blank leaves common" do
    refute Keyword.has_key?(barkpark(%{}), :microsoft_tenant)
    refute Keyword.has_key?(barkpark(%{"BARKPARK_MICROSOFT_TENANT" => "  "}), :microsoft_tenant)

    tenant = "11111111-2222-3333-4444-555555555555"

    assert Keyword.get(barkpark(%{"BARKPARK_MICROSOFT_TENANT" => tenant}), :microsoft_tenant) ==
             tenant
  end

  test "a tenant that is not an id or a domain refuses to boot" do
    assert_raise RuntimeError, ~r/BARKPARK_MICROSOFT_TENANT/, fn ->
      barkpark(%{"BARKPARK_MICROSOFT_TENANT" => "evil/../x"})
    end
  end
end
