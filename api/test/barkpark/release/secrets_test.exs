defmodule Barkpark.Release.SecretsTest do
  use ExUnit.Case, async: true

  alias Barkpark.Release.Secrets

  describe "generate/0" do
    test "returns exactly the three crypto secret keys runtime.exs needs" do
      secrets = Secrets.generate()

      assert Map.keys(secrets) |> Enum.sort() == [
               "BARKPARK_CLOAK_KEY",
               "PREVIEW_JWT_SECRET",
               "SECRET_KEY_BASE"
             ]
    end

    test "decoded byte-lengths match the documented sizes" do
      secrets = Secrets.generate()

      assert byte_size(Base.decode64!(secrets["SECRET_KEY_BASE"])) == 64
      # PREVIEW_JWT_SECRET must be >= 64 bytes.
      assert byte_size(Base.decode64!(secrets["PREVIEW_JWT_SECRET"])) >= 64
      # Cloak needs a 32-byte key.
      assert byte_size(Base.decode64!(secrets["BARKPARK_CLOAK_KEY"])) == 32
    end

    test "secrets are independent of each other and random across calls" do
      a = Secrets.generate()
      b = Secrets.generate()

      # Independent generation: the cloak key is not derived from the key base.
      refute a["BARKPARK_CLOAK_KEY"] == a["SECRET_KEY_BASE"]
      # Fresh entropy on each call.
      refute a["SECRET_KEY_BASE"] == b["SECRET_KEY_BASE"]
      refute a["BARKPARK_CLOAK_KEY"] == b["BARKPARK_CLOAK_KEY"]
    end
  end

  describe "write_env/1" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "barkpark-secrets-test-#{System.unique_integer([:positive])}"
        )

      path = Path.join(tmp, ".env")
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, path: path, tmp: tmp}
    end

    test "creates the file with the 3 secrets + 2 placeholders", %{path: path} do
      assert {:ok, ^path} = Secrets.write_env(path)
      assert File.exists?(path)

      env = parse_env(path)

      assert byte_size(Base.decode64!(env["SECRET_KEY_BASE"])) == 64
      assert byte_size(Base.decode64!(env["PREVIEW_JWT_SECRET"])) >= 64
      assert byte_size(Base.decode64!(env["BARKPARK_CLOAK_KEY"])) == 32

      # Placeholders use the exact var names runtime.exs reads.
      assert Map.has_key?(env, "DATABASE_URL")
      assert Map.has_key?(env, "PHX_HOST")
      assert env["PHX_HOST"] == "localhost"
      assert String.starts_with?(env["DATABASE_URL"], "ecto://")
    end

    test "chmods the file to 0600", %{path: path} do
      {:ok, ^path} = Secrets.write_env(path)
      %File.Stat{mode: mode} = File.stat!(path)
      # Mask off the file-type bits, keep the permission bits.
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "is idempotent: a second call never clobbers a hand-set value", %{path: path} do
      {:ok, ^path} = Secrets.write_env(path)

      first = parse_env(path)
      original_key_base = first["SECRET_KEY_BASE"]

      # Hand-edit a value, as a user filling in their real database URL.
      hand_set_db = "ecto://me:hunter2@db.example.com/barkpark_prod"

      rewritten =
        path
        |> File.read!()
        |> String.replace(~r/^DATABASE_URL=.*$/m, "DATABASE_URL=#{hand_set_db}")

      File.write!(path, rewritten)

      # Second call must not touch existing keys.
      {:ok, ^path} = Secrets.write_env(path)

      second = parse_env(path)
      assert second["DATABASE_URL"] == hand_set_db
      assert second["SECRET_KEY_BASE"] == original_key_base
    end

    test "tops up only missing keys when the file is partial", %{path: path, tmp: tmp} do
      File.mkdir_p!(tmp)
      File.write!(path, "SECRET_KEY_BASE=preexisting-do-not-touch\n")

      {:ok, ^path} = Secrets.write_env(path)

      env = parse_env(path)
      # Pre-existing key survives verbatim.
      assert env["SECRET_KEY_BASE"] == "preexisting-do-not-touch"
      # Missing ones are filled in.
      assert byte_size(Base.decode64!(env["BARKPARK_CLOAK_KEY"])) == 32
      assert byte_size(Base.decode64!(env["PREVIEW_JWT_SECRET"])) >= 64
      assert Map.has_key?(env, "DATABASE_URL")
      assert Map.has_key?(env, "PHX_HOST")
    end
  end

  # Minimal .env reader for assertions — splits on the first `=` per line.
  defp parse_env(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)
      {String.trim(k), v}
    end)
  end
end
