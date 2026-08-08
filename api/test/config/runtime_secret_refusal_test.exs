defmodule Barkpark.Config.RuntimeSecretRefusalTest do
  # NOT async: mutates the process-global env vars config/runtime.exs reads
  # at eval time (same pattern as RuntimeUrlPortTest / RuntimeMailerTest).
  use ExUnit.Case, async: false

  @runtime_exs Path.join(File.cwd!(), "config/runtime.exs")

  # Boot refusals for the three session/crypto secrets (self-host-blessing
  # wave 1, S1c). The SECRET_KEY_BASE predicate is on the RAW env string —
  # at least 64 bytes, never trimmed, never base64-decoded: guerrilla's live
  # value is EXACTLY 64 raw bytes, so the measured boundary is 63 red /
  # 64 green and any stricter predicate would brick the next deploy.

  @prod_env %{
    "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET" => String.duplicate("r", 32),
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/ignored",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PREVIEW_JWT_SECRET" => String.duplicate("p", 32),
    "BARKPARK_CLOAK_KEY" => Base.encode64(String.duplicate("c", 32)),
    "BARKPARK_KEK" => Base.encode64(String.duplicate("k", 32)),
    "PHX_HOST" => "guerrilla.barkpark.cloud"
  }

  setup do
    keys = Map.keys(@prod_env) ++ ~w(MEDIA_SIGNING_SECRET PHX_SCHEME PHX_PORT PORT)
    prev = Map.new(keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
    Enum.each(~w(MEDIA_SIGNING_SECRET PHX_SCHEME PHX_PORT PORT), &System.delete_env/1)
    :ok
  end

  defp read!(env \\ %{}, config_env \\ :prod) do
    Enum.each(env, fn
      {k, nil} -> System.delete_env(k)
      {k, v} -> System.put_env(k, v)
    end)

    Config.Reader.read!(@runtime_exs, env: config_env)
  end

  describe "SECRET_KEY_BASE" do
    @skb_anchor "SECRET_KEY_BASE must be at least 64 bytes"

    test "63 raw bytes refuses at boot, citing the LENGTH, never the value" do
      short = String.duplicate("s", 63)

      err =
        assert_raise RuntimeError, fn ->
          read!(%{"SECRET_KEY_BASE" => short})
        end

      assert err.message =~ "#{@skb_anchor} (got 63 bytes)."
      refute err.message =~ short
    end

    test "unset refuses with the same anchor line" do
      err =
        assert_raise RuntimeError, fn ->
          read!(%{"SECRET_KEY_BASE" => nil})
        end

      assert err.message =~ "#{@skb_anchor} (it is not set)."
    end

    test "exactly 64 raw bytes boots (guerrilla live shape) and feeds BOTH consumers" do
      skb = String.duplicate("s", 64)
      config = read!()

      assert get_in(config, [:barkpark, BarkparkWeb.Endpoint, :secret_key_base]) == skb

      assert config[:barkpark][:media_signing_secret] ==
               Base.encode64(:crypto.hash(:sha256, "barkpark-media:" <> skb), padding: false)
    end

    test "dev env stays permissive — no refusal when unset outside prod" do
      config = read!(%{"SECRET_KEY_BASE" => nil}, :dev)
      assert get_in(config, [:barkpark, BarkparkWeb.Endpoint, :secret_key_base]) == nil
    end
  end

  describe "BARKPARK_KEK" do
    @kek_anchor "BARKPARK_KEK must be the base64 encoding of exactly 32 raw bytes."

    test "empty string refuses (base64-decodes to 0 bytes — the old bypass)" do
      err = assert_raise RuntimeError, fn -> read!(%{"BARKPARK_KEK" => ""}) end
      assert err.message =~ @kek_anchor
    end

    test "base64 of 31 bytes refuses" do
      err =
        assert_raise RuntimeError, fn ->
          read!(%{"BARKPARK_KEK" => Base.encode64(String.duplicate("k", 31))})
        end

      assert err.message =~ @kek_anchor
    end

    test "base64 of 33 bytes refuses" do
      err =
        assert_raise RuntimeError, fn ->
          read!(%{"BARKPARK_KEK" => Base.encode64(String.duplicate("k", 33))})
        end

      assert err.message =~ @kek_anchor
    end

    test "a value that is not valid base64 refuses" do
      err = assert_raise RuntimeError, fn -> read!(%{"BARKPARK_KEK" => "not base64!!"}) end
      assert err.message =~ @kek_anchor
    end

    test "base64 of exactly 32 bytes boots and configures LocalKek" do
      config = read!()

      assert get_in(config, [:barkpark, Barkpark.Crypto.LocalKek, :key]) ==
               Base.encode64(String.duplicate("k", 32))
    end

    test "a SET value is validated outside prod too (all envs — D12)" do
      err =
        assert_raise RuntimeError, fn ->
          read!(%{"BARKPARK_KEK" => Base.encode64(String.duplicate("k", 31))}, :dev)
        end

      assert err.message =~ @kek_anchor
    end

    test "unset outside prod stays permitted (nil branch prod-gated, unchanged)" do
      config = read!(%{"BARKPARK_KEK" => nil}, :dev)
      assert get_in(config, [:barkpark, Barkpark.Crypto.LocalKek]) == nil
    end
  end

  describe "PREVIEW_JWT_SECRET" do
    @preview_anchor "PREVIEW_JWT_SECRET must be set to a non-empty value."

    test "empty string refuses" do
      err = assert_raise RuntimeError, fn -> read!(%{"PREVIEW_JWT_SECRET" => ""}) end
      assert err.message =~ @preview_anchor
    end

    test "unset refuses" do
      err = assert_raise RuntimeError, fn -> read!(%{"PREVIEW_JWT_SECRET" => nil}) end
      assert err.message =~ @preview_anchor
    end

    test "any non-empty value passes — no byte floor (D13)" do
      config = read!(%{"PREVIEW_JWT_SECRET" => "x"})
      assert get_in(config, [:barkpark, :preview, :secret]) == "x"
    end
  end
end
