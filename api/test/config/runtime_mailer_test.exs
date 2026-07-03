defmodule Barkpark.Config.RuntimeMailerTest do
  # NOT async: each test mutates the process-global SMTP_* env vars that
  # config/runtime.exs reads at eval time.
  use ExUnit.Case, async: false

  @runtime_exs Path.join(File.cwd!(), "config/runtime.exs")

  setup do
    # Snapshot + clear every SMTP_* var so the surrounding shell can't leak into
    # the assertions; restore verbatim afterwards.
    keys = ~w(SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_VERIFY_PEER)
    prev = Map.new(keys, fn k -> {k, System.get_env(k)} end)
    Enum.each(keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end

  # Evaluate the real runtime.exs and read back the Barkpark.Mailer keyword list
  # it produced (nil when the file left it untouched). The mailer block is
  # unguarded (runs in every config_env), so we eval as :test — that skips the
  # prod-only block below it, which raises on missing BARKPARK_CLOAK_KEY etc.
  defp mailer_config do
    @runtime_exs
    |> Config.Reader.read!(env: :test)
    |> get_in([:barkpark, Barkpark.Mailer])
  end

  test "SMTP_HOST unset leaves Barkpark.Mailer untouched (falls back to compile-time adapter)" do
    # runtime.exs must NOT set the adapter — so config.exs's Local (dev/prod) or
    # test.exs's Test survives. A nil here == 'no runtime override'.
    assert mailer_config() == nil
  end

  test "SMTP_HOST set selects the SMTP adapter with the relay + default port" do
    System.put_env("SMTP_HOST", "relay.example.test")

    cfg = mailer_config()

    assert cfg[:adapter] == Swoosh.Adapters.SMTP
    assert cfg[:relay] == "relay.example.test"
    # Default port when SMTP_PORT is unset.
    assert cfg[:port] == 587
    # No creds → no username/password keys, auth is opportunistic.
    refute Keyword.has_key?(cfg, :username)
    refute Keyword.has_key?(cfg, :password)
    assert cfg[:auth] == :if_available
    # Peer verification is ON by default.
    assert cfg[:tls_options][:verify] == :verify_peer
  end

  test "SMTP_PORT overrides the default port" do
    System.put_env("SMTP_HOST", "relay.example.test")
    System.put_env("SMTP_PORT", "2525")

    assert mailer_config()[:port] == 2525
  end

  test "SMTP_USERNAME/PASSWORD wire credentials and force auth" do
    System.put_env("SMTP_HOST", "relay.example.test")
    System.put_env("SMTP_USERNAME", "postmaster@barkpark.cloud")
    System.put_env("SMTP_PASSWORD", "s3cr3t")

    cfg = mailer_config()

    assert cfg[:username] == "postmaster@barkpark.cloud"
    assert cfg[:password] == "s3cr3t"
    assert cfg[:auth] == :always
  end

  test "SMTP_VERIFY_PEER=false disables TLS peer verification" do
    System.put_env("SMTP_HOST", "postfix.internal")
    System.put_env("SMTP_VERIFY_PEER", "false")

    assert mailer_config()[:tls_options][:verify] == :verify_none
  end
end
