defmodule Barkpark.Config.RuntimeDatabaseSslTest do
  # NOT async: mutates the process-global env vars config/runtime.exs reads at
  # eval time (same pattern as RuntimeObanPoolSizeTest).
  use ExUnit.Case, async: false

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

  @ssl_vars ~w(DATABASE_SSL DATABASE_SSL_CA_FILE)

  setup do
    keys = Map.keys(@prod_env) ++ @ssl_vars
    prev = Map.new(keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
    Enum.each(@ssl_vars, &System.delete_env/1)
    :ok
  end

  defp repo_config(env_vars) do
    Enum.each(env_vars, fn {k, v} -> System.put_env(k, v) end)

    @runtime_exs
    |> Config.Reader.read!(env: :prod)
    |> get_in([:barkpark, Barkpark.Repo])
  end

  test "unset or off adds no :ssl option, so existing boxes connect as before" do
    refute Keyword.has_key?(repo_config(%{}), :ssl)
    refute Keyword.has_key?(repo_config(%{"DATABASE_SSL" => "off"}), :ssl)
  end

  test "verify-full without a CA file uses Postgrex's verifying defaults over the OS store" do
    assert repo_config(%{"DATABASE_SSL" => "verify-full"})[:ssl] == true
  end

  @tag :tmp_dir
  test "verify-full with a CA file pins that file", %{tmp_dir: dir} do
    ca = Path.join(dir, "ca.pem")
    File.write!(ca, "")

    assert repo_config(%{"DATABASE_SSL" => "verify-full", "DATABASE_SSL_CA_FILE" => ca})[:ssl] ==
             [cacertfile: ca]
  end

  test "an unknown mode or a missing CA file refuses boot" do
    assert_raise RuntimeError, ~r/DATABASE_SSL is "require"/, fn ->
      repo_config(%{"DATABASE_SSL" => "require"})
    end

    assert_raise RuntimeError, ~r/DATABASE_SSL_CA_FILE/, fn ->
      repo_config(%{
        "DATABASE_SSL" => "verify-full",
        "DATABASE_SSL_CA_FILE" => "/nonexistent.pem"
      })
    end
  end

  # A Postgres-shaped TLS endpoint: answers SSLRequest with "S", then offers a
  # certificate from a CA the client was NOT given. The connection must fail on
  # certificate verification, with an error that says so.
  @tag :tmp_dir
  test "a CA file that does not match the server certificate fails the connection with a TLS error",
       %{tmp_dir: dir} do
    rsa = [key: {:rsa, 2048, 65_537}]
    chain = %{root: rsa, intermediates: [], peer: rsa}
    served = :public_key.pkix_test_data(%{server_chain: chain, client_chain: chain})
    other = :public_key.pkix_test_data(%{server_chain: chain, client_chain: chain})

    ca = Path.join(dir, "other-ca.pem")
    other_root = List.last(other.client_config[:cacerts])
    File.write!(ca, :public_key.pem_encode([{:Certificate, other_root, :not_encrypted}]))

    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server =
      Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)
        {:ok, <<8::32, 80_877_103::32>>} = :gen_tcp.recv(sock, 8, 5_000)
        :ok = :gen_tcp.send(sock, "S")

        :ssl.handshake(sock, served.server_config, 5_000)
      end)

    ssl =
      repo_config(%{"DATABASE_SSL" => "verify-full", "DATABASE_SSL_CA_FILE" => ca})[:ssl]

    assert {:error, %DBConnection.ConnectionError{message: message}} =
             Postgrex.Protocol.connect(
               hostname: "localhost",
               port: port,
               username: "postgres",
               database: "ignored",
               types: Postgrex.DefaultTypes,
               timeout: 5_000,
               ssl: ssl
             )

    assert message =~ "ssl connect"
    assert message =~ ~r/unknown.?ca/i
    assert {:error, _} = Task.await(server)
    :gen_tcp.close(listen)
  end
end
