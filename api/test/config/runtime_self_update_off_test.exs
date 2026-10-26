defmodule Barkpark.Config.RuntimeSelfUpdateOffTest do
  # NOT async: mutates process-global env vars, Application env and the
  # Runner singleton.
  use ExUnit.Case, async: false

  alias Barkpark.SelfUpdate.Runner

  @runtime_exs Path.join(File.cwd!(), "config/runtime.exs")

  @prod_env %{
    "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET" => String.duplicate("r", 32),
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/ignored",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PREVIEW_JWT_SECRET" => String.duplicate("p", 32),
    "BARKPARK_CLOAK_KEY" => Base.encode64(String.duplicate("c", 32)),
    "BARKPARK_KEK" => Base.encode64(String.duplicate("k", 32)),
    "PHX_HOST" => "guerrilla.barkpark.cloud"
  }

  @self_update_vars ~w(BARKPARK_SELF_UPDATE_CHECK BARKPARK_SELF_UPDATE_APPLY BARKPARK_SELF_UPDATE_CD
                       BARKPARK_UPSTREAM_REPO BARKPARK_UPSTREAM_BRANCH BARKPARK_UPSTREAM_CHANNEL)

  setup do
    keys = Map.keys(@prod_env) ++ @self_update_vars
    prev_env = Map.new(keys, fn k -> {k, System.get_env(k)} end)
    prev_app = Map.new([Barkpark.SelfUpdate, Runner], &{&1, Application.get_env(:barkpark, &1)})

    on_exit(fn ->
      Enum.each(prev_env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      Enum.each(prev_app, fn {k, v} -> Application.put_env(:barkpark, k, v) end)
    end)

    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
    Enum.each(@self_update_vars, &System.delete_env/1)
    :ok
  end

  defp prod_config(env_vars) do
    Enum.each(env_vars, fn {k, v} -> System.put_env(k, v) end)
    Config.Reader.read!(@runtime_exs, env: :prod)[:barkpark]
  end

  test "prod checks for updates by default, so the off switch is needed on a pinned image" do
    assert prod_config(%{})[Barkpark.SelfUpdate][:enabled] == true
  end

  @tag :tmp_dir
  test "CHECK=off with APPLY unset starts no Checker, and the Runner refuses without running a command",
       %{tmp_dir: dir} do
    # The upstream vars are set to prove they do not switch anything back on.
    config =
      prod_config(%{
        "BARKPARK_SELF_UPDATE_CHECK" => "off",
        "BARKPARK_UPSTREAM_REPO" => "FRIKKern/barkpark",
        "BARKPARK_UPSTREAM_CHANNEL" => "tags"
      })

    assert config[Barkpark.SelfUpdate][:enabled] == false
    assert config[Runner][:enabled] == false

    Application.put_env(:barkpark, Barkpark.SelfUpdate, config[Barkpark.SelfUpdate])
    assert Barkpark.Application.self_update_children() == []

    marker = Path.join(dir, "ran")

    Application.put_env(
      :barkpark,
      Runner,
      Keyword.merge(Application.get_env(:barkpark, Runner, []),
        enabled: config[Runner][:enabled],
        command: {"sh", ["-c", "touch #{marker}"]},
        run_state_dir: dir
      )
    )

    assert Runner.trigger() == {:error, :disabled}
    assert Runner.trigger_rollback() == {:error, :disabled}
    Process.sleep(100)
    refute File.exists?(marker)
  end
end
