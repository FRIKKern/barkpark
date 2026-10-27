defmodule Barkpark.SetupDocsTest do
  # NOT async: the boot refusal tests set the env vars config/runtime.exs reads.
  use ExUnit.Case, async: false

  alias Barkpark.SetupDocs

  @repo Path.expand("../../..", __DIR__)
  @runtime_exs Path.join(@repo, "api/config/runtime.exs")
  @prefix "https://github.com/FRIKKern/barkpark/blob/main/"

  @prod_env %{
    "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET" => String.duplicate("r", 32),
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/ignored",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PREVIEW_JWT_SECRET" => String.duplicate("p", 32),
    "BARKPARK_CLOAK_KEY" => Base.encode64(String.duplicate("c", 32)),
    "BARKPARK_KEK" => Base.encode64(String.duplicate("k", 32)),
    "PHX_HOST" => "guerrilla.barkpark.cloud"
  }
  @other ~w(MEDIA_SIGNING_SECRET PHX_SCHEME PHX_PORT PORT DATABASE_SSL DATABASE_SSL_CA_FILE)

  # GitHub's heading slug: lower case, punctuation dropped, spaces to hyphens.
  defp anchors(md) do
    for "#" <> _ = line <- String.split(md, "\n"), into: MapSet.new() do
      line
      |> String.replace(~r/^#+\s*/, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9 _-]/u, "")
      |> String.replace(" ", "-")
    end
  end

  describe "links" do
    test "every link names a guide file and a heading that exist" do
      for {topic, url} <- SetupDocs.links() do
        assert String.starts_with?(url, @prefix), "#{topic}: #{url}"
        [path, anchor] = url |> String.replace_prefix(@prefix, "") |> String.split("#")
        file = Path.join(@repo, path)
        assert File.regular?(file), "#{topic}: #{path} does not exist"

        assert anchor in anchors(File.read!(file)),
               "#{topic}: ##{anchor} is not a heading in #{path}"
      end
    end

    test "api/entrypoint.sh links the media dir error to the same section" do
      script = File.read!(Path.join(@repo, "api/entrypoint.sh"))
      [block] = Regex.run(~r/if \[ ! -w \/app\/uploads \].*?\nfi\n/s, script)
      assert block =~ SetupDocs.url(:media_dir)
    end
  end

  describe "boot refusals carry a guide link" do
    setup do
      keys = Map.keys(@prod_env) ++ @other
      prev = Map.new(keys, fn k -> {k, System.get_env(k)} end)

      on_exit(fn ->
        Enum.each(prev, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end)

      Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
      Enum.each(@other, &System.delete_env/1)
      :ok
    end

    defp refusal(env) do
      Enum.each(env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      assert_raise RuntimeError, fn -> Config.Reader.read!(@runtime_exs, env: :prod) end
    end

    for {name, env, topic} <- [
          {"two required settings missing", %{"PHX_HOST" => nil, "BARKPARK_KEK" => nil},
           :settings_file},
          {"DATABASE_URL missing", %{"DATABASE_URL" => nil}, :settings_file},
          {"PHX_HOST missing", %{"PHX_HOST" => nil}, :host_name},
          {"PHX_HOST empty", %{"PHX_HOST" => ""}, :host_name},
          {"PHX_HOST is an IP", %{"PHX_HOST" => "20.1.2.3", "PHX_SCHEME" => "https"}, :host_name},
          {"SECRET_KEY_BASE short", %{"SECRET_KEY_BASE" => "short"}, :keys},
          {"BARKPARK_CLOAK_KEY missing", %{"BARKPARK_CLOAK_KEY" => nil}, :keys},
          {"BARKPARK_KEK missing", %{"BARKPARK_KEK" => nil}, :keys},
          {"BARKPARK_KEK malformed", %{"BARKPARK_KEK" => "abc"}, :keys},
          {"PREVIEW_JWT_SECRET missing", %{"PREVIEW_JWT_SECRET" => nil}, :keys},
          {"DATABASE_SSL unknown", %{"DATABASE_SSL" => "require"}, :database_tls},
          {"DATABASE_SSL_CA_FILE missing",
           %{"DATABASE_SSL" => "verify-full", "DATABASE_SSL_CA_FILE" => "/nonexistent/ca.pem"},
           :database_tls}
        ] do
      test name do
        err = refusal(unquote(Macro.escape(env)))
        assert err.message =~ SetupDocs.url(unquote(topic))
      end
    end

    test "the release-capture HMAC secret warning carries a guide link" do
      System.delete_env("BARKPARK_RELEASE_CAPTURE_HMAC_SECRET")

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          Config.Reader.read!(@runtime_exs, env: :prod)
        end)

      assert log =~ "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET must be at least 32 bytes"
      assert log =~ SetupDocs.url(:settings_file)
    end
  end

  test "the platform operator 403 hint carries a guide link" do
    hint = BarkparkWeb.Plugs.RequirePlatformOperator.grant_hint(%{id: "tok-1"})
    assert hint =~ "tok-1"
    assert hint =~ SetupDocs.url(:operator_access)
  end
end
