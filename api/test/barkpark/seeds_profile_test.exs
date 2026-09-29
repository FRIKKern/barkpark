defmodule Barkpark.SeedsProfileTest do
  # async: false — the cases write BARKPARK_SEED_PROFILE and the
  # :default_seed_profile app env, both process-global.
  use ExUnit.Case, async: false

  alias Barkpark.Seeds

  setup do
    prev_env = System.get_env("BARKPARK_SEED_PROFILE")
    prev_cfg = Application.fetch_env(:barkpark, :default_seed_profile)
    System.delete_env("BARKPARK_SEED_PROFILE")
    Application.delete_env(:barkpark, :default_seed_profile)

    on_exit(fn ->
      if prev_env,
        do: System.put_env("BARKPARK_SEED_PROFILE", prev_env),
        else: System.delete_env("BARKPARK_SEED_PROFILE")

      case prev_cfg do
        {:ok, value} -> Application.put_env(:barkpark, :default_seed_profile, value)
        :error -> Application.delete_env(:barkpark, :default_seed_profile)
      end
    end)

    :ok
  end

  test "with nothing set, a fresh Barkpark seeds the clean profile" do
    assert Seeds.profile() == "clean"
  end

  test "the configured default applies when the variable is unset" do
    Application.put_env(:barkpark, :default_seed_profile, "demo")
    assert Seeds.profile() == "demo"
  end

  test "an empty variable counts as unset" do
    System.put_env("BARKPARK_SEED_PROFILE", "")
    assert Seeds.profile() == "clean"
  end

  test "the variable wins over the configured default" do
    Application.put_env(:barkpark, :default_seed_profile, "demo")
    System.put_env("BARKPARK_SEED_PROFILE", "clean")
    assert Seeds.profile() == "clean"
  end

  test "an unknown profile still reaches run/0's refusal instead of a default" do
    System.put_env("BARKPARK_SEED_PROFILE", "sample")
    assert Seeds.profile() == "sample"
    assert_raise RuntimeError, ~r/must be clean or demo/, fn -> Seeds.run() end
  end
end
